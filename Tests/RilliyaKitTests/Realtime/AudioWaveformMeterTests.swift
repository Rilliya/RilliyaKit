import Foundation
import RilliyaCore
import Testing
import os.lock

@testable import RilliyaRealtime

// SPDX-License-Identifier: Apache-2.0

/// A source with no capture device behind it meters itself through this, so what it reports is
/// the only thing an interface can draw for such a source.
@Suite("Audio waveform meter")
struct AudioWaveformMeterTests {
  private enum Fixture {
    static let sampleRate = 48_000.0
    static let channelCount = 2
    /// One publishing interval at 48 kHz, which is what fills before anything is reported.
    static let intervalFrameCount = Int(
      48_000 / Double(AudioWaveformMeter.defaultUpdatesPerSecond))

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

  /// A source that produces planar audio meters the same as one that produces interleaved, or a
  /// file being played could not be drawn while a network stream could.
  @Test("Planar audio meters the same as interleaved")
  func planarMatchesInterleaved() {
    let frames = Fixture.intervalFrameCount
    let interleavedMeter = Fixture.meter()
    let planarMeter = Fixture.meter()

    var interleaved = [Float](repeating: 0, count: frames * Fixture.channelCount)
    var left = [Float](repeating: 0, count: frames)
    var right = [Float](repeating: 0, count: frames)
    for frame in 0..<frames {
      let value = Float(0.5 * sin(2 * .pi * 440 * Double(frame) / Fixture.sampleRate))
      interleaved[frame * 2] = value
      interleaved[frame * 2 + 1] = value * 0.25
      left[frame] = value
      right[frame] = value * 0.25
    }
    interleaved.withUnsafeBufferPointer {
      guard let base = $0.baseAddress else { return }
      interleavedMeter.submit(interleaved: base, frameCount: frames)
    }
    left.withUnsafeBufferPointer { l in
      right.withUnsafeBufferPointer { r in
        guard let lb = l.baseAddress, let rb = r.baseAddress else { return }
        [lb, rb].withUnsafeBufferPointer { channels in
          planarMeter.submit(planar: channels, frameCount: frames)
        }
      }
    }

    let fromInterleaved = interleavedMeter.snapshot()
    let fromPlanar = planarMeter.snapshot()
    #expect(fromPlanar.count == fromInterleaved.count)
    #expect(fromPlanar.count == 2)
    for (planar, woven) in zip(fromPlanar, fromInterleaved) {
      #expect(abs(planar.rootMeanSquare - woven.rootMeanSquare) < 0.0001)
      #expect(planar.waveform == woven.waveform)
    }
    // And the channels stayed apart rather than being averaged on the way in.
    #expect(fromPlanar[0].rootMeanSquare > fromPlanar[1].rootMeanSquare * 3)
  }

  /// Anything that draws needs telling rather than asking.
  ///
  /// A reader that only polls redraws when something else happens to change, which showed a
  /// network stream's waveform moving about once every ten seconds instead of many times a
  /// second.
  @Test("A new interval tells whoever is drawing")
  func publishingTells() {
    let meter = Fixture.meter()
    let told = OSAllocatedUnfairLock<[[AudioChannelMeterSnapshot]]>(initialState: [])
    meter.onPublish { snapshots in told.withLock { $0.append(snapshots) } }

    Self.feedTone(meter, frameCount: Fixture.intervalFrameCount, amplitude: 0.5)
    Self.feedTone(meter, frameCount: Fixture.intervalFrameCount, amplitude: 0.2)

    let reports = told.withLock { $0 }
    #expect(reports.count == 2, "told \(reports.count) times for two intervals")
    #expect(reports.allSatisfy { $0.count == Fixture.channelCount })
    // What it was told matches what it would have read.
    #expect(reports.last?.map(\.waveform) == meter.snapshot().map(\.waveform))
  }

