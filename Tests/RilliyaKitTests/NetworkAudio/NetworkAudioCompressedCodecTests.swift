// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaRealtime
import Testing

@testable import RilliyaNetworkAudio

@Suite("Network audio Opus block lengths")
struct NetworkAudioOpusBlockTests {
  @Test(
    "The block lengths offered are the ones Opus defines at that rate",
    arguments: [
      (48_000.0, [120, 240, 480, 960, 1_920, 2_880]),
      (24_000.0, [60, 120, 240, 480, 960, 1_440]),
      (16_000.0, [40, 80, 160, 320, 640, 960]),
      (12_000.0, [30, 60, 120, 240, 480, 720]),
      (8_000.0, [20, 40, 80, 160, 320, 480]),
    ]
  )
  func frameCountsMatchTheDefinition(sampleRate: Double, expected: [Int]) {
    #expect(NetworkAudioCodec.opus.frameCounts(sampleRate: sampleRate, channelCount: 2) == expected)
  }

  @Test("A rate Opus does not carry offers no block lengths")
  func unsupportedRateOffersNothing() {
    #expect(NetworkAudioCodec.opus.frameCounts(sampleRate: 44_100, channelCount: 2).isEmpty)
    #expect(!NetworkAudioCodec.opus.carries(frameCount: 128, sampleRate: 44_100, channelCount: 2))
  }

  /// A render quantum is not an Opus block, so a sender has to be given one that is.
  @Test("A block a graph would render is not mistaken for one Opus carries")
  func renderQuantaAreNotOpusBlocks() {
    #expect(!NetworkAudioCodec.opus.carries(frameCount: 128, sampleRate: 48_000, channelCount: 2))
    #expect(!NetworkAudioCodec.opus.carries(frameCount: 512, sampleRate: 48_000, channelCount: 2))
    #expect(NetworkAudioCodec.opus.carries(frameCount: 480, sampleRate: 48_000, channelCount: 2))
  }

  @Test(
    "The nearest block to a wanted length is one Opus carries",
    arguments: [(2.0, 120), (4.0, 240), (10.0, 480), (11.0, 480), (55.0, 2_880)]
  )
  func nearestBlockIsCarried(milliseconds: Double, expected: Int) {
    #expect(
      NetworkAudioCodec.opus.frameCount(
        nearestTo: milliseconds, sampleRate: 48_000, channelCount: 2) == expected
    )
  }
}

@Suite("Network audio Opus round trip")
struct NetworkAudioOpusRoundTripTests {
  private enum Fixture {
    static let sampleRate = 48_000.0
    static let channelCount = 2
    static let frameCount = 480
    static let bitRate = 128_000
    static let frequency = 440.0
    static let blocks = 40
  }

  /// The point of carrying Opus is that far fewer bytes cross the network.
  @Test("A compressed packet is a fraction of the samples it replaces")
  func compressionIsSubstantial() throws {
    let harness = try Harness()

    let byteCounts = try (0..<Fixture.blocks).map { try harness.encodeBlock($0) }

    let raw = Fixture.frameCount * Fixture.channelCount * MemoryLayout<Float>.stride
    let mean = byteCounts.reduce(0, +) / byteCounts.count
    #expect(mean > 0)
    #expect(mean < raw / 8)
  }

  /// A packet larger than the codec's own bound would overrun the storage it is copied into.
  @Test("Every packet stays inside the codec's bound")
  func packetsStayBounded() throws {
    let harness = try Harness()

    for block in 0..<Fixture.blocks {
      #expect(try harness.encodeBlock(block) <= NetworkAudioCodec.maximumPacketByteCount)
    }
  }

