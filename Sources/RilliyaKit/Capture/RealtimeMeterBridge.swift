// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import Dispatch
import Foundation
import os.lock

@available(macOS 14.2, *)
final class RealtimeMeterBridge: @unchecked Sendable {
  private let format: ProcessOutputCaptureFormat
  private let configuration: ProcessOutputCaptureConfiguration
  private let snapshotHandler: ProcessOutputCapture.SnapshotHandler
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

  init(
    format: ProcessOutputCaptureFormat,
    configuration: ProcessOutputCaptureConfiguration,
    snapshotHandler: @escaping ProcessOutputCapture.SnapshotHandler
  ) {
    self.format = format
    self.configuration = configuration
    self.snapshotHandler = snapshotHandler
    let channelCount = format.channelIDs.count
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
      label: "moe.uwucocoa.rilliyakit.process-meter.delivery",
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
    let channelCount = format.channelIDs.count
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

  func consume(_ list: UnsafePointer<AudioBufferList>) {
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
    framesUntilUpdate = max(1, Int(format.sampleRate / Double(configuration.updatesPerSecond)))
    guard os_unfair_lock_trylock(&storageLock) else { return }
    defer { os_unfair_lock_unlock(&storageLock) }
    guard isPublishing else { return }

    var channelIndex = 0
    for buffer in buffers {
      let localChannelCount = max(Int(buffer.mNumberChannels), 1)
      let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.stride
      let localFrameCount = sampleCount / localChannelCount
      let samples = buffer.mData?.assumingMemoryBound(to: Float32.self)

      for localChannel in 0..<localChannelCount where channelIndex < format.channelIDs.count {
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

    while channelIndex < format.channelIDs.count {
      let waveform = waveforms.advanced(
        by: channelIndex * configuration.waveformSampleCount
      )
      waveform.update(repeating: 0, count: configuration.waveformSampleCount)
      rootMeanSquares[channelIndex] = 0
      peaks[channelIndex] = 0
      decibels[channelIndex] = configuration.minimumDecibels
      clipping[channelIndex] = false
      waveformCounts[channelIndex] = 0
      channelIndex += 1
    }

    latestFrameCount = frameCount
    sequence &+= 1
    deliverySource.add(data: 1)
  }

  func stopPublishing() {
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
    channelSnapshots.reserveCapacity(format.channelIDs.count)
    for (index, channelID) in format.channelIDs.enumerated() {
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

    snapshotHandler(
      ProcessOutputMeterSnapshot(
        format: format,
        sequence: capturedSequence,
        frameCount: capturedFrameCount,
        channels: channelSnapshots
      )
    )
  }
}
