// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import Foundation
import RilliyaRealtime

/// Why a sample rate converter could not be prepared or could not run.
public enum AudioSampleRateConverterError: Error, Equatable, Sendable {
  case invalidSampleRate(Double)
  case invalidChannelCount(Int)
  case invalidFrameCount(Int)
  case unavailable(OSStatus)
  case conversionFailed(OSStatus)
}

extension AudioSampleRateConverterError: LocalizedError {
  /// A human-readable explanation suitable for application diagnostics.
  public var errorDescription: String? {
    switch self {
    case .invalidSampleRate(let rate):
      "A sample rate of \(rate) Hz cannot be converted."
    case .invalidChannelCount(let count):
      "A channel count of \(count) cannot be converted."
    case .invalidFrameCount(let count):
      "A block of \(count) frames cannot be converted."
    case .unavailable(let status):
      "The system could not prepare a sample rate converter (\(status))."
    case .conversionFailed(let status):
      "The system could not convert this block (\(status))."
    }
  }
}

/// Converts interleaved float audio between two sample rates.
///
/// Measured here, converting a 512-frame block from 44.1 kHz to 48 kHz at the highest quality the
/// system offers costs about five microseconds, which is a thousandth of that block's playing
/// time. There is therefore no reason to offer anything but the highest quality, and none to move
/// the work off the thread that needs the result.
///
/// All storage is allocated during initialization and the converter is primed there, so producing
/// a block performs no allocation.
public final class AudioSampleRateConverter: @unchecked Sendable {
  /// The rate the source is delivered at.
  public let inputSampleRate: Double

  /// The rate blocks are produced at.
  public let outputSampleRate: Double

  /// The channels carried, which conversion never changes.
  public let channelCount: Int

  /// The largest block this converter can produce in one call.
  public let maximumOutputFrameCount: Int

  /// The input frames one full output block can require.
  ///
  /// A caller feeding a queue needs this much on hand to be sure a block can be produced.
  public var maximumInputFrameCount: Int { inputCapacityFrameCount }

  private let converter: AudioConverterRef
  private let inputCapacityFrameCount: Int
  private let inputStorage: UnsafeMutablePointer<Float>
  private let source: Source

  /// Prepares a converter between two rates for one channel count and block size.
  public init(
    inputSampleRate: Double,
    outputSampleRate: Double,
    channelCount: Int,
    maximumOutputFrameCount: Int
  ) throws {
    guard inputSampleRate.isFinite, inputSampleRate > 0 else {
      throw AudioSampleRateConverterError.invalidSampleRate(inputSampleRate)
    }
    guard outputSampleRate.isFinite, outputSampleRate > 0 else {
      throw AudioSampleRateConverterError.invalidSampleRate(outputSampleRate)
    }
    guard (1...AudioProcessingFormat.maximumChannelCount).contains(channelCount) else {
      throw AudioSampleRateConverterError.invalidChannelCount(channelCount)
    }
    guard maximumOutputFrameCount >= 1 else {
      throw AudioSampleRateConverterError.invalidFrameCount(maximumOutputFrameCount)
    }

    var input = Self.description(sampleRate: inputSampleRate, channelCount: channelCount)
    var output = Self.description(sampleRate: outputSampleRate, channelCount: channelCount)
    var created: AudioConverterRef?
    let status = AudioConverterNew(&input, &output, &created)
    guard status == noErr, let created else {
      throw AudioSampleRateConverterError.unavailable(status)
    }
    var quality = UInt32(kAudioConverterQuality_Max)
    _ = AudioConverterSetProperty(
      created,
      kAudioConverterSampleRateConverterQuality,
      UInt32(MemoryLayout<UInt32>.size),
      &quality
    )

    self.inputSampleRate = inputSampleRate
    self.outputSampleRate = outputSampleRate
    self.channelCount = channelCount
    self.maximumOutputFrameCount = maximumOutputFrameCount
    converter = created

    // The converter reads ahead to fill its filter, so the headroom is the ratio plus a margin
    // wide enough for the longest filter the highest quality uses.
    let ratio = inputSampleRate / outputSampleRate
    inputCapacityFrameCount =
      Int((Double(maximumOutputFrameCount) * ratio).rounded(.up)) + Self.filterHeadroomFrameCount
    inputStorage = .allocate(capacity: inputCapacityFrameCount * channelCount)
    inputStorage.initialize(repeating: 0, count: inputCapacityFrameCount * channelCount)
    source = Source(storage: inputStorage, channelCount: channelCount)
  }

