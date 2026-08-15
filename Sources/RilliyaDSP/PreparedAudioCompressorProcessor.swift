// SPDX-License-Identifier: Apache-2.0

import Atomics
import Foundation
import RilliyaRealtime

/// Immutable parameters for a linked, feed-forward dynamics compressor.
public struct AudioCompressorConfiguration: Equatable, Hashable, Codable, Sendable {
  /// Level above which compression begins, measured in dBFS.
  public let thresholdDecibels: Float

  /// Input-to-output slope above the threshold, expressed as `ratio:1`.
  public let ratio: Float

  /// Width of the transition around the threshold, measured in decibels.
  public let kneeDecibels: Float

  /// Time used to approach greater gain reduction.
  public let attackSeconds: Double

  /// Time used to return toward unity gain.
  public let releaseSeconds: Double

  /// Constant output gain applied after compression.
  public let makeupGainDecibels: Float

  /// Creates validated compressor parameters.
  public init(
    thresholdDecibels: Float = -18,
    ratio: Float = 4,
    kneeDecibels: Float = 6,
    attackSeconds: Double = 0.01,
    releaseSeconds: Double = 0.12,
    makeupGainDecibels: Float = 0
  ) throws {
    guard thresholdDecibels.isFinite, (-96...0).contains(thresholdDecibels) else {
      throw AudioDSPConfigurationError.invalidCompressorThreshold(thresholdDecibels)
    }
    guard ratio.isFinite, (1...100).contains(ratio) else {
      throw AudioDSPConfigurationError.invalidCompressorRatio(ratio)
    }
    guard kneeDecibels.isFinite, (0...24).contains(kneeDecibels) else {
      throw AudioDSPConfigurationError.invalidCompressorKnee(kneeDecibels)
    }
    guard attackSeconds.isFinite, (0...1).contains(attackSeconds) else {
      throw AudioDSPConfigurationError.invalidCompressorAttack(attackSeconds)
    }
    guard releaseSeconds.isFinite, (0...10).contains(releaseSeconds) else {
      throw AudioDSPConfigurationError.invalidCompressorRelease(releaseSeconds)
    }
    guard makeupGainDecibels.isFinite, (-24...24).contains(makeupGainDecibels) else {
      throw AudioDSPConfigurationError.invalidCompressorMakeupGain(makeupGainDecibels)
    }
    self.thresholdDecibels = thresholdDecibels
    self.ratio = ratio
    self.kneeDecibels = kneeDecibels
    self.attackSeconds = attackSeconds
    self.releaseSeconds = releaseSeconds
    self.makeupGainDecibels = makeupGainDecibels
  }

  private enum CodingKeys: String, CodingKey {
    case thresholdDecibels
    case ratio
    case kneeDecibels
    case attackSeconds
    case releaseSeconds
    case makeupGainDecibels
  }

  /// Decodes parameters through the same bounds as direct creation.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        thresholdDecibels: container.decode(Float.self, forKey: .thresholdDecibels),
        ratio: container.decode(Float.self, forKey: .ratio),
        kneeDecibels: container.decode(Float.self, forKey: .kneeDecibels),
        attackSeconds: container.decode(Double.self, forKey: .attackSeconds),
        releaseSeconds: container.decode(Double.self, forKey: .releaseSeconds),
        makeupGainDecibels: container.decode(Float.self, forKey: .makeupGainDecibels)
      )
    } catch let error as DecodingError {
      throw error
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .thresholdDecibels,
        in: container,
        debugDescription: "Compressor parameters are outside the supported bounds."
      )
    }
  }
}

/// A zero-latency, linked multichannel compressor prepared for realtime rendering.
///
/// The detector uses the greatest absolute sample across every channel and applies one gain
/// envelope to the complete bus, preserving stereo and surround balance. The soft-knee transfer is
/// feed-forward and does not clip output. `process` allocates no memory, takes no locks, logs
/// nothing, invokes no callbacks, and sends no Objective-C messages.
public final class PreparedAudioCompressorProcessor: PreparedAudioProcessor,
  @unchecked Sendable
{
  /// The immutable stream format and maximum render quantum accepted by this processor.
  public let preparation: AudioRenderPreparation

  /// The validated parameters used when the processor was prepared.
  public let initialConfiguration: AudioCompressorConfiguration

  /// The compressor adds no sample delay and has no finite tail declaration.
  public let timing = AudioNodeTiming.transparent

  private let controls: AudioCompressorRealtimeControls
  private var currentControls: AudioCompressorControlSnapshot
  private var currentGain: Float = 1

  /// Prepares one fixed-format compressor away from the realtime render thread.
  public init(
    preparation: AudioRenderPreparation,
    configuration: AudioCompressorConfiguration
  ) throws {
    self.preparation = preparation
    initialConfiguration = configuration
    let controls = AudioCompressorRealtimeControls(
      sampleRate: preparation.format.sampleRate,
      configuration: configuration
    )
    self.controls = controls
    currentControls = controls.initialSnapshot
  }

  /// Publishes validated parameters without reallocating or restarting the render path.
  public func setConfiguration(_ configuration: AudioCompressorConfiguration) {
    controls.setConfiguration(configuration)
  }

  /// Processes one planar Float32 render quantum with linked multichannel detection.
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

    if let publishedControls = controls.snapshot() {
      currentControls = publishedControls
    }
    let controls = currentControls
    for frame in 0..<frameCount {
      var linkedMagnitude: Float = 0
      for channel in 0..<channelCount {
        let magnitude = abs(inputChannels[channel][frame])
        if !magnitude.isFinite {
          linkedMagnitude = .infinity
          break
        }
        linkedMagnitude = max(linkedMagnitude, magnitude)
      }
      let targetGain = controls.targetGain(for: linkedMagnitude)
      let coefficient =
        targetGain < currentGain ? controls.attackCoefficient : controls.releaseCoefficient
      currentGain = targetGain + coefficient * (currentGain - targetGain)
      if abs(currentGain - targetGain) < 1e-8 {
        currentGain = targetGain
      }
      for channel in 0..<channelCount {
        let sample = inputChannels[channel][frame]
        outputChannels[channel][frame] = sample.isFinite ? sample * currentGain : 0
      }
    }
    return .rendered
  }

  /// Clears envelope history before returning the processor to a render thread.
  ///
  /// The caller must serialize this operation with `process`.
  public func reset() {
    currentGain = 1
  }
}

