// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A validation failure for jitter buffer controls.
public enum AudioJitterBufferError: Error, Equatable, LocalizedError, Sendable {
  /// The latency bounds are not ordered, or the target sits outside them.
  case invalidLatencyRange

  /// A latency bound cannot be represented in the buffer's storage.
  case latencyExceedsCapacity(Duration)

  /// A localized explanation suitable for diagnostics.
  public var errorDescription: String? {
    switch self {
    case .invalidLatencyRange:
      "The jitter buffer needs a target latency between its minimum and maximum."
    case .latencyExceedsCapacity(let latency):
      "The jitter buffer cannot hold \(latency) of audio."
    }
  }
}

/// Bounded controls for one receive-side jitter buffer.
public struct AudioJitterBufferConfiguration: Equatable, Hashable, Sendable {
  /// A wired local network needs only a couple of packets of slack.
  public static let localNetworkTarget = Duration.milliseconds(5)

  /// The controls a wired local network uses.
  public static let localNetwork = AudioJitterBufferConfiguration(
    validatedTargetLatency: localNetworkTarget,
    minimumLatency: .milliseconds(2),
    maximumLatency: .milliseconds(200),
    underrunPenalty: .milliseconds(3),
    trimFraction: 0.05,
    resynchronizationThreshold: .milliseconds(500)
  )

  /// The latency the buffer aims to hold once it settles.
  public let targetLatency: Duration

  /// The floor the buffer will not trim below.
  public let minimumLatency: Duration

  /// The ceiling beyond which arriving audio is dropped rather than queued.
  public let maximumLatency: Duration

  /// How much one underrun raises the target.
  public let underrunPenalty: Duration

  /// How much of the surplus one trim removes, as a fraction.
  ///
  /// Trimming a fraction rather than the whole surplus turns a step in delay into a slow ramp,
  /// which is inaudible where an abrupt correction is not.
  public let trimFraction: Double

  /// A silence longer than this is treated as a new stream rather than something to conceal.
  public let resynchronizationThreshold: Duration

  /// Creates validated controls.
  public init(
    targetLatency: Duration = AudioJitterBufferConfiguration.localNetworkTarget,
    minimumLatency: Duration = .milliseconds(2),
    maximumLatency: Duration = .milliseconds(200),
    underrunPenalty: Duration = .milliseconds(3),
    trimFraction: Double = 0.05,
    resynchronizationThreshold: Duration = .milliseconds(500)
  ) throws {
    guard minimumLatency >= .zero,
      minimumLatency <= targetLatency,
      targetLatency <= maximumLatency,
      underrunPenalty >= .zero,
      trimFraction > 0,
      trimFraction <= 1,
      resynchronizationThreshold > .zero
    else {
      throw AudioJitterBufferError.invalidLatencyRange
    }
    self.targetLatency = targetLatency
    self.minimumLatency = minimumLatency
    self.maximumLatency = maximumLatency
    self.underrunPenalty = underrunPenalty
    self.trimFraction = trimFraction
    self.resynchronizationThreshold = resynchronizationThreshold
  }

  private init(
    validatedTargetLatency targetLatency: Duration,
    minimumLatency: Duration,
    maximumLatency: Duration,
    underrunPenalty: Duration,
    trimFraction: Double,
    resynchronizationThreshold: Duration
  ) {
    self.targetLatency = targetLatency
    self.minimumLatency = minimumLatency
    self.maximumLatency = maximumLatency
    self.underrunPenalty = underrunPenalty
    self.trimFraction = trimFraction
    self.resynchronizationThreshold = resynchronizationThreshold
  }
}

/// Monotonic diagnostics for one jitter buffer.
public struct AudioJitterBufferStatistics: Equatable, Sendable {
  /// Whether the buffer has filled enough to start playing.
  public let isPlaying: Bool

  /// The latency the buffer currently aims to hold, in frames.
  public let targetFrameCount: Int

  /// The frames queued right now.
  public let availableFrameCount: Int

  /// Reads that found less audio than they asked for.
  public let underrunCount: UInt64

  /// Frames dropped because the queue ran past the ceiling.
  public let trimmedFrameCount: UInt64

  /// Times the buffer gave up on the stream and refilled from empty.
  public let resynchronizationCount: UInt64
}

/// Holds a target amount of received audio so a render callback has something to read when the
/// network runs late.
///
/// Reading straight from a receive queue drains it to empty and keeps it there: every read takes
/// whatever arrived and silences the rest, so each late packet inserts a gap and the stream never
/// recovers the time. Worse, the silence is itself latency the stream never gives back. This
/// holds a measured target instead, raising it when reads run dry and trimming it back slowly.
///
/// One producer writes and one consumer reads, as with the buffer it wraps.
public final class AudioJitterBuffer: @unchecked Sendable {
  /// The queue this buffer paces.
  public let frameBuffer: AudioRealtimeFrameBuffer