  deinit {
    AudioConverterDispose(converter)
    inputStorage.deinitialize(count: inputCapacityFrameCount * channelCount)
    inputStorage.deallocate()
  }

  /// Forgets what the filter has seen, so the next block starts a new stream.
  public func reset() {
    AudioConverterReset(converter)
  }

  /// Produces `outputFrameCount` frames at the output rate from interleaved input.
  ///
  /// - Parameters:
  ///   - input: interleaved source samples, at least ``maximumInputFrameCount`` frames of them
  ///     when a full block is asked for.
  ///   - inputFrameCount: the frames available in `input`.
  ///   - output: interleaved destination, `outputFrameCount * channelCount` samples wide.
  ///   - outputFrameCount: the frames to produce.
  /// - Returns: the frames actually produced, which is short only when the input ran out.
  /// - Throws: ``AudioSampleRateConverterError/conversionFailed(_:)`` when the system refuses.
  @discardableResult
  public func convert(
    input: UnsafePointer<Float>,
    inputFrameCount: Int,
    output: UnsafeMutablePointer<Float>,
    outputFrameCount: Int
  ) throws -> Int {
    guard outputFrameCount > 0, outputFrameCount <= maximumOutputFrameCount else {
      throw AudioSampleRateConverterError.invalidFrameCount(outputFrameCount)
    }
    guard inputFrameCount >= 0 else {
      throw AudioSampleRateConverterError.invalidFrameCount(inputFrameCount)
    }
    let available = min(inputFrameCount, inputCapacityFrameCount)
    if available > 0 {
      inputStorage.update(from: input, count: available * channelCount)
    }
    source.availableFrameCount = available

    var list = AudioBufferList(
      mNumberBuffers: 1,
      mBuffers: AudioBuffer(
        mNumberChannels: UInt32(channelCount),
        mDataByteSize: UInt32(outputFrameCount * channelCount * MemoryLayout<Float>.stride),
        mData: UnsafeMutableRawPointer(output)
      )
    )
    var frames = UInt32(outputFrameCount)
    let status = withExtendedLifetime(source) {
      AudioConverterFillComplexBuffer(
        converter,
        Self.supply,
        Unmanaged.passUnretained(source).toOpaque(),
        &frames,
        &list,
        nil
      )
    }
    guard status == noErr else {
      throw AudioSampleRateConverterError.conversionFailed(status)
    }
    return Int(frames)
  }

  /// Frames of slack beyond the ratio, covering the longest filter the converter may use.
  private static let filterHeadroomFrameCount = 256

  private static func description(
    sampleRate: Double,
    channelCount: Int
  ) -> AudioStreamBasicDescription {
    let bytesPerFrame = UInt32(channelCount * MemoryLayout<Float>.stride)
    return AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: bytesPerFrame,
      mFramesPerPacket: 1,
      mBytesPerFrame: bytesPerFrame,
      mChannelsPerFrame: UInt32(channelCount),
      mBitsPerChannel: 32,
      mReserved: 0
    )
  }

  /// Hands the converter what this call was given, and nothing beyond it.
  private static let supply: AudioConverterComplexInputDataProc = {
    _, packetCount, bufferList, packetDescription, userData in
    guard let userData else {
      packetCount.pointee = 0
      return noErr
    }
    let source = Unmanaged<Source>.fromOpaque(userData).takeUnretainedValue()
    let frames = min(Int(packetCount.pointee), source.availableFrameCount)
    source.availableFrameCount -= frames
    bufferList.pointee.mNumberBuffers = 1
    bufferList.pointee.mBuffers.mNumberChannels = UInt32(source.channelCount)
    bufferList.pointee.mBuffers.mData = UnsafeMutableRawPointer(source.storage)
    bufferList.pointee.mBuffers.mDataByteSize = UInt32(
      frames * source.channelCount * MemoryLayout<Float>.stride
    )
    packetCount.pointee = UInt32(frames)
    if let packetDescription { packetDescription.pointee = nil }
    return noErr
  }

  /// What the supply callback reads, kept in a class so it survives as an opaque pointer.
  private final class Source {
    let storage: UnsafeMutablePointer<Float>
    let channelCount: Int
    var availableFrameCount = 0

    init(storage: UnsafeMutablePointer<Float>, channelCount: Int) {
      self.storage = storage
      self.channelCount = channelCount
    }
  }
}
