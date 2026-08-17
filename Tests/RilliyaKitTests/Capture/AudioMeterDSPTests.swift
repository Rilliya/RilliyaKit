// SPDX-License-Identifier: Apache-2.0

import RilliyaCore
import Testing

@testable import RilliyaCapture
@testable import RilliyaRealtime

@Suite("Audio meter DSP")
struct AudioMeterDSPTests {
  @Test("Processes planar Float32 channels independently")
  func processesPlanarChannels() throws {
    let measurements = AudioMeterDSP.processPlanar(
      [
        [0.5, -0.5, 0.5, -0.5],
        [0, 0, 0, 0],
      ],
      waveformSampleCount: 8,
      minimumDecibels: -120
    )

    let first = try #require(measurements.first)
    let second = try #require(measurements.last)
    #expect(abs(first.rootMeanSquare - 0.5) < 0.000_001)
    #expect(abs(first.decibels - -6.020_600_3) < 0.000_1)
    #expect(first.peak == 0.5)
    #expect(!first.isClipping)
    #expect(first.waveform == [0.5, -0.5, 0.5, -0.5])
    #expect(second.rootMeanSquare == 0)
    #expect(second.decibels == -120)
    #expect(second.waveform == [0, 0, 0, 0])
  }

  @Test("Deinterleaves Float32 frames")
  func processesInterleavedChannels() throws {
    let measurements = AudioMeterDSP.processInterleaved(
      [
        1, 0.25,
        -1, -0.25,
      ],
      channelCount: 2,
      waveformSampleCount: 4,
      minimumDecibels: -120
    )

    let left = try #require(measurements.first)
    let right = try #require(measurements.last)
    #expect(left.rootMeanSquare == 1)
    #expect(left.peak == 1)
    #expect(left.isClipping)
    #expect(left.waveform == [1, -1])
    #expect(right.rootMeanSquare == 0.25)
    #expect(right.peak == 0.25)
    #expect(!right.isClipping)
    #expect(right.waveform == [0.25, -0.25])
  }

  @Test("Reports clipping without hiding over-range peak amplitude")
  func detectsClipping() throws {
    let measurement = try #require(
      AudioMeterDSP.processPlanar(
        [[0.2, -1.25, 0.4]],
        waveformSampleCount: 8,
        minimumDecibels: -120
      ).first
    )

    #expect(measurement.isClipping)
    #expect(measurement.peak == 1.25)
    #expect(measurement.waveform == [0.2, -1, 0.4])
  }

  @Test("Downsampling retains the strongest signed transient in each bucket")
  func downsamplesByPeakBuckets() throws {
    let measurement = try #require(
      AudioMeterDSP.processPlanar(
        [[0.1, -0.8, 0.2, 0.3, 0.1, 0.2, -0.9, 0.4]],
        waveformSampleCount: 2,
        minimumDecibels: -120
      ).first
    )

    #expect(measurement.waveform == [-0.8, -0.9])
    #expect(measurement.waveform.count == 2)
  }

  @Test("Treats nonfinite samples as silence")
  func sanitizesNonfiniteSamples() throws {
    let measurement = try #require(
      AudioMeterDSP.processPlanar(
        [[.nan, .infinity, -.infinity]],
        waveformSampleCount: 3,
        minimumDecibels: -96
      ).first
    )

    #expect(measurement.rootMeanSquare == 0)
    #expect(measurement.peak == 0)
    #expect(measurement.decibels == -96)
    #expect(!measurement.isClipping)
    #expect(measurement.waveform == [0, 0, 0])
  }

  @Test("Clamps public visualizer bounds")
  func clampsConfiguration() {
    let configuration = AudioMeterCaptureConfiguration(
      updatesPerSecond: 500,
      waveformSampleCount: 10_000,
      minimumDecibels: -500,
      maximumAdditionalFrameSubscriberCount: 500
    )

    #expect(configuration.updatesPerSecond == 60)
    #expect(
      configuration.waveformSampleCount
        == AudioMeterCaptureConfiguration.maximumWaveformSampleCount
    )
    #expect(configuration.minimumDecibels == -200)
    #expect(
      configuration.maximumAdditionalFrameSubscriberCount
        == AudioCaptureConfiguration.maximumAdditionalFrameSubscriberCountLimit
    )

    let nonfiniteConfiguration = AudioMeterCaptureConfiguration(minimumDecibels: .nan)
    #expect(nonfiniteConfiguration.minimumDecibels == -120)
    #expect(
      AudioCaptureConfiguration(maximumAdditionalFrameSubscriberCount: -1)
        .maximumAdditionalFrameSubscriberCount == 0
    )

    let processCompatibilityConfiguration = ProcessOutputCaptureConfiguration()
    #expect(processCompatibilityConfiguration == AudioMeterCaptureConfiguration())
  }
}
