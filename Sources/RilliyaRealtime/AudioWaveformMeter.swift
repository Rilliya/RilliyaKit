// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaCore
import os.lock

/// Publishes what a producer is putting out, so an interface can draw it.
///
/// A capture device meters itself on the way in. A source that is not a capture device — audio
/// arriving from a network, a file being played, a generated signal — has no such path, and
/// without one an interface cannot show anything for it at all.
///
/// The producer pushes; a reader takes the most recent snapshot whenever it draws. Nothing is
/// queued: a reader that is slow sees the newest audio rather than a backlog, which is what
/// drawing wants and what keeps the producer from ever waiting.
///
/// A reader can take the newest snapshot whenever it likes, but polling is not enough on its own:
/// something drawing thirty times a second cannot discover a change it is never told about. Set
/// ``onPublish`` to be told, and read ``snapshot()`` when a reader simply wants the latest.
///
/// Measuring costs one pass over the interval's samples and happens on the thread that completes
/// it, so a producer running where allocation is unsafe must not submit to this directly.
public final class AudioWaveformMeter: @unchecked Sendable {
  /// How often a snapshot is produced, which is what an interface can usefully draw.
  ///
  /// The same rate a capture device meters itself at, so a stream and a microphone drawn side by
  /// side move together. Faster would redraw a canvas that is otherwise idle for nothing.
  public static let defaultUpdatesPerSecond = 30

  /// The interval one snapshot covers.
  public static let defaultInterval = interval(forUpdatesPerSecond: defaultUpdatesPerSecond)

  /// The interval that reports `updatesPerSecond` times a second.
  ///
  /// Nothing above is refused. A rate a machine cannot keep up with is the caller's choice, and
  /// the arithmetic holds whatever they ask for.
  public static func interval(forUpdatesPerSecond updatesPerSecond: Int) -> Duration {
    .nanoseconds(1_000_000_000 / max(updatesPerSecond, 1))
  }

  /// The samples one channel's drawn waveform is reduced to.
  public static let defaultWaveformSampleCount = 512

  /// The quietest level reported, below which everything reads as silence.
  public static let minimumDecibels: Float = -96

  /// The channels this meter reports, in order.
  public let channelIDs: [AudioChannelID]

  private let waveformSampleCount: Int
  private let intervalFrameCount: Int
  private let channelCount: Int
  private let storage: UnsafeMutablePointer<Float>
  private let capacityFrameCount: Int
  private var writtenFrameCount = 0
  private let lock = OSAllocatedUnfairLock<[AudioChannelMeterSnapshot]>(initialState: [])
  private let inputLock = NSLock()
  private let handlerLock = NSLock()
  private var publishHandler: (@Sendable ([AudioChannelMeterSnapshot]) -> Void)?

  /// Prepares a meter for a fixed channel layout.
  ///
  /// - Parameters:
  ///   - channelIDs: the channels reported, in the order the producer interleaves them.
  ///   - sampleRate: the producer's rate, which decides how many frames one interval holds.
  ///   - interval: how much audio each snapshot covers.
  ///   - waveformSampleCount: the samples one channel's waveform is reduced to.
  ///
  /// A rate faster than the audio itself gathers less than one frame per report, which is
  /// meaningless but not broken: the interval is held at one frame rather than zero.
  public init(
    channelIDs: [AudioChannelID],
    sampleRate: Double,
    interval: Duration = AudioWaveformMeter.defaultInterval,
    waveformSampleCount: Int = AudioWaveformMeter.defaultWaveformSampleCount
  ) {
    self.channelIDs = channelIDs
    channelCount = max(channelIDs.count, 1)
    self.waveformSampleCount = max(waveformSampleCount, 1)
    let frames = Int((sampleRate * Double(interval.wholeNanoseconds) / 1_000_000_000).rounded())
    intervalFrameCount = max(frames, 1)
    capacityFrameCount = intervalFrameCount
    storage = .allocate(capacity: capacityFrameCount * channelCount)
    storage.initialize(repeating: 0, count: capacityFrameCount * channelCount)
  }

  deinit {
    storage.deinitialize(count: capacityFrameCount * channelCount)
    storage.deallocate()
  }

