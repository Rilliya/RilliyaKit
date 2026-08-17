// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import Foundation

/// Why a compressed codec could not be prepared or could not run.
public enum NetworkAudioCodecError: Error, Equatable, Sendable {
  /// This codec does not carry this sample rate.
  case unsupportedSampleRate(Double)

  /// This codec does not carry this channel count.
  case unsupportedChannelCount(Int)

  /// This codec does not carry a block of this length at this rate.
  case unsupportedFrameCount(Int)

  /// The requested bit rate is outside what the system's encoder offers.
  case unsupportedBitRate(Int)

  /// The system could not prepare the codec.
  case unavailable(OSStatus)

  /// The system refused this block.
  case failed(OSStatus)

  /// The compressed packet is larger than any this codec produces.
  case oversizedPacket(Int)

  /// This codec cannot read anything until the encoder's configuration arrives.
  case missingConfiguration
}

extension NetworkAudioCodecError: LocalizedError {
  /// A human-readable explanation suitable for application diagnostics.
  public var errorDescription: String? {
    switch self {
    case .unsupportedSampleRate(let rate):
      "This wire format does not carry \(Int(rate)) Hz audio."
    case .unsupportedChannelCount(let count):
      "This wire format does not carry \(count) channels."
    case .unsupportedFrameCount(let count):
      "This wire format does not carry blocks of \(count) frames at this rate."
    case .unsupportedBitRate(let rate):
      "The system's encoder does not offer \(rate) bits per second."
    case .unavailable(let status):
      "The system could not prepare this wire format (\(status))."
    case .failed(let status):
      "The system could not code this block (\(status))."
    case .oversizedPacket(let byteCount):
      "A packet of \(byteCount) bytes is larger than this wire format produces."
    case .missingConfiguration:
      "This wire format cannot be read until the sender's codec configuration arrives."
    }
  }
}

/// One compressed representation the system can both produce and read.
///
/// What a codec costs in delay is the block it insists on: a packet cannot be sent until its
/// whole block exists, so the block length is a floor under the latency of the whole path. Opus
/// packs 2.5 milliseconds, the low-delay AAC profiles 10.7, and Apple Lossless 85, which is why
/// the last suits listening rather than monitoring and is offered as a choice rather than a
/// default.
///
/// The system's lossless codecs are absent for two different reasons, both measured. FLAC does
/// not return every sample exactly through this float path, so calling it lossless would be
/// untrue. Apple Lossless does — but one of its blocks is about twenty datagrams wide, and
/// losing any one of them loses the whole block.
public struct NetworkAudioCodec: Equatable, Hashable, Sendable {
  /// The value this codec writes into a datagram's encoding byte.
  public let encoding: NetworkAudioWireEncoding

  /// The system's identifier for this format.
  public let formatID: AudioFormatID

  /// Whether the encoder takes a bit rate.
  public let usesBitRate: Bool

  /// Whether a decoder needs the encoder's own configuration before it can read anything.
  ///
  /// Opus and the AAC profiles carry everything a decoder needs in the packet. Apple Lossless
  /// does not: without the configuration its encoder settled on, a decoder produces nothing at
  /// all, so that configuration has to cross the network too.
  public let needsConfiguration: Bool

  /// Whether every sample comes back exactly as it was sent.
  public let isLossless: Bool

  /// The largest compressed packet any of these codecs is allowed to produce.
  public static let maximumPacketByteCount = 4_000

  /// Opus, which packs the shortest blocks of anything here and carries loss well.
  public static let opus = NetworkAudioCodec(
    encoding: .opus,
    formatID: kAudioFormatOpus,
    usesBitRate: true,
    needsConfiguration: false,
    isLossless: false
  )

  /// AAC Enhanced Low Delay, which carries 44.1 kHz where Opus does not.
  public static let aacEnhancedLowDelay = NetworkAudioCodec(
    encoding: .aacEnhancedLowDelay,
    formatID: kAudioFormatMPEG4AAC_ELD,
    usesBitRate: true,
    needsConfiguration: false,
    isLossless: false
  )

