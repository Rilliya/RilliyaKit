// SPDX-License-Identifier: Apache-2.0

import Foundation

package struct AudioMeterMeasurement: Equatable, Sendable {
  package let rootMeanSquare: Float
  package let peak: Float
  package let decibels: Float
  package let isClipping: Bool
  package let waveform: [Float]
}

package enum AudioMeterDSP {
  package static func processPlanar(
    _ channels: [[Float]],
    waveformSampleCount: Int,
    minimumDecibels: Float
  ) -> [AudioMeterMeasurement] {
    channels.map { samples in
      samples.withUnsafeBufferPointer { buffer in
        process(
          samples: buffer.baseAddress,
          frameCount: buffer.count,
          sampleStride: 1,
          waveformSampleCount: waveformSampleCount,
          minimumDecibels: minimumDecibels
        )
      }
    }
  }

  package static func processInterleaved(
    _ samples: [Float],
    channelCount: Int,
    waveformSampleCount: Int,
    minimumDecibels: Float
  ) -> [AudioMeterMeasurement] {
    guard channelCount > 0 else { return [] }
    let frameCount = samples.count / channelCount
    return samples.withUnsafeBufferPointer { buffer in
      (0..<channelCount).map { channel in
        process(
          samples: buffer.baseAddress.map { $0.advanced(by: channel) },
          frameCount: frameCount,
          sampleStride: channelCount,
          waveformSampleCount: waveformSampleCount,
          minimumDecibels: minimumDecibels
        )
      }
    }
  }

  package static func writeMeasurement(
    samples: UnsafePointer<Float>?,
    frameCount: Int,
    sampleStride: Int,
    waveformSampleCount: Int,
    minimumDecibels: Float,
    waveformOutput: UnsafeMutablePointer<Float>
  ) -> RealtimeAudioMeterScalars {
    guard
      let samples,
      frameCount > 0,
      sampleStride > 0,
      waveformSampleCount > 0
    else {
      waveformOutput.update(repeating: 0, count: max(waveformSampleCount, 0))
      return RealtimeAudioMeterScalars(
        rootMeanSquare: 0,
        peak: 0,
        decibels: minimumDecibels,
        isClipping: false,
        waveformCount: 0
      )
    }

    var sumOfSquares = 0.0
    var peak: Float = 0
    var isClipping = false
    for frame in 0..<frameCount {
      let sample = finiteSample(samples[frame * sampleStride])
      let magnitude = abs(sample)
      sumOfSquares += Double(sample) * Double(sample)
      peak = max(peak, magnitude)
      isClipping = isClipping || magnitude >= 1
    }

    let rootMeanSquare = Float(sqrt(sumOfSquares / Double(frameCount)))
    let decibels = max(
      20 * log10(max(rootMeanSquare, Float.leastNonzeroMagnitude)), minimumDecibels)
    let outputCount = min(frameCount, waveformSampleCount)
    for outputIndex in 0..<outputCount {
      let firstFrame = outputIndex * frameCount / outputCount
      let endFrame = max((outputIndex + 1) * frameCount / outputCount, firstFrame + 1)
      var retainedSample: Float = 0
      var retainedMagnitude: Float = -1
      for frame in firstFrame..<min(endFrame, frameCount) {
        let sample = finiteSample(samples[frame * sampleStride])
        let magnitude = abs(sample)
        if magnitude > retainedMagnitude {
          retainedSample = sample
          retainedMagnitude = magnitude
        }
      }
      waveformOutput[outputIndex] = min(max(retainedSample, -1), 1)
    }
    if outputCount < waveformSampleCount {
      waveformOutput.advanced(by: outputCount).update(
        repeating: 0,
        count: waveformSampleCount - outputCount
      )
    }
    return RealtimeAudioMeterScalars(
      rootMeanSquare: rootMeanSquare,
      peak: peak,
      decibels: decibels,
      isClipping: isClipping,
      waveformCount: outputCount
    )
  }

  private static func process(
    samples: UnsafePointer<Float>?,
    frameCount: Int,
    sampleStride: Int,
    waveformSampleCount: Int,
    minimumDecibels: Float
  ) -> AudioMeterMeasurement {
    let boundedWaveformCount = max(waveformSampleCount, 1)
    var waveform = [Float](repeating: 0, count: boundedWaveformCount)
    let scalars = waveform.withUnsafeMutableBufferPointer { output in
      guard let baseAddress = output.baseAddress else {
        return RealtimeAudioMeterScalars(
          rootMeanSquare: 0,
          peak: 0,
          decibels: minimumDecibels,
          isClipping: false,
          waveformCount: 0
        )
      }
      return writeMeasurement(
        samples: samples,
        frameCount: frameCount,
        sampleStride: sampleStride,
        waveformSampleCount: boundedWaveformCount,
        minimumDecibels: minimumDecibels,
        waveformOutput: baseAddress
      )
    }
    waveform.removeLast(waveform.count - scalars.waveformCount)
    return AudioMeterMeasurement(
      rootMeanSquare: scalars.rootMeanSquare,
      peak: scalars.peak,
      decibels: scalars.decibels,
      isClipping: scalars.isClipping,
      waveform: waveform
    )
  }

  private static func finiteSample(_ sample: Float) -> Float {
    sample.isFinite ? sample : 0
  }
}

package struct RealtimeAudioMeterScalars: Sendable {
  package let rootMeanSquare: Float
  package let peak: Float
  package let decibels: Float
  package let isClipping: Bool
  package let waveformCount: Int
}
