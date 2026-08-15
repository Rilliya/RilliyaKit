// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Immutable parameters for a bounded realtime delay line.
public struct AudioDelayConfiguration: Equatable, Hashable, Codable, Sendable {
  /// The longest delay duration accepted by the generic processor.
  public static let maximumDelaySeconds = 10.0

  /// Delay duration in seconds.
  public let delaySeconds: Double

  /// Delayed signal returned to the delay line.
  ///
  /// Values remain below unity magnitude so a finite input cannot create an unstable feedback
  /// loop through this processor alone.
  public let feedback: Float

  /// Linear crossfade from the original input at zero to only the delayed signal at one.
  public let dryWetMix: Float

  /// Creates validated delay parameters.
  public init(
    delaySeconds: Double,
    feedback: Float = 0,
    dryWetMix: Float = 1
  ) throws {
    guard delaySeconds.isFinite,
      delaySeconds > 0,
      delaySeconds <= Self.maximumDelaySeconds
    else {
      throw AudioDSPConfigurationError.invalidDelayDuration(delaySeconds)
    }
    guard feedback.isFinite, (-0.95...0.95).contains(feedback) else {
      throw AudioDSPConfigurationError.invalidDelayFeedback(feedback)
    }
    guard dryWetMix.isFinite, (0...1).contains(dryWetMix) else {
      throw AudioDSPConfigurationError.invalidDryWetMix(dryWetMix)
    }
    self.delaySeconds = delaySeconds
    self.feedback = feedback
    self.dryWetMix = dryWetMix
  }

  private enum CodingKeys: String, CodingKey {
    case delaySeconds
    case feedback
    case dryWetMix
  }

  /// Decodes delay parameters while preserving the same public safety bounds as direct creation.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let delaySeconds = try container.decode(Double.self, forKey: .delaySeconds)
    let feedback = try container.decode(Float.self, forKey: .feedback)
    let dryWetMix = try container.decode(Float.self, forKey: .dryWetMix)
    do {
      try self.init(
        delaySeconds: delaySeconds,
        feedback: feedback,
        dryWetMix: dryWetMix
      )
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .delaySeconds,
        in: container,
        debugDescription: "Delay parameters are outside the supported bounds."
      )
    }
  }
}

/// A prepared multichannel delay with optional bounded feedback.
///
/// Preparation allocates one channel-isolated circular buffer. `process` performs no allocation,
/// locking, logging, Objective-C messaging, or callback work. The sample recurrence is scalar by
/// necessity: each delayed sample can feed the next traversal of the same ring position. Calls for
/// one instance must remain serialized on one render thread.
public final class PreparedAudioDelayProcessor: PreparedAudioProcessor, @unchecked Sendable {
  /// The maximum aggregate delay storage owned by one processor.
  ///
  /// The bound prevents an extreme channel-count and duration combination from silently consuming
  /// hundreds of mebibytes. Float32 storage at this limit occupies 64 MiB.
  public static let maximumStoredSampleCount = 16 * 1_024 * 1_024

  /// The immutable preparation used by this processor.
  public let preparation: AudioRenderPreparation

  /// The validated configuration used by this processor.
  public let configuration: AudioDelayConfiguration

  /// Intentional delay and tail behavior visible to a graph compiler.
  public let timing: AudioNodeTiming

  /// Integer sample-frame duration of the prepared delay line.
  public let delayFrameCount: Int

  private let storage: UnsafeMutablePointer<Float>
  private let storedSampleCount: Int
  private var writeFrameIndex = 0

  /// Prepares a fixed delay line for one format and bounded render quantum.
  public init(
    preparation: AudioRenderPreparation,
    configuration: AudioDelayConfiguration
  ) throws {
    let requestedFrames = configuration.delaySeconds * preparation.format.sampleRate
    guard requestedFrames.isFinite, requestedFrames <= Double(Int.max) else {
      throw AudioDSPConfigurationError.invalidDelayDuration(configuration.delaySeconds)
    }
    let delayFrameCount = max(1, Int(requestedFrames.rounded()))
    let (sampleCount, overflow) = delayFrameCount.multipliedReportingOverflow(
      by: preparation.format.channelCount
    )
    guard !overflow, sampleCount <= Self.maximumStoredSampleCount else {
      throw AudioDSPConfigurationError.delayStorageTooLarge(
        overflow ? Int.max : sampleCount
      )
    }

    self.preparation = preparation
    self.configuration = configuration
    self.delayFrameCount = delayFrameCount
    storedSampleCount = sampleCount
    storage = .allocate(capacity: sampleCount)
    storage.initialize(repeating: 0, count: sampleCount)
    timing = try AudioNodeTiming(
      processingLatencyFrames: 0,
      intentionalDelayFrames: delayFrameCount,
      tail: configuration.feedback == 0 ? .finiteFrames(delayFrameCount) : .unbounded
    )
  }

  deinit {
    storage.deinitialize(count: storedSampleCount)
    storage.deallocate()
  }

  /// Processes one bounded planar Float32 render quantum.
  ///
  /// Input and output pointers may alias. Output remains unclipped so saturation and limiting can
  /// remain explicit downstream graph operations.
  @discardableResult
  public func process(
    inputChannels: UnsafeBufferPointer<UnsafePointer<Float>>,
    outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRenderResult {
    guard (0...preparation.maximumFrameCount).contains(frameCount) else {
      return .invalidFrameCount
    }
    let channelCount = preparation.format.channelCount
    guard inputChannels.count >= channelCount, outputChannels.count >= channelCount else {
      return .insufficientChannels
    }
    guard frameCount > 0 else { return .rendered }

    let wet = configuration.dryWetMix
    let dry = 1 - wet
    let feedback = configuration.feedback
    for channel in 0..<channelCount {
      let ring = storage.advanced(by: channel * delayFrameCount)
      let input = inputChannels[channel]
      let output = outputChannels[channel]
      var ringIndex = writeFrameIndex
      for frame in 0..<frameCount {
        let inputSample = input[frame]
        let delayedSample = ring[ringIndex]
        ring[ringIndex] = inputSample + delayedSample * feedback
        output[frame] = inputSample * dry + delayedSample * wet
        ringIndex += 1
        if ringIndex == delayFrameCount {
          ringIndex = 0
        }
      }
    }
    writeFrameIndex = (writeFrameIndex + frameCount) % delayFrameCount
    return .rendered
  }

  /// Clears delayed history before the processor is returned to a render thread.
  ///
  /// The caller must serialize this operation with `process`.
  public func reset() {
    storage.update(repeating: 0, count: storedSampleCount)
    writeFrameIndex = 0
  }
}
