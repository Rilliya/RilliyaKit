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

/// The graph carries one buffer per channel, so the converter has to work in that layout without
/// weaving the channels together and apart again on every block.
@Suite("Audio sample rate converter, planar")
struct AudioSampleRatePlanarConverterTests {
  private enum Fixture {
    static let channelCount = 2
    static let outputFrameCount = 512
    static let frequency = 440.0
  }

  @Test(
    "A planar block is produced at the output rate",
    arguments: [(44_100.0, 48_000.0), (48_000.0, 96_000.0), (96_000.0, 48_000.0)]
  )
  func producesAFullBlock(input: Double, output: Double) throws {
    let harness = try Harness(input: input, output: output)

    #expect(try harness.convert() == Fixture.outputFrameCount)
  }

  /// Each channel must come out as itself: a converter that shared state across channels would
  /// smear one into another, which no level check on a single channel would notice.
  @Test("Every channel keeps its own signal")
  func channelsStayApart() throws {
    let harness = try Harness(input: 44_100, output: 48_000, distinctChannels: true)

    _ = try harness.convert()

    let first = harness.rendered(channel: 0).suffix(Fixture.outputFrameCount / 2)
    let second = harness.rendered(channel: 1).suffix(Fixture.outputFrameCount / 2)
    // The second channel was supplied at half amplitude and must still be at half.
    let ratio = harness.level(Array(second)) / harness.level(Array(first))
    #expect(ratio > 0.45)
    #expect(ratio < 0.55)
  }

  @Test("The same rate in and out passes each channel through")
  func identityConversionIsTransparent() throws {
    let harness = try Harness(input: 48_000, output: 48_000, distinctChannels: true)

    _ = try harness.convert()

    for channel in 0..<Fixture.channelCount {
      let source = harness.source(channel: channel)
      let rendered = harness.rendered(channel: channel)
      for frame in 0..<Fixture.outputFrameCount {
        #expect(abs(rendered[frame] - source[frame]) < 1e-4)
      }
    }
  }

  @Test("An interleaved converter refuses planar buffers rather than reading them wrongly")
  func layoutIsEnforced() throws {
    let converter = try AudioSampleRateConverter(
      inputSampleRate: 44_100,
      outputSampleRate: 48_000,
      channelCount: Fixture.channelCount,
      maximumOutputFrameCount: Fixture.outputFrameCount,
      layout: .interleaved
    )
    let harness = try Harness(input: 44_100, output: 48_000)

    #expect(throws: AudioSampleRateConverterError.self) {
      _ = try harness.withBuffers { input, output in
        try converter.convert(
          input: input,
          inputFrameCount: 128,
          output: output,
          outputFrameCount: Fixture.outputFrameCount
        )
      }
    }
  }

  private final class Harness {
    let converter: AudioSampleRateConverter
    private let inputChannels: [UnsafeMutablePointer<Float>]
    private let outputChannels: [UnsafeMutablePointer<Float>]
    private let inputCapacity: Int

    init(input: Double, output: Double, distinctChannels: Bool = false) throws {
      converter = try AudioSampleRateConverter(
        inputSampleRate: input,
        outputSampleRate: output,
        channelCount: Fixture.channelCount,
        maximumOutputFrameCount: Fixture.outputFrameCount,
        layout: .planar
      )
      let capacity = converter.maximumInputFrameCount
      inputCapacity = capacity
      inputChannels = (0..<Fixture.channelCount).map { channel in
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        let scale: Double = distinctChannels && channel == 1 ? 0.5 : 1
        for frame in 0..<capacity {
          buffer[frame] = Float(
            0.3 * scale * sin(2 * .pi * Fixture.frequency * Double(frame) / input)
          )
        }
        return buffer
      }
      outputChannels = (0..<Fixture.channelCount).map { _ in
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: Fixture.outputFrameCount)
        buffer.initialize(repeating: 0, count: Fixture.outputFrameCount)
        return buffer
      }
    }

    deinit {
      for buffer in inputChannels + outputChannels { buffer.deallocate() }
    }

    func withBuffers<T>(
      _ body: (
        UnsafeBufferPointer<UnsafePointer<Float>>,
        UnsafeBufferPointer<UnsafeMutablePointer<Float>>
      ) throws -> T
    ) rethrows -> T {
      let readOnly = inputChannels.map { UnsafePointer<Float>($0) }
      return try readOnly.withUnsafeBufferPointer { input in
        try outputChannels.withUnsafeBufferPointer { output in
          try body(input, output)
        }
      }
    }

    func convert() throws -> Int {
      try withBuffers { input, output in
        try converter.convert(
          input: input,
          inputFrameCount: inputCapacity,
          output: output,
          outputFrameCount: Fixture.outputFrameCount
        )
      }
    }

    func rendered(channel: Int) -> [Float] {
      Array(UnsafeBufferPointer(start: outputChannels[channel], count: Fixture.outputFrameCount))
    }

    func source(channel: Int) -> [Float] {
      Array(UnsafeBufferPointer(start: inputChannels[channel], count: Fixture.outputFrameCount))
    }

    func level(_ samples: [Float]) -> Float {
      guard !samples.isEmpty else { return 0 }
      return (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }
  }
}

