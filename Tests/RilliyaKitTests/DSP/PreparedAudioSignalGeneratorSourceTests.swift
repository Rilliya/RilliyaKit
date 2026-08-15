// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaRealtime
import Testing

@testable import RilliyaDSP

@Suite("Prepared signal generator")
struct PreparedAudioSignalGeneratorSourceTests {
  @Test("Sine phase remains continuous across render quanta")
  func sinePhaseContinuity() throws {
    let source = try makeSource(waveform: .sine, sampleRate: 8, frequency: 1, amplitude: 1)

    let first = render(source, frameCount: 3)
    let second = render(source, frameCount: 5)
    let rendered = first + second
    let expected: [Float] = [0, 0.707_106_77, 1, 0.707_106_77, 0, -0.707_106_77, -1, -0.707_106_77]

    for (actual, expected) in zip(rendered, expected) {
      #expect(abs(actual - expected) < 0.000_01)
    }
  }

  @Test("Periodic waveforms remain finite and bounded")
  func periodicWaveformsRemainBounded() throws {
    for waveform in [
      AudioSignalGeneratorWaveform.square,
      .triangle,
      .sawtooth,
    ] {
      let source = try makeSource(waveform: waveform, frequency: 997, amplitude: 0.75)
      let rendered = render(source, frameCount: 512)

      #expect(rendered.allSatisfy { $0.isFinite })
      #expect(rendered.allSatisfy { abs($0) <= 0.750_01 })
      #expect(rendered.contains { abs($0) > 0.1 })
    }
  }

  @Test("Noise is deterministic by seed and colored noise changes more slowly")
  func deterministicColoredNoise() throws {
    let whiteA = try makeSource(waveform: .whiteNoise, seed: 42)
    let whiteB = try makeSource(waveform: .whiteNoise, seed: 42)
    let brown = try makeSource(waveform: .brownNoise, seed: 42)
    let whiteSamples = render(whiteA, frameCount: 512)

    #expect(whiteSamples == render(whiteB, frameCount: 512))
    #expect(
      meanAbsoluteDifference(render(brown, frameCount: 512))
        < meanAbsoluteDifference(whiteSamples)
    )
  }

  @Test("Every prepared output channel receives the same generated signal")
  func copiesSignalAcrossChannels() throws {
    let source = try makeSource(waveform: .sine, channelCount: 2)
    let rendered = renderChannels(source, channelCount: 2, frameCount: 32)

    #expect(rendered[0] == rendered[1])
  }

  @Test("Rejects unsafe generator parameters and render bounds")
  func rejectsInvalidParametersAndRenderBounds() throws {
    #expect(throws: AudioDSPConfigurationError.invalidGeneratorAmplitude(1.1)) {
      try AudioSignalGeneratorConfiguration(waveform: .sine, amplitude: 1.1)
    }
    let preparation = try AudioRenderPreparation(
      format: AudioProcessingFormat(sampleRate: 48_000, channelCount: 1),
      maximumFrameCount: 16
    )
    let nyquist = try AudioSignalGeneratorConfiguration(waveform: .sine, frequency: 24_000)
    #expect(throws: AudioDSPConfigurationError.invalidGeneratorFrequency(24_000)) {
      try PreparedAudioSignalGeneratorSource(preparation: preparation, configuration: nyquist)
    }
    let source = try makeSource(waveform: .sine, maximumFrameCount: 16)
    let storage = UnsafeMutablePointer<Float>.allocate(capacity: 17)
    defer { storage.deallocate() }
    let channels = [storage]
    let result = channels.withUnsafeBufferPointer {
      source.render(outputChannels: $0, frameCount: 17)
    }
    #expect(result == .invalidFrameCount)
  }

  @Test("Decoding cannot bypass generator parameter validation")
  func decodingPreservesConfigurationBounds() {
    let invalid = Data(
      #"{"waveform":"sine","frequency":440,"amplitude":2,"seed":1}"#.utf8
    )

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(AudioSignalGeneratorConfiguration.self, from: invalid)
    }
  }

  private func makeSource(
    waveform: AudioSignalGeneratorWaveform,
    sampleRate: Double = 48_000,
    channelCount: Int = 1,
    maximumFrameCount: Int = 512,
    frequency: Double = 440,
    amplitude: Float = 0.25,
    seed: UInt64 = 1
  ) throws -> PreparedAudioSignalGeneratorSource {
    try PreparedAudioSignalGeneratorSource(
      preparation: AudioRenderPreparation(
        format: AudioProcessingFormat(sampleRate: sampleRate, channelCount: channelCount),
        maximumFrameCount: maximumFrameCount
      ),
      configuration: AudioSignalGeneratorConfiguration(
        waveform: waveform,
        frequency: frequency,
        amplitude: amplitude,
        seed: seed
      )
    )
  }

  private func render(
    _ source: PreparedAudioSignalGeneratorSource,
    frameCount: Int
  ) -> [Float] {
    renderChannels(source, channelCount: 1, frameCount: frameCount)[0]
  }

  private func renderChannels(
    _ source: PreparedAudioSignalGeneratorSource,
    channelCount: Int,
    frameCount: Int
  ) -> [[Float]] {
    let storagePointers = (0..<channelCount).map { _ in
      UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
    }
    defer {
      for channel in storagePointers { channel.deallocate() }
    }
    let result = storagePointers.withUnsafeBufferPointer {
      source.render(outputChannels: $0, frameCount: frameCount)
    }
    #expect(result == .rendered)
    return storagePointers.map {
      [Float](UnsafeBufferPointer(start: $0, count: frameCount))
    }
  }

  private func meanAbsoluteDifference(_ samples: [Float]) -> Float {
    guard samples.count > 1 else { return 0 }
    let total = zip(samples.dropFirst(), samples).reduce(Float.zero) {
      $0 + abs($1.0 - $1.1)
    }
    return total / Float(samples.count - 1)
  }
}
