// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RilliyaRealtime

@Suite("Audio jitter buffer")
struct AudioJitterBufferTests {
  private enum Fixture {
    static let sampleRate = 48_000.0
    static let quantum = 128
    static let capacity = 32_768

    /// Five milliseconds at 48 kHz.
    static let targetFrames = 240

    static func configuration(
      target: Duration = .milliseconds(5),
      minimum: Duration = .milliseconds(2),
      maximum: Duration = .milliseconds(200),
      underrunPenalty: Duration = .milliseconds(3),
      trimFraction: Double = 0.05,
      correction: AudioJitterCorrection = .discard,
      surplusReadsBeforeCorrection: Int = 0
    ) throws -> AudioJitterBufferConfiguration {
      try AudioJitterBufferConfiguration(
        targetLatency: target,
        minimumLatency: minimum,
        maximumLatency: maximum,
        underrunPenalty: underrunPenalty,
        trimFraction: trimFraction,
        correction: correction,
        surplusReadsBeforeCorrection: surplusReadsBeforeCorrection
      )
    }
  }

  @Test("The buffer holds silence until it reaches its target")
  func prefillBeforePlaying() throws {
    let harness = try Harness()

    // One quantum is not the target, so nothing plays yet.
    harness.write(Fixture.quantum)
    #expect(harness.read() == .silence)
    #expect(!harness.buffer.statistics().isPlaying)

    harness.write(Fixture.targetFrames)
    #expect(harness.read() == .audio)
    #expect(harness.buffer.statistics().isPlaying)
  }

  /// Reading straight from the queue lets every late packet insert a gap the stream never makes
  /// up, so latency ratchets upward one underrun at a time. Refilling instead keeps the delay a
  /// measured quantity.
  @Test("An underrun raises the target and refills rather than handing out a gap")
  func underrunRaisesTheTarget() throws {
    let harness = try Harness()
    harness.write(Fixture.targetFrames + Fixture.quantum)
    #expect(harness.read() == .audio)

    let before = harness.buffer.statistics().targetFrameCount
    harness.drainEverything()
    #expect(harness.read() == .silence)

    let after = harness.buffer.statistics()
    #expect(after.targetFrameCount > before)
    #expect(after.underrunCount == 1)
    #expect(!after.isPlaying)
  }

  @Test("The target stops rising at the ceiling")
  func targetIsBounded() throws {
    let harness = try Harness(
      configuration: try Fixture.configuration(maximum: .milliseconds(20))
    )
    for _ in 0..<200 {
      harness.write(Fixture.targetFrames * 4)
      _ = harness.read()
      harness.drainEverything()
      _ = harness.read()
    }

    let ceiling = Int(0.020 * Fixture.sampleRate)
    #expect(harness.buffer.statistics().targetFrameCount <= ceiling)
  }

  /// A surplus trimmed all at once is an audible step; trimming a fraction each read turns it
  /// into a ramp.
  @Test("A surplus is trimmed gradually rather than in one step")
  func surplusIsTrimmedGradually() throws {
    let harness = try Harness()
    harness.write(Fixture.targetFrames * 20)
    #expect(harness.read() == .audio)

    let firstTrim = harness.buffer.statistics().trimmedFrameCount
    #expect(firstTrim > 0)
    let surplus = Fixture.targetFrames * 20 - Fixture.targetFrames
    #expect(Int(firstTrim) < surplus / 2)

    var reads = 1
    while harness.buffer.statistics().availableFrameCount > Fixture.targetFrames * 2,
      reads < 500
    {
      harness.write(Fixture.quantum)
      _ = harness.read()
      reads += 1
    }
    #expect(reads > 5)
    #expect(reads < 500)
  }

  /// A burst that arrives early and drains again needs no correction, and correcting it anyway
  /// spends audio on nothing.
  @Test("A surplus that does not persist is left alone")
  func transientSurplusIsIgnored() throws {
    let harness = try Harness(
      configuration: try Fixture.configuration(surplusReadsBeforeCorrection: 8)
    )
    harness.write(Fixture.targetFrames * 6)

    // Fewer reads above target than the hysteresis allows.
    for _ in 0..<6 { _ = harness.read() }

    #expect(harness.buffer.statistics().trimmedFrameCount == 0)
  }

  @Test("A surplus that persists past the hysteresis is corrected")
  func persistentSurplusIsCorrected() throws {
    let harness = try Harness(
      configuration: try Fixture.configuration(surplusReadsBeforeCorrection: 8)
    )
    harness.write(Fixture.targetFrames * 40)

    for _ in 0..<12 {
      harness.write(Fixture.quantum)
      _ = harness.read()
    }

    #expect(harness.buffer.statistics().trimmedFrameCount > 0)
  }

