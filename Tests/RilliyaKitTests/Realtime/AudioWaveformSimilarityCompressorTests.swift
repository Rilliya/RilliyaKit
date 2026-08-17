// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RilliyaRealtime

@Suite("Audio waveform similarity compressor")
struct AudioWaveformSimilarityCompressorTests {
  private enum Fixture {
    static let sampleRate = 48_000.0
    static let outputFrameCount = 512
    static let removal = 480

    /// A frequency whose period sits inside the search range, as voice and music do.
    static let frequency = 220.0
  }

  /// The reason this exists. A queue that shortens itself by moving its read pointer jumps the
  /// waveform to an unrelated phase, and the step between the last frame it played and the first
  /// frame after the jump is the click. Overlapping at the matching period leaves the stream
  /// continuous across that boundary instead.
  @Test("Overlapping leaves a far smaller seam than discarding the same frames")
  func seamIsSmallerThanDiscarding() throws {
    let harness = try Harness(channelCount: 1)
    let history = 1_024
    let source = harness.sine(
      frameCount: history + Fixture.outputFrameCount + Fixture.removal * 2)
    let playedSoFar = source.channels[0][history - 1]

    // Discarding: the next frame played is the one `removal` frames further along.
    let discardedSeam = abs(source.channels[0][history + Fixture.removal] - playedSoFar)

    // Overlapping: the next frame played is the one that followed, so the boundary is continuous
    // and the only seam is the crossfade the compressor made inside its own output.
    var tail = Planar(channels: [Array(source.channels[0].dropFirst(history))])
    tail.channels[0] = Array(tail.channels[0].prefix(Fixture.outputFrameCount + Fixture.removal))
    let compressed = try harness.compress(tail, removal: Fixture.removal)
    let boundarySeam = abs(compressed.channels[0][0] - playedSoFar)
    let internalSeam = harness.largestNeighbourStep(compressed.channels[0])
    let compressedSeam = max(boundarySeam, internalSeam)

    let natural = harness.largestNeighbourStep(harness.sine(frameCount: 4_096).channels[0])
    #expect(compressed.removed > 0)
    #expect(discardedSeam > natural * 3)
    #expect(compressedSeam < natural * 1.5)
    #expect(compressedSeam < discardedSeam / 4)
  }

  /// A long crossfade hides a step whatever lag it uses, so the step alone does not show whether
  /// the lag matched the waveform. Overlapping at the wrong phase makes the two copies cancel,
  /// and that shows up as level lost from the output.
  @Test("Overlapping preserves the level, which a mismatched period would not")
  func levelIsPreserved() throws {
    let harness = try Harness(channelCount: 1)
    let input = harness.sine(frameCount: Fixture.outputFrameCount + Fixture.removal)

    let compressed = try harness.compress(input, removal: Fixture.removal)

    let sourceLevel = harness.level(Array(input.channels[0].prefix(Fixture.outputFrameCount)))
    let compressedLevel = harness.level(compressed.channels[0])
    #expect(compressedLevel > sourceLevel * 0.9)
    #expect(compressedLevel < sourceLevel * 1.1)
  }

  @Test("The output keeps the requested length and the caller learns what was consumed")
  func lengthAndConsumption() throws {
    let harness = try Harness(channelCount: 2)
    let input = harness.sine(frameCount: Fixture.outputFrameCount + Fixture.removal)

    let compressed = try harness.compress(input, removal: Fixture.removal)

    #expect(compressed.channels[0].count == Fixture.outputFrameCount)
    #expect(compressed.removed > 0)
    #expect(compressed.removed <= Fixture.removal)
  }

  /// Splicing channels at different points would pull a stereo image apart, so the lag found on
  /// the mixdown has to be the lag applied everywhere.
  @Test("Every channel is spliced at the same point")
  func channelsShareOneSplice() throws {
    let harness = try Harness(channelCount: 2)
    var input = harness.sine(frameCount: Fixture.outputFrameCount + Fixture.removal)
    // Give the second channel the same waveform at half amplitude.
    for frame in 0..<input.channels[1].count {
      input.channels[1][frame] = input.channels[0][frame] * 0.5
    }

    let compressed = try harness.compress(input, removal: Fixture.removal)

    for frame in 0..<Fixture.outputFrameCount {
      #expect(abs(compressed.channels[1][frame] - compressed.channels[0][frame] * 0.5) < 1e-5)
    }
  }

