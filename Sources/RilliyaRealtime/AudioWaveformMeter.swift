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
  public static let defaultInterval = Duration.milliseconds(1_000 / defaultUpdatesPerSecond)

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
  /// Copies and returns; it never measures, allocates, or waits on the reader. Frames beyond the
  /// interval being gathered are dropped, because a meter reports the recent rather than all of it.
  public func submit(interleaved samples: UnsafePointer<Float>, frameCount: Int) {
    guard frameCount > 0 else { return }
    let ready: Int? = inputLock.withLock {
      let room = capacityFrameCount - writtenFrameCount
      guard room > 0 else { return writtenFrameCount }
      let taken = min(room, frameCount)
      storage.advanced(by: writtenFrameCount * channelCount)
        .update(from: samples, count: taken * channelCount)
      writtenFrameCount += taken
      return writtenFrameCount >= capacityFrameCount ? writtenFrameCount : nil
    }
    guard let ready else { return }
    measure(frameCount: ready)
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
    let ready: Int? = inputLock.withLock {
      let room = capacityFrameCount - writtenFrameCount
      guard room > 0 else { return writtenFrameCount }
      let taken = min(room, frameCount)
      let base = storage.advanced(by: writtenFrameCount * channelCount)
      for frame in 0..<taken {
        for channel in 0..<channelCount {
          base[frame * channelCount + channel] =
            channel < channels.count ? channels[channel][frame] : 0
        }
      }
      writtenFrameCount += taken
      return writtenFrameCount >= capacityFrameCount ? writtenFrameCount : nil
    }
    guard let ready else { return }
    measure(frameCount: ready)
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
