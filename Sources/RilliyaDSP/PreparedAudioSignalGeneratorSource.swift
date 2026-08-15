// SPDX-License-Identifier: Apache-2.0

import Accelerate
import Foundation
import RilliyaRealtime

/// A waveform produced by a prepared signal generator.
public enum AudioSignalGeneratorWaveform: String, CaseIterable, Codable, Sendable {
  /// A pure sinusoid.
  case sine

  /// A discontinuous waveform corrected with a polynomial band-limited step.
  case square

  /// An integrated band-limited square wave.
  case triangle

  /// A discontinuous ramp corrected with a polynomial band-limited step.
  case sawtooth

  /// Uniform pseudorandom noise with a flat expected spectrum.
  case whiteNoise

  /// Voss-McCartney pseudorandom noise with an approximate inverse-frequency spectrum.
  case pinkNoise

  /// Leaky integrated pseudorandom noise with an approximate inverse-square spectrum.
  case brownNoise
}

/// Immutable parameters for a prepared signal generator.
public struct AudioSignalGeneratorConfiguration: Equatable, Hashable, Codable, Sendable {
  /// The generated waveform.
  public let waveform: AudioSignalGeneratorWaveform

  /// Oscillator frequency in hertz.
  ///
  /// Noise waveforms retain this value for stable configuration interchange but do not use it
  /// while rendering.
  public let frequency: Double

  /// Peak linear amplitude in the closed interval from silence through full scale.
  public let amplitude: Float

  /// Deterministic noise seed.
  ///
  /// A zero seed is mapped to a fixed nonzero generator state.
  public let seed: UInt64

  /// Creates generator parameters.
  ///
  /// Frequency is validated against the prepared sample rate when the source is created.
  public init(
    waveform: AudioSignalGeneratorWaveform,
    frequency: Double = 440,
    amplitude: Float = 0.25,
    seed: UInt64 = 0x5249_4C4C_4959_4101
  ) throws {
    guard frequency.isFinite, frequency > 0 else {
      throw AudioDSPConfigurationError.invalidGeneratorFrequency(frequency)
    }
    guard amplitude.isFinite, (0...1).contains(amplitude) else {
      throw AudioDSPConfigurationError.invalidGeneratorAmplitude(amplitude)
    }
    self.waveform = waveform
    self.frequency = frequency
    self.amplitude = amplitude
    self.seed = seed
  }

  private enum CodingKeys: String, CodingKey {
    case waveform
    case frequency
    case amplitude
    case seed
  }

  /// Decodes generator parameters while preserving the same public safety bounds as direct
  /// creation.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let waveform = try container.decode(AudioSignalGeneratorWaveform.self, forKey: .waveform)
    let frequency = try container.decode(Double.self, forKey: .frequency)
    let amplitude = try container.decode(Float.self, forKey: .amplitude)
    let seed = try container.decode(UInt64.self, forKey: .seed)
    do {
      try self.init(
        waveform: waveform,
        frequency: frequency,
        amplitude: amplitude,
        seed: seed
      )
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .frequency,
        in: container,
        debugDescription: "Generator parameters are outside the supported bounds."
      )
    }
  }
}

/// A prepared, deterministic audio signal generator.
///
/// Preparation allocates all scratch storage. `render` performs no allocation, locking, logging,
/// or callback work. Sine generation uses Accelerate for vectorized phase and transcendental
/// evaluation. Discontinuous periodic waveforms use a polynomial band-limited step to reduce
/// aliasing instead of emitting naive digital edges. Calls for one instance must remain serialized
/// on one render thread.
public final class PreparedAudioSignalGeneratorSource: PreparedAudioSource, @unchecked Sendable {
  private static let pinkRowCount = 16
  private static let fallbackSeed: UInt64 = 0x9E37_79B9_7F4A_7C15

  /// The immutable preparation used by this generator.
  public let preparation: AudioRenderPreparation

  /// Signal generation has no algorithmic latency or tail.
  public let timing = AudioNodeTiming.transparent

  /// The immutable parameters used by this generator.
  public let configuration: AudioSignalGeneratorConfiguration

  private let phaseScratch: UnsafeMutablePointer<Float>
  private var phase = 0.0
  private var triangle = -1.0
  private var randomState: UInt64
  private var pinkCounter: UInt32 = 0
  private var pinkRows: [Float]
  private var pinkSum: Float = 0
  private var brown: Float = 0

  /// Prepares a generator for a fixed format and maximum render quantum.
  public init(
    preparation: AudioRenderPreparation,
    configuration: AudioSignalGeneratorConfiguration
  ) throws {
    guard configuration.frequency < preparation.format.sampleRate / 2 else {
      throw AudioDSPConfigurationError.invalidGeneratorFrequency(configuration.frequency)
    }
    self.preparation = preparation
    self.configuration = configuration
    randomState = configuration.seed == 0 ? Self.fallbackSeed : configuration.seed
    pinkRows = .init(repeating: 0, count: Self.pinkRowCount)
    phaseScratch = .allocate(capacity: preparation.maximumFrameCount)
    phaseScratch.initialize(repeating: 0, count: preparation.maximumFrameCount)
  }

