// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import Foundation

/// Why an Opus codec could not be prepared or could not run.
public enum NetworkAudioOpusError: Error, Equatable, Sendable {
  /// Opus does not carry this sample rate.
  case unsupportedSampleRate(Double)

  /// Opus does not carry this channel count.
  case unsupportedChannelCount(Int)

  /// Opus does not carry a block of this length at this rate.
  case unsupportedFrameCount(Int)

  /// The requested bit rate is outside what the system's encoder offers.
  case unsupportedBitRate(Int)

  /// The system could not prepare the codec.
  case unavailable(OSStatus)

  /// The system refused this block.
  case failed(OSStatus)

  /// The compressed packet is larger than any this codec produces.
  case oversizedPacket(Int)
}

extension NetworkAudioOpusError: LocalizedError {
  /// A human-readable explanation suitable for application diagnostics.
  public var errorDescription: String? {
    switch self {
    case .unsupportedSampleRate(let rate):
      "Opus does not carry \(Int(rate)) Hz audio."
    case .unsupportedChannelCount(let count):
      "Opus does not carry \(count) channels."
    case .unsupportedFrameCount(let count):
      "Opus does not carry blocks of \(count) frames at this rate."
    case .unsupportedBitRate(let rate):
      "The system's Opus encoder does not offer \(rate) bits per second."
    case .unavailable(let status):
      "The system could not prepare an Opus codec (\(status))."
    case .failed(let status):
      "The system could not code this block (\(status))."
    case .oversizedPacket(let byteCount):
      "An Opus packet of \(byteCount) bytes is larger than this codec produces."
    }
  }
}

/// What Opus can carry, and at what block lengths.
///
/// Opus is defined at a handful of rates and a handful of block lengths at each of them, so a
/// stream that is not already one of those has to be converted before it can be carried. The
/// system's encoder and decoder are both used, so no third-party code is involved.
public enum NetworkAudioOpus {
  /// The sample rates Opus carries.
  public static let supportedSampleRates: [Double] = [8_000, 12_000, 16_000, 24_000, 48_000]

  /// The channel counts this wire format carries.
  public static let supportedChannelCounts = [1, 2]

  /// The block lengths Opus defines, in milliseconds.
  public static let blockMilliseconds: [Double] = [2.5, 5, 10, 20, 40, 60]

  /// The largest compressed packet the encoder is allowed to produce.
  public static let maximumPacketByteCount = 4_000

  /// The block lengths Opus carries at `sampleRate`, in frames.
  public static func frameCounts(atSampleRate sampleRate: Double) -> [Int] {
    guard supportedSampleRates.contains(sampleRate) else { return [] }
    return blockMilliseconds.map { Int((sampleRate * $0 / 1_000).rounded()) }
  }

  /// Whether a block of `frameCount` frames is one Opus carries at `sampleRate`.
  public static func carries(frameCount: Int, atSampleRate sampleRate: Double) -> Bool {
    frameCounts(atSampleRate: sampleRate).contains(frameCount)
  }

  /// The block closest to `preferred` milliseconds that Opus carries at `sampleRate`.
  public static func frameCount(
    nearestTo preferredMilliseconds: Double,
    atSampleRate sampleRate: Double
  ) -> Int? {
    guard supportedSampleRates.contains(sampleRate) else { return nil }
    let nearest = blockMilliseconds.min {
      abs($0 - preferredMilliseconds) < abs($1 - preferredMilliseconds)
    }
    return nearest.map { Int((sampleRate * $0 / 1_000).rounded()) }
  }
}

/// Compresses one block of interleaved float audio into one Opus packet.
///
/// Measured here, a 2.5 millisecond stereo block at 48 kHz costs about sixteen microseconds to
/// compress, which is under one percent of that block's playing time, and leaves thirty-five
/// bytes where the samples were nine hundred and sixty. Compressing therefore happens on the
/// thread that is already producing the packet rather than being handed to another.
///
/// All storage is allocated during initialization.
public final class NetworkAudioOpusEncoder: @unchecked Sendable {
  /// The rate the source is delivered at.
  public let sampleRate: Double

  /// The channels carried.
  public let channelCount: Int

  /// The frames one packet carries.
  public let frameCountPerPacket: Int