  /// AAC Low Delay, the plainer of the two low-delay AAC profiles.
  public static let aacLowDelay = NetworkAudioCodec(
    encoding: .aacLowDelay,
    formatID: kAudioFormatMPEG4AAC_LD,
    usesBitRate: true,
    needsConfiguration: false,
    isLossless: false
  )

  /// Apple Lossless, which returns every sample exactly but does not fit in a datagram.
  ///
  /// Measured here it packs 4096 frames into about 23,000 bytes on music-like content, against a
  /// datagram this protocol keeps at 1,200 to stay under every path's limit. One block would
  /// therefore have to be split across some twenty datagrams, and losing any one of them loses
  /// all eighty-five milliseconds: on a link dropping one packet in a hundred that is a fifth of
  /// all audio gone, which is far worse than anything a lossy codec does.
  ///
  /// It is defined but not offered. Re-enter it in ``all`` once datagrams are reassembled.
  public static let appleLossless = NetworkAudioCodec(
    encoding: .appleLossless,
    formatID: kAudioFormatAppleLossless,
    usesBitRate: false,
    needsConfiguration: true,
    isLossless: true
  )

  /// Every compressed format this wire protocol carries.
  ///
  /// ``appleLossless`` is absent because one of its blocks does not fit in a datagram; see its
  /// documentation.
  public static let all: [NetworkAudioCodec] = [opus, aacEnhancedLowDelay, aacLowDelay]

  /// The largest configuration any of these codecs produces.
  ///
  /// Apple Lossless reports 24 bytes on this machine; the bound is generous so a later system
  /// reporting more is refused rather than truncated.
  public static let maximumConfigurationByteCount = 256

  /// The codec a datagram's encoding byte names, or `nil` when it names no compression.
  public static func codec(for encoding: NetworkAudioWireEncoding) -> NetworkAudioCodec? {
    all.first { $0.encoding == encoding }
  }

  /// The sample rates the system's encoder offers for this format.
  ///
  /// Asked of the system rather than written down, so a codec that gains a rate in a later macOS
  /// gains it here without a change.
  public var supportedSampleRates: [Double] {
    NetworkAudioCodecCapabilities.shared.sampleRates(for: formatID)
  }

  /// The channel counts this format carries, among those a caller might route.
  public var supportedChannelCounts: [Int] {
    NetworkAudioCodecCapabilities.shared.channelCounts(for: formatID)
  }

  /// Whether this format carries audio of this shape.
  public func carries(sampleRate: Double, channelCount: Int) -> Bool {
    supportedSampleRates.contains(sampleRate) && supportedChannelCounts.contains(channelCount)
  }

  /// The block lengths this format offers at this shape, in frames.
  ///
  /// Opus defines several; the AAC profiles report one.
  public func frameCounts(sampleRate: Double, channelCount: Int) -> [Int] {
    guard carries(sampleRate: sampleRate, channelCount: channelCount) else { return [] }
    if formatID == kAudioFormatOpus {
      return Self.opusBlockMilliseconds.map { Int((sampleRate * $0 / 1_000).rounded()) }
    }
    return NetworkAudioCodecCapabilities.shared
      .frameCountPerPacket(formatID: formatID, sampleRate: sampleRate, channelCount: channelCount)
      .map { [$0] } ?? []
  }

  /// Whether a block of this length is one this format carries.
  public func carries(frameCount: Int, sampleRate: Double, channelCount: Int) -> Bool {
    frameCounts(sampleRate: sampleRate, channelCount: channelCount).contains(frameCount)
  }

  /// The block closest to `preferred` milliseconds this format offers.
  public func frameCount(
    nearestTo preferredMilliseconds: Double,
    sampleRate: Double,
    channelCount: Int
  ) -> Int? {
    let available = frameCounts(sampleRate: sampleRate, channelCount: channelCount)
    guard !available.isEmpty else { return nil }
    let wanted = preferredMilliseconds * sampleRate / 1_000
    return available.min { abs(Double($0) - wanted) < abs(Double($1) - wanted) }
  }