private struct AudioCompressorControlSnapshot {
  let thresholdDecibels: Float
  let slope: Float
  let kneeDecibels: Float
  let makeupGain: Float
  let attackCoefficient: Float
  let releaseCoefficient: Float

  func targetGain(for magnitude: Float) -> Float {
    guard magnitude.isFinite else { return 0 }
    guard magnitude > 0 else { return makeupGain }
    let inputDecibels = 20 * log10(magnitude)
    let overThreshold = inputDecibels - thresholdDecibels
    let reductionDecibels: Float
    if kneeDecibels > 0 {
      let kneePosition = overThreshold + kneeDecibels / 2
      if kneePosition <= 0 {
        reductionDecibels = 0
      } else if kneePosition >= kneeDecibels {
        reductionDecibels = slope * overThreshold
      } else {
        reductionDecibels = slope * kneePosition * kneePosition / (2 * kneeDecibels)
      }
    } else {
      reductionDecibels = slope * max(overThreshold, 0)
    }
    return pow(10, -reductionDecibels / 20) * makeupGain
  }
}

private final class AudioCompressorRealtimeControls: @unchecked Sendable {
  let initialSnapshot: AudioCompressorControlSnapshot
  private let sampleRate: Double
  private let writerLock = NSLock()
  private let generation = ManagedAtomic<UInt64>(0)
  private let transfer: ManagedAtomic<UInt64>
  private let timing: ManagedAtomic<UInt64>
  private let makeupAndPadding: ManagedAtomic<UInt64>

  init(sampleRate: Double, configuration: AudioCompressorConfiguration) {
    self.sampleRate = sampleRate
    let snapshot = Self.makeSnapshot(sampleRate: sampleRate, configuration: configuration)
    initialSnapshot = snapshot
    transfer = ManagedAtomic(Self.pack(snapshot.thresholdDecibels, snapshot.slope))
    timing = ManagedAtomic(Self.pack(snapshot.attackCoefficient, snapshot.releaseCoefficient))
    makeupAndPadding = ManagedAtomic(Self.pack(snapshot.makeupGain, snapshot.kneeDecibels))
  }

  func setConfiguration(_ configuration: AudioCompressorConfiguration) {
    let snapshot = Self.makeSnapshot(sampleRate: sampleRate, configuration: configuration)
    writerLock.lock()
    defer { writerLock.unlock() }
    let initialGeneration = generation.load(ordering: .relaxed)
    generation.store(initialGeneration &+ 1, ordering: .releasing)
    transfer.store(Self.pack(snapshot.thresholdDecibels, snapshot.slope), ordering: .relaxed)
    timing.store(
      Self.pack(snapshot.attackCoefficient, snapshot.releaseCoefficient),
      ordering: .relaxed
    )
    makeupAndPadding.store(
      Self.pack(snapshot.makeupGain, snapshot.kneeDecibels),
      ordering: .relaxed
    )
    generation.store(initialGeneration &+ 2, ordering: .releasing)
  }

  /// Returns one coherent snapshot, or `nil` when a publisher is currently replacing it.
  ///
  /// The realtime caller never waits for the non-realtime publisher. It keeps using its previous
  /// complete snapshot for that render quantum when publication overlaps this read.
  func snapshot() -> AudioCompressorControlSnapshot? {
    let initialGeneration = generation.load(ordering: .acquiring)
    guard initialGeneration.isMultiple(of: 2) else { return nil }
    let transfer = transfer.load(ordering: .relaxed)
    let timing = timing.load(ordering: .relaxed)
    let makeup = makeupAndPadding.load(ordering: .relaxed)
    let finalGeneration = generation.load(ordering: .acquiring)
    guard finalGeneration == initialGeneration else { return nil }
    return AudioCompressorControlSnapshot(
      thresholdDecibels: Self.firstFloat(transfer),
      slope: Self.secondFloat(transfer),
      kneeDecibels: Self.secondFloat(makeup),
      makeupGain: Self.firstFloat(makeup),
      attackCoefficient: Self.firstFloat(timing),
      releaseCoefficient: Self.secondFloat(timing)
    )
  }

  private static func makeSnapshot(
    sampleRate: Double,
    configuration: AudioCompressorConfiguration
  ) -> AudioCompressorControlSnapshot {
    AudioCompressorControlSnapshot(
      thresholdDecibels: configuration.thresholdDecibels,
      slope: 1 - 1 / configuration.ratio,
      kneeDecibels: configuration.kneeDecibels,
      makeupGain: pow(10, configuration.makeupGainDecibels / 20),
      attackCoefficient: smoothingCoefficient(
        seconds: configuration.attackSeconds,
        sampleRate: sampleRate
      ),
      releaseCoefficient: smoothingCoefficient(
        seconds: configuration.releaseSeconds,
        sampleRate: sampleRate
      )
    )
  }

  private static func smoothingCoefficient(seconds: Double, sampleRate: Double) -> Float {
    guard seconds > 0 else { return 0 }
    return Float(exp(-1 / (seconds * sampleRate)))
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
}