  private let converter: AudioConverterRef
  private let source: Source
  private let inputStorage: UnsafeMutablePointer<Float>

  /// Prepares an encoder for one format and block length.
  public init(
    sampleRate: Double,
    channelCount: Int,
    frameCountPerPacket: Int,
    bitRate: Int
  ) throws {
    guard NetworkAudioOpus.supportedSampleRates.contains(sampleRate) else {
      throw NetworkAudioOpusError.unsupportedSampleRate(sampleRate)
    }
    guard NetworkAudioOpus.supportedChannelCounts.contains(channelCount) else {
      throw NetworkAudioOpusError.unsupportedChannelCount(channelCount)
    }
    guard NetworkAudioOpus.carries(frameCount: frameCountPerPacket, atSampleRate: sampleRate)
    else {
      throw NetworkAudioOpusError.unsupportedFrameCount(frameCountPerPacket)
    }

    var pcm = NetworkAudioOpusFormat.pcm(sampleRate: sampleRate, channelCount: channelCount)
    var opus = try NetworkAudioOpusFormat.opus(
      sampleRate: sampleRate,
      channelCount: channelCount,
      frameCountPerPacket: frameCountPerPacket
    )
    var created: AudioConverterRef?
    let status = AudioConverterNew(&pcm, &opus, &created)
    guard status == noErr, let created else {
      throw NetworkAudioOpusError.unavailable(status)
    }
    var rate = UInt32(bitRate)
    let bitRateStatus = AudioConverterSetProperty(
      created,
      kAudioConverterEncodeBitRate,
      UInt32(MemoryLayout<UInt32>.size),
      &rate
    )
    guard bitRateStatus == noErr else {
      AudioConverterDispose(created)
      throw NetworkAudioOpusError.unsupportedBitRate(bitRate)
    }

    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.frameCountPerPacket = frameCountPerPacket
    converter = created
    inputStorage = .allocate(capacity: frameCountPerPacket * channelCount)
    inputStorage.initialize(repeating: 0, count: frameCountPerPacket * channelCount)
    source = Source(storage: inputStorage, channelCount: channelCount)
  }

  deinit {
    AudioConverterDispose(converter)
    inputStorage.deinitialize(count: frameCountPerPacket * channelCount)
    inputStorage.deallocate()
  }

  /// Compresses one block into `packet`.
  ///
  /// - Parameters:
  ///   - input: interleaved samples, ``frameCountPerPacket`` frames of them.
  ///   - packet: where the compressed bytes are written.
  /// - Returns: the bytes written.
  /// - Throws: ``NetworkAudioOpusError`` when the system refuses the block.
  public func encode(
    input: UnsafePointer<Float>,
    into packet: UnsafeMutableRawBufferPointer
  ) throws -> Int {
    guard let destination = packet.baseAddress, packet.count > 0 else {
      throw NetworkAudioOpusError.oversizedPacket(packet.count)
    }
    inputStorage.update(from: input, count: frameCountPerPacket * channelCount)
    source.availableFrameCount = frameCountPerPacket
    source.consumedFrameCount = 0

    var list = AudioBufferList(
      mNumberBuffers: 1,
      mBuffers: AudioBuffer(
        mNumberChannels: UInt32(channelCount),
        mDataByteSize: UInt32(packet.count),
        mData: destination
      )
    )
    var packetCount: UInt32 = 1
    var description = AudioStreamPacketDescription()
    let status = withExtendedLifetime(source) {
      AudioConverterFillComplexBuffer(
        converter,
        NetworkAudioOpusSupply.pcm,
        Unmanaged.passUnretained(source).toOpaque(),
        &packetCount,
        &list,
        &description
      )
    }
    guard status == noErr, packetCount == 1 else {
      throw NetworkAudioOpusError.failed(status)
    }
    return Int(list.mBuffers.mDataByteSize)
  }

  /// What the supply callback reads, kept in a class so it survives as an opaque pointer.
  final class Source {
    let storage: UnsafeMutablePointer<Float>
    let channelCount: Int
    var availableFrameCount = 0
    var consumedFrameCount = 0

    init(storage: UnsafeMutablePointer<Float>, channelCount: Int) {
      self.storage = storage
      self.channelCount = channelCount
    }
  }
}

