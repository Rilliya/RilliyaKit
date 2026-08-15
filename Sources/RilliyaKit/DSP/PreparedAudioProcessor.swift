// SPDX-License-Identifier: Apache-2.0

import Atomics
import Foundation

/// The result of one bounded realtime processing call.
public enum AudioRenderResult: Equatable, Sendable {
  /// Every requested frame and channel was processed.
  case rendered

  /// The requested frame count exceeded the processor's prepared storage.
  case invalidFrameCount

  /// The caller supplied fewer channel pointers than the prepared format requires.
  case insufficientChannels
}

/// A prepared processor that can run without allocating, locking, or invoking user callbacks.
///
/// Implementations are prepared away from the realtime thread. Calls to `process` for one instance
/// must be serialized on a single render thread; control updates may arrive concurrently.
public protocol PreparedAudioProcessor: AnyObject, Sendable {
  /// The immutable format and frame bound used to prepare this processor.
  var preparation: AudioRenderPreparation { get }

  /// Latency, intentional delay, and tail behavior reported to a graph compiler.
  var timing: AudioNodeTiming { get }

  /// Processes noninterleaved Float32 PCM into caller-owned output storage.
  ///
  /// Input and output may alias for in-place processing. The pointer collections and their sample
  /// storage must remain valid for the duration of this call.
  @discardableResult
  func process(
    inputChannels: UnsafeBufferPointer<UnsafePointer<Float>>,
    outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRenderResult
}

/// One channel's atomically published gain and mute controls.
public struct AudioChannelGainControl: Equatable, Sendable {
  /// The largest accepted linear gain, equivalent to approximately +24.1 dB.
  public static let maximumLinearGain: Float = 16

  /// Linear amplitude applied to this channel before mute state.
  public let linearGain: Float

  /// Whether the channel should ramp to silence.
  public let isMuted: Bool

  /// Creates a validated channel control value.
  public init(linearGain: Float = 1, isMuted: Bool = false) throws {
    guard linearGain.isFinite else {
      throw AudioDSPConfigurationError.nonfiniteGain
    }
    guard (0...Self.maximumLinearGain).contains(linearGain) else {
      throw AudioDSPConfigurationError.invalidChannelGain(linearGain)
    }
    self.linearGain = linearGain
    self.isMuted = isMuted
  }

  fileprivate init(validatedLinearGain: Float, isMuted: Bool) {
    linearGain = validatedLinearGain
    self.isMuted = isMuted
  }

  fileprivate var effectiveGain: Float {
    isMuted ? 0 : linearGain
  }
}

/// A validation failure while addressing a channel-control bank.
public enum AudioChannelControlError: Error, Equatable, LocalizedError, Sendable {
  /// The requested channel is outside the prepared bank.
  case channelOutOfRange(Int)

  /// A localized description of the invalid channel address.
  public var errorDescription: String? {
    switch self {
    case .channelOutOfRange(let channel):
      return "Channel \(channel) is outside this audio control bank."
    }
  }
}

/// Thread-safe channel controls for one prepared audio path.
///
/// Each channel is represented by one lock-free atomic word. UI and control threads can update a
/// bank while a prepared processor reads it on a realtime thread.
public final class AudioChannelGainControlBank: @unchecked Sendable {
  private final class Slot: @unchecked Sendable {
    let value: ManagedAtomic<UInt64>

    init(_ control: AudioChannelGainControl) {
      value = ManagedAtomic(AudioChannelGainControlBank.pack(control))
    }
  }

  /// The fixed number of channels in this bank.
  public let channelCount: Int

  private let slots: [Slot]

  /// Creates a bank initialized to unity gain with every channel unmuted.
  public init(channelCount: Int) throws {
    guard (1...AudioProcessingFormat.maximumChannelCount).contains(channelCount) else {
      throw AudioDSPConfigurationError.invalidChannelCount(channelCount)
    }
    self.channelCount = channelCount
    let initial = try AudioChannelGainControl()
    slots = (0..<channelCount).map { _ in Slot(initial) }
  }

  /// Returns the latest atomically published value for one channel.
  public func control(at channel: Int) throws -> AudioChannelGainControl {
    try slot(at: channel).value.load(ordering: .relaxed).control
  }

  /// Atomically replaces gain and mute state for one channel.
  public func setControl(_ control: AudioChannelGainControl, at channel: Int) throws {
    try slot(at: channel).value.store(Self.pack(control), ordering: .relaxed)
  }

  /// Atomically changes one channel's linear gain without altering mute state.
  public func setLinearGain(_ linearGain: Float, at channel: Int) throws {
    let current = try control(at: channel)
    try setControl(
      AudioChannelGainControl(linearGain: linearGain, isMuted: current.isMuted),
      at: channel
    )
  }