  /// Compression is lossy, so the test is that the tone comes back, not that the samples do.
  @Test("A tone survives the round trip at its own frequency and level")
  func toneSurvivesTheRoundTrip() throws {
    let harness = try Harness()

    let decoded = try harness.roundTrip(blocks: Fixture.blocks)

    // The codec looks ahead, so the opening blocks are still filling.
    let settled = Array(decoded.dropFirst(Fixture.frameCount * 4))
    #expect(harness.level(settled) > 0.15)
    #expect(harness.level(settled) < 0.30)
    #expect(
      abs(harness.dominantFrequency(settled) - Fixture.frequency) < 5
    )
  }

  /// The decoder looks ahead, so a caller that assumed a full block from the first packet would
  /// write frames it was never given.
  @Test("Blocks decode to a full length once the decoder's lookahead has filled")
  func blockLengthSettlesAfterTheFirstPacket() throws {
    let harness = try Harness()

    let first = try harness.decodeBlock(byteCount: try harness.encodeBlock(0))
    #expect(first > 0)
    #expect(first < Fixture.frameCount)

    for block in 1..<Fixture.blocks {
      let byteCount = try harness.encodeBlock(block)
      #expect(try harness.decodeBlock(byteCount: byteCount) == Fixture.frameCount)
    }
  }

  @Test("Bytes that are not a packet are refused rather than decoded")
  func rubbishIsRefused() throws {
    let harness = try Harness()
    var seed: UInt64 = 0x5DEE_CE66_D1CE_1234

    for _ in 0..<200 {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      let byteCount = Int(seed % 300) + 1
      for index in 0..<byteCount {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        harness.packet[index] = UInt8(truncatingIfNeeded: seed >> 33)
      }
      // Either it decodes to something, or it says no. It never traps.
      _ = try? harness.decodeBlock(byteCount: byteCount)
    }
  }

  @Test(
    "A format Opus does not carry is refused",
    arguments: [(44_100.0, 2, 480), (48_000.0, 3, 480), (48_000.0, 2, 128)]
  )
  func unsupportedFormatsAreRefused(sampleRate: Double, channelCount: Int, frameCount: Int) {
    #expect(throws: NetworkAudioCodecError.self) {
      _ = try NetworkAudioCompressedEncoder(
        codec: .opus,
        sampleRate: sampleRate,
        channelCount: channelCount,
        frameCountPerPacket: frameCount,
        bitRate: Fixture.bitRate
      )
    }
    #expect(throws: NetworkAudioCodecError.self) {
      _ = try NetworkAudioCompressedDecoder(
        codec: .opus,
        sampleRate: sampleRate,
        channelCount: channelCount,
        frameCountPerPacket: frameCount
      )
    }
  }

  private final class Harness {
    let encoder: NetworkAudioCompressedEncoder
    let decoder: NetworkAudioCompressedDecoder
    let packet: UnsafeMutablePointer<UInt8>
    private let input: UnsafeMutablePointer<Float>
    private let output: UnsafeMutablePointer<Float>

    init() throws {
      encoder = try NetworkAudioCompressedEncoder(
        codec: .opus,
        sampleRate: Fixture.sampleRate,
        channelCount: Fixture.channelCount,
        frameCountPerPacket: Fixture.frameCount,
        bitRate: Fixture.bitRate
      )
      decoder = try NetworkAudioCompressedDecoder(
        codec: .opus,
        sampleRate: Fixture.sampleRate,
        channelCount: Fixture.channelCount,
        frameCountPerPacket: Fixture.frameCount
      )
      let sampleCount = Fixture.frameCount * Fixture.channelCount
      input = .allocate(capacity: sampleCount)
      output = .allocate(capacity: sampleCount)
      packet = .allocate(capacity: NetworkAudioCodec.maximumPacketByteCount)
      input.initialize(repeating: 0, count: sampleCount)
      output.initialize(repeating: 0, count: sampleCount)
      packet.initialize(repeating: 0, count: NetworkAudioCodec.maximumPacketByteCount)
    }

    deinit {
      input.deallocate()
      output.deallocate()
      packet.deallocate()
    }

    /// Fills the input with the block of the tone starting at `block`, and compresses it.
    func encodeBlock(_ block: Int) throws -> Int {
      for frame in 0..<Fixture.frameCount {
        let position = block * Fixture.frameCount + frame
        let value = Float(
          0.25 * sin(2 * .pi * Fixture.frequency * Double(position) / Fixture.sampleRate)
        )
        for channel in 0..<Fixture.channelCount {
          input[frame * Fixture.channelCount + channel] = value
        }
      }
      return try encoder.encode(
        input: input,
        into: UnsafeMutableRawBufferPointer(
          start: packet,
          count: NetworkAudioCodec.maximumPacketByteCount
        )
      )
    }

    func decodeBlock(byteCount: Int) throws -> Int {
      try decoder.decode(
        packet: UnsafeRawBufferPointer(start: packet, count: byteCount),
        into: output
      )
    }

    /// One channel of everything that came back.
    func roundTrip(blocks: Int) throws -> [Float] {
      var decoded: [Float] = []
      for block in 0..<blocks {
        let byteCount = try encodeBlock(block)
        let frames = try decodeBlock(byteCount: byteCount)
        for frame in 0..<frames {
          decoded.append(output[frame * Fixture.channelCount])
        }
      }
      return decoded
    }

    func level(_ samples: [Float]) -> Float {
      guard !samples.isEmpty else { return 0 }
      return (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    func dominantFrequency(_ samples: [Float]) -> Double {
      var crossings: [Double] = []
      for index in 1..<samples.count where samples[index - 1] < 0 && samples[index] >= 0 {
        let previous = Double(samples[index - 1])
        let current = Double(samples[index])
        let fraction = current == previous ? 0 : -previous / (current - previous)
        crossings.append(Double(index - 1) + fraction)
      }
      guard crossings.count > 1, let first = crossings.first, let last = crossings.last else {
        return 0
      }
      let period = (last - first) / Double(crossings.count - 1)
      return period > 0 ? Fixture.sampleRate / period : 0
    }
  }
}

/// The wire has to carry a compressed payload as readily as an uncompressed one, including under
/// a key: the header it is authenticated against says which of the two it is.
@Suite("Network audio Opus on the wire")
struct NetworkAudioOpusWireTests {
  private enum Fixture {
    static let sampleRate = 48_000.0
    static let channelCount = 2
    static let frameCount = 480
    static let sessionID = UUID(
      uuid: (
        0x0A, 0x1B, 0x2C, 0x3D, 0x4E, 0x5F, 0x40, 0x81,
        0x92, 0xA3, 0xB4, 0xC5, 0xD6, 0xE7, 0xF8, 0x09
      )
    )
  }

  @Test("A compressed datagram round-trips through the codec")
  func compressedDatagramRoundTrips() throws {
    let payload = Data((0..<200).map { UInt8($0 % 251) })

    let datagram = try encode(payload: payload, key: nil)
    let decoded = try NetworkAudioPacketCodec.decode(datagram)

    #expect(decoded.encoding == .opus)
    #expect(decoded.payload == payload)
    #expect(decoded.frameCount == Fixture.frameCount)
    #expect(decoded.format.sampleRate == Fixture.sampleRate)
  }

  @Test("A compressed datagram round-trips under a key")
  func compressedDatagramRoundTripsEncrypted() throws {
    let key = NetworkAudioSharedKey.random()
    let payload = Data((0..<173).map { UInt8($0 % 251) })

    let datagram = try encode(payload: payload, key: key)
    let cipher = NetworkAudioSessionCipher(sharedKey: key, sessionID: Fixture.sessionID)
    let decoded = try NetworkAudioPacketCodec.decode(datagram, cipher: cipher)

    #expect(decoded.encoding == .opus)
    #expect(decoded.payload == payload)
    // The compressed bytes must not be readable without the key.
    #expect(!datagram.dropFirst(NetworkAudioPacketCodec.headerByteCount).starts(with: payload))
  }

  /// The encoding is part of what the tag covers, so flipping it is a forgery, not a fallback.
  @Test("Changing the declared encoding of a sealed datagram is refused")
  func encodingIsAuthenticated() throws {
    let key = NetworkAudioSharedKey.random()
    var datagram = try encode(payload: Data((0..<64).map { UInt8($0) }), key: key)

    // Byte five of the header is the encoding.
    datagram[5] = NetworkAudioWireEncoding.interleavedFloat32.rawValue

    let cipher = NetworkAudioSessionCipher(sharedKey: key, sessionID: Fixture.sessionID)
    #expect(throws: (any Error).self) {
      _ = try NetworkAudioPacketCodec.decode(datagram, cipher: cipher)
    }
  }

  @Test("A payload no Opus packet could be is refused")
  func impossiblePayloadIsRefused() throws {
    #expect(throws: (any Error).self) {
      _ = try encode(payload: Data(), key: nil)
    }
    #expect(throws: (any Error).self) {
      _ = try encode(
        payload: Data(count: NetworkAudioCodec.maximumPacketByteCount + 1),
        key: nil
      )
    }
  }

  /// Every packet the ingestor is handed has to reach the queue as audio, which is the whole
  /// path a receiver runs.
  @Test("A compressed stream reaches the receiver's queue as audio")
  func compressedStreamReachesTheQueue() throws {
    let format = try NetworkAudioStreamFormat(
      sampleRate: Fixture.sampleRate,
      channelCount: Fixture.channelCount
    )
    let frameBuffer = try AudioRealtimeFrameBuffer(
      format: AudioProcessingFormat(
        sampleRate: Fixture.sampleRate,
        channelCount: Fixture.channelCount
      ),
      capacityFrameCount: 32_768
    )
    let ingestor = try NetworkAudioPacketIngestor(
      configuration: NetworkAudioReceiverConfiguration(
        port: 49_999,
        format: format,
        capacityFrameCount: 32_768
      ),
      frameBuffer: frameBuffer
    )
    let encoder = try NetworkAudioCompressedEncoder(
      codec: .opus,
      sampleRate: Fixture.sampleRate,
      channelCount: Fixture.channelCount,
      frameCountPerPacket: Fixture.frameCount,
      bitRate: 128_000
    )
    let samples = UnsafeMutablePointer<Float>.allocate(
      capacity: Fixture.frameCount * Fixture.channelCount)
    let packet = UnsafeMutableRawBufferPointer.allocate(byteCount: 4_000, alignment: 16)
    defer {
      samples.deallocate()
      packet.deallocate()
    }

    var accepted = 0
    for block in 0..<20 {
      for frame in 0..<Fixture.frameCount {
        let position = block * Fixture.frameCount + frame
        let value = Float(0.25 * sin(2 * .pi * 440 * Double(position) / Fixture.sampleRate))
        for channel in 0..<Fixture.channelCount {
          samples[frame * Fixture.channelCount + channel] = value
        }
      }
      let byteCount = try encoder.encode(input: samples, into: packet)
      let datagram = try encode(
        payload: Data(UnsafeRawBufferPointer(rebasing: packet[..<byteCount])),
        key: nil,
        sequence: UInt64(block)
      )
      if case .accepted = ingestor.ingest(datagram, now: UInt64(block) * 10_000_000) {
        accepted += 1
      }
    }

    #expect(accepted == 20)
    let statistics = ingestor.statistics()
    #expect(statistics.rejectedPacketCount == 0)
    // Every block but the decoder's first reaches the queue in full.
    #expect(statistics.frameBuffer.writtenFrameCount > UInt64(Fixture.frameCount * 18))
  }

  private func encode(
    payload: Data,
    key: NetworkAudioSharedKey?,
    sequence: UInt64 = 0
  ) throws -> Data {
    let format = try NetworkAudioStreamFormat(
      sampleRate: Fixture.sampleRate,
      channelCount: Fixture.channelCount
    )
    let cipher = key.map { NetworkAudioSessionCipher(sharedKey: $0, sessionID: Fixture.sessionID) }
    var datagram = Data(count: NetworkAudioPacketCodec.maximumDatagramByteCount)
    let written = try payload.withUnsafeBytes { source in
      try datagram.withUnsafeMutableBytes { destination in
        try NetworkAudioPacketCodec.encode(
          sessionID: Fixture.sessionID,
          sequence: sequence,
          format: format,
          frameCount: Fixture.frameCount,
          encoding: .opus,
          payload: source,
          into: destination,
          cipher: cipher
        )
      }
    }
    return datagram.prefix(written)
  }
}

