// SPDX-License-Identifier: Apache-2.0

import Atomics
import CoreAudio
import Foundation

/// A validation or capacity failure while preparing realtime source fan-out.
public enum AudioRealtimeFrameDistributorError: Error, Equatable, LocalizedError, Sendable {
  /// The requested subscriber bound is outside the supported range.
  case invalidSubscriberCount(Int)

  /// Preallocating every subscriber queue would exceed the aggregate storage bound.
  case excessiveStorage(
    channelCount: Int,
    capacityFrameCount: Int,
    maximumSubscriberCount: Int
  )

  /// Every prepared subscriber slot is currently active.
  case subscriberLimitReached(Int)

  /// A human-readable explanation suitable for application diagnostics.
  public var errorDescription: String? {
    switch self {
    case .invalidSubscriberCount(let count):
      "A realtime distributor must prepare between 1 and 64 subscriber slots; received \(count)."
    case .excessiveStorage(let channelCount, let capacityFrameCount, let subscriberCount):
      "Realtime fan-out storage for \(channelCount) channels, \(capacityFrameCount) frames, and \(subscriberCount) subscribers exceeds the bounded allocation limit."
    case .subscriberLimitReached(let count):
      "All \(count) prepared realtime subscriber slots are in use."
    }
  }
}

/// The result of publishing one source quantum to every active subscription.
public struct AudioRealtimeFrameDistributionResult: Equatable, Sendable {
  /// The source frame count offered to each active subscriber.
  public let requestedFrameCount: Int

  /// The subscriptions active during this publication.
  public let activeSubscriberCount: Int

  /// The smallest frame count accepted by any active subscriber queue.
  ///
  /// This is zero when there are no subscribers or when every active queue is full.
  public let minimumWrittenFrameCount: Int

  /// The largest frame count accepted by any active subscriber queue.
  public let maximumWrittenFrameCount: Int
}

/// The result of reading from one independently paced realtime subscription.
public enum AudioRealtimeFrameSubscriptionReadResult: Equatable, Sendable {
  /// Audio was copied and any unavailable tail was explicitly silenced.
  case read(frameCount: Int, silencedFrameCount: Int)

  /// The subscription has been cancelled or its slot has been safely reused.
  case inactive

  /// The requested frame count was negative.
  case invalidFrameCount

  /// The caller supplied fewer channel pointers than the prepared format requires.
  case insufficientChannels
}

/// A diagnostic snapshot for one independently paced realtime subscription.
public struct AudioRealtimeFrameSubscriptionStatistics: Equatable, Sendable {
  /// Whether the subscription still owns its prepared slot.
  public let isActive: Bool

  /// The underlying bounded SPSC queue diagnostics.
  public let frameBuffer: AudioRealtimeFrameBufferStatistics
}

/// A bounded single-source, multiple-consumer distributor for planar Float32 PCM.
///
/// Subscriber queues are allocated during initialization. The producer copies each source quantum
/// only to currently active slots and never allocates, locks, logs, or invokes application code.
/// Every subscription owns one SPSC queue, so a slow workflow cannot consume another workflow's
/// cursor or make two render clocks race on one ``AudioRealtimeFrameBuffer``.
public final class AudioRealtimeFrameDistributor: @unchecked Sendable {
  /// The largest supported subscriber bound.
  public static let maximumSubscriberCountLimit = 64

  /// The largest aggregate allocation, measured in Float32 samples.
  public static let maximumAggregateSampleCapacity = 8_388_608

  /// The immutable PCM format shared by every subscriber queue.
  public let format: AudioProcessingFormat

  /// The fixed queue capacity prepared for each subscriber.
  public let capacityFrameCount: Int

  /// The fixed number of independently paced subscribers that can be active.
  public let maximumSubscriberCount: Int

  private let subscriptionLock = NSLock()
  private let slots: [AudioRealtimeFrameDistributionSlot]