  /// Atomically changes one channel's mute state without altering its stored gain.
  public func setMuted(_ isMuted: Bool, at channel: Int) throws {
    let current = try control(at: channel)
    try setControl(
      AudioChannelGainControl(linearGain: current.linearGain, isMuted: isMuted),
      at: channel
    )
  }

  func effectiveGain(at channel: Int) -> Float {
    slots[channel].value.load(ordering: .relaxed).control.effectiveGain
  }

  private func slot(at channel: Int) throws -> Slot {
    guard slots.indices.contains(channel) else {
      throw AudioChannelControlError.channelOutOfRange(channel)
    }
    return slots[channel]
  }

  private static func pack(_ control: AudioChannelGainControl) -> UInt64 {
    UInt64(control.linearGain.bitPattern) | (control.isMuted ? UInt64(1) << 32 : 0)
  }
}

extension UInt64 {
  fileprivate var control: AudioChannelGainControl {
    AudioChannelGainControl(
      validatedLinearGain: Float(bitPattern: UInt32(truncatingIfNeeded: self)),
      isMuted: self & (UInt64(1) << 32) != 0
    )
  }
}

/// A click-free, channel-independent gain processor.
///
/// The processor owns one reusable gain envelope and per-channel ramp state. Its render method does
/// not allocate, lock, log, or perform reference-counted callback work.
public final class PreparedAudioChannelGainProcessor: PreparedAudioProcessor,
  @unchecked Sendable
{
  /// The immutable preparation used by this processor.
  public let preparation: AudioRenderPreparation

  /// Gain processing is transparent and has no tail.
  public let timing = AudioNodeTiming.transparent

  /// Atomically updateable controls read by the render thread.
  public let controls: AudioChannelGainControlBank

  private let rampDurationFrames: Int
  private let envelope: UnsafeMutablePointer<Float>
  private var rampStates: [AudioGainRampState]

  /// Creates a prepared gain processor with a five-millisecond smoothing ramp by default.
  public init(
    preparation: AudioRenderPreparation,
    controls: AudioChannelGainControlBank? = nil,
    rampDurationSeconds: Double = 0.005
  ) throws {
    guard rampDurationSeconds.isFinite, rampDurationSeconds >= 0 else {
      throw AudioDSPConfigurationError.invalidTiming
    }
    let controls =
      try controls
      ?? AudioChannelGainControlBank(
        channelCount: preparation.format.channelCount
      )
    guard controls.channelCount == preparation.format.channelCount else {
      throw AudioDSPConfigurationError.invalidChannelCount(controls.channelCount)
    }
    let requestedRampFrames = rampDurationSeconds * preparation.format.sampleRate
    guard requestedRampFrames.isFinite, requestedRampFrames <= Double(Int.max) else {
      throw AudioDSPConfigurationError.invalidTiming
    }
    self.preparation = preparation
    self.controls = controls
    rampDurationFrames = max(0, Int(requestedRampFrames.rounded()))
    envelope = .allocate(capacity: preparation.maximumFrameCount)
    envelope.initialize(repeating: 1, count: preparation.maximumFrameCount)
    rampStates = (0..<preparation.format.channelCount).map { channel in
      AudioGainRampState(gain: controls.effectiveGain(at: channel))
    }
  }

  deinit {
    envelope.deinitialize(count: preparation.maximumFrameCount)
    envelope.deallocate()
  }

  /// Applies the latest channel controls to one bounded planar Float32 render quantum.
  @discardableResult
  public func process(
    inputChannels: UnsafeBufferPointer<UnsafePointer<Float>>,
    outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRenderResult {
    guard (0...preparation.maximumFrameCount).contains(frameCount) else {
      return .invalidFrameCount
    }
    let channelCount = preparation.format.channelCount
    guard inputChannels.count >= channelCount, outputChannels.count >= channelCount else {
      return .insufficientChannels
    }
    guard frameCount > 0 else { return .rendered }

    for channel in 0..<channelCount {
      let targetGain = controls.effectiveGain(at: channel)
      if targetGain != rampStates[channel].targetGain {
        rampStates[channel].setTarget(targetGain, durationFrames: rampDurationFrames)
      }
      rampStates[channel].writeEnvelope(to: envelope, frameCount: frameCount)
      AudioGainDSP.apply(
        input: inputChannels[channel],
        envelope: UnsafePointer(envelope),
        output: outputChannels[channel],
        frameCount: frameCount
      )
    }
    return .rendered
  }
}