/// A converter used block after block is where drift shows up: the system decides for itself how
/// much of each block it consumes, so anything the caller assumes about that accumulates.
@Suite("Audio sample rate converter, streaming")
struct AudioSampleRateStreamingTests {
  private enum Fixture {
    static let channelCount = 1
    static let outputFrameCount = 512
    static let blocks = 200
    static let inputRate = 44_100.0
    static let outputRate = 48_000.0
    static let frequency = 440.0
  }

  @Test("A tone stays continuous across two hundred blocks")
  func streamStaysContinuous() throws {
    let harness = try Harness()

    let rendered = try harness.stream(blocks: Fixture.blocks)

    #expect(rendered.count == Fixture.blocks * Fixture.outputFrameCount)
    // A splice or a repeated run shows up as a step no sine wave of this frequency can make.
    let stepLimit = harness.largestNeighbourStep(harness.reference())
    let settled = Array(rendered.dropFirst(Fixture.outputFrameCount))
    #expect(harness.largestNeighbourStep(settled) < stepLimit * 1.5)
  }

  /// The output must advance at exactly the ratio, or the stream slowly leads or lags the source.
  @Test("The frequency is held for the whole stream, not just the first block")
  func frequencyDoesNotDrift() throws {
    let harness = try Harness()

    let rendered = try harness.stream(blocks: Fixture.blocks)
    let settled = Array(rendered.dropFirst(Fixture.outputFrameCount))
    let firstHalf = Array(settled.prefix(settled.count / 2))
    let secondHalf = Array(settled.suffix(settled.count / 2))

    let start = harness.dominantFrequency(firstHalf, sampleRate: Fixture.outputRate)
    let end = harness.dominantFrequency(secondHalf, sampleRate: Fixture.outputRate)
    #expect(abs(start - Fixture.frequency) < 2)
    #expect(abs(end - Fixture.frequency) < 2)
  }

  /// What the converter asks for has to settle at the ratio, or a caller reading that many frames
  /// from a queue would drain it faster or slower than it fills.
  @Test("The input it asks for settles at the ratio between the rates")
  func requestSettlesAtTheRatio() throws {
    let harness = try Harness()

    _ = try harness.stream(blocks: 20)
    let asked = harness.converter.inputFrameCountNeeded(
      forOutputFrameCount: Fixture.outputFrameCount)

    let ratio = Fixture.inputRate / Fixture.outputRate
    let expected = Double(Fixture.outputFrameCount) * ratio
    #expect(Double(asked) > expected - 4)
    #expect(Double(asked) < expected + 4)
  }

  @Test("Resetting drops what was held so a new stream does not inherit it")
  func resetDropsTheCarry() throws {
    let harness = try Harness()

    _ = try harness.stream(blocks: 5)
    #expect(harness.converter.carriedInputFrameCount > 0)

    harness.converter.reset()

    #expect(harness.converter.carriedInputFrameCount == 0)
  }

  private final class Harness {
    let converter: AudioSampleRateConverter
    private let input: UnsafeMutablePointer<Float>
    private let output: UnsafeMutablePointer<Float>
    private var sourceFrame = 0

    init() throws {
      converter = try AudioSampleRateConverter(
        inputSampleRate: Fixture.inputRate,
        outputSampleRate: Fixture.outputRate,
        channelCount: Fixture.channelCount,
        maximumOutputFrameCount: Fixture.outputFrameCount
      )
      input = .allocate(capacity: converter.maximumInputFrameCount)
      output = .allocate(capacity: Fixture.outputFrameCount)
      input.initialize(repeating: 0, count: converter.maximumInputFrameCount)
      output.initialize(repeating: 0, count: Fixture.outputFrameCount)
    }

    deinit {
      input.deallocate()
      output.deallocate()
    }

    /// Feeds exactly what the converter asks for, block after block, as a graph would.
    func stream(blocks: Int) throws -> [Float] {
      var rendered: [Float] = []
      for _ in 0..<blocks {
        let needed = converter.inputFrameCountNeeded(
          forOutputFrameCount: Fixture.outputFrameCount)
        for index in 0..<needed {
          input[index] = sample(at: sourceFrame + index)
        }
        sourceFrame += needed
        let produced = try converter.convert(
          input: input,
          inputFrameCount: needed,
          output: output,
          outputFrameCount: Fixture.outputFrameCount
        )
        rendered.append(contentsOf: UnsafeBufferPointer(start: output, count: produced))
      }
      return rendered
    }

    private func sample(at frame: Int) -> Float {
      Float(0.3 * sin(2 * .pi * Fixture.frequency * Double(frame) / Fixture.inputRate))
    }

    /// The same tone rendered directly at the output rate, as the yardstick.
    func reference() -> [Float] {
      (0..<(Fixture.outputFrameCount * 4)).map { frame in
        Float(0.3 * sin(2 * .pi * Fixture.frequency * Double(frame) / Fixture.outputRate))
      }
    }

    func largestNeighbourStep(_ samples: [Float]) -> Float {
      guard samples.count > 1 else { return 0 }
      var largest: Float = 0
      for index in 1..<samples.count {
        largest = max(largest, abs(samples[index] - samples[index - 1]))
      }
      return largest
    }

    func dominantFrequency(_ samples: [Float], sampleRate: Double) -> Double {
      var crossings: [Double] = []
      for index in 1..<samples.count where samples[index - 1] < 0 && samples[index] >= 0 {
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
