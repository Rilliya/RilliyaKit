// SPDX-License-Identifier: Apache-2.0

import Accelerate
import Foundation

/// Mutable state for a click-free linear gain transition.
struct AudioGainRampState: Equatable, Sendable {
  private(set) var currentGain: Float
  private(set) var targetGain: Float
  private(set) var remainingFrameCount: Int

  init(gain: Float) {
    precondition(gain.isFinite)
    currentGain = gain
    targetGain = gain
    remainingFrameCount = 0
  }

  mutating func setTarget(_ gain: Float, durationFrames: Int) {
    precondition(gain.isFinite)
    precondition(durationFrames >= 0)
    targetGain = gain
    remainingFrameCount = durationFrames
    if durationFrames == 0 {
      currentGain = gain
    }
  }

  /// Writes one gain value per frame into caller-owned memory.
  ///
  /// This method performs no allocation, locking, logging, or reference-counted callback work.
  mutating func writeEnvelope(
    to output: UnsafeMutablePointer<Float>,
    frameCount: Int
  ) {
    precondition(frameCount >= 0)
    guard frameCount > 0 else { return }

    let rampFrameCount = min(frameCount, remainingFrameCount)
    if rampFrameCount > 0 {
      let step = (targetGain - currentGain) / Float(remainingFrameCount)
      for frame in 0..<rampFrameCount {
        output[frame] = currentGain
        currentGain += step
      }
      remainingFrameCount -= rampFrameCount
      if remainingFrameCount == 0 {
        currentGain = targetGain
      }
    }
    if rampFrameCount < frameCount {
      output.advanced(by: rampFrameCount).update(
        repeating: currentGain,
        count: frameCount - rampFrameCount
      )
    }
  }
}

enum AudioPassThroughDSP {
  static func copy(
    input: UnsafePointer<Float>,
    output: UnsafeMutablePointer<Float>,
    frameCount: Int
  ) {
    precondition(frameCount >= 0)
    guard frameCount > 0, input != UnsafePointer(output) else { return }
    output.update(from: input, count: frameCount)
  }
}

enum AudioGainDSP {
  static func apply(
    input: UnsafePointer<Float>,
    envelope: UnsafePointer<Float>,
    output: UnsafeMutablePointer<Float>,
    frameCount: Int
  ) {
    precondition(frameCount >= 0)
    guard frameCount > 0 else { return }
    vDSP_vmul(input, 1, envelope, 1, output, 1, vDSP_Length(frameCount))
  }
}

enum AudioMixerDSP {
  static func clear(
    _ output: UnsafeMutablePointer<Float>,
    frameCount: Int
  ) {
    precondition(frameCount >= 0)
    guard frameCount > 0 else { return }
    vDSP_vclr(output, 1, vDSP_Length(frameCount))
  }

  /// Adds one input contribution without averaging or clipping the destination.
  static func accumulate(
    input: UnsafePointer<Float>,
    gain: Float,
    output: UnsafeMutablePointer<Float>,
    frameCount: Int
  ) {
    precondition(gain.isFinite)
    precondition(frameCount >= 0)
    guard frameCount > 0 else { return }
    var gain = gain
    vDSP_vsma(input, 1, &gain, output, 1, output, 1, vDSP_Length(frameCount))
  }
}