  /// The controls in effect.
  public let configuration: AudioJitterBufferConfiguration

  private let minimumFrameCount: Int
  private let maximumFrameCount: Int
  private let underrunPenaltyFrameCount: Int
  private let resynchronizationFrameCount: Int
  private var targetFrameCount: Int
  private var isPlaying = false
  private var underrunCount: UInt64 = 0
  private var trimmedFrameCount: UInt64 = 0
  private var resynchronizationCount: UInt64 = 0
  private var silentReadFrameCount = 0

  /// Prepares a jitter buffer over an existing receive queue.
  public init(
    frameBuffer: AudioRealtimeFrameBuffer,
    configuration: AudioJitterBufferConfiguration = .localNetwork
  ) throws {
    let sampleRate = frameBuffer.format.sampleRate
    func frames(_ duration: Duration) -> Int {
      Int((Double(duration.wholeNanoseconds) / 1_000_000_000 * sampleRate).rounded())
    }
    let maximumFrameCount = frames(configuration.maximumLatency)
    guard maximumFrameCount <= frameBuffer.capacityFrameCount else {
      throw AudioJitterBufferError.latencyExceedsCapacity(configuration.maximumLatency)
    }
    self.frameBuffer = frameBuffer
    self.configuration = configuration
    minimumFrameCount = frames(configuration.minimumLatency)
    self.maximumFrameCount = maximumFrameCount
    underrunPenaltyFrameCount = max(frames(configuration.underrunPenalty), 1)
    resynchronizationFrameCount = frames(configuration.resynchronizationThreshold)
    targetFrameCount = frames(configuration.targetLatency)
  }

  /// Reads one render quantum, holding silence until the buffer has filled to its target.
  ///
  /// Calls for one instance must come from one serialized consumer, as with the underlying queue.
  @discardableResult
  public func read(
    into outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRealtimeFrameBufferReadResult {
    guard frameCount >= 0 else { return .invalidFrameCount }
    guard outputChannels.count >= frameBuffer.format.channelCount else {
      return .insufficientChannels
    }
    let available = frameBuffer.statistics().availableFrameCount

    if !isPlaying {
      guard available >= targetFrameCount, available >= frameCount else {
        silence(outputChannels, frameCount: frameCount)
        silentReadFrameCount += frameCount
        if silentReadFrameCount >= resynchronizationFrameCount, available == 0 {
          silentReadFrameCount = 0
        }
        return .read(frameCount: 0, silencedFrameCount: frameCount)
      }
      isPlaying = true
      silentReadFrameCount = 0
    }

    if available < frameCount {
      // The stream ran dry. Raise the target so the next fill has more slack, and refill from
      // empty rather than handing out a gap the stream would never make up.
      underrunCount &+= 1
      targetFrameCount = min(targetFrameCount + underrunPenaltyFrameCount, maximumFrameCount)
      isPlaying = false
      if available == 0 {
        resynchronizationCount &+= 1
      }
      silence(outputChannels, frameCount: frameCount)
      return .read(frameCount: 0, silencedFrameCount: frameCount)
    }

    if available > targetFrameCount + frameCount {
      let surplus = available - targetFrameCount
      let trim = max(Int(Double(surplus) * configuration.trimFraction), 1)
      let dropped = frameBuffer.discardOldestFrames(keepingLatest: available - trim)
      trimmedFrameCount &+= UInt64(dropped)
    }
    return frameBuffer.read(into: outputChannels, frameCount: frameCount)
  }

  /// Discards everything queued and refills from empty.
  public func resynchronize() {
    frameBuffer.discardOldestFrames(keepingLatest: 0)
    isPlaying = false
    silentReadFrameCount = 0
    resynchronizationCount &+= 1
  }

  /// Returns bounded diagnostics.
  public func statistics() -> AudioJitterBufferStatistics {
    AudioJitterBufferStatistics(
      isPlaying: isPlaying,
      targetFrameCount: targetFrameCount,
      availableFrameCount: frameBuffer.statistics().availableFrameCount,
      underrunCount: underrunCount,
      trimmedFrameCount: trimmedFrameCount,
      resynchronizationCount: resynchronizationCount
    )
  }

  private func silence(
    _ outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) {
    guard frameCount > 0 else { return }
    for channel in 0..<frameBuffer.format.channelCount {
      outputChannels[channel].update(repeating: 0, count: frameCount)
    }
  }
}
