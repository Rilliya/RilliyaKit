// SPDX-License-Identifier: Apache-2.0

import Atomics
import Foundation
import RilliyaRealtime

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

  /// The validated configuration used when this processor was prepared.
  public let initialConfiguration: AudioNoiseGateConfiguration

  /// Noise gating adds no look-ahead latency and has no signal tail.
  public let timing = AudioNodeTiming.transparent

  private let controls: AudioNoiseGateRealtimeControls

  private var isOpen = false
  private var holdFramesRemaining = 0
  private var currentGain: Float

  /// Prepares one fixed-format gate away from the realtime render thread.
  public init(
    preparation: AudioRenderPreparation,
    configuration: AudioNoiseGateConfiguration
  ) throws {
    self.preparation = preparation
    initialConfiguration = configuration
    let controls = try AudioNoiseGateRealtimeControls(
      sampleRate: preparation.format.sampleRate,
      configuration: configuration
    )
    self.controls = controls
    currentGain = controls.snapshot().closedGain
  }

  /// Publishes new parameters without reallocating or stopping the render path.
  ///
  /// Thresholds and smoothing coefficients are converted away from the realtime thread. The next
  /// render quantum observes bounded values through relaxed lock-free loads. A quantum concurrent
  /// with an update may briefly combine values from the old and new configurations, but every value
  /// remains independently validated and realtime-safe.
  public func setConfiguration(_ configuration: AudioNoiseGateConfiguration) throws {
    try controls.setConfiguration(configuration)
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

    let controls = controls.snapshot()

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

      updateGateState(linkedMagnitude: linkedMagnitude, controls: controls)
      let targetGain: Float = isOpen ? 1 : controls.closedGain
      let coefficient = isOpen ? controls.attackCoefficient : controls.releaseCoefficient
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
    currentGain = controls.snapshot().closedGain
  }

  private func updateGateState(
    linkedMagnitude: Float,
    controls: AudioNoiseGateControlSnapshot
  ) {
    if isOpen {
      if linkedMagnitude >= controls.closeThreshold {
        holdFramesRemaining = controls.holdFrameCount
      } else if holdFramesRemaining > 0 {
        holdFramesRemaining -= 1
      } else {
        isOpen = false
      }
    } else if linkedMagnitude >= controls.openThreshold {
      isOpen = true
      holdFramesRemaining = controls.holdFrameCount
    }
  }
}

private struct AudioNoiseGateControlSnapshot {
  let openThreshold: Float
  let closeThreshold: Float
  let closedGain: Float
  let attackCoefficient: Float
  let releaseCoefficient: Float
  let holdFrameCount: Int
}

private final class AudioNoiseGateRealtimeControls: @unchecked Sendable {
  private let sampleRate: Double
  private let thresholds: ManagedAtomic<UInt64>
  private let coefficients: ManagedAtomic<UInt64>
  private let closedGain: ManagedAtomic<UInt32>
  private let holdFrameCount: ManagedAtomic<UInt64>

  init(sampleRate: Double, configuration: AudioNoiseGateConfiguration) throws {
    self.sampleRate = sampleRate
    let snapshot = try Self.makeSnapshot(sampleRate: sampleRate, configuration: configuration)
    thresholds = ManagedAtomic(Self.pack(snapshot.openThreshold, snapshot.closeThreshold))
    coefficients = ManagedAtomic(
      Self.pack(snapshot.attackCoefficient, snapshot.releaseCoefficient)
    )
    closedGain = ManagedAtomic(snapshot.closedGain.bitPattern)
    holdFrameCount = ManagedAtomic(UInt64(snapshot.holdFrameCount))
  }

  func setConfiguration(_ configuration: AudioNoiseGateConfiguration) throws {
    let snapshot = try Self.makeSnapshot(sampleRate: sampleRate, configuration: configuration)
    thresholds.store(
      Self.pack(snapshot.openThreshold, snapshot.closeThreshold),
      ordering: .relaxed
    )
    coefficients.store(
      Self.pack(snapshot.attackCoefficient, snapshot.releaseCoefficient),
      ordering: .relaxed
    )
    closedGain.store(snapshot.closedGain.bitPattern, ordering: .relaxed)
    holdFrameCount.store(UInt64(snapshot.holdFrameCount), ordering: .relaxed)
  }

  func snapshot() -> AudioNoiseGateControlSnapshot {
    let thresholdPair = thresholds.load(ordering: .relaxed)
    let coefficientPair = coefficients.load(ordering: .relaxed)
    return AudioNoiseGateControlSnapshot(
      openThreshold: Self.firstFloat(thresholdPair),
      closeThreshold: Self.secondFloat(thresholdPair),
      closedGain: Float(bitPattern: closedGain.load(ordering: .relaxed)),
      attackCoefficient: Self.firstFloat(coefficientPair),
      releaseCoefficient: Self.secondFloat(coefficientPair),
      holdFrameCount: Int(holdFrameCount.load(ordering: .relaxed))
    )
  }

  private static func makeSnapshot(
    sampleRate: Double,
    configuration: AudioNoiseGateConfiguration
  ) throws -> AudioNoiseGateControlSnapshot {
    let requestedHoldFrames = configuration.holdSeconds * sampleRate
    guard requestedHoldFrames.isFinite,
      requestedHoldFrames <= Double(Int.max),
      requestedHoldFrames <= Double(UInt64.max)
    else {
      throw AudioDSPConfigurationError.invalidNoiseGateHold(configuration.holdSeconds)
    }
    return AudioNoiseGateControlSnapshot(
      openThreshold: linearAmplitude(decibels: configuration.thresholdDecibels),
      closeThreshold: linearAmplitude(
        decibels: configuration.thresholdDecibels - configuration.hysteresisDecibels
      ),
      closedGain: linearAmplitude(decibels: -configuration.reductionDecibels),
      attackCoefficient: smoothingCoefficient(
        seconds: configuration.attackSeconds,
        sampleRate: sampleRate
      ),
      releaseCoefficient: smoothingCoefficient(
        seconds: configuration.releaseSeconds,
        sampleRate: sampleRate
      ),
      holdFrameCount: Int(requestedHoldFrames.rounded())
    )
  }

  private static func pack(_ first: Float, _ second: Float) -> UInt64 {
    UInt64(first.bitPattern) | UInt64(second.bitPattern) << 32
  }

  private static func firstFloat(_ packed: UInt64) -> Float {
    Float(bitPattern: UInt32(truncatingIfNeeded: packed))
  }

  private static func secondFloat(_ packed: UInt64) -> Float {
    Float(bitPattern: UInt32(truncatingIfNeeded: packed >> 32))
  }

  private static func linearAmplitude(decibels: Float) -> Float {
    pow(10, decibels / 20)
  }

  private static func smoothingCoefficient(seconds: Double, sampleRate: Double) -> Float {
    guard seconds > 0 else { return 0 }
    return Float(exp(-1 / (seconds * sampleRate)))
  }
}