/// Expands one Opus packet into interleaved float audio.
public final class NetworkAudioOpusDecoder: @unchecked Sendable {
  /// The rate blocks are produced at.
  public let sampleRate: Double

  /// The channels carried.
  public let channelCount: Int

  /// The frames one packet carries.
  public let frameCountPerPacket: Int

  private let converter: AudioConverterRef
  private let packetStorage: UnsafeMutableRawPointer
  private let source: PacketSource

  /// Prepares a decoder for one format and block length.
  public init(sampleRate: Double, channelCount: Int, frameCountPerPacket: Int) throws {
    guard NetworkAudioOpus.supportedSampleRates.contains(sampleRate) else {
      throw NetworkAudioOpusError.unsupportedSampleRate(sampleRate)
    }
    guard NetworkAudioOpus.supportedChannelCounts.contains(channelCount) else {
      throw NetworkAudioOpusError.unsupportedChannelCount(channelCount)
    }
    guard NetworkAudioOpus.carries(frameCount: frameCountPerPacket, atSampleRate: sampleRate)
    else {
      throw NetworkAudioOpusError.unsupportedFrameCount(frameCountPerPacket)
    }

    var opus = try NetworkAudioOpusFormat.opus(
      sampleRate: sampleRate,
      channelCount: channelCount,
      frameCountPerPacket: frameCountPerPacket
    )
    var pcm = NetworkAudioOpusFormat.pcm(sampleRate: sampleRate, channelCount: channelCount)
    var created: AudioConverterRef?
    let status = AudioConverterNew(&opus, &pcm, &created)
    guard status == noErr, let created else {
      throw NetworkAudioOpusError.unavailable(status)
    }

    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.frameCountPerPacket = frameCountPerPacket
    converter = created
    packetStorage = .allocate(
      byteCount: NetworkAudioOpus.maximumPacketByteCount,
      alignment: 16
    )
    source = PacketSource(storage: packetStorage)
  }

  deinit {
    AudioConverterDispose(converter)
    packetStorage.deallocate()
  }

  /// Forgets what the decoder has heard, so the next packet starts a new stream.
  public func reset() {
    AudioConverterReset(converter)
  }

  /// Expands one packet into `output`.
  ///
  /// The decoder looks ahead, so the first packet of a stream yields fewer frames than it carries
  /// while that lookahead fills. Every packet after it yields a full block.
  ///
  /// - Parameters:
  ///   - packet: the compressed bytes.
  ///   - output: interleaved destination, `frameCountPerPacket * channelCount` samples wide.
  /// - Returns: the frames produced, which the caller writes rather than assuming a full block.
  /// - Throws: ``NetworkAudioOpusError`` when the system refuses the packet.
  public func decode(
    packet: UnsafeRawBufferPointer,
    into output: UnsafeMutablePointer<Float>
  ) throws -> Int {
    guard let bytes = packet.baseAddress, packet.count > 0 else {
      throw NetworkAudioOpusError.failed(kAudioConverterErr_UnspecifiedError)
    }
    guard packet.count <= NetworkAudioOpus.maximumPacketByteCount else {
      throw NetworkAudioOpusError.oversizedPacket(packet.count)
    }
    packetStorage.copyMemory(from: bytes, byteCount: packet.count)
    source.byteCount = packet.count
    source.isSupplied = false

    var list = AudioBufferList(
      mNumberBuffers: 1,
      mBuffers: AudioBuffer(
        mNumberChannels: UInt32(channelCount),
        mDataByteSize: UInt32(frameCountPerPacket * channelCount * MemoryLayout<Float>.stride),
        mData: UnsafeMutableRawPointer(output)
      )
    )
    var frames = UInt32(frameCountPerPacket)
    let status = withExtendedLifetime(source) {
      AudioConverterFillComplexBuffer(
        converter,
        NetworkAudioOpusSupply.packet,
        Unmanaged.passUnretained(source).toOpaque(),
        &frames,
        &list,
        nil
      )
    }
    guard status == noErr || status == NetworkAudioOpusSupply.noDataNow else {
      throw NetworkAudioOpusError.failed(status)
    }
    return Int(frames)
  }