  /// Preallocates every bounded subscriber queue away from realtime work.
  public init(
    format: AudioProcessingFormat,
    capacityFrameCount: Int = AudioRealtimeFrameBuffer.defaultCapacityFrameCount,
    maximumSubscriberCount: Int = 4
  ) throws {
    guard (1...Self.maximumSubscriberCountLimit).contains(maximumSubscriberCount) else {
      throw AudioRealtimeFrameDistributorError.invalidSubscriberCount(maximumSubscriberCount)
    }
    let perSubscriber = format.channelCount.multipliedReportingOverflow(by: capacityFrameCount)
    let aggregate = perSubscriber.partialValue.multipliedReportingOverflow(
      by: maximumSubscriberCount
    )
    guard !perSubscriber.overflow, !aggregate.overflow,
      aggregate.partialValue <= Self.maximumAggregateSampleCapacity
    else {
      throw AudioRealtimeFrameDistributorError.excessiveStorage(
        channelCount: format.channelCount,
        capacityFrameCount: capacityFrameCount,
        maximumSubscriberCount: maximumSubscriberCount
      )
    }
    self.format = format
    self.capacityFrameCount = capacityFrameCount
    self.maximumSubscriberCount = maximumSubscriberCount
    slots = try (0..<maximumSubscriberCount).map { _ in
      try AudioRealtimeFrameDistributionSlot(
        format: format,
        capacityFrameCount: capacityFrameCount
      )
    }
  }

  /// How many subscriptions are reading right now.
  public var activeSubscriberCount: Int {
    slots.reduce(0) { $0 + ($1.isClaimed ? 1 : 0) }
  }

  /// The frames queued for whichever reader has fewest, or `nil` when nothing is reading.
  ///
  /// The reader closest to running dry is the one that decides how urgent a gap is, so this is
  /// what a producer asks when it has to decide whether there is still time to recover one.
  public var minimumAvailableFrameCount: Int? {
    slots.lazy.filter(\.isClaimed).map(\.availableFrameCount).min()
  }

  /// Claims one independently paced subscriber queue.
  ///
  /// Subscription management may lock and must not run on an audio callback. Cancelling a
  /// subscription makes its slot reusable; a stale subscription can never read from a later owner.
  public func subscribe() throws -> AudioRealtimeFrameSubscription {
    try subscriptionLock.withLock {
      for slot in slots where slot.canBeClaimed {
        let generation = slot.claim()
        return AudioRealtimeFrameSubscription(slot: slot, generation: generation)
      }
      throw AudioRealtimeFrameDistributorError.subscriberLimitReached(maximumSubscriberCount)
    }
  }

  /// Claims one subscriber queue and paces it against the reader's own clock.
  ///
  /// What a network source has to give several destinations at once. Each one reads on a different
  /// clock, so each needs its own measured target: a single jitter buffer can only hold the amount
  /// that suits one reader, and correcting the queue for that reader is wrong for every other.
  ///
  /// The subscription stays inside the returned buffer. Nothing else can reach it to cancel, so the
  /// slot cannot be released and handed to another subscriber while this buffer is still reading
  /// it; releasing the buffer releases the slot.
  public func subscribeWithJitterBuffer(
    configuration: AudioJitterBufferConfiguration = .localNetwork,
    maximumFrameCount: Int = 4_096
  ) throws -> AudioJitterBuffer {
    let subscription = try subscribe()
    do {
      return try AudioJitterBuffer(
        frameBuffer: subscription.frameBuffer,
        queueOwner: subscription,
        configuration: configuration,
        maximumFrameCount: maximumFrameCount
      )
    } catch {
      subscription.cancel()
      throw error
    }
  }

  /// Publishes caller-owned planar Float32 PCM to every active subscriber.
  ///
  /// Calls for one distributor must be serialized on exactly one producer thread. This method is
  /// realtime-safe after initialization.
  @discardableResult
  public func writePlanar(
    _ inputChannels: UnsafeBufferPointer<UnsafePointer<Float>>,
    frameCount: Int
  ) -> AudioRealtimeFrameDistributionResult {
    distribute(requestedFrameCount: frameCount) { frameBuffer in
      frameBuffer.writePlanar(inputChannels, frameCount: frameCount)
    }
  }

