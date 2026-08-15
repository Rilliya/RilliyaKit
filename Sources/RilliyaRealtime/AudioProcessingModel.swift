// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The result of one bounded realtime rendering or processing call.
public enum AudioRenderResult: Equatable, Sendable {
  /// Every requested frame and channel was rendered or processed.
  case rendered

  /// The requested frame count exceeded the prepared storage.
  case invalidFrameCount

  /// The caller supplied fewer channel pointers than the prepared format requires.
  case insufficientChannels
}

/// A validation failure for a realtime audio-processing configuration.
public enum AudioDSPConfigurationError: Error, Equatable, LocalizedError, Sendable {
  /// A sample rate must be finite and greater than zero.
  case invalidSampleRate(Double)

  /// A channel count must be within the library's supported planar-audio bound.
  case invalidChannelCount(Int)

  /// A render quantum must contain a positive, bounded number of frames.
  case invalidMaximumFrameCount(Int)

  /// A channel route references a negative input or channel index.
  case invalidChannelRoute

  /// A gain value must be finite.
  case nonfiniteGain

  /// A user-facing channel gain must remain within the safe realtime control range.
  case invalidChannelGain(Float)

  /// A signal generator frequency must be finite, positive, and below Nyquist.
  case invalidGeneratorFrequency(Double)

  /// A signal generator amplitude must be finite and remain within full scale.
  case invalidGeneratorAmplitude(Float)

  /// A delay duration must be finite and remain within the prepared processor's bound.
  case invalidDelayDuration(Double)

  /// Delay feedback must be finite and remain below self-oscillation.
  case invalidDelayFeedback(Float)

  /// A dry/wet mix must be finite and remain between dry and wet.
  case invalidDryWetMix(Float)

  /// A delay line would exceed the library's bounded storage budget.
  case delayStorageTooLarge(Int)

  /// A noise-gate threshold must be a finite full-scale decibel value.
  case invalidNoiseGateThreshold(Float)

  /// Noise-gate hysteresis must be finite and remain within the supported range.
  case invalidNoiseGateHysteresis(Float)

  /// A noise-gate attack duration must be finite and bounded.
  case invalidNoiseGateAttack(Double)

  /// A noise-gate hold duration must be finite and bounded.
  case invalidNoiseGateHold(Double)

  /// A noise-gate release duration must be finite and bounded.
  case invalidNoiseGateRelease(Double)

  /// Closed-gate attenuation must be finite and bounded.
  case invalidNoiseGateReduction(Float)

  /// Latency, intentional delay, and finite tail lengths cannot be negative.
  case invalidTiming

  /// Every mixer input and output must use one clock rate before realtime rendering begins.
  case incompatibleMixerSampleRates

  /// A localized description of the invalid configuration.
  public var errorDescription: String? {
    switch self {
    case .invalidSampleRate(let sampleRate):
      return "The sample rate must be finite and greater than zero; received \(sampleRate)."
    case .invalidChannelCount(let channelCount):
      return "The channel count must be between 1 and 256; received \(channelCount)."
    case .invalidMaximumFrameCount(let frameCount):
      return "The maximum render frame count must be between 1 and 65,536; received \(frameCount)."
    case .invalidChannelRoute:
      return "Audio channel routes cannot contain negative input or channel indices."
    case .nonfiniteGain:
      return "Audio gain values must be finite."
    case .invalidChannelGain(let gain):
      return "Channel gain must be between -16 and 16; received \(gain)."
    case .invalidGeneratorFrequency(let frequency):
      return
        "Generator frequency must be finite, positive, and below Nyquist; received \(frequency)."
    case .invalidGeneratorAmplitude(let amplitude):
      return "Generator amplitude must be between 0 and 1; received \(amplitude)."
    case .invalidDelayDuration(let duration):
      return
        "Delay duration must be finite, positive, and no greater than 10 seconds; received \(duration)."
    case .invalidDelayFeedback(let feedback):
      return "Delay feedback must be finite and between -0.95 and 0.95; received \(feedback)."
    case .invalidDryWetMix(let mix):
      return "Dry/wet mix must be finite and between 0 and 1; received \(mix)."
    case .delayStorageTooLarge(let sampleCount):
      return
        "The requested delay line needs \(sampleCount) samples and exceeds the bounded storage budget."
    case .invalidNoiseGateThreshold(let threshold):
      return "Noise-gate threshold must be between -96 and 0 dBFS; received \(threshold)."
    case .invalidNoiseGateHysteresis(let hysteresis):
      return "Noise-gate hysteresis must be between 0 and 24 dB; received \(hysteresis)."
    case .invalidNoiseGateAttack(let attack):
      return "Noise-gate attack must be between 0 and 1 second; received \(attack)."
    case .invalidNoiseGateHold(let hold):
      return "Noise-gate hold must be between 0 and 5 seconds; received \(hold)."
    case .invalidNoiseGateRelease(let release):
      return "Noise-gate release must be between 0 and 10 seconds; received \(release)."
    case .invalidNoiseGateReduction(let reduction):
      return "Noise-gate reduction must be between 0 and 96 dB; received \(reduction)."
    case .invalidTiming:
      return "Audio timing frame counts cannot be negative."
    case .incompatibleMixerSampleRates:
      return "Mixer inputs and outputs must use the same prepared sample rate."
    }
  }
}