  /// Overlapping needs a block long enough to host the crossfade, so a buffer configured for it
  /// with a short quantum has to fall back rather than silently stop correcting.
  @Test("Overlap correction is used when the quantum allows and falls back when it does not")
  func overlapFallsBackOnShortQuanta() throws {
    let long = try Harness(
      configuration: try Fixture.configuration(correction: .overlap),
      quantum: 1_024
    )
    long.write(Fixture.targetFrames * 40)
    for _ in 0..<12 {
      long.write(1_024)
      _ = long.read()
    }
    #expect(long.buffer.statistics().overlapCount > 0)

    let short = try Harness(
      configuration: try Fixture.configuration(correction: .overlap),
      quantum: 128
    )
    short.write(Fixture.targetFrames * 40)
    for _ in 0..<12 {
      short.write(128)
      _ = short.read()
    }
    #expect(short.buffer.statistics().overlapCount == 0)
    #expect(short.buffer.statistics().trimmedFrameCount > 0)
  }

  @Test("A steady stream neither trims nor underruns")
  func steadyStreamIsUntouched() throws {
    let harness = try Harness()
    harness.write(Fixture.targetFrames)
    for _ in 0..<400 {
      harness.write(Fixture.quantum)
      #expect(harness.read() == .audio)
    }

    let statistics = harness.buffer.statistics()
    #expect(statistics.underrunCount == 0)
    #expect(statistics.trimmedFrameCount == 0)
    #expect(statistics.isPlaying)
  }

  @Test("Resynchronizing empties the queue and refills")
  func resynchronize() throws {
    let harness = try Harness()
    harness.write(Fixture.targetFrames * 4)
    #expect(harness.read() == .audio)

    harness.buffer.resynchronize()
    let statistics = harness.buffer.statistics()
    #expect(!statistics.isPlaying)
    #expect(statistics.availableFrameCount == 0)
    #expect(statistics.resynchronizationCount == 1)
    #expect(harness.read() == .silence)
  }

  @Test("Controls that cannot be ordered are rejected")
  func configurationValidation() {
    #expect(throws: AudioJitterBufferError.invalidLatencyRange) {
      _ = try Fixture.configuration(target: .milliseconds(1), minimum: .milliseconds(5))
    }
    #expect(throws: AudioJitterBufferError.invalidLatencyRange) {
      _ = try Fixture.configuration(target: .milliseconds(500), maximum: .milliseconds(200))
    }
    #expect(throws: AudioJitterBufferError.invalidLatencyRange) {
      _ = try Fixture.configuration(trimFraction: 0)
    }
  }

  @Test("A ceiling the queue cannot hold is rejected")
  func capacityValidation() throws {
    let frameBuffer = try AudioRealtimeFrameBuffer(
      format: AudioProcessingFormat(sampleRate: Fixture.sampleRate, channelCount: 1),
      capacityFrameCount: 512
    )

    #expect(throws: AudioJitterBufferError.self) {
      _ = try AudioJitterBuffer(
        frameBuffer: frameBuffer,
        configuration: try Fixture.configuration(maximum: .milliseconds(200))
      )
    }
  }

  private enum ReadOutcome: Equatable {
    case audio
    case silence
  }

  private final class Harness {
    let frameBuffer: AudioRealtimeFrameBuffer
    let buffer: AudioJitterBuffer
    let quantum: Int

    private let output: [UnsafeMutablePointer<Float>]
    private let input: [UnsafeMutablePointer<Float>]
    private var writtenFrames = 0

    init(
      configuration: AudioJitterBufferConfiguration? = nil,
      quantum: Int = Fixture.quantum
    ) throws {
      self.quantum = quantum
      frameBuffer = try AudioRealtimeFrameBuffer(
        format: AudioProcessingFormat(sampleRate: Fixture.sampleRate, channelCount: 1),
        capacityFrameCount: Fixture.capacity
      )
      buffer = try AudioJitterBuffer(
        frameBuffer: frameBuffer,
        configuration: configuration ?? Fixture.configuration(),
        maximumFrameCount: quantum
      )
      output = [UnsafeMutablePointer<Float>.allocate(capacity: quantum)]
      input = [UnsafeMutablePointer<Float>.allocate(capacity: Fixture.capacity)]
      output[0].initialize(repeating: 0, count: quantum)
      input[0].initialize(repeating: 0, count: Fixture.capacity)
    }

    deinit {
      output[0].deallocate()
      input[0].deallocate()
    }

    /// Writes a run of nonzero samples so a read can tell audio from silence.
    func write(_ frameCount: Int) {
      for index in 0..<frameCount {
        input[0][index] = Float(writtenFrames + index + 1)
      }
      writtenFrames += frameCount
      let pointers = [UnsafePointer(input[0])]
      _ = pointers.withUnsafeBufferPointer {
        frameBuffer.writePlanar($0, frameCount: frameCount)
      }
    }

    func drainEverything() {
      frameBuffer.discardOldestFrames(keepingLatest: 0)
    }

    func read() -> ReadOutcome {
      output[0].update(repeating: .nan, count: quantum)
      _ = output.withUnsafeBufferPointer {
        buffer.read(into: $0, frameCount: quantum)
      }
      let samples = UnsafeBufferPointer(start: output[0], count: quantum)
      return samples.allSatisfy { $0 == 0 } ? .silence : .audio
    }
  }
}
