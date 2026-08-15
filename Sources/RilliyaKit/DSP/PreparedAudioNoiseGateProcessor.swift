// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Immutable parameters for a linked multichannel noise gate.
///
/// This processor attenuates quiet passages. It is intentionally named a noise gate rather than
/// noise reduction: noise that overlaps wanted signal remains present while the gate is open.
public struct AudioNoiseGateConfiguration: Equatable, Hashable, Codable, Sendable {
  /// The signal level that opens a closed gate, measured in dBFS.
  public let thresholdDecibels: Float

  /// The close threshold's distance below the open threshold.
  public let hysteresisDecibels: Float

  /// Time used to fade from the closed gain to unity.
  public let attackSeconds: Double

  /// Minimum time the gate remains open after the linked signal falls below its close threshold.
  public let holdSeconds: Double

  /// Time used to fade from unity to the closed gain.
  public let releaseSeconds: Double

  /// Attenuation applied while the gate is closed.
  public let reductionDecibels: Float

  /// Creates validated noise-gate parameters.
  public init(
    thresholdDecibels: Float = -40,
    hysteresisDecibels: Float = 6,
    attackSeconds: Double = 0.005,
    holdSeconds: Double = 0.05,
    releaseSeconds: Double = 0.15,
    reductionDecibels: Float = 60
  ) throws {
    guard thresholdDecibels.isFinite, (-96...0).contains(thresholdDecibels) else {
      throw AudioDSPConfigurationError.invalidNoiseGateThreshold(thresholdDecibels)
    }
    guard hysteresisDecibels.isFinite, (0...24).contains(hysteresisDecibels) else {
      throw AudioDSPConfigurationError.invalidNoiseGateHysteresis(hysteresisDecibels)
    }
    guard attackSeconds.isFinite, (0...1).contains(attackSeconds) else {
      throw AudioDSPConfigurationError.invalidNoiseGateAttack(attackSeconds)
    }
    guard holdSeconds.isFinite, (0...5).contains(holdSeconds) else {
      throw AudioDSPConfigurationError.invalidNoiseGateHold(holdSeconds)
    }
    guard releaseSeconds.isFinite, (0...10).contains(releaseSeconds) else {
      throw AudioDSPConfigurationError.invalidNoiseGateRelease(releaseSeconds)
    }
    guard reductionDecibels.isFinite, (0...96).contains(reductionDecibels) else {
      throw AudioDSPConfigurationError.invalidNoiseGateReduction(reductionDecibels)
    }
    self.thresholdDecibels = thresholdDecibels
    self.hysteresisDecibels = hysteresisDecibels
    self.attackSeconds = attackSeconds
    self.holdSeconds = holdSeconds
    self.releaseSeconds = releaseSeconds
    self.reductionDecibels = reductionDecibels
  }

  private enum CodingKeys: String, CodingKey {
    case thresholdDecibels
    case hysteresisDecibels
    case attackSeconds
    case holdSeconds
    case releaseSeconds
    case reductionDecibels
  }

  /// Decodes parameters through the same safety bounds as direct creation.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        thresholdDecibels: container.decode(Float.self, forKey: .thresholdDecibels),
        hysteresisDecibels: container.decode(Float.self, forKey: .hysteresisDecibels),
        attackSeconds: container.decode(Double.self, forKey: .attackSeconds),
        holdSeconds: container.decode(Double.self, forKey: .holdSeconds),
        releaseSeconds: container.decode(Double.self, forKey: .releaseSeconds),
        reductionDecibels: container.decode(Float.self, forKey: .reductionDecibels)
      )
    } catch let error as DecodingError {
      throw error
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .thresholdDecibels,
        in: container,
        debugDescription: "Noise-gate parameters are outside the supported bounds."
      )
    }
  }
}

