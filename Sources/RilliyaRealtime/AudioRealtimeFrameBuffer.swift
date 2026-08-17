// SPDX-License-Identifier: Apache-2.0

import Atomics
import CoreAudio
import Foundation

/// A validation failure while preparing bounded realtime PCM storage.
public enum AudioRealtimeFrameBufferError: Error, Equatable, LocalizedError, Sendable {
  /// The requested frame capacity is outside the supported bound.
  case invalidCapacity(Int)

  /// The requested channel and frame capacity would exceed the storage bound.
  case excessiveStorage(channelCount: Int, capacityFrameCount: Int)

  /// A localized description of the invalid buffer configuration.
  public var errorDescription: String? {
    switch self {
    case .invalidCapacity(let capacity):
      return "Realtime audio capacity must be between 2 and 65,536 frames; received \(capacity)."
    case .excessiveStorage(let channelCount, let capacityFrameCount):
      return
        "Realtime audio storage for \(channelCount) channels and \(capacityFrameCount) frames exceeds the bounded allocation limit."
    }
  }
}

/// The result of one realtime PCM read.
public enum AudioRealtimeFrameBufferReadResult: Equatable, Sendable {
  /// Audio was copied and any missing tail was explicitly silenced.
  case read(frameCount: Int, silencedFrameCount: Int)

  /// The requested frame count was negative.
  case invalidFrameCount

  /// The caller supplied fewer channel pointers than the prepared format requires.
  case insufficientChannels
}

/// Monotonic diagnostics for a bounded realtime PCM buffer.
public struct AudioRealtimeFrameBufferStatistics: Equatable, Sendable {
  /// Frames accepted from the capture producer.
  public let writtenFrameCount: UInt64

  /// Frames delivered to the render consumer.
  public let readFrameCount: UInt64

  /// New capture frames dropped because the bounded buffer was full.
  public let droppedFrameCount: UInt64

  /// Old capture frames discarded by the consumer to restore its latency bound.
  public let discardedFrameCount: UInt64

  /// Render frames replaced with silence because capture data was unavailable.
  public let silencedFrameCount: UInt64

  /// Frames currently available to the single consumer.
  public let availableFrameCount: Int
}

/// A bounded single-producer, single-consumer buffer for planar Float32 PCM.
///
/// Core Audio capture writes into this buffer without allocating, locking, logging, or invoking a
/// user callback. One realtime render consumer may call ``read(into:frameCount:)`` concurrently.
/// New frames are dropped when storage is full; reads always silence an unavailable tail. These
/// policies keep latency and memory bounded instead of moving either failure onto the audio thread.
///
/// The buffer does not perform sample-rate conversion or clock-drift correction. A graph compiler
/// must place an explicit converter between sources and destinations that do not share one clock.
public final class AudioRealtimeFrameBuffer: @unchecked Sendable {
  /// The default capacity used by native captures.
  public static let defaultCapacityFrameCount = 4_096

  /// The largest accepted frame capacity.
  public static let maximumCapacityFrameCount = 65_536

  /// The largest allocation, measured in Float32 samples, accepted by one buffer.
  public static let maximumSampleCapacity = 4_194_304

  /// The noninterleaved Float32 format stored by this buffer.
  public let format: AudioProcessingFormat

  /// The fixed number of frames retained for each channel.
  public let capacityFrameCount: Int

  private let storage: UnsafeMutablePointer<Float>
  private let writePosition = ManagedAtomic<UInt64>(0)
  private let readPosition = ManagedAtomic<UInt64>(0)
  private let writtenFrameCount = ManagedAtomic<UInt64>(0)
  private let readFrameCount = ManagedAtomic<UInt64>(0)
  private let droppedFrameCount = ManagedAtomic<UInt64>(0)
  private let discardedFrameCount = ManagedAtomic<UInt64>(0)
  private let silencedFrameCount = ManagedAtomic<UInt64>(0)

  /// Prepares fixed PCM storage away from the realtime thread.
  public init(
    format: AudioProcessingFormat,
    capacityFrameCount: Int = AudioRealtimeFrameBuffer.defaultCapacityFrameCount
  ) throws {
    guard (2...Self.maximumCapacityFrameCount).contains(capacityFrameCount) else {
      throw AudioRealtimeFrameBufferError.invalidCapacity(capacityFrameCount)
    }
    let (sampleCapacity, overflowed) = format.channelCount.multipliedReportingOverflow(
      by: capacityFrameCount
    )
    guard !overflowed, sampleCapacity <= Self.maximumSampleCapacity else {
      throw AudioRealtimeFrameBufferError.excessiveStorage(
        channelCount: format.channelCount,
        capacityFrameCount: capacityFrameCount
      )
    }
    self.format = format
    self.capacityFrameCount = capacityFrameCount
    storage = .allocate(capacity: sampleCapacity)
    storage.initialize(repeating: 0, count: sampleCapacity)
  }

  deinit {
    storage.deinitialize(count: format.channelCount * capacityFrameCount)
    storage.deallocate()
  }