  deinit {
    phaseScratch.deinitialize(count: preparation.maximumFrameCount)
    phaseScratch.deallocate()
  }

  /// Renders the configured signal into caller-owned planar Float32 channels.
  @discardableResult
  public func render(
    outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRenderResult {
    guard (0...preparation.maximumFrameCount).contains(frameCount) else {
      return .invalidFrameCount
    }
    let channelCount = preparation.format.channelCount
    guard outputChannels.count >= channelCount else { return .insufficientChannels }
    guard frameCount > 0 else { return .rendered }

    let firstOutput = outputChannels[0]
    switch configuration.waveform {
    case .sine:
      renderSine(to: firstOutput, frameCount: frameCount)
    case .square, .triangle, .sawtooth:
      renderBandLimitedPeriodicSignal(to: firstOutput, frameCount: frameCount)
    case .whiteNoise, .pinkNoise, .brownNoise:
      renderNoise(to: firstOutput, frameCount: frameCount)
    }
    for channel in 1..<channelCount {
      outputChannels[channel].update(from: firstOutput, count: frameCount)
    }
    return .rendered
  }

  private func renderSine(to output: UnsafeMutablePointer<Float>, frameCount: Int) {
    var initialAngle = Float(phase * 2 * Double.pi)
    var angleIncrement = Float(
      configuration.frequency / preparation.format.sampleRate * 2 * Double.pi
    )
    vDSP_vramp(
      &initialAngle,
      &angleIncrement,
      phaseScratch,
      1,
      vDSP_Length(frameCount)
    )
    var count = Int32(frameCount)
    vvsinf(output, phaseScratch, &count)
    var amplitude = configuration.amplitude
    vDSP_vsmul(output, 1, &amplitude, output, 1, vDSP_Length(frameCount))
    advancePhase(by: frameCount)
  }

  private func renderBandLimitedPeriodicSignal(
    to output: UnsafeMutablePointer<Float>,
    frameCount: Int
  ) {
    let increment = configuration.frequency / preparation.format.sampleRate
    let amplitude = Double(configuration.amplitude)
    for frame in 0..<frameCount {
      let value: Double
      switch configuration.waveform {
      case .square:
        value = bandLimitedSquare(phase: phase, increment: increment)
      case .triangle:
        let square = bandLimitedSquare(phase: phase, increment: increment)
        triangle += square * 4 * increment
        triangle = min(1, max(-1, triangle))
        value = triangle
      case .sawtooth:
        value = 2 * phase - 1 - polynomialBandLimitedStep(phase, increment: increment)
      case .sine, .whiteNoise, .pinkNoise, .brownNoise:
        preconditionFailure("The periodic renderer received an incompatible waveform.")
      }
      output[frame] = Float(value * amplitude)
      phase += increment
      if phase >= 1 { phase -= 1 }
    }
  }

  private func renderNoise(to output: UnsafeMutablePointer<Float>, frameCount: Int) {
    let amplitude = configuration.amplitude
    for frame in 0..<frameCount {
      let value: Float
      switch configuration.waveform {
      case .whiteNoise:
        value = nextWhiteSample()
      case .pinkNoise:
        value = nextPinkSample()
      case .brownNoise:
        let white = nextWhiteSample()
        brown = 0.995 * brown + 0.02 * white
        value = min(1, max(-1, brown * 3.5))
      case .sine, .square, .triangle, .sawtooth:
        preconditionFailure("The noise renderer received an incompatible waveform.")
      }
      output[frame] = value * amplitude
    }
  }

  private func bandLimitedSquare(phase: Double, increment: Double) -> Double {
    var value = phase < 0.5 ? 1.0 : -1.0
    value += polynomialBandLimitedStep(phase, increment: increment)
    let fallingPhase = phase < 0.5 ? phase + 0.5 : phase - 0.5
    value -= polynomialBandLimitedStep(fallingPhase, increment: increment)
    return value
  }

  private func polynomialBandLimitedStep(_ phase: Double, increment: Double) -> Double {
    if phase < increment {
      let normalized = phase / increment
      return normalized + normalized - normalized * normalized - 1
    }
    if phase > 1 - increment {
      let normalized = (phase - 1) / increment
      return normalized * normalized + normalized + normalized + 1
    }
    return 0
  }

  private func nextWhiteSample() -> Float {
    randomState ^= randomState >> 12
    randomState ^= randomState << 25
    randomState ^= randomState >> 27
    let value = randomState &* 0x2545_F491_4F6C_DD1D
    let normalized = Double(value >> 11) * (1.0 / 9_007_199_254_740_992.0)
    return Float(normalized * 2 - 1)
  }

  private func nextPinkSample() -> Float {
    pinkCounter &+= 1
    let row = min(pinkCounter.trailingZeroBitCount, Self.pinkRowCount - 1)
    pinkSum -= pinkRows[row]
    let replacement = nextWhiteSample()
    pinkRows[row] = replacement
    pinkSum += replacement
    return (pinkSum + nextWhiteSample()) / Float(Self.pinkRowCount + 1)
  }

  private func advancePhase(by frameCount: Int) {
    let increment = configuration.frequency / preparation.format.sampleRate
    phase = (phase + increment * Double(frameCount)).truncatingRemainder(dividingBy: 1)
  }
}