  /// The block lengths Opus defines, in milliseconds.
  static let opusBlockMilliseconds: [Double] = [2.5, 5, 10, 20, 40, 60]
}

/// What the system says each format can carry, asked once and remembered.
///
/// Creating a converter to find out is expensive enough that a view redrawing must not do it, so
/// the answers are cached behind a lock.
final class NetworkAudioCodecCapabilities: @unchecked Sendable {
  static let shared = NetworkAudioCodecCapabilities()

  /// The channel counts worth asking about, being the ones a routing graph offers.
  private static let candidateChannelCounts = [1, 2, 4, 6, 8]

  /// The rates worth asking about when a codec says it accepts any.
  private static let candidateSampleRates: [Double] = [
    8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000,
    176_400, 192_000,
  ]

  private let lock = NSLock()
  private var sampleRatesByFormat: [AudioFormatID: [Double]] = [:]
  private var channelCountsByFormat: [AudioFormatID: [Int]] = [:]
  private var frameCounts: [FrameCountKey: Int?] = [:]

  private struct FrameCountKey: Hashable {
    let formatID: AudioFormatID
    let sampleRate: Double
    let channelCount: Int
  }

  func sampleRates(for formatID: AudioFormatID) -> [Double] {
    lock.withLock {
      if let cached = sampleRatesByFormat[formatID] { return cached }
      let rates = Self.queryEncodeSampleRates(formatID)
      sampleRatesByFormat[formatID] = rates
      return rates
    }
  }

  func channelCounts(for formatID: AudioFormatID) -> [Int] {
    lock.withLock {
      if let cached = channelCountsByFormat[formatID] { return cached }
      // The system's channel-count property comes back empty for these formats, so the question
      // is put the only way it answers: whether a block length exists for that shape.
      let rate = sampleRatesByFormat[formatID]?.last ?? Self.queryEncodeSampleRates(formatID).last
      guard let rate else {
        channelCountsByFormat[formatID] = []
        return []
      }
      let counts = Self.candidateChannelCounts.filter {
        Self.queryFrameCountPerPacket(formatID: formatID, sampleRate: rate, channelCount: $0) != nil
      }
      channelCountsByFormat[formatID] = counts
      return counts
    }
  }

  func frameCountPerPacket(
    formatID: AudioFormatID,
    sampleRate: Double,
    channelCount: Int
  ) -> Int? {
    let key = FrameCountKey(
      formatID: formatID, sampleRate: sampleRate, channelCount: channelCount)
    return lock.withLock {
      if let cached = frameCounts[key] { return cached }
      let count = Self.queryFrameCountPerPacket(
        formatID: formatID, sampleRate: sampleRate, channelCount: channelCount)
      frameCounts[key] = count
      return count
    }
  }

  private static func queryEncodeSampleRates(_ formatID: AudioFormatID) -> [Double] {
    var identifier = formatID
    var size: UInt32 = 0
    guard
      AudioFormatGetPropertyInfo(
        kAudioFormatProperty_AvailableEncodeSampleRates,
        UInt32(MemoryLayout<AudioFormatID>.size),
        &identifier,
        &size
      ) == noErr, size > 0
    else { return [] }
    var ranges = [AudioValueRange](
      repeating: AudioValueRange(),
      count: Int(size) / MemoryLayout<AudioValueRange>.size
    )
    guard
      AudioFormatGetProperty(
        kAudioFormatProperty_AvailableEncodeSampleRates,
        UInt32(MemoryLayout<AudioFormatID>.size),
        &identifier,
        &size,
        &ranges
      ) == noErr
    else { return [] }
    // A codec that constrains nothing reports one empty range rather than a list, so the
    // question is put again as whether a block length exists at each rate a caller might use.
    let discrete = ranges.filter { $0.mMinimum == $0.mMaximum && $0.mMinimum > 0 }
    if !discrete.isEmpty { return discrete.map(\.mMinimum).sorted() }
    return candidateSampleRates.filter {
      queryFrameCountPerPacket(formatID: formatID, sampleRate: $0, channelCount: 2) != nil
    }
  }