  @Test("Silence compresses to silence")
  func silenceStaysSilent() throws {
    let harness = try Harness(channelCount: 1)
    let input = harness.constant(0, frameCount: Fixture.outputFrameCount + Fixture.removal)

    let compressed = try harness.compress(input, removal: Fixture.removal)

    #expect(compressed.channels[0].allSatisfy { $0 == 0 })
  }

  @Test("A removal smaller than the shortest period is refused rather than forced")
  func refusesTinyRemoval() throws {
    let harness = try Harness(channelCount: 1)
    let input = harness.sine(frameCount: Fixture.outputFrameCount + 4)

    let compressed = try harness.compress(input, removal: 4)

    #expect(compressed.removed == 0)
    // Refusing means passing the head through untouched, so the caller can try again later.
    for frame in 0..<Fixture.outputFrameCount {
      #expect(compressed.channels[0][frame] == input.channels[0][frame])
    }
  }

  private struct Planar {
    var channels: [[Float]]
  }

  private struct Compressed {
    let channels: [[Float]]
    let removed: Int
  }

  private struct Harness {
    let channelCount: Int
    let compressor: AudioWaveformSimilarityCompressor

    init(channelCount: Int) throws {
      self.channelCount = channelCount
      compressor = try AudioWaveformSimilarityCompressor(
        format: AudioProcessingFormat(
          sampleRate: Fixture.sampleRate, channelCount: channelCount),
        maximumFrameCount: Fixture.outputFrameCount
      )
    }

    func sine(frameCount: Int) -> Planar {
      Planar(
        channels: (0..<channelCount).map { _ in
          (0..<frameCount).map { frame in
            Float(0.5 * sin(2 * .pi * Fixture.frequency * Double(frame) / Fixture.sampleRate))
          }
        })
    }

    func constant(_ value: Float, frameCount: Int) -> Planar {
      Planar(channels: (0..<channelCount).map { _ in [Float](repeating: value, count: frameCount) })
    }

    /// Removing frames by moving a read pointer, as a queue does.
    func discard(_ input: Planar, removal: Int) -> [[Float]] {
      input.channels.map { Array($0.dropFirst(removal).prefix(Fixture.outputFrameCount)) }
    }

    func compress(_ input: Planar, removal: Int) throws -> Compressed {
      var storage = input.channels
      var output = (0..<channelCount).map { _ in
        [Float](repeating: .nan, count: Fixture.outputFrameCount)
      }
      let removed = storage.withUnsafeMutableBufferPointer { inputStorage in
        output.withUnsafeMutableBufferPointer { outputStorage -> Int in
          let inputPointers = (0..<channelCount).map {
            UnsafePointer(inputStorage[$0].withUnsafeMutableBufferPointer { $0.baseAddress! })
          }
          let outputPointers = (0..<channelCount).map {
            outputStorage[$0].withUnsafeMutableBufferPointer { $0.baseAddress! }
          }
          return inputPointers.withUnsafeBufferPointer { input in
            outputPointers.withUnsafeBufferPointer { output in
              compressor.compress(
                input: input,
                output: output,
                outputFrameCount: Fixture.outputFrameCount,
                removal: removal
              )
            }
          }
        }
      }
      return Compressed(channels: output, removed: removed)
    }

    /// Root mean square, which drops when overlapped copies cancel.
    func level(_ samples: [Float]) -> Float {
      guard !samples.isEmpty else { return 0 }
      let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
      return (sum / Float(samples.count)).squareRoot()
    }

    /// The largest step between neighbouring samples, which is where a splice shows up.
    func largestNeighbourStep(_ samples: [Float]) -> Float {
      guard samples.count > 1 else { return 0 }
      var largest: Float = 0
      for index in 1..<samples.count {
        largest = max(largest, abs(samples[index] - samples[index - 1]))
      }
      return largest
    }
  }
}