  @Test("Nothing is told after the handler is taken away")
  func publishingStopsWhenAsked() {
    let meter = Fixture.meter()
    let count = OSAllocatedUnfairLock<Int>(initialState: 0)
    meter.onPublish { _ in count.withLock { $0 += 1 } }

    Self.feedTone(meter, frameCount: Fixture.intervalFrameCount)
    let afterFirst = count.withLock { $0 }
    meter.onPublish(nil)
    Self.feedTone(meter, frameCount: Fixture.intervalFrameCount)

    #expect(afterFirst == 1)
    #expect(count.withLock { $0 } == 1)
  }

  /// A rate is the caller's to choose, so the arithmetic has to hold at any of them.
  @Test(
    "Any rate a caller asks for produces a usable interval",
    arguments: [1, 30, 60, 120, 240, 1_000, 100_000, 1_000_000]
  )
  func anyRateIsUsable(updatesPerSecond: Int) {
    let interval = AudioWaveformMeter.interval(forUpdatesPerSecond: updatesPerSecond)
    #expect(interval > .zero, "\(updatesPerSecond) gave an interval of nothing")

    let meter = AudioWaveformMeter(
      channelIDs: Fixture.channelIDs(),
      sampleRate: Fixture.sampleRate,
      interval: interval
    )
    // One second of audio, whatever the rate, and it must report something and not trap.
    Self.feedTone(meter, frameCount: Int(Fixture.sampleRate))

    #expect(meter.snapshot().count == Fixture.channelCount)
  }

  /// A rate below one would report nothing at all, so it is the one value held.
  @Test("A rate of nothing is held at the slowest that still reports")
  func nonPositiveRateIsHeld() {
    for rate in [0, -1, Int.min + 1] {
      #expect(
        AudioWaveformMeter.interval(forUpdatesPerSecond: rate)
          == AudioWaveformMeter.interval(forUpdatesPerSecond: 1)
      )
    }
  }

  /// The rate decides how often there is something new, which is what the preference sets.
  @Test("A faster rate reports more often over the same audio")
  func fasterRateReportsMoreOften() {
    let slow = AudioWaveformMeter(
      channelIDs: Fixture.channelIDs(),
      sampleRate: Fixture.sampleRate,
      interval: AudioWaveformMeter.interval(forUpdatesPerSecond: 30)
    )
    let fast = AudioWaveformMeter(
      channelIDs: Fixture.channelIDs(),
      sampleRate: Fixture.sampleRate,
      interval: AudioWaveformMeter.interval(forUpdatesPerSecond: 120)
    )
    let slowCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    let fastCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    slow.onPublish { _ in slowCount.withLock { $0 += 1 } }
    fast.onPublish { _ in fastCount.withLock { $0 += 1 } }

    // Exactly one second of audio through each.
    Self.feedTone(slow, frameCount: Int(Fixture.sampleRate))
    Self.feedTone(fast, frameCount: Int(Fixture.sampleRate))

    #expect(slowCount.withLock { $0 } == 30)
    #expect(fastCount.withLock { $0 } == 120)
  }

  /// A submission larger than one interval is the ordinary case, not the exception.
  ///
  /// A lossless block is 4096 frames and an interval at thirty a second is 1600, so taking only
  /// the first interval's worth threw most of every block away and reported once per block
  /// instead of once per interval.
  @Test("A block larger than an interval is gathered whole")
  func oversizedSubmissionIsGatheredWhole() {
    let meter = Fixture.meter()
    let reports = OSAllocatedUnfairLock<Int>(initialState: 0)
    meter.onPublish { _ in reports.withLock { $0 += 1 } }

    // Four thousand and ninety-six frames at a time, as Apple Lossless arrives, for one second.
    let block = 4_096
    let blocks = Int(Fixture.sampleRate) / block
    for _ in 0..<blocks {
      Self.feedTone(meter, frameCount: block)
    }

    // A second of audio is a second's worth of reports, however it was handed over.
    let counted = reports.withLock { $0 }
    let expected = blocks * block / Fixture.intervalFrameCount
    #expect(counted == expected, "reported \(counted) times for \(expected) intervals of audio")
    #expect(counted > blocks, "reported once per block rather than once per interval")
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