  private static func queryFrameCountPerPacket(
    formatID: AudioFormatID,
    sampleRate: Double,
    channelCount: Int
  ) -> Int? {
    var description = NetworkAudioCodecFormat.compressed(
      formatID: formatID,
      sampleRate: sampleRate,
      channelCount: channelCount,
      frameCountPerPacket: 0
    )
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard
      AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &description) == noErr,
      description.mFramesPerPacket > 0
    else { return nil }
    return Int(description.mFramesPerPacket)
  }
}

/// Compresses one block of interleaved float audio into one packet.
///
/// Measured here, Opus compressing a 2.5 millisecond stereo block at 48 kHz costs about sixteen
/// microseconds, which is under one percent of that block's playing time. Compressing therefore
/// happens on the thread that is already producing the packet rather than being handed to another.
///
/// All storage is allocated during initialization.
public final class NetworkAudioCompressedEncoder: @unchecked Sendable {
  /// The format this encoder produces.
  public let codec: NetworkAudioCodec

  /// The rate the source is delivered at.
  public let sampleRate: Double

  /// The channels carried.
  public let channelCount: Int

  /// The frames one packet carries.
  public let frameCountPerPacket: Int

  /// The configuration a decoder needs before it can read this encoder's packets.
  ///
  /// Empty for a codec that needs none.
  public private(set) var configuration = Data()

  private let converter: AudioConverterRef
  private let source: Source
  private let inputStorage: UnsafeMutablePointer<Float>

  /// Prepares an encoder for one format and block length.
  public init(
    codec: NetworkAudioCodec,
    sampleRate: Double,
    channelCount: Int,
    frameCountPerPacket: Int,
    bitRate: Int
  ) throws {
    guard codec.supportedSampleRates.contains(sampleRate) else {
      throw NetworkAudioCodecError.unsupportedSampleRate(sampleRate)
    }
    guard codec.supportedChannelCounts.contains(channelCount) else {
      throw NetworkAudioCodecError.unsupportedChannelCount(channelCount)
    }
    guard
      codec.carries(
        frameCount: frameCountPerPacket, sampleRate: sampleRate, channelCount: channelCount)
    else {
      throw NetworkAudioCodecError.unsupportedFrameCount(frameCountPerPacket)
    }

    var pcm = NetworkAudioCodecFormat.pcm(sampleRate: sampleRate, channelCount: channelCount)
    var compressed = try NetworkAudioCodecFormat.resolved(
      formatID: codec.formatID,
      sampleRate: sampleRate,
      channelCount: channelCount,
      frameCountPerPacket: frameCountPerPacket
    )
    var created: AudioConverterRef?
    let status = AudioConverterNew(&pcm, &compressed, &created)
    guard status == noErr, let created else {
      throw NetworkAudioCodecError.unavailable(status)
    }
    if codec.usesBitRate {
      var rate = UInt32(bitRate)
      let bitRateStatus = AudioConverterSetProperty(
        created,
        kAudioConverterEncodeBitRate,
        UInt32(MemoryLayout<UInt32>.size),
        &rate
      )
      guard bitRateStatus == noErr else {
        AudioConverterDispose(created)
        throw NetworkAudioCodecError.unsupportedBitRate(bitRate)
      }
    }

    self.codec = codec
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.frameCountPerPacket = frameCountPerPacket
    converter = created
    inputStorage = .allocate(capacity: frameCountPerPacket * channelCount)
    inputStorage.initialize(repeating: 0, count: frameCountPerPacket * channelCount)
    source = Source(storage: inputStorage, channelCount: channelCount)
    if codec.needsConfiguration {
      configuration = Self.readConfiguration(from: created)
      guard !configuration.isEmpty else {
        throw NetworkAudioCodecError.unavailable(kAudioConverterErr_PropertyNotSupported)
      }
    }
  }

