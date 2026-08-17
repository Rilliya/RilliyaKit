// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Removes time from planar audio by overlapping the waveform with itself.
///
/// Discarding frames to shorten a stream leaves a step where the two sides do not meet, which is
/// audible as a click. Overlapping at the lag where the waveform most resembles itself removes
/// close to a whole period instead, so the two sides already agree and the seam is a crossfade
/// rather than a step.
///
/// The lag is searched on a mono mixdown and applied to every channel, so a stereo image is not
/// pulled apart by channels being spliced at different points.
///
/// All storage is allocated during initialization and the search is a plain dot product, so this
/// runs on a render thread.
public final class AudioWaveformSimilarityCompressor: @unchecked Sendable {
  /// Bounded controls for one compressor.
  public struct Configuration: Equatable, Hashable, Sendable {
    /// The shortest period the search considers, matching a high voice or instrument.
    public let minimumLag: Duration

    /// The longest period the search considers, matching a low voice.
    public let maximumLag: Duration

    /// The window compared at each candidate lag.
    public let correlationWindow: Duration

    /// Controls tuned for the 5 to 15 millisecond periods of ordinary program material.
    public static let standard = Configuration(
      minimumLag: .milliseconds(3),
      maximumLag: .milliseconds(10),
      correlationWindow: .milliseconds(3)
    )

    public init(minimumLag: Duration, maximumLag: Duration, correlationWindow: Duration) {
      self.minimumLag = minimumLag
      self.maximumLag = maximumLag
      self.correlationWindow = correlationWindow
    }
  }

  /// The frames the compressor removes in one correction, which is one waveform period.
  ///
  /// Bounded by the render quantum: the crossfade reads a second copy of the period past the
  /// splice, so removing a period longer than the block being produced would read past the audio
  /// the caller supplied.
  public let maximumRemovableFrameCount: Int

  /// The frames one correction needs beyond the frames it produces.
  public var additionalFrameCount: Int { maximumRemovableFrameCount }

  /// Whether the render quantum leaves room for a period worth removing.
  ///
  /// A quantum shorter than the shortest period searched cannot host a crossfade, so a caller
  /// that renders very small blocks has to correct another way.
  public var isEffective: Bool { maximumRemovableFrameCount > minimumLagFrameCount }

  private let channelCount: Int
  private let minimumLagFrameCount: Int
  private let correlationFrameCount: Int
  private let mixdown: UnsafeMutablePointer<Float>
  private let mixdownCapacity: Int

  /// Prepares a compressor for one format and render quantum.
  public init(
    format: AudioProcessingFormat,
    maximumFrameCount: Int,
    configuration: Configuration = .standard
  ) throws {
    func frames(_ duration: Duration) -> Int {
      Int((Double(duration.wholeNanoseconds) / 1_000_000_000 * format.sampleRate).rounded())
    }
    let minimumLag = max(frames(configuration.minimumLag), 1)
    let maximumLag = max(frames(configuration.maximumLag), minimumLag + 1)
    let correlation = max(frames(configuration.correlationWindow), 1)
    guard maximumFrameCount > 0 else {
      throw AudioRealtimeSchedulingError.invalidFrameCount(maximumFrameCount)
    }
    channelCount = format.channelCount
    minimumLagFrameCount = minimumLag
    maximumRemovableFrameCount = min(maximumLag, maximumFrameCount)
    correlationFrameCount = correlation
    mixdownCapacity = 2 * maximumFrameCount + correlation
    mixdown = .allocate(capacity: mixdownCapacity)
    mixdown.initialize(repeating: 0, count: mixdownCapacity)
  }

  deinit {
    mixdown.deinitialize(count: mixdownCapacity)
    mixdown.deallocate()
  }

  /// Shortens `input` into `output`, removing the frames between their lengths.
  ///
  /// - Parameters:
  ///   - input: planar channels holding `outputFrameCount + removal` frames.
  ///   - output: planar channels receiving `outputFrameCount` frames.
  ///   - removal: the frames to remove, which the compressor rounds to the period it finds.
  /// - Returns: the frames actually removed, which is what the caller consumed beyond its output.
  @discardableResult
  public func compress(
    input: UnsafeBufferPointer<UnsafePointer<Float>>,
    output: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    outputFrameCount: Int,
    removal: Int
  ) -> Int {
    guard outputFrameCount > 0,
      input.count >= channelCount,
      output.count >= channelCount,
      removal > 0
    else {
      copy(input: input, output: output, frameCount: max(outputFrameCount, 0), offset: 0)
      return 0
    }
    // The crossfade reads as far as twice the lag, so the lag can never exceed the block.
    let searchLimit = min(removal, maximumRemovableFrameCount, outputFrameCount)
    guard searchLimit > minimumLagFrameCount,
      outputFrameCount + searchLimit + correlationFrameCount <= mixdownCapacity
    else {
      copy(input: input, output: output, frameCount: outputFrameCount, offset: 0)
      return 0
    }

    let available = outputFrameCount + searchLimit
    buildMixdown(input: input, frameCount: available)
    let lag = bestLag(limit: searchLimit)
    guard lag > 0, lag <= searchLimit else {
      copy(input: input, output: output, frameCount: outputFrameCount, offset: 0)
      return 0
    }

    // The seam crossfades the frames before the splice into the frames one period later, so both
    // sides carry the same waveform and meet without a step.
    for channel in 0..<channelCount {
      let source = input[channel]
      let destination = output[channel]
      for frame in 0..<lag {
        let ramp = Float(frame) / Float(lag)
        destination[frame] = source[frame] * (1 - ramp) + source[frame + lag] * ramp
      }
      let tail = outputFrameCount - lag
      if tail > 0 {
        destination.advanced(by: lag).update(from: source.advanced(by: lag * 2), count: tail)
      }
    }
    return lag
  }

  private func buildMixdown(
    input: UnsafeBufferPointer<UnsafePointer<Float>>,
    frameCount: Int
  ) {
    let scale = 1 / Float(channelCount)
    for frame in 0..<frameCount {
      var sum: Float = 0
      for channel in 0..<channelCount { sum += input[channel][frame] }
      mixdown[frame] = sum * scale
    }
  }

  /// The lag in `minimumLag...limit` where the waveform most resembles itself.
  private func bestLag(limit: Int) -> Int {
    var bestLag = 0
    var bestScore = -Float.greatestFiniteMagnitude
    for lag in minimumLagFrameCount...limit {
      var correlation: Float = 0
      var energy: Float = 0
      for frame in 0..<correlationFrameCount {
        let shifted = mixdown[frame + lag]
        correlation += mixdown[frame] * shifted
        energy += shifted * shifted
      }
      // Normalising by the shifted energy keeps a loud but dissimilar lag from winning.
      let score = energy > 0 ? correlation / energy.squareRoot() : 0
      if score > bestScore {
        bestScore = score
        bestLag = lag
      }
    }
    return bestLag
  }

  private func copy(
    input: UnsafeBufferPointer<UnsafePointer<Float>>,
    output: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int,
    offset: Int
  ) {
    guard frameCount > 0 else { return }
    for channel in 0..<min(channelCount, min(input.count, output.count)) {
      output[channel].update(from: input[channel].advanced(by: offset), count: frameCount)
    }
  }
}