  /// Offers interleaved frames the producer has just put out.
  ///
  /// Every frame offered is gathered, reporting each time an interval fills. A submission larger
  /// than one interval is the ordinary case rather than the exception — a lossless block is four
  /// thousand frames and an interval at thirty a second is sixteen hundred — so taking only the
  /// first interval's worth would throw most of the audio away and report once per block instead
  /// of once per interval.
  public func submit(interleaved samples: UnsafePointer<Float>, frameCount: Int) {
    guard frameCount > 0 else { return }
    var offset = 0
    while offset < frameCount {
      let taken = gather(frameCount - offset) { destination, count in
        destination.update(from: samples + offset * channelCount, count: count * channelCount)
      }
      offset += taken.consumed
      if let ready = taken.ready { measure(frameCount: ready) }
    }
  }

  /// Offers planar frames the producer has just put out, one pointer per channel.
  ///
  /// The same handoff as ``submit(interleaved:frameCount:)``; it weaves the channels together on
  /// the way in because a meter reads them together.
  public func submit(
    planar channels: UnsafeBufferPointer<UnsafePointer<Float>>,
    frameCount: Int
  ) {
    guard frameCount > 0, !channels.isEmpty else { return }
    var offset = 0
    while offset < frameCount {
      let taken = gather(frameCount - offset) { destination, count in
        for frame in 0..<count {
          for channel in 0..<channelCount {
            destination[frame * channelCount + channel] =
              channel < channels.count ? channels[channel][offset + frame] : 0
          }
        }
      }
      offset += taken.consumed
      if let ready = taken.ready { measure(frameCount: ready) }
    }
  }

  /// Takes as much of what is offered as the interval being gathered has room for.
  ///
  /// - Returns: how many frames were taken, and the interval's length when it filled.
  private func gather(
    _ available: Int,
    writing: (UnsafeMutablePointer<Float>, Int) -> Void
  ) -> (consumed: Int, ready: Int?) {
    inputLock.withLock {
      let room = capacityFrameCount - writtenFrameCount
      let taken = min(max(room, 0), available)
      guard taken > 0 else { return (available, capacityFrameCount) }
      writing(storage.advanced(by: writtenFrameCount * channelCount), taken)
      writtenFrameCount += taken
      return (taken, writtenFrameCount >= capacityFrameCount ? capacityFrameCount : nil)
    }
  }

  /// The most recent snapshot, or an empty array before enough audio has arrived.
  public func snapshot() -> [AudioChannelMeterSnapshot] {
    lock.withLock { $0 }
  }

  /// Called whenever a new snapshot is ready, on whichever thread completed the interval.
  ///
  /// Anything that draws needs telling rather than asking: a reader with no other reason to look
  /// again shows the first waveform it happened to catch and nothing after it.
  public func onPublish(_ handler: (@Sendable ([AudioChannelMeterSnapshot]) -> Void)?) {
    handlerLock.withLock { publishHandler = handler }
  }

  /// Forgets what was gathered, as a source that restarted requires.
  public func reset() {
    inputLock.withLock { writtenFrameCount = 0 }
    lock.withLock { $0 = [] }
  }

  private func measure(frameCount: Int) {
    let sampleCount = frameCount * channelCount
    let samples = Array(UnsafeBufferPointer(start: storage, count: sampleCount))
    inputLock.withLock { writtenFrameCount = 0 }

    let measurements = AudioMeterDSP.processInterleaved(
      samples,
      channelCount: channelCount,
      waveformSampleCount: waveformSampleCount,
      minimumDecibels: Self.minimumDecibels
    )
    // Only channels the caller named are reported; the measurement carries no identity of its
    // own, and inventing one would put a channel on screen that nothing upstream can name.
    let snapshots = zip(measurements, channelIDs).map { measurement, channelID in
      AudioChannelMeterSnapshot(
        channelID: channelID,
        rootMeanSquare: measurement.rootMeanSquare,
        peak: measurement.peak,
        decibels: measurement.decibels,
        isClipping: measurement.isClipping,
        waveform: measurement.waveform
      )
    }
    lock.withLock { $0 = snapshots }
    // Outside the locks: a handler is free to hop to wherever it draws.
    let handler = handlerLock.withLock { publishHandler }
    handler?(snapshots)
  }
}