/// The canonical native format used by RilliyaKit DSP kernels.
///
/// Samples are noninterleaved, native-endian Float32 PCM. Format conversion belongs at graph
/// boundaries so inner render paths can remain allocation-free and deterministic.
public struct AudioProcessingFormat: Equatable, Hashable, Sendable {
  /// The maximum supported channel count for one processing bus.
  public static let maximumChannelCount = 256

  /// The number of sample frames per second.
  public let sampleRate: Double

  /// The number of noninterleaved Float32 channels.
  public let channelCount: Int

  /// Creates a validated processing format.
  public init(sampleRate: Double, channelCount: Int) throws {
    guard sampleRate.isFinite, sampleRate > 0 else {
      throw AudioDSPConfigurationError.invalidSampleRate(sampleRate)
    }
    guard (1...Self.maximumChannelCount).contains(channelCount) else {
      throw AudioDSPConfigurationError.invalidChannelCount(channelCount)
    }
    self.sampleRate = sampleRate
    self.channelCount = channelCount
  }
}

/// The immutable preparation contract supplied before a kernel reaches the render thread.
public struct AudioRenderPreparation: Equatable, Hashable, Sendable {
  /// A defensive upper bound for one render quantum.
  public static let maximumSupportedFrameCount = 65_536

  /// The format used for the prepared render path.
  public let format: AudioProcessingFormat

  /// The largest frame count that may be supplied to one render call.
  public let maximumFrameCount: Int

  /// Creates a validated render preparation.
  public init(format: AudioProcessingFormat, maximumFrameCount: Int) throws {
    guard (1...Self.maximumSupportedFrameCount).contains(maximumFrameCount) else {
      throw AudioDSPConfigurationError.invalidMaximumFrameCount(maximumFrameCount)
    }
    self.format = format
    self.maximumFrameCount = maximumFrameCount
  }
}

/// The amount of output that can remain after a node stops receiving input.
public enum AudioProcessingTail: Equatable, Hashable, Sendable {
  /// The node has no tail, as with gain or a transparent analyzer.
  case none

  /// The node has a known finite tail measured in sample frames.
  case finiteFrames(Int)

  /// The node can feed back indefinitely and must be stopped explicitly.
  case unbounded
}

/// Timing information used by the graph compiler for alignment and teardown.
public struct AudioNodeTiming: Equatable, Hashable, Sendable {
  /// Algorithmic latency introduced by the node.
  public let processingLatencyFrames: Int

  /// User-requested delay that is semantically part of the route.
  public let intentionalDelayFrames: Int

  /// Output that may remain after the final input frame.
  public let tail: AudioProcessingTail

  /// Creates node timing metadata.
  public init(
    processingLatencyFrames: Int,
    intentionalDelayFrames: Int,
    tail: AudioProcessingTail
  ) throws {
    guard processingLatencyFrames >= 0, intentionalDelayFrames >= 0 else {
      throw AudioDSPConfigurationError.invalidTiming
    }
    if case .finiteFrames(let frameCount) = tail, frameCount < 0 {
      throw AudioDSPConfigurationError.invalidTiming
    }
    self.processingLatencyFrames = processingLatencyFrames
    self.intentionalDelayFrames = intentionalDelayFrames
    self.tail = tail
  }

  /// Timing for a transparent, zero-latency node.
  public static let transparent = AudioNodeTiming(
    validatedProcessingLatencyFrames: 0,
    intentionalDelayFrames: 0,
    tail: .none
  )

  private init(
    validatedProcessingLatencyFrames: Int,
    intentionalDelayFrames: Int,
    tail: AudioProcessingTail
  ) {
    processingLatencyFrames = validatedProcessingLatencyFrames
    self.intentionalDelayFrames = intentionalDelayFrames
    self.tail = tail
  }
}

/// One explicit contribution to an audio mixer's output channel matrix.
public struct AudioChannelRoute: Equatable, Hashable, Sendable {
  /// The zero-based mixer input index.
  public let inputIndex: Int

  /// The zero-based channel within the selected input.
  public let sourceChannel: Int

  /// The zero-based output channel receiving the contribution.
  public let destinationChannel: Int

  /// Linear gain applied before summing.
  ///
  /// Values are intentionally not clamped to unit amplitude.
  public let gain: Float

  /// Creates a validated channel route.
  public init(
    inputIndex: Int,
    sourceChannel: Int,
    destinationChannel: Int,
    gain: Float = 1
  ) throws {
    guard inputIndex >= 0, sourceChannel >= 0, destinationChannel >= 0 else {
      throw AudioDSPConfigurationError.invalidChannelRoute
    }
    guard gain.isFinite else {
      throw AudioDSPConfigurationError.nonfiniteGain
    }
    self.inputIndex = inputIndex
    self.sourceChannel = sourceChannel
    self.destinationChannel = destinationChannel
    self.gain = gain
  }
}
