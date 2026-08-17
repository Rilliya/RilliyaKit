// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RilliyaDSP

@Suite("Audio sample rate ladder")
struct AudioSampleRateLadderTests {
  /// What a codec offering only these rates does with each source rate.
  private static let opusRates = [8_000.0, 12_000.0, 16_000.0, 24_000.0, 48_000.0]

  @Test(
    "A source is carried at its own rate, or the nearest one above it",
    arguments: [
      (44_100.0, 48_000.0),
      (48_000.0, 48_000.0),
      (96_000.0, 48_000.0),
      (32_000.0, 48_000.0),
      (22_050.0, 24_000.0),
      (8_000.0, 8_000.0),
      (12_000.0, 12_000.0),
      (16_000.0, 16_000.0),
      (24_000.0, 24_000.0),
      (11_025.0, 12_000.0),
      (192_000.0, 48_000.0),
    ]
  )
  func resolvesToTheNearestRateAbove(input: Double, expected: Double) {
    #expect(AudioSampleRateLadder.resolve(input: input, supported: Self.opusRates) == expected)
  }

  /// Going down throws away bandwidth nothing later can restore, so it happens only where the
  /// source sits above everything on offer.
  @Test(
    "Only a source above every offered rate is brought down",
    arguments: [
      (44_100.0, false),
      (48_000.0, false),
      (32_000.0, false),
      (96_000.0, true),
      (192_000.0, true),
    ]
  )
  func onlyRatesAboveTheCeilingLose(input: Double, loses: Bool) throws {
    let resolved = try #require(
      AudioSampleRateLadder.resolve(input: input, supported: Self.opusRates)
    )

    #expect(AudioSampleRateLadder.loses(input: input, resolved: resolved) == loses)
  }

  @Test("The order the rates are offered in does not matter")
  func orderDoesNotMatter() {
    let shuffled = [48_000.0, 8_000.0, 24_000.0, 12_000.0, 16_000.0]

    #expect(AudioSampleRateLadder.resolve(input: 44_100, supported: shuffled) == 48_000)
    #expect(AudioSampleRateLadder.resolve(input: 22_050, supported: shuffled) == 24_000)
  }

  @Test(
    "Rates that are not rates are ignored rather than chosen",
    arguments: [Double.nan, 0, -48_000, .infinity]
  )
  func unusableRatesAreIgnored(rate: Double) {
    #expect(AudioSampleRateLadder.resolve(input: rate, supported: Self.opusRates) == nil)
    #expect(AudioSampleRateLadder.resolve(input: 44_100, supported: [rate]) == nil)
  }

  @Test("Nothing on offer means nothing to choose")
  func emptyLadderResolvesToNothing() {
    #expect(AudioSampleRateLadder.resolve(input: 48_000, supported: []) == nil)
  }
}

@Suite("Audio sample rate converter")
struct AudioSampleRateConverterTests {
  private enum Fixture {
    static let channelCount = 2
    static let outputFrameCount = 512
    static let frequency = 440.0
  }

  @Test(
    "A block is produced at the output rate",
    arguments: [(44_100.0, 48_000.0), (48_000.0, 96_000.0), (96_000.0, 48_000.0)]
  )
  func producesAFullBlock(input: Double, output: Double) throws {
    let harness = try Harness(input: input, output: output)

    let produced = try harness.convert(inputFrameCount: harness.converter.maximumInputFrameCount)

    #expect(produced == Fixture.outputFrameCount)
  }

  /// A resampled tone must still be that tone: energy at the right frequency, and no silence.
  @Test("A tone survives conversion at its own frequency")
  func toneSurvivesConversion() throws {
    let harness = try Harness(input: 44_100, output: 48_000)

    _ = try harness.convert(inputFrameCount: harness.converter.maximumInputFrameCount)
    let rendered = harness.rendered()

    // The converter's filter needs priming, so the tail is what has settled.
    let settled = Array(rendered.suffix(Fixture.outputFrameCount / 2))
    #expect(harness.level(settled) > 0.2)
    #expect(harness.level(settled) < 0.4)

    // Read the source with the same estimator, so a biased estimator cannot fail a good result.
    let sourceFrequency = harness.dominantFrequency(harness.source(), sampleRate: 44_100)
    let renderedFrequency = harness.dominantFrequency(settled, sampleRate: 48_000)
    #expect(abs(sourceFrequency - Fixture.frequency) < 5)
    #expect(abs(renderedFrequency - sourceFrequency) < 5)
  }

  @Test("The same rate in and out passes the samples through")
  func identityConversionIsTransparent() throws {
    let harness = try Harness(input: 48_000, output: 48_000)

    _ = try harness.convert(inputFrameCount: harness.converter.maximumInputFrameCount)

    let source = harness.source()
    let rendered = harness.rendered()
    for frame in 0..<Fixture.outputFrameCount {
      #expect(abs(rendered[frame] - source[frame]) < 1e-4)
    }
  }