  deinit {
    AudioConverterDispose(converter)
    inputStorage.deinitialize(count: frameCountPerPacket * channelCount)
    inputStorage.deallocate()
  }

  /// The configuration the system's encoder settled on, which a decoder cannot infer.
  private static func readConfiguration(from converter: AudioConverterRef) -> Data {
    var size: UInt32 = 0
    guard
      AudioConverterGetPropertyInfo(
        converter, kAudioConverterCompressionMagicCookie, &size, nil) == noErr,
      size > 0, size <= UInt32(NetworkAudioCodec.maximumConfigurationByteCount)
    else { return Data() }
    var bytes = [UInt8](repeating: 0, count: Int(size))
    guard
      AudioConverterGetProperty(
        converter, kAudioConverterCompressionMagicCookie, &size, &bytes) == noErr
    else { return Data() }
    return Data(bytes.prefix(Int(size)))
  }

  /// Compresses one block into `packet`.
  ///
  /// - Parameters:
  ///   - input: interleaved samples, ``frameCountPerPacket`` frames of them.
  ///   - packet: where the compressed bytes are written.
  /// A codec that fills before it emits produces no packet from its opening blocks. That is
  /// reported as zero bytes rather than an error, and the caller sends nothing that turn.
  ///
  /// - Returns: the bytes written, or zero when this block produced no packet.
  /// - Throws: ``NetworkAudioCodecError`` when the system refuses the block.
  public func encode(
    input: UnsafePointer<Float>,
    into packet: UnsafeMutableRawBufferPointer
  ) throws -> Int {
    guard let destination = packet.baseAddress, packet.count > 0 else {
      throw NetworkAudioCodecError.oversizedPacket(packet.count)
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
        NetworkAudioCodecSupply.samples,
        Unmanaged.passUnretained(source).toOpaque(),
        &packetCount,
        &list,
        &description
      )
    }
    guard status == noErr || status == NetworkAudioCodecSupply.noDataNow else {
      throw NetworkAudioCodecError.failed(status)
    }
    guard packetCount == 1 else { return 0 }
    // A codec with a variable packet size reports it in the description rather than the buffer.
    let described = Int(description.mDataByteSize)
    return described > 0 ? described : Int(list.mBuffers.mDataByteSize)
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

/// Expands one compressed packet into interleaved float audio.
public final class NetworkAudioCompressedDecoder: @unchecked Sendable {
  /// The format this decoder reads.
  public let codec: NetworkAudioCodec

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
  public init(
    codec: NetworkAudioCodec,
    sampleRate: Double,
    channelCount: Int,
    frameCountPerPacket: Int,
    configuration: Data = Data()
  ) throws {
    guard codec.supportedSampleRates.contains(sampleRate) else {
      throw NetworkAudioCodecError.unsupportedSampleRate(sampleRate)
    }
    guard !codec.needsConfiguration || !configuration.isEmpty else {
      throw NetworkAudioCodecError.missingConfiguration
    }
    guard codec.supportedChannelCounts.contains(channelCount) else {
      throw NetworkAudioCodecError.unsupportedChannelCount(channelCount)
    }
    guard
      codec.carries(
        frameCount: frameCountPerPacket, sampleRate: sampleRate, channelCount: channelCount)
    else {
      throw NetworkAudioCodecError.unsupportedFrameCount(frameCountPerPacket)
    }

    var compressed = try NetworkAudioCodecFormat.resolved(
      formatID: codec.formatID,
      sampleRate: sampleRate,
      channelCount: channelCount,
      frameCountPerPacket: frameCountPerPacket
    )
    var pcm = NetworkAudioCodecFormat.pcm(sampleRate: sampleRate, channelCount: channelCount)
    var created: AudioConverterRef?
    let status = AudioConverterNew(&compressed, &pcm, &created)
    guard status == noErr, let created else {
      throw NetworkAudioCodecError.unavailable(status)
    }

    self.codec = codec
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.frameCountPerPacket = frameCountPerPacket
    converter = created
    if !configuration.isEmpty {
      var bytes = [UInt8](configuration)
      let status = AudioConverterSetProperty(
        created,
        kAudioConverterDecompressionMagicCookie,
        UInt32(bytes.count),
        &bytes
      )
      guard status == noErr else {
        AudioConverterDispose(created)
        throw NetworkAudioCodecError.unavailable(status)
      }
    }
    packetStorage = .allocate(
      byteCount: NetworkAudioCodec.maximumPacketByteCount,
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
  /// A codec that looks ahead yields fewer frames from the opening packets of a stream than they
  /// carry, while that lookahead fills. What it yields is what the caller writes.
  ///
  /// - Parameters:
  ///   - packet: the compressed bytes.
  ///   - output: interleaved destination, `frameCountPerPacket * channelCount` samples wide.
  /// - Returns: the frames produced.
  /// - Throws: ``NetworkAudioCodecError`` when the system refuses the packet.
  public func decode(
    packet: UnsafeRawBufferPointer,
    into output: UnsafeMutablePointer<Float>
  ) throws -> Int {
    guard let bytes = packet.baseAddress, packet.count > 0 else {
      throw NetworkAudioCodecError.failed(kAudioConverterErr_UnspecifiedError)
    }
    guard packet.count <= NetworkAudioCodec.maximumPacketByteCount else {
      throw NetworkAudioCodecError.oversizedPacket(packet.count)
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
        NetworkAudioCodecSupply.packet,
        Unmanaged.passUnretained(source).toOpaque(),
        &frames,
        &list,
        nil
      )
    }
    guard status == noErr || status == NetworkAudioCodecSupply.noDataNow else {
      throw NetworkAudioCodecError.failed(status)
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
enum NetworkAudioCodecFormat {
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

  static func compressed(
    formatID: AudioFormatID,
    sampleRate: Double,
    channelCount: Int,
    frameCountPerPacket: Int
  ) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: formatID,
      mFormatFlags: 0,
      mBytesPerPacket: 0,
      mFramesPerPacket: UInt32(frameCountPerPacket),
      mBytesPerFrame: 0,
      mChannelsPerFrame: UInt32(channelCount),
      mBitsPerChannel: 0,
      mReserved: 0
    )
  }

  /// The description with everything the system knows filled in, and the block length kept.
  static func resolved(
    formatID: AudioFormatID,
    sampleRate: Double,
    channelCount: Int,
    frameCountPerPacket: Int
  ) throws -> AudioStreamBasicDescription {
    var description = compressed(
      formatID: formatID,
      sampleRate: sampleRate,
      channelCount: channelCount,
      frameCountPerPacket: frameCountPerPacket
    )
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioFormatGetProperty(
      kAudioFormatProperty_FormatInfo,
      0,
      nil,
      &size,
      &description
    )
    guard status == noErr else { throw NetworkAudioCodecError.unavailable(status) }
    description.mFramesPerPacket = UInt32(frameCountPerPacket)
    return description
  }
}

/// The two C callbacks, kept out of the classes so neither captures anything.
enum NetworkAudioCodecSupply {
  /// Says there is nothing more for this block without saying the stream has ended.
  ///
  /// Answering a further ask with zero packets reports end of stream, after which the converter
  /// produces nothing ever again. A codec fed one block at a time has to say something else.
  static let noDataNow: OSStatus = 1_853_321_324

  /// Feeds the encoder the block it was given, advancing through it if asked more than once.
  static let samples: AudioConverterComplexInputDataProc = {
    _, packetCount, bufferList, packetDescription, userData in
    guard let userData else {
      packetCount.pointee = 0
      return noDataNow
    }
    let source = Unmanaged<NetworkAudioCompressedEncoder.Source>.fromOpaque(userData)
      .takeUnretainedValue()
    let frames = min(Int(packetCount.pointee), source.availableFrameCount)
    guard frames > 0 else {
      packetCount.pointee = 0
      return noDataNow
    }
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
      return noDataNow
    }
    let source = Unmanaged<NetworkAudioCompressedDecoder.PacketSource>.fromOpaque(userData)
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