  /// What the supply callback reads, kept in a class so it survives as an opaque pointer.
  final class PacketSource {
    let storage: UnsafeMutableRawPointer
    /// The packet description the system reads after the callback returns, so it has to outlive
    /// the callback rather than being a pointer to a local.
    let description: UnsafeMutablePointer<AudioStreamPacketDescription>
    var byteCount = 0
    var isSupplied = false

    init(storage: UnsafeMutableRawPointer) {
      self.storage = storage
      description = .allocate(capacity: 1)
      description.initialize(to: AudioStreamPacketDescription())
    }

    deinit {
      description.deinitialize(count: 1)
      description.deallocate()
    }
  }
}

/// The stream descriptions both directions are built from.
enum NetworkAudioOpusFormat {
  static func pcm(sampleRate: Double, channelCount: Int) -> AudioStreamBasicDescription {
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

  static func opus(
    sampleRate: Double,
    channelCount: Int,
    frameCountPerPacket: Int
  ) throws -> AudioStreamBasicDescription {
    var description = AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatOpus,
      mFormatFlags: 0,
      mBytesPerPacket: 0,
      mFramesPerPacket: UInt32(frameCountPerPacket),
      mBytesPerFrame: 0,
      mChannelsPerFrame: UInt32(channelCount),
      mBitsPerChannel: 0,
      mReserved: 0
    )
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioFormatGetProperty(
      kAudioFormatProperty_FormatInfo,
      0,
      nil,
      &size,
      &description
    )
    guard status == noErr else { throw NetworkAudioOpusError.unavailable(status) }
    // The system fills in what it knows; the block length is ours to keep.
    description.mFramesPerPacket = UInt32(frameCountPerPacket)
    return description
  }
}

/// The two C callbacks, kept out of the classes so neither captures anything.
enum NetworkAudioOpusSupply {
  /// Says there is nothing more for this block without saying the stream has ended.
  ///
  /// Answering a further ask with zero packets is how a caller reports end of stream, after which
  /// the converter produces nothing ever again. A decoder fed one packet at a time has to say
  /// something else.
  static let noDataNow: OSStatus = 1_853_321_324
  /// Feeds the encoder the block it was given, advancing through it if asked more than once.
  static let pcm: AudioConverterComplexInputDataProc = {
    _, packetCount, bufferList, packetDescription, userData in
    guard let userData else {
      packetCount.pointee = 0
      return noErr
    }
    let source = Unmanaged<NetworkAudioOpusEncoder.Source>.fromOpaque(userData)
      .takeUnretainedValue()
    let frames = min(Int(packetCount.pointee), source.availableFrameCount)
    let offset = source.consumedFrameCount
    source.consumedFrameCount += frames
    source.availableFrameCount -= frames
    bufferList.pointee.mNumberBuffers = 1
    bufferList.pointee.mBuffers.mNumberChannels = UInt32(source.channelCount)
    bufferList.pointee.mBuffers.mData = UnsafeMutableRawPointer(
      source.storage.advanced(by: offset * source.channelCount)
    )
    bufferList.pointee.mBuffers.mDataByteSize = UInt32(
      frames * source.channelCount * MemoryLayout<Float>.stride
    )
    packetCount.pointee = UInt32(frames)
    if let packetDescription { packetDescription.pointee = nil }
    return noErr
  }

  /// Feeds the decoder exactly one compressed packet, and nothing after it.
  static let packet: AudioConverterComplexInputDataProc = {
    _, packetCount, bufferList, packetDescription, userData in
    guard let userData else {
      packetCount.pointee = 0
      return noErr
    }
    let source = Unmanaged<NetworkAudioOpusDecoder.PacketSource>.fromOpaque(userData)
      .takeUnretainedValue()
    guard !source.isSupplied else {
      packetCount.pointee = 0
      return noDataNow
    }
    source.isSupplied = true
    bufferList.pointee.mNumberBuffers = 1
    bufferList.pointee.mBuffers.mNumberChannels = 1
    bufferList.pointee.mBuffers.mData = source.storage
    bufferList.pointee.mBuffers.mDataByteSize = UInt32(source.byteCount)
    packetCount.pointee = 1
    if let packetDescription {
      source.description.pointee = AudioStreamPacketDescription(
        mStartOffset: 0,
        mVariableFramesInPacket: 0,
        mDataByteSize: UInt32(source.byteCount)
      )
      packetDescription.pointee = source.description
    }
    return noErr
  }
}