  /// Reads one bounded render quantum into caller-owned planar channels.
  ///
  /// Calls for one instance must come from one serialized consumer. Missing frames are zero-filled,
  /// allowing an output callback to remain deterministic during startup or capture starvation.
  @discardableResult
  public func read(
    into outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRealtimeFrameBufferReadResult {
    copyFrames(into: outputChannels, frameCount: frameCount, advances: true)
  }

  /// Copies frames without consuming them, so a caller can inspect audio before deciding how
  /// much of it to take.
  ///
  /// Calls must come from the same single consumer as ``read(into:frameCount:)``.
  @discardableResult
  public func peek(
    into outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRealtimeFrameBufferReadResult {
    copyFrames(into: outputChannels, frameCount: frameCount, advances: false)
  }

  /// Consumes frames the caller has already inspected.
  ///
  /// - Returns: the frames actually consumed, which is bounded by what is available.
  @discardableResult
  public func advance(frameCount: Int) -> Int {
    guard frameCount > 0 else { return 0 }
    let read = readPosition.load(ordering: .relaxed)
    let write = writePosition.load(ordering: .acquiring)
    let available = min(frameDistance(from: read, to: write), capacityFrameCount)
    let consumed = min(frameCount, available)
    guard consumed > 0 else { return 0 }
    readPosition.store(read &+ UInt64(consumed), ordering: .releasing)
    add(consumed, to: readFrameCount)
    return consumed
  }

  private func copyFrames(
    into outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int,
    advances: Bool
  ) -> AudioRealtimeFrameBufferReadResult {
    guard frameCount >= 0 else { return .invalidFrameCount }
    guard outputChannels.count >= format.channelCount else { return .insufficientChannels }
    guard frameCount > 0 else { return .read(frameCount: 0, silencedFrameCount: 0) }

    let read = readPosition.load(ordering: .relaxed)
    let write = writePosition.load(ordering: .acquiring)
    let available = min(frameDistance(from: read, to: write), capacityFrameCount)
    let copiedFrameCount = min(frameCount, available)
    let silenced = frameCount - copiedFrameCount
    let start = Int(read % UInt64(capacityFrameCount))
    let firstSpanCount = min(copiedFrameCount, capacityFrameCount - start)
    let secondSpanCount = copiedFrameCount - firstSpanCount

    for channel in 0..<format.channelCount {
      let channelStorage = storage.advanced(by: channel * capacityFrameCount)
      if firstSpanCount > 0 {
        outputChannels[channel].update(
          from: channelStorage.advanced(by: start),
          count: firstSpanCount
        )
      }
      if secondSpanCount > 0 {
        outputChannels[channel].advanced(by: firstSpanCount).update(
          from: channelStorage,
          count: secondSpanCount
        )
      }
      if silenced > 0 {
        outputChannels[channel].advanced(by: copiedFrameCount).update(
          repeating: 0,
          count: silenced
        )
      }
    }

    if advances {
      readPosition.store(read &+ UInt64(copiedFrameCount), ordering: .releasing)
      add(copiedFrameCount, to: readFrameCount)
      add(silenced, to: silencedFrameCount)
    }
    return .read(frameCount: copiedFrameCount, silencedFrameCount: silenced)
  }

  /// Returns a lock-free diagnostic snapshot away from the realtime thread.
  public func statistics() -> AudioRealtimeFrameBufferStatistics {
    let read = readPosition.load(ordering: .acquiring)
    let write = writePosition.load(ordering: .acquiring)
    return AudioRealtimeFrameBufferStatistics(
      writtenFrameCount: writtenFrameCount.load(ordering: .relaxed),
      readFrameCount: readFrameCount.load(ordering: .relaxed),
      droppedFrameCount: droppedFrameCount.load(ordering: .relaxed),
      discardedFrameCount: discardedFrameCount.load(ordering: .relaxed),
      silencedFrameCount: silencedFrameCount.load(ordering: .relaxed),
      availableFrameCount: min(frameDistance(from: read, to: write), capacityFrameCount)
    )
  }

  /// Discards the oldest queued frames while retaining a bounded live tail.
  ///
  /// Calls for one instance must be serialized with ``read(into:frameCount:)`` on the same single
  /// consumer thread. The producer may continue writing concurrently. This operation copies no
  /// samples and is safe for a realtime render thread.
  @discardableResult
  public func discardOldestFrames(keepingLatest retainedFrameCount: Int) -> Int {
    let retainedFrameCount = min(max(retainedFrameCount, 0), capacityFrameCount)
    let read = readPosition.load(ordering: .relaxed)
    let write = writePosition.load(ordering: .acquiring)
    let available = min(frameDistance(from: read, to: write), capacityFrameCount)
    let discarded = max(available - retainedFrameCount, 0)
    guard discarded > 0 else { return 0 }

    readPosition.store(read &+ UInt64(discarded), ordering: .releasing)
    add(discarded, to: discardedFrameCount)
    return discarded
  }

  @discardableResult
  package func write(_ list: UnsafePointer<AudioBufferList>) -> Int {
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
    var availableChannelCount = 0
    var sourceFrameCount = Int.max
    for buffer in buffers {
      let localChannelCount = Int(buffer.mNumberChannels)
      guard localChannelCount > 0, buffer.mData != nil else { continue }
      availableChannelCount += localChannelCount
      sourceFrameCount = min(
        sourceFrameCount,
        Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride / localChannelCount
      )
    }
    guard availableChannelCount >= format.channelCount,
      sourceFrameCount != Int.max,
      sourceFrameCount > 0
    else {
      return 0
    }

    return writeFrames(frameCount: sourceFrameCount) { channel, sourceOffset, destination, count in
      var flattenedStart = 0
      for buffer in buffers {
        let localChannelCount = Int(buffer.mNumberChannels)
        let flattenedEnd = flattenedStart + localChannelCount
        defer { flattenedStart = flattenedEnd }
        guard (flattenedStart..<flattenedEnd).contains(channel),
          let samples = buffer.mData?.assumingMemoryBound(to: Float.self)
        else {
          continue
        }
        let localChannel = channel - flattenedStart
        copyStrided(
          from: samples.advanced(by: sourceOffset * localChannelCount + localChannel),
          stride: localChannelCount,
          to: destination,
          count: count
        )
        return
      }
    }
  }

  /// Writes caller-owned planar Float32 PCM from the buffer's single producer.
  ///
  /// This method is realtime-safe after both the source pointers and this buffer have been
  /// prepared. Calls for one instance must be serialized on exactly one producer thread.
  @discardableResult
  public func writePlanar(
    _ inputChannels: UnsafeBufferPointer<UnsafePointer<Float>>,
    frameCount: Int
  ) -> Int {
    guard inputChannels.count >= format.channelCount, frameCount > 0 else { return 0 }
    return writeFrames(frameCount: frameCount) { channel, sourceOffset, destination, count in
      destination.update(from: inputChannels[channel].advanced(by: sourceOffset), count: count)
    }
  }

  /// Writes caller-owned interleaved Float32 PCM from the buffer's single producer.
  ///
  /// This method is realtime-safe after this buffer has been prepared. Calls for one instance
  /// must be serialized on exactly one producer thread.
  @discardableResult
  public func writeInterleaved(
    _ samples: UnsafePointer<Float>,
    channelCount: Int,
    frameCount: Int
  ) -> Int {
    guard channelCount >= format.channelCount, frameCount > 0 else { return 0 }
    return writeFrames(frameCount: frameCount) { channel, sourceOffset, destination, count in
      copyStrided(
        from: samples.advanced(by: sourceOffset * channelCount + channel),
        stride: channelCount,
        to: destination,
        count: count
      )
    }
  }

  private func writeFrames(
    frameCount: Int,
    copyChannel: (
      _ channel: Int,
      _ sourceOffset: Int,
      _ destination: UnsafeMutablePointer<Float>,
      _ count: Int
    ) -> Void
  ) -> Int {
    let write = writePosition.load(ordering: .relaxed)
    let read = readPosition.load(ordering: .acquiring)
    let occupied = min(frameDistance(from: read, to: write), capacityFrameCount)
    let copiedFrameCount = min(frameCount, capacityFrameCount - occupied)
    let dropped = frameCount - copiedFrameCount
    guard copiedFrameCount > 0 else {
      add(dropped, to: droppedFrameCount)
      return 0
    }

    let start = Int(write % UInt64(capacityFrameCount))
    let firstSpanCount = min(copiedFrameCount, capacityFrameCount - start)
    let secondSpanCount = copiedFrameCount - firstSpanCount
    for channel in 0..<format.channelCount {
      let channelStorage = storage.advanced(by: channel * capacityFrameCount)
      copyChannel(channel, 0, channelStorage.advanced(by: start), firstSpanCount)
      if secondSpanCount > 0 {
        copyChannel(channel, firstSpanCount, channelStorage, secondSpanCount)
      }
    }

    writePosition.store(write &+ UInt64(copiedFrameCount), ordering: .releasing)
    add(copiedFrameCount, to: writtenFrameCount)
    add(dropped, to: droppedFrameCount)
    return copiedFrameCount
  }

  private func frameDistance(from start: UInt64, to end: UInt64) -> Int {
    Int(min(end &- start, UInt64(Int.max)))
  }

  private func add(_ value: Int, to counter: ManagedAtomic<UInt64>) {
    guard value > 0 else { return }
    counter.store(
      counter.load(ordering: .relaxed) &+ UInt64(value),
      ordering: .relaxed
    )
  }
}

private func copyStrided(
  from source: UnsafePointer<Float>,
  stride: Int,
  to destination: UnsafeMutablePointer<Float>,
  count: Int
) {
  precondition(stride > 0)
  guard count > 0 else { return }
  if stride == 1 {
    destination.update(from: source, count: count)
    return
  }
  for index in 0..<count {
    destination[index] = source[index * stride]
  }
}