/// A zero-latency, linked multichannel noise gate prepared for realtime rendering.
///
/// The detector uses the greatest absolute sample across all channels, then applies one smoothed
/// gain to every channel. Linking preserves the stereo or surround image when only one channel
/// crosses the threshold. Hysteresis and hold time prevent chatter around the threshold, while
/// attack and release smoothing avoid discontinuities. `process` allocates no memory, takes no
/// locks, performs no logging, invokes no callbacks, and sends no Objective-C messages.
public final class PreparedAudioNoiseGateProcessor: PreparedAudioProcessor,
  @unchecked Sendable
{
  /// The immutable preparation used by this processor.
  public let preparation: AudioRenderPreparation

  /// The validated configuration used by this processor.
  public let configuration: AudioNoiseGateConfiguration

  /// Noise gating adds no look-ahead latency and has no signal tail.
  public let timing = AudioNodeTiming.transparent

  private let openThreshold: Float
  private let closeThreshold: Float
  private let closedGain: Float
  private let attackCoefficient: Float
  private let releaseCoefficient: Float
  private let holdFrameCount: Int

  private var isOpen = false
  private var holdFramesRemaining = 0
  private var currentGain: Float

  /// Prepares one fixed-format gate away from the realtime render thread.
  public init(
    preparation: AudioRenderPreparation,
    configuration: AudioNoiseGateConfiguration
  ) throws {
    self.preparation = preparation
    self.configuration = configuration
    openThreshold = Self.linearAmplitude(decibels: configuration.thresholdDecibels)
    closeThreshold = Self.linearAmplitude(
      decibels: configuration.thresholdDecibels - configuration.hysteresisDecibels
    )
    closedGain = Self.linearAmplitude(decibels: -configuration.reductionDecibels)
    currentGain = closedGain
    attackCoefficient = Self.smoothingCoefficient(
      seconds: configuration.attackSeconds,
      sampleRate: preparation.format.sampleRate
    )
    releaseCoefficient = Self.smoothingCoefficient(
      seconds: configuration.releaseSeconds,
      sampleRate: preparation.format.sampleRate
    )
    let requestedHoldFrames = configuration.holdSeconds * preparation.format.sampleRate
    guard requestedHoldFrames.isFinite, requestedHoldFrames <= Double(Int.max) else {
      throw AudioDSPConfigurationError.invalidNoiseGateHold(configuration.holdSeconds)
    }
    holdFrameCount = Int(requestedHoldFrames.rounded())
  }

  /// Processes one bounded planar Float32 render quantum.
  ///
  /// Input and output pointers may alias. Samples are not clipped, and nonfinite input keeps the
  /// gate open rather than hiding an upstream DSP failure.
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

    for frame in 0..<frameCount {
      var linkedMagnitude: Float = 0
      for channel in 0..<channelCount {
        let sample = inputChannels[channel][frame]
        if !sample.isFinite {
          linkedMagnitude = .infinity
          break
        }
        linkedMagnitude = max(linkedMagnitude, abs(sample))
      }

      updateGateState(linkedMagnitude: linkedMagnitude)
      let targetGain: Float = isOpen ? 1 : closedGain
      let coefficient = isOpen ? attackCoefficient : releaseCoefficient
      currentGain = targetGain + coefficient * (currentGain - targetGain)
      if abs(currentGain - targetGain) < 1e-8 {
        currentGain = targetGain
      }
      for channel in 0..<channelCount {
        outputChannels[channel][frame] = inputChannels[channel][frame] * currentGain
      }
    }
    return .rendered
  }

  /// Clears detector history before the processor is returned to a render thread.
  ///
  /// The caller must serialize this operation with `process`.
  public func reset() {
    isOpen = false
    holdFramesRemaining = 0
    currentGain = closedGain
  }

  private func updateGateState(linkedMagnitude: Float) {
    if isOpen {
      if linkedMagnitude >= closeThreshold {
        holdFramesRemaining = holdFrameCount
      } else if holdFramesRemaining > 0 {
        holdFramesRemaining -= 1
      } else {
        isOpen = false
      }
    } else if linkedMagnitude >= openThreshold {
      isOpen = true
      holdFramesRemaining = holdFrameCount
    }
  }

  private static func linearAmplitude(decibels: Float) -> Float {
    pow(10, decibels / 20)
  }

  private static func smoothingCoefficient(seconds: Double, sampleRate: Double) -> Float {
    guard seconds > 0 else { return 0 }
    return Float(exp(-1 / (seconds * sampleRate)))
  }
}