  /// Publishes caller-owned interleaved Float32 PCM to every active subscriber.
  ///
  /// Calls for one distributor must be serialized on exactly one producer thread. This method is
  /// realtime-safe after initialization.
  @discardableResult
  public func writeInterleaved(
    _ samples: UnsafePointer<Float>,
    channelCount: Int,
    frameCount: Int
  ) -> AudioRealtimeFrameDistributionResult {
    distribute(requestedFrameCount: frameCount) { frameBuffer in
      frameBuffer.writeInterleaved(
        samples,
        channelCount: channelCount,
        frameCount: frameCount
      )
    }
  }

  @discardableResult
  package func write(_ list: UnsafePointer<AudioBufferList>)
    -> AudioRealtimeFrameDistributionResult
  {
    let frameCount = AudioRealtimeFrameDistributor.frameCount(in: list)
    return distribute(requestedFrameCount: frameCount) { frameBuffer in
      frameBuffer.write(list)
    }
  }

  private func distribute(
    requestedFrameCount: Int,
    write: (AudioRealtimeFrameBuffer) -> Int
  ) -> AudioRealtimeFrameDistributionResult {
    var activeSubscriberCount = 0
    var minimumWrittenFrameCount = Int.max
    var maximumWrittenFrameCount = 0
    for slot in slots {
      guard slot.beginProduction() else { continue }
      let writtenFrameCount = write(slot.frameBuffer)
      slot.endProduction()
      activeSubscriberCount += 1
      minimumWrittenFrameCount = min(minimumWrittenFrameCount, writtenFrameCount)
      maximumWrittenFrameCount = max(maximumWrittenFrameCount, writtenFrameCount)
    }
    return AudioRealtimeFrameDistributionResult(
      requestedFrameCount: requestedFrameCount,
      activeSubscriberCount: activeSubscriberCount,
      minimumWrittenFrameCount: activeSubscriberCount == 0 ? 0 : minimumWrittenFrameCount,
      maximumWrittenFrameCount: maximumWrittenFrameCount
    )
  }

  private static func frameCount(in list: UnsafePointer<AudioBufferList>) -> Int {
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
    var result = Int.max
    for buffer in buffers where buffer.mNumberChannels > 0 && buffer.mData != nil {
      result = min(
        result,
        Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride / Int(buffer.mNumberChannels)
      )
    }
    return result == .max ? 0 : result
  }
}

/// One independently paced consumer of an ``AudioRealtimeFrameDistributor``.
public final class AudioRealtimeFrameSubscription: @unchecked Sendable {
  /// The immutable PCM format supplied by the distributor.
  public let format: AudioProcessingFormat

  /// The fixed queue capacity dedicated to this subscription.
  public let capacityFrameCount: Int

  private let slot: AudioRealtimeFrameDistributionSlot
  private let generation: UInt64
  private let cancellationLock = NSLock()
  private var didCancel = false

  package var frameBuffer: AudioRealtimeFrameBuffer {
    slot.frameBuffer
  }

  fileprivate init(slot: AudioRealtimeFrameDistributionSlot, generation: UInt64) {
    self.slot = slot
    self.generation = generation
    format = slot.frameBuffer.format
    capacityFrameCount = slot.frameBuffer.capacityFrameCount
  }

  deinit {
    cancel()
  }

