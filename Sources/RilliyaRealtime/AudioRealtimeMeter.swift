// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import Dispatch
import Foundation
import RilliyaCore
import os.lock

/// What a realtime meter reports and how often.
public struct AudioRealtimeMeterConfiguration: Equatable, Hashable, Sendable {
  /// How many times a second a snapshot is produced.
  public let updatesPerSecond: Int

  /// How many points one channel's drawable waveform is reduced to.
  public let waveformSampleCount: Int

  /// The floor a silent channel reports rather than negative infinity.
  public let minimumDecibels: Float

  /// Creates meter controls.
  public init(
    updatesPerSecond: Int = 30,
    waveformSampleCount: Int = 128,
    minimumDecibels: Float = -80
  ) {
    precondition(updatesPerSecond > 0)
    precondition(waveformSampleCount > 0)
    self.updatesPerSecond = updatesPerSecond
    self.waveformSampleCount = waveformSampleCount
    self.minimumDecibels = minimumDecibels
  }
}

/// Measures audio where measuring is all that may happen, and delivers it where drawing may.
///
/// Some audio only exists on the thread that renders it — a generator makes its samples as it
/// plays them, and there is no producer elsewhere to read. Measuring has to happen there, which
/// means into storage that is already allocated, under a lock that is only ever tried, and with
/// nothing handed to application code. The snapshot is then delivered on a queue of its own, which
/// is where allocating an array and calling a handler are allowed.
///
/// A reader that falls behind sees the newest measurement rather than a backlog, because a drawing
/// is only ever interested in what the audio is doing now.
@available(macOS 14.2, *)
public final class AudioRealtimeMeter: @unchecked Sendable {
  /// Receives one measurement, on the meter's delivery queue rather than the audio thread.
  public typealias SnapshotHandler =
    @Sendable (
      _ sequence: UInt64,
      _ frameCount: Int,
      _ channels: [AudioChannelMeterSnapshot]
    ) -> Void

  private let sampleRate: Double
  private let channelIDs: [AudioChannelID]
  private let configuration: AudioRealtimeMeterConfiguration
  private let snapshotHandler: SnapshotHandler
  private let deliverySource: DispatchSourceUserDataAdd
  private let rootMeanSquares: UnsafeMutablePointer<Float>
  private let peaks: UnsafeMutablePointer<Float>
  private let decibels: UnsafeMutablePointer<Float>
  private let clipping: UnsafeMutablePointer<Bool>
  private let waveformCounts: UnsafeMutablePointer<Int>
  private let waveforms: UnsafeMutablePointer<Float>
  private var storageLock = os_unfair_lock_s()
  private var framesUntilUpdate = 0
  private var latestFrameCount = 0
  private var sequence: UInt64 = 0
  private var publishedSequence: UInt64 = 0
  private var isPublishing = true

  /// Preallocates every measurement slot away from the audio thread.
  public init(
    sampleRate: Double,
    channelIDs: [AudioChannelID],
    configuration: AudioRealtimeMeterConfiguration,
    snapshotHandler: @escaping SnapshotHandler
  ) {
    self.sampleRate = sampleRate
    self.channelIDs = channelIDs
    self.configuration = configuration
    self.snapshotHandler = snapshotHandler
    let channelCount = channelIDs.count
    let waveformCapacity = channelCount * configuration.waveformSampleCount
    rootMeanSquares = .allocate(capacity: channelCount)
    peaks = .allocate(capacity: channelCount)
    decibels = .allocate(capacity: channelCount)
    clipping = .allocate(capacity: channelCount)
    waveformCounts = .allocate(capacity: channelCount)
    waveforms = .allocate(capacity: waveformCapacity)
    rootMeanSquares.initialize(repeating: 0, count: channelCount)
    peaks.initialize(repeating: 0, count: channelCount)
    decibels.initialize(repeating: configuration.minimumDecibels, count: channelCount)
    clipping.initialize(repeating: false, count: channelCount)
    waveformCounts.initialize(repeating: 0, count: channelCount)
    waveforms.initialize(repeating: 0, count: waveformCapacity)

    let deliveryQueue = DispatchQueue(
      label: "moe.uwucocoa.rilliyakit.meter.delivery",
      qos: .userInitiated
    )
    deliverySource = DispatchSource.makeUserDataAddSource(queue: deliveryQueue)
    deliverySource.setEventHandler { [weak self] in
      self?.publishLatestSnapshot()
    }
    deliverySource.resume()
  }

  deinit {
    deliverySource.setEventHandler {}
    deliverySource.cancel()
    let channelCount = channelIDs.count
    rootMeanSquares.deinitialize(count: channelCount)
    peaks.deinitialize(count: channelCount)
    decibels.deinitialize(count: channelCount)
    clipping.deinitialize(count: channelCount)
    waveformCounts.deinitialize(count: channelCount)
    waveforms.deinitialize(count: channelCount * configuration.waveformSampleCount)
    rootMeanSquares.deallocate()
    peaks.deallocate()
    decibels.deallocate()
    clipping.deallocate()
    waveformCounts.deallocate()
    waveforms.deallocate()
  }

