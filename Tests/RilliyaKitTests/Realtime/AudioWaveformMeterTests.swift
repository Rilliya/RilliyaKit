// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaCore
import Testing

@testable import RilliyaRealtime

/// A source with no capture device behind it meters itself through this, so what it reports is
/// the only thing an interface can draw for such a source.
@Suite("Audio waveform meter")
struct AudioWaveformMeterTests {
  private enum Fixture {
    static let sampleRate = 48_000.0
    static let channelCount = 2
    /// Fifty milliseconds at 48 kHz.
    static let intervalFrameCount = 2_400

    static func channelIDs(_ count: Int = channelCount) -> [AudioChannelID] {
      let owner = AudioChannelOwnerID.source(.stream(UUID()))
      return (0..<count).compactMap { index in
        AudioChannelIndex(rawValue: index).map { AudioChannelID(ownerID: owner, index: $0) }
      }
    }

    static func meter(channelCount: Int = channelCount) -> AudioWaveformMeter {
      AudioWaveformMeter(channelIDs: channelIDs(channelCount), sampleRate: sampleRate)
    }
  }

  @Test("Nothing is reported before enough audio has arrived")
  func emptyBeforeAnInterval() {
    let meter = Fixture.meter()
    var frame = [Float](repeating: 0.5, count: 2 * Fixture.channelCount)

    frame.withUnsafeBufferPointer {
      guard let base = $0.baseAddress else { return }
      meter.submit(interleaved: base, frameCount: 2)
    }

    #expect(meter.snapshot().isEmpty)
  }

  @Test("A full interval is reported, one entry per channel")
  func intervalIsReported() {
    let meter = Fixture.meter()

    Self.feedTone(meter, frameCount: Fixture.intervalFrameCount)

    let snapshot = meter.snapshot()
    #expect(snapshot.count == Fixture.channelCount)
    #expect(Set(snapshot.map(\.channelID.index.rawValue)) == [0, 1])
    for channel in snapshot {
      #expect(!channel.waveform.isEmpty)
      #expect(channel.rootMeanSquare > 0.1)
    }
  }

  /// Each channel is measured on its own, or a source could not be drawn channel by channel.
  @Test("Channels are measured apart from each other")
  func channelsAreMeasuredApart() {
    let meter = Fixture.meter()
    let frames = Fixture.intervalFrameCount
    var samples = [Float](repeating: 0, count: frames * Fixture.channelCount)
    for frame in 0..<frames {
      // Left loud, right quiet.
      samples[frame * 2] = Float(0.5 * sin(2 * .pi * 440 * Double(frame) / Fixture.sampleRate))
      samples[frame * 2 + 1] = samples[frame * 2] * 0.1
    }
    samples.withUnsafeBufferPointer {
      guard let base = $0.baseAddress else { return }
      meter.submit(interleaved: base, frameCount: frames)
    }

    let snapshot = meter.snapshot()
    #expect(snapshot.count == 2)
    let left = snapshot[0].rootMeanSquare
    let right = snapshot[1].rootMeanSquare
    #expect(left > right * 5, "the channels were measured together, \(left) against \(right)")
  }

  @Test("Silence reports as silence rather than as nothing")
  func silenceIsReported() {
    let meter = Fixture.meter()
    var samples = [Float](repeating: 0, count: Fixture.intervalFrameCount * Fixture.channelCount)

    samples.withUnsafeBufferPointer {
      guard let base = $0.baseAddress else { return }
      meter.submit(interleaved: base, frameCount: Fixture.intervalFrameCount)
    }

    let snapshot = meter.snapshot()
    #expect(snapshot.count == Fixture.channelCount)
    for channel in snapshot {
      #expect(channel.rootMeanSquare == 0)
      #expect(channel.waveform.allSatisfy { $0 == 0 })
    }
  }

  /// A reader that draws twice between two intervals sees the same audio, not a backlog.
  @Test("The newest interval replaces the last")
  func newestReplacesTheLast() {
    let meter = Fixture.meter()

    Self.feedTone(meter, frameCount: Fixture.intervalFrameCount, amplitude: 0.5)
    let loud = meter.snapshot().first?.rootMeanSquare ?? 0
    Self.feedTone(meter, frameCount: Fixture.intervalFrameCount, amplitude: 0.05)
    let quiet = meter.snapshot().first?.rootMeanSquare ?? 0

    #expect(loud > 0.2)
    #expect(quiet < loud / 4, "the meter reported the old interval, \(quiet) against \(loud)")
  }

  @Test("A reset forgets what was gathered")
  func resetForgets() {
    let meter = Fixture.meter()
    Self.feedTone(meter, frameCount: Fixture.intervalFrameCount)
    #expect(!meter.snapshot().isEmpty)

    meter.reset()

    #expect(meter.snapshot().isEmpty)
  }

  private static func feedTone(
    _ meter: AudioWaveformMeter,
    frameCount: Int,
    amplitude: Float = 0.5
  ) {
    var samples = [Float](repeating: 0, count: frameCount * Fixture.channelCount)
    for frame in 0..<frameCount {
      let value =
        amplitude * Float(sin(2 * .pi * 440 * Double(frame) / Fixture.sampleRate))
      for channel in 0..<Fixture.channelCount {
        samples[frame * Fixture.channelCount + channel] = value
      }
    }
    samples.withUnsafeBufferPointer {
      guard let base = $0.baseAddress else { return }
      meter.submit(interleaved: base, frameCount: frameCount)
    }
  }
}