  /// Reads one bounded render quantum and zero-fills any unavailable tail.
  ///
  /// Calls for one subscription must be serialized on exactly one consumer thread.
  @discardableResult
  public func read(
    into outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRealtimeFrameSubscriptionReadResult {
    guard slot.beginConsumption(generation: generation) else { return .inactive }
    let result = slot.frameBuffer.read(into: outputChannels, frameCount: frameCount)
    slot.endConsumption()
    switch result {
    case .read(let frameCount, let silencedFrameCount):
      return .read(frameCount: frameCount, silencedFrameCount: silencedFrameCount)
    case .invalidFrameCount:
      return .invalidFrameCount
    case .insufficientChannels:
      return .insufficientChannels
    }
  }

  /// Discards an old queued prefix while retaining the newest bounded tail.
  ///
  /// Calls must be serialized with ``read(into:frameCount:)`` on the same consumer thread.
  @discardableResult
  public func discardOldestFrames(keepingLatest retainedFrameCount: Int) -> Int {
    guard slot.beginConsumption(generation: generation) else { return 0 }
    let result = slot.frameBuffer.discardOldestFrames(keepingLatest: retainedFrameCount)
    slot.endConsumption()
    return result
  }

  /// Returns lock-free queue diagnostics and the current ownership state.
  public func statistics() -> AudioRealtimeFrameSubscriptionStatistics {
    AudioRealtimeFrameSubscriptionStatistics(
      isActive: slot.isActive(generation: generation),
      frameBuffer: slot.frameBuffer.statistics()
    )
  }

  /// Releases this subscription's slot.
  ///
  /// Repeated calls are harmless. Cancellation may lock and must not run on an audio callback.
  public func cancel() {
    cancellationLock.withLock {
      guard !didCancel else { return }
      didCancel = true
      slot.cancel(generation: generation)
    }
  }
}

private final class AudioRealtimeFrameDistributionSlot: @unchecked Sendable {
  let frameBuffer: AudioRealtimeFrameBuffer

  var isClaimed: Bool { active.load(ordering: .acquiring) }

  var availableFrameCount: Int { frameBuffer.statistics().availableFrameCount }

  private let active = ManagedAtomic<Bool>(false)
  private let generation = ManagedAtomic<UInt64>(0)
  private let producerInFlight = ManagedAtomic<Int>(0)
  private let consumerInFlight = ManagedAtomic<Int>(0)

  init(format: AudioProcessingFormat, capacityFrameCount: Int) throws {
    frameBuffer = try AudioRealtimeFrameBuffer(
      format: format,
      capacityFrameCount: capacityFrameCount
    )
  }

  var canBeClaimed: Bool {
    !active.load(ordering: .acquiring)
      && producerInFlight.load(ordering: .acquiring) == 0
      && consumerInFlight.load(ordering: .acquiring) == 0
  }

  func claim() -> UInt64 {
    precondition(canBeClaimed)
    _ = frameBuffer.discardOldestFrames(keepingLatest: 0)
    let nextGeneration = generation.load(ordering: .relaxed) &+ 1
    generation.store(nextGeneration, ordering: .releasing)
    active.store(true, ordering: .releasing)
    return nextGeneration
  }

  func cancel(generation expectedGeneration: UInt64) {
    guard generation.load(ordering: .acquiring) == expectedGeneration else { return }
    active.store(false, ordering: .releasing)
  }

  func isActive(generation expectedGeneration: UInt64) -> Bool {
    active.load(ordering: .acquiring)
      && generation.load(ordering: .acquiring) == expectedGeneration
  }

  func beginProduction() -> Bool {
    guard active.load(ordering: .acquiring) else { return false }
    producerInFlight.wrappingIncrement(ordering: .acquiring)
    guard active.load(ordering: .acquiring) else {
      producerInFlight.wrappingDecrement(ordering: .releasing)
      return false
    }
    return true
  }

  func endProduction() {
    producerInFlight.wrappingDecrement(ordering: .releasing)
  }

  func beginConsumption(generation expectedGeneration: UInt64) -> Bool {
    guard isActive(generation: expectedGeneration) else { return false }
    consumerInFlight.wrappingIncrement(ordering: .acquiring)
    guard isActive(generation: expectedGeneration) else {
      consumerInFlight.wrappingDecrement(ordering: .releasing)
      return false
    }
    return true
  }

  func endConsumption() {
    consumerInFlight.wrappingDecrement(ordering: .releasing)
  }
}