  /// Measures one CoreAudio buffer list, on the thread that produced it.
  public func consume(_ list: UnsafePointer<AudioBufferList>) {
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
    guard let firstBuffer = buffers.first else { return }
    let firstChannelCount = max(Int(firstBuffer.mNumberChannels), 1)
    let frameCount =
      Int(firstBuffer.mDataByteSize)
      / MemoryLayout<Float32>.stride
      / firstChannelCount
    guard frameCount > 0 else { return }

    framesUntilUpdate -= frameCount
    guard framesUntilUpdate <= 0 else { return }
    framesUntilUpdate = max(1, Int(sampleRate / Double(configuration.updatesPerSecond)))
    guard os_unfair_lock_trylock(&storageLock) else { return }
    defer { os_unfair_lock_unlock(&storageLock) }
    guard isPublishing else { return }

    var channelIndex = 0
    for buffer in buffers {
      let localChannelCount = max(Int(buffer.mNumberChannels), 1)
      let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.stride
      let localFrameCount = sampleCount / localChannelCount
      let samples = buffer.mData?.assumingMemoryBound(to: Float32.self)

      for localChannel in 0..<localChannelCount where channelIndex < channelIDs.count {
        let waveform = waveforms.advanced(
          by: channelIndex * configuration.waveformSampleCount
        )
        let scalars = AudioMeterDSP.writeMeasurement(
          samples: samples.map { $0.advanced(by: localChannel) },
          frameCount: localFrameCount,
          sampleStride: localChannelCount,
          waveformSampleCount: configuration.waveformSampleCount,
          minimumDecibels: configuration.minimumDecibels,
          waveformOutput: waveform
        )
        rootMeanSquares[channelIndex] = scalars.rootMeanSquare
        peaks[channelIndex] = scalars.peak
        decibels[channelIndex] = scalars.decibels
        clipping[channelIndex] = scalars.isClipping
        waveformCounts[channelIndex] = scalars.waveformCount
        channelIndex += 1
      }
    }

    silenceChannels(from: channelIndex)
    latestFrameCount = frameCount
    sequence &+= 1
    deliverySource.add(data: 1)
  }

  /// Measures noninterleaved channels, on the thread that produced them.
  ///
  /// What audio made inside a render graph has to use: a generator writes its channels straight
  /// into the graph's buffers and there is no buffer list to hand over. Deliberately not shared
  /// with the buffer-list path through a closure — this runs on the audio thread, where a call
  /// through an unknown function is the thing being avoided.
  public func consume(
    planar channels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) {
    guard frameCount > 0 else { return }
    framesUntilUpdate -= frameCount
    guard framesUntilUpdate <= 0 else { return }
    framesUntilUpdate = max(1, Int(sampleRate / Double(configuration.updatesPerSecond)))
    guard os_unfair_lock_trylock(&storageLock) else { return }
    defer { os_unfair_lock_unlock(&storageLock) }
    guard isPublishing else { return }

    var channelIndex = 0
    while channelIndex < min(channels.count, channelIDs.count) {
      let waveform = waveforms.advanced(by: channelIndex * configuration.waveformSampleCount)
      let scalars = AudioMeterDSP.writeMeasurement(
        samples: channels[channelIndex],
        frameCount: frameCount,
        sampleStride: 1,
        waveformSampleCount: configuration.waveformSampleCount,
        minimumDecibels: configuration.minimumDecibels,
        waveformOutput: waveform
      )
      rootMeanSquares[channelIndex] = scalars.rootMeanSquare
      peaks[channelIndex] = scalars.peak
      decibels[channelIndex] = scalars.decibels
      clipping[channelIndex] = scalars.isClipping
      waveformCounts[channelIndex] = scalars.waveformCount
      channelIndex += 1
    }

    silenceChannels(from: channelIndex)
    latestFrameCount = frameCount
    sequence &+= 1
    deliverySource.add(data: 1)
  }

  /// Reports silence for channels this measurement did not reach.
  private func silenceChannels(from firstChannelIndex: Int) {
    var channelIndex = firstChannelIndex
    while channelIndex < channelIDs.count {
      let waveform = waveforms.advanced(by: channelIndex * configuration.waveformSampleCount)
      waveform.update(repeating: 0, count: configuration.waveformSampleCount)
      rootMeanSquares[channelIndex] = 0
      peaks[channelIndex] = 0
      decibels[channelIndex] = configuration.minimumDecibels
      clipping[channelIndex] = false
      waveformCounts[channelIndex] = 0
      channelIndex += 1
    }
  }

  /// Stops delivering, so a meter outliving its producer reports nothing rather than stale audio.
  public func stopPublishing() {
    os_unfair_lock_lock(&storageLock)
    isPublishing = false
    os_unfair_lock_unlock(&storageLock)
  }

  private func publishLatestSnapshot() {
    os_unfair_lock_lock(&storageLock)
    guard isPublishing, publishedSequence != sequence else {
      os_unfair_lock_unlock(&storageLock)
      return
    }
    let capturedSequence = sequence
    let capturedFrameCount = latestFrameCount
    var channelSnapshots: [AudioChannelMeterSnapshot] = []
    channelSnapshots.reserveCapacity(channelIDs.count)
    for (index, channelID) in channelIDs.enumerated() {
      let waveformStart = waveforms.advanced(by: index * configuration.waveformSampleCount)
      let waveform = Array(
        UnsafeBufferPointer(start: waveformStart, count: waveformCounts[index])
      )
      channelSnapshots.append(
        AudioChannelMeterSnapshot(
          channelID: channelID,
          rootMeanSquare: rootMeanSquares[index],
          peak: peaks[index],
          decibels: decibels[index],
          isClipping: clipping[index],
          waveform: waveform
        )
      )
    }
    publishedSequence = capturedSequence
    os_unfair_lock_unlock(&storageLock)

    snapshotHandler(capturedSequence, capturedFrameCount, channelSnapshots)
  }
}