@Suite("Audio waveform similarity compressor bounds")
struct AudioWaveformSimilarityCompressorBoundsTests {
  /// The crossfade reads a second copy of the period past the splice, so a lag longer than the
  /// block being produced would read past the audio the caller supplied.
  @Test(
    "The removable period never exceeds the render quantum",
    arguments: [16, 64, 128, 256, 512, 1_024, 4_096]
  )
  func removableIsBoundedByQuantum(maximumFrameCount: Int) throws {
    let compressor = try AudioWaveformSimilarityCompressor(
      format: AudioProcessingFormat(sampleRate: 48_000, channelCount: 2),
      maximumFrameCount: maximumFrameCount
    )

    #expect(compressor.maximumRemovableFrameCount <= maximumFrameCount)
  }

  /// A quantum shorter than the shortest period searched cannot host a crossfade at all, and
  /// saying so lets a caller fall back rather than silently doing nothing.
  @Test("A quantum too short to host a crossfade reports that it cannot help")
  func shortQuantumIsIneffective() throws {
    let short = try AudioWaveformSimilarityCompressor(
      format: AudioProcessingFormat(sampleRate: 48_000, channelCount: 2),
      maximumFrameCount: 128
    )
    let long = try AudioWaveformSimilarityCompressor(
      format: AudioProcessingFormat(sampleRate: 48_000, channelCount: 2),
      maximumFrameCount: 1_024
    )

    // Three milliseconds is 144 frames, so a 128 frame block cannot hold one.
    #expect(!short.isEffective)
    #expect(long.isEffective)
  }

  /// A render callback may ask for fewer frames than the compressor was prepared for, and the
  /// crossfade reads twice the lag, so a period chosen for the prepared size would read past the
  /// audio a shorter block supplied.
  @Test("A block shorter than the prepared size still stays inside its input")
  func shortBlockStaysInsideTheInput() throws {
    let compressor = try AudioWaveformSimilarityCompressor(
      format: AudioProcessingFormat(sampleRate: 48_000, channelCount: 1),
      maximumFrameCount: 1_024
    )
    #expect(compressor.maximumRemovableFrameCount > 256)

    for outputFrameCount in [64, 128, 200, 256] {
      let available = outputFrameCount + compressor.maximumRemovableFrameCount
      var input = (0..<available).map { Float(sin(Double($0) * 0.02)) }
      var output = [Float](repeating: 0, count: outputFrameCount)

      let removed = input.withUnsafeMutableBufferPointer { inputBuffer in
        output.withUnsafeMutableBufferPointer { outputBuffer -> Int in
          let readOnly = [UnsafePointer(inputBuffer.baseAddress!)]
          let writable = [outputBuffer.baseAddress!]
          return readOnly.withUnsafeBufferPointer { input in
            writable.withUnsafeBufferPointer { output in
              compressor.compress(
                input: input,
                output: output,
                outputFrameCount: outputFrameCount,
                removal: compressor.maximumRemovableFrameCount
              )
            }
          }
        }
      }

      #expect(removed <= outputFrameCount)
      #expect(output.allSatisfy { $0.isFinite })
    }
  }

  /// Reads past the supplied audio corrupt memory rather than failing, so the bound is asserted
  /// against every combination rather than the one the caller happens to use.
  @Test("Compressing never reads past the frames it was given")
  func staysInsideTheInput() throws {
    for quantum in [64, 128, 256, 512, 1_024] {
      let compressor = try AudioWaveformSimilarityCompressor(
        format: AudioProcessingFormat(sampleRate: 48_000, channelCount: 1),
        maximumFrameCount: quantum
      )
      let available = quantum + compressor.maximumRemovableFrameCount
      var input = (0..<available).map { Float(sin(Double($0) * 0.01)) }
      var output = [Float](repeating: 0, count: quantum)

      let removed = input.withUnsafeMutableBufferPointer { inputBuffer in
        output.withUnsafeMutableBufferPointer { outputBuffer -> Int in
          let readOnly = [UnsafePointer(inputBuffer.baseAddress!)]
          let writable = [outputBuffer.baseAddress!]
          return readOnly.withUnsafeBufferPointer { input in
            writable.withUnsafeBufferPointer { output in
              compressor.compress(
                input: input,
                output: output,
                outputFrameCount: quantum,
                removal: compressor.maximumRemovableFrameCount
              )
            }
          }
        }
      }

      #expect(removed <= quantum)
      #expect(removed <= compressor.maximumRemovableFrameCount)
      #expect(output.allSatisfy { $0.isFinite })
    }
  }
}