  @Test("Running out of input produces a short block rather than inventing one")
  func shortInputProducesAShortBlock() throws {
    let harness = try Harness(input: 44_100, output: 48_000)

    let produced = try harness.convert(inputFrameCount: 64)

    #expect(produced > 0)
    #expect(produced < Fixture.outputFrameCount)
  }

  @Test(
    "Controls outside the bounded policy are rejected",
    arguments: [
      (0.0, 48_000.0, 2, 512), (48_000.0, 0.0, 2, 512), (48_000.0, 48_000.0, 0, 512),
      (48_000.0, 48_000.0, 2, 0),
    ]
  )
  func invalidControlsAreRejected(
    input: Double,
    output: Double,
    channelCount: Int,
    frameCount: Int
  ) {
    #expect(throws: AudioSampleRateConverterError.self) {
      _ = try AudioSampleRateConverter(
        inputSampleRate: input,
        outputSampleRate: output,
        channelCount: channelCount,
        maximumOutputFrameCount: frameCount
      )
    }
  }

  @Test("A block larger than the converter was built for is refused")
  func oversizedBlockIsRefused() throws {
    let harness = try Harness(input: 44_100, output: 48_000)

    #expect(throws: AudioSampleRateConverterError.self) {
      _ = try harness.converter.convert(
        input: harness.inputStorage,
        inputFrameCount: harness.converter.maximumInputFrameCount,
        output: harness.outputStorage,
        outputFrameCount: Fixture.outputFrameCount + 1
      )
    }
  }

  private final class Harness {
    let converter: AudioSampleRateConverter
    let inputStorage: UnsafeMutablePointer<Float>
    let outputStorage: UnsafeMutablePointer<Float>
    private let inputCapacity: Int

    init(input: Double, output: Double) throws {
      converter = try AudioSampleRateConverter(
        inputSampleRate: input,
        outputSampleRate: output,
        channelCount: Fixture.channelCount,
        maximumOutputFrameCount: Fixture.outputFrameCount
      )
      inputCapacity = converter.maximumInputFrameCount
      inputStorage = .allocate(capacity: inputCapacity * Fixture.channelCount)
      outputStorage = .allocate(capacity: Fixture.outputFrameCount * Fixture.channelCount)
      inputStorage.initialize(repeating: 0, count: inputCapacity * Fixture.channelCount)
      outputStorage.initialize(
        repeating: 0,
        count: Fixture.outputFrameCount * Fixture.channelCount
      )
      for frame in 0..<inputCapacity {
        let value = Float(
          0.3 * sin(2 * .pi * Fixture.frequency * Double(frame) / input)
        )
        for channel in 0..<Fixture.channelCount {
          inputStorage[frame * Fixture.channelCount + channel] = value
        }
      }
    }

    deinit {
      inputStorage.deallocate()
      outputStorage.deallocate()
    }

    func convert(inputFrameCount: Int) throws -> Int {
      try converter.convert(
        input: inputStorage,
        inputFrameCount: inputFrameCount,
        output: outputStorage,
        outputFrameCount: Fixture.outputFrameCount
      )
    }

    /// The first channel of what was produced.
    func rendered() -> [Float] {
      (0..<Fixture.outputFrameCount).map { outputStorage[$0 * Fixture.channelCount] }
    }

    /// The first channel of what was supplied.
    func source() -> [Float] {
      (0..<Fixture.outputFrameCount).map { inputStorage[$0 * Fixture.channelCount] }
    }

    func level(_ samples: [Float]) -> Float {
      guard !samples.isEmpty else { return 0 }
      let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
      return (sum / Float(samples.count)).squareRoot()
    }

    /// The tone's frequency, from the mean period between rising zero crossings.
    ///
    /// Counting crossings over a short block quantises badly — a 440 Hz tone in ten milliseconds
    /// has four and a half of them — so the span between the first and last is measured instead.
    func dominantFrequency(_ samples: [Float], sampleRate: Double) -> Double {
      var crossings: [Double] = []
      for index in 1..<samples.count where samples[index - 1] < 0 && samples[index] >= 0 {
        // Interpolate where the line between the two samples actually crosses zero.
        let previous = Double(samples[index - 1])
        let current = Double(samples[index])
        let fraction = current == previous ? 0 : -previous / (current - previous)
        crossings.append(Double(index - 1) + fraction)
      }
      guard crossings.count > 1, let first = crossings.first, let last = crossings.last else {
        return 0
      }
      let period = (last - first) / Double(crossings.count - 1)
      return period > 0 ? sampleRate / period : 0
    }
  }
}