/// Every codec offered has to survive the same round trip, or offering it is a promise the wire
/// does not keep.
@Suite("Network audio codecs")
struct NetworkAudioCodecSuiteTests {
  private static let codecs = NetworkAudioCodec.all

  @Test("Every codec the system offers can be both built and read")
  func everyCodecBuildsBothWays() throws {
    for codec in Self.codecs {
      let rate = try #require(codec.supportedSampleRates.last)
      let channels = try #require(codec.supportedChannelCounts.first { $0 == 2 })
      let frames = try #require(
        codec.frameCount(nearestTo: 10, sampleRate: rate, channelCount: channels))

      #expect(throws: Never.self) {
        _ = try NetworkAudioCompressedEncoder(
          codec: codec,
          sampleRate: rate,
          channelCount: channels,
          frameCountPerPacket: frames,
          bitRate: 128_000
        )
      }
      let encoder = try NetworkAudioCompressedEncoder(
        codec: codec,
        sampleRate: rate,
        channelCount: channels,
        frameCountPerPacket: frames,
        bitRate: 128_000
      )
      #expect(throws: Never.self) {
        _ = try NetworkAudioCompressedDecoder(
          codec: codec,
          sampleRate: rate,
          channelCount: channels,
          frameCountPerPacket: frames,
          configuration: encoder.configuration
        )
      }
    }
  }

  /// Not a sine: a pure tone compresses to almost nothing and would pass a codec that is broken
  /// on anything real.
  @Test("Every codec carries music-like content back at its own level")
  func everyCodecCarriesTheAudio() throws {
    for codec in Self.codecs {
      let harness = try Harness(codec: codec)

      let decoded = try harness.roundTrip(blocks: 24)

      let settled = Array(decoded.dropFirst(harness.frameCount * 4))
      #expect(!settled.isEmpty, "\(codec.encoding) produced nothing")
      #expect(harness.level(settled) > 0.10, "\(codec.encoding) came back too quiet")
      #expect(harness.level(settled) < 0.40, "\(codec.encoding) came back too loud")
    }
  }

  @Test("Every codec's packets stay inside the bound the wire allows")
  func everyCodecStaysBounded() throws {
    for codec in Self.codecs {
      let harness = try Harness(codec: codec)
      var produced = 0
      for block in 0..<24 {
        let byteCount = try harness.encodeBlock(block)
        #expect(
          byteCount
            <= codec.maximumPacketByteCount(sampleRate: 48_000, channelCount: 2))
        if byteCount > 0 { produced += 1 }
      }
      // A codec that fills first still has to produce most of what it was given.
      #expect(produced >= 20, "\(codec.encoding) produced only \(produced) packets from 24")
    }
  }

  /// A block length is a floor under the delay of the whole path, so what each codec insists on
  /// is part of what choosing it means.
  @Test("The lossy codecs pack a block short enough for live audio, and the lossless one does not")
  func blockLengthsAreWhatTheyClaim() throws {
    for codec in Self.codecs {
      let frames = try #require(
        codec.frameCount(nearestTo: 10, sampleRate: 48_000, channelCount: 2))
      let milliseconds = Double(frames) / 48_000 * 1_000
      if codec.isLossless {
        // Paying for every sample means waiting for a long block, which a caller has to know.
        #expect(milliseconds > 25, "\(codec.encoding) packs \(milliseconds) ms per packet")
      } else {
        #expect(milliseconds <= 25, "\(codec.encoding) packs \(milliseconds) ms per packet")
      }
    }
  }

  /// A codec that cannot read anything without the sender's configuration must say so rather
  /// than build and then produce silence.
  @Test("A decoder that needs a configuration refuses to be built without one")
  func missingConfigurationIsRefused() throws {
    let codec = NetworkAudioCodec.appleLossless
    let frames = try #require(
      codec.frameCount(nearestTo: 10, sampleRate: 48_000, channelCount: 2))

    #expect(throws: NetworkAudioCodecError.missingConfiguration) {
      _ = try NetworkAudioCompressedDecoder(
        codec: codec,
        sampleRate: 48_000,
        channelCount: 2,
        frameCountPerPacket: frames
      )
    }
  }

  /// What "lossless" is worth here, measured rather than claimed.
  ///
  /// The round trip is not bit-exact for 32-bit float: it returns every sample to about two to
  /// the minus thirty-second, which is one step of a 32-bit integer. That is far below the least
  /// significant bit of 24-bit audio, so nothing a converter or a recording carries is altered —
  /// but it is not zero, and an earlier measurement that printed it as zero was rounding.
  @Test("The lossless codec returns every sample below the smallest step real audio has")
  func losslessReturnsEverySampleExactly() throws {
    let codec = NetworkAudioCodec.appleLossless
    let frames = try #require(
      codec.frameCount(nearestTo: 10, sampleRate: 48_000, channelCount: 2))
    let channelCount = 2
    let sampleCount = frames * channelCount

    let encoder = try NetworkAudioCompressedEncoder(
      codec: codec,
      sampleRate: 48_000,
      channelCount: channelCount,
      frameCountPerPacket: frames,
      bitRate: 0
    )
    #expect(!encoder.configuration.isEmpty)
    let decoder = try NetworkAudioCompressedDecoder(
      codec: codec,
      sampleRate: 48_000,
      channelCount: channelCount,
      frameCountPerPacket: frames,
      configuration: encoder.configuration
    )

    let input = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
    let output = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
    let packet = UnsafeMutableRawBufferPointer.allocate(
      byteCount: codec.maximumPacketByteCount(sampleRate: 48_000, channelCount: channelCount),
      alignment: 16)
    defer {
      input.deallocate()
      output.deallocate()
      packet.deallocate()
    }
    input.initialize(repeating: 0, count: sampleCount)
    output.initialize(repeating: 0, count: sampleCount)

    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    var worstError: Float = 0
    for block in 0..<8 {
      for frame in 0..<frames {
        let position = Double(block * frames + frame)
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        let noise = Double(Int64(bitPattern: seed >> 11)) / Double(1 << 52) * 0.04
        let value = Float(
          0.20 * sin(2 * .pi * 220 * position / 48_000)
            + 0.10 * sin(2 * .pi * 3_140 * position / 48_000) + noise
        )
        for channel in 0..<channelCount { input[frame * channelCount + channel] = value }
      }
      let byteCount = try encoder.encode(input: input, into: packet)
      guard byteCount > 0 else { continue }
      let produced = try decoder.decode(
        packet: UnsafeRawBufferPointer(rebasing: packet[..<byteCount]),
        into: output
      )
      guard block >= 1, produced == frames else { continue }
      for index in 0..<sampleCount {
        worstError = max(worstError, abs(output[index] - input[index]))
      }
    }

    // One step of 24-bit audio, which is finer than any source this carries.
    let twentyFourBitStep = Float(1.0 / 8_388_608.0)
    #expect(worstError < twentyFourBitStep)
    #expect(worstError > 0, "a bit-exact result would mean the float path changed")
  }

  /// Opus cannot carry 44.1 kHz and the low-delay AAC profiles can, which is the whole reason to
  /// offer more than one.
  @Test("The codecs between them carry the rates a source is likely to arrive at")
  func codecsCoverTheUsualRates() {
    #expect(!NetworkAudioCodec.opus.supportedSampleRates.contains(44_100))
    #expect(NetworkAudioCodec.aacEnhancedLowDelay.supportedSampleRates.contains(44_100))
    #expect(NetworkAudioCodec.aacLowDelay.supportedSampleRates.contains(44_100))
    for codec in NetworkAudioCodec.all {
      #expect(codec.supportedSampleRates.contains(48_000))
      #expect(codec.supportedChannelCounts.contains(2))
    }
  }

  @Test("A datagram's encoding byte names exactly one codec")
  func encodingNamesOneCodec() {
    #expect(NetworkAudioCodec.codec(for: .interleavedFloat32) == nil)
    for codec in NetworkAudioCodec.all {
      #expect(NetworkAudioCodec.codec(for: codec.encoding) == codec)
    }
    #expect(Set(NetworkAudioCodec.all.map(\.encoding)).count == NetworkAudioCodec.all.count)
  }

  private final class Harness {
    let codec: NetworkAudioCodec
    let frameCount: Int
    private let encoder: NetworkAudioCompressedEncoder
    private let decoder: NetworkAudioCompressedDecoder
    private let input: UnsafeMutablePointer<Float>
    private let output: UnsafeMutablePointer<Float>
    private let packet: UnsafeMutableRawBufferPointer
    private let channelCount = 2
    private let sampleRate = 48_000.0
    private var seed: UInt64 = 0x2545_F491_4F6C_DD1D

    init(codec: NetworkAudioCodec) throws {
      self.codec = codec
      frameCount = try #require(
        codec.frameCount(nearestTo: 10, sampleRate: 48_000, channelCount: 2))
      encoder = try NetworkAudioCompressedEncoder(
        codec: codec,
        sampleRate: sampleRate,
        channelCount: channelCount,
        frameCountPerPacket: frameCount,
        bitRate: 128_000
      )
      decoder = try NetworkAudioCompressedDecoder(
        codec: codec,
        sampleRate: sampleRate,
        channelCount: channelCount,
        frameCountPerPacket: frameCount,
        configuration: encoder.configuration
      )
      let sampleCount = frameCount * channelCount
      input = .allocate(capacity: sampleCount)
      output = .allocate(capacity: sampleCount)
      input.initialize(repeating: 0, count: sampleCount)
      output.initialize(repeating: 0, count: sampleCount)
      packet = .allocate(
        byteCount: codec.maximumPacketByteCount(sampleRate: sampleRate, channelCount: channelCount),
        alignment: 16)
    }

    deinit {
      input.deallocate()
      output.deallocate()
      packet.deallocate()
    }

    func encodeBlock(_ block: Int) throws -> Int {
      for frame in 0..<frameCount {
        let position = Double(block * frameCount + frame)
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        let noise = Double(Int64(bitPattern: seed >> 11)) / Double(1 << 52) * 0.04
        let value = Float(
          0.20 * sin(2 * .pi * 220 * position / sampleRate)
            + 0.10 * sin(2 * .pi * 3_140 * position / sampleRate)
            + 0.06 * sin(2 * .pi * 7_700 * position / sampleRate) + noise
        )
        for channel in 0..<channelCount {
          input[frame * channelCount + channel] = value
        }
      }
      return try encoder.encode(input: input, into: packet)
    }

    func roundTrip(blocks: Int) throws -> [Float] {
      var decoded: [Float] = []
      for block in 0..<blocks {
        let byteCount = try encodeBlock(block)
        guard byteCount > 0 else { continue }
        let frames = try decoder.decode(
          packet: UnsafeRawBufferPointer(rebasing: packet[..<byteCount]),
          into: output
        )
        for frame in 0..<frames { decoded.append(output[frame * channelCount]) }
      }
      return decoded
    }

    func level(_ samples: [Float]) -> Float {
      guard !samples.isEmpty else { return 0 }
      return (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }
  }
}
