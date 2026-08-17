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
    #expect(NetworkAudioOpus.frameCounts(atSampleRate: sampleRate) == expected)
  }

  @Test("A rate Opus does not carry offers no block lengths")
  func unsupportedRateOffersNothing() {
    #expect(NetworkAudioOpus.frameCounts(atSampleRate: 44_100).isEmpty)
    #expect(!NetworkAudioOpus.carries(frameCount: 128, atSampleRate: 44_100))
  }

  /// A render quantum is not an Opus block, so a sender has to be given one that is.
  @Test("A block a graph would render is not mistaken for one Opus carries")
  func renderQuantaAreNotOpusBlocks() {
    #expect(!NetworkAudioOpus.carries(frameCount: 128, atSampleRate: 48_000))
    #expect(!NetworkAudioOpus.carries(frameCount: 512, atSampleRate: 48_000))
    #expect(NetworkAudioOpus.carries(frameCount: 480, atSampleRate: 48_000))
  }

  @Test(
    "The nearest block to a wanted length is one Opus carries",
    arguments: [(2.0, 120), (4.0, 240), (10.0, 480), (11.0, 480), (55.0, 2_880)]
  )
  func nearestBlockIsCarried(milliseconds: Double, expected: Int) {
    #expect(
      NetworkAudioOpus.frameCount(nearestTo: milliseconds, atSampleRate: 48_000) == expected
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
      #expect(try harness.encodeBlock(block) <= NetworkAudioOpus.maximumPacketByteCount)
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
    #expect(throws: NetworkAudioOpusError.self) {
      _ = try NetworkAudioOpusEncoder(
        sampleRate: sampleRate,
        channelCount: channelCount,
        frameCountPerPacket: frameCount,
        bitRate: Fixture.bitRate
      )
    }
    #expect(throws: NetworkAudioOpusError.self) {
      _ = try NetworkAudioOpusDecoder(
        sampleRate: sampleRate,
        channelCount: channelCount,
        frameCountPerPacket: frameCount
      )
    }
  }

  private final class Harness {
    let encoder: NetworkAudioOpusEncoder
    let decoder: NetworkAudioOpusDecoder
    let packet: UnsafeMutablePointer<UInt8>
    private let input: UnsafeMutablePointer<Float>
    private let output: UnsafeMutablePointer<Float>

    init() throws {
      encoder = try NetworkAudioOpusEncoder(
        sampleRate: Fixture.sampleRate,
        channelCount: Fixture.channelCount,
        frameCountPerPacket: Fixture.frameCount,
        bitRate: Fixture.bitRate
      )
      decoder = try NetworkAudioOpusDecoder(
        sampleRate: Fixture.sampleRate,
        channelCount: Fixture.channelCount,
        frameCountPerPacket: Fixture.frameCount
      )
      let sampleCount = Fixture.frameCount * Fixture.channelCount
      input = .allocate(capacity: sampleCount)
      output = .allocate(capacity: sampleCount)
      packet = .allocate(capacity: NetworkAudioOpus.maximumPacketByteCount)
      input.initialize(repeating: 0, count: sampleCount)
      output.initialize(repeating: 0, count: sampleCount)
      packet.initialize(repeating: 0, count: NetworkAudioOpus.maximumPacketByteCount)
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
          count: NetworkAudioOpus.maximumPacketByteCount
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
        payload: Data(count: NetworkAudioOpus.maximumPacketByteCount + 1),
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
    let encoder = try NetworkAudioOpusEncoder(
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
