// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaRealtime
import Testing

@testable import RilliyaNetworkAudio

/// The decoder is the first code an untrusted datagram reaches, so it has to survive arbitrary
/// bytes without trapping and must never report success for a packet whose metadata and payload
/// disagree.
///
/// Every corpus here is generated from a fixed seed so a failure is reproducible.
@Suite("Network audio packet fuzzing")
struct NetworkAudioPacketFuzzTests {
  private enum Corpus {
    static let seed: UInt64 = 0x5249_4C4C_4959_4101
    static let arbitraryDatagramCount = 20_000
    static let maximumArbitraryLength = 2_048
  }

  @Test("Arbitrary bytes decode to a valid packet or a typed error, never a trap")
  func arbitraryDatagramsNeverTrap() {
    var random = SplitMix64(seed: Corpus.seed)
    var decoded = 0

    for _ in 0..<Corpus.arbitraryDatagramCount {
      let length = Int(random.next() % UInt64(Corpus.maximumArbitraryLength + 1))
      var datagram = Data(count: length)
      for index in 0..<length {
        datagram[index] = UInt8(truncatingIfNeeded: random.next())
      }
      if let packet = decodeIgnoringTypedErrors(datagram) {
        expectSelfConsistent(packet)
        decoded += 1
      }
    }

    // Random bytes essentially never carry the magic, so this documents the corpus rather than
    // asserting a behaviour: a nonzero count would mean the generator drifted.
    #expect(decoded == 0)
  }

  @Test("Every single-bit corruption of a valid datagram is rejected or self-consistent")
  func singleBitCorruptionsNeverTrap() throws {
    let encoded = try NetworkAudioPacketCodec.encode(try validPacket())
    var accepted = 0

    for byteIndex in 0..<encoded.count {
      for bit in 0..<8 {
        var corrupted = encoded
        corrupted[byteIndex] ^= UInt8(1 << bit)
        if let packet = decodeIgnoringTypedErrors(corrupted) {
          expectSelfConsistent(packet)
          accepted += 1
        }
      }
    }

    // The session ID, sequence, and payload bytes are opaque, so flipping them still decodes.
    #expect(accepted > 0)
  }

  @Test("Every truncation of a valid datagram is rejected")
  func truncationsAreRejected() throws {
    let encoded = try NetworkAudioPacketCodec.encode(try validPacket())

    for length in 0..<encoded.count {
      #expect(decodeIgnoringTypedErrors(encoded.prefix(length)) == nil)
    }
    #expect(decodeIgnoringTypedErrors(encoded) != nil)
  }

  @Test("A datagram beyond the protocol bound is rejected before any parsing")
  func oversizedDatagramsAreRejected() throws {
    let encoded = try NetworkAudioPacketCodec.encode(try validPacket())
    var oversized = encoded
    oversized.append(
      Data(count: NetworkAudioPacketCodec.maximumDatagramByteCount - encoded.count + 1)
    )

    #expect(throws: NetworkAudioPacketError.datagramTooLarge) {
      _ = try NetworkAudioPacketCodec.decode(oversized)
    }
  }

  @Test("A declared payload length that disagrees with the frame metadata is rejected")
  func inconsistentPayloadLengthIsRejected() throws {
    let encoded = try NetworkAudioPacketCodec.encode(try validPacket())

    for declared: UInt32 in [0, 1, 3, 5, 1_000, .max] {
      var tampered = encoded
      tampered.replaceSubrange(40..<44, with: withUnsafeBytes(of: declared.bigEndian, Array.init))
      #expect(decodeIgnoringTypedErrors(tampered) == nil)
    }
  }

  /// The fragmented flag waives the rule tying a payload's length to the frames it claims.
  ///
  /// That is right for a piece of a compressed block, which says nothing about the block.
  /// Honouring it on uncompressed audio waived the rule for samples too, and nothing downstream
  /// looked at the flag again: one datagram could name a payload longer than the receiver's
  /// storage and be copied into it.
  ///
  /// The flag belongs to compressed encodings only, which is what both of these check.
  @Test("Uncompressed audio cannot claim to be a fragment")
  func uncompressedFragmentIsRefused() throws {
    let format = try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 2)

    #expect(throws: NetworkAudioPacketError.self) {
      _ = try NetworkAudioPacket(
        sessionID: UUID(),
        sequence: 1,
        format: format,
        frameCount: 1,
        payload: Data(count: 1_100),
        encoding: .interleavedFloat32,
        fragment: try NetworkAudioPacketFragment(index: 0, count: 2)
      )
    }
  }

  /// Encoding a packet used to write a zero where its flags belong, so which piece of a block a
  /// packet was — and any codec configuration it carried — was dropped on the way out and could
  /// never come back.
  @Test("A packet keeps its place in a block and its configuration through a round trip")
  func packetRoundTripsWithEverythingItHolds() throws {
    let format = try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 2)
    let packet = try NetworkAudioPacket(
      sessionID: UUID(),
      sequence: 9,
      format: format,
      frameCount: 4_096,
      payload: Data((0..<300).map { UInt8($0 % 251) }),
      encoding: .appleLossless,
      codecConfiguration: Data((0..<24).map { UInt8($0) }),
      fragment: try NetworkAudioPacketFragment(index: 3, count: 20)
    )

    let decoded = try NetworkAudioPacketCodec.decode(
      try NetworkAudioPacketCodec.encode(packet))

    #expect(decoded.fragment == packet.fragment)
    #expect(decoded.codecConfiguration == packet.codecConfiguration)
    #expect(decoded.payload == packet.payload)
    #expect(decoded.encoding == packet.encoding)
    #expect(decoded == packet)
  }

  /// The header is not authenticated when no key is set, so the flag has to be refused on the way
  /// in rather than trusted because a sender would not have set it.
  @Test("A forged uncompressed fragment is refused on the way in")
  func forgedUncompressedFragmentIsRefused() throws {
    let format = try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 2)
    // A legitimate compressed fragment, which is the only kind that may carry the flag.
    let compressed = try NetworkAudioPacket(
      sessionID: UUID(),
      sequence: 1,
      format: format,
      frameCount: 480,
      payload: Data(count: 1_100),
      encoding: .opus,
      fragment: try NetworkAudioPacketFragment(index: 0, count: 2)
    )
    var datagram = try NetworkAudioPacketCodec.encode(compressed)

    // Byte 5 is the encoding: claim samples while keeping the fragmented flag.
    #expect(datagram[5] == NetworkAudioWireEncoding.opus.rawValue)
    datagram[5] = NetworkAudioWireEncoding.interleavedFloat32.rawValue

    #expect(throws: NetworkAudioPacketError.self) {
      _ = try NetworkAudioPacketCodec.decode(datagram)
    }

    // And the receiver refuses it rather than copying the payload into storage sized for a block.
    //
    // Seven channels on purpose: no codec carries that count, so the receiver's storage is sized
    // by the uncompressed block alone and is smaller than a datagram. Channel counts a codec does
    // carry hide the overrun behind the larger compressed bound.
    let wide = try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 7)
    let frameBuffer = try AudioRealtimeFrameBuffer(
      format: AudioProcessingFormat(sampleRate: 48_000, channelCount: 7)
    )
    let ingestor = try NetworkAudioPacketIngestor(
      configuration: try NetworkAudioReceiverConfiguration(
        port: 48_620,
        format: wide,
        maximumDatagramByteCount: 1_195
      ),
      frameBuffer: frameBuffer
    )
    let forged = try Self.forgedWideFragment(sessionID: compressed.sessionID, format: wide)
    let outcome = ingestor.ingest(forged, now: 0)

    if case .accepted = outcome {
      Issue.record("a forged uncompressed fragment was accepted")
    }
    #expect(frameBuffer.statistics().writtenFrameCount == 0)
  }

  /// One datagram claiming samples, the fragmented flag, and a payload far longer than seven
  /// channels of one frame.
  private static func forgedWideFragment(
    sessionID: UUID,
    format: NetworkAudioStreamFormat
  ) throws -> Data {
    // One frame, so the frame-count bound is satisfied, and a payload far longer than one frame of
    // seven channels — which only the fragmented flag let past.
    let honest = try NetworkAudioPacket(
      sessionID: sessionID,
      sequence: 1,
      format: format,
      frameCount: 1,
      payload: Data(count: 1_143),
      encoding: .opus,
      fragment: try NetworkAudioPacketFragment(index: 0, count: 2)
    )
    var datagram = try NetworkAudioPacketCodec.encode(honest)
    datagram[5] = NetworkAudioWireEncoding.interleavedFloat32.rawValue
    return datagram
  }

  @Test("The ingestor survives hostile datagrams without writing unclaimed frames")
  func ingestorSurvivesHostileDatagrams() throws {
    let format = try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 2)
    let frameBuffer = try AudioRealtimeFrameBuffer(
      format: AudioProcessingFormat(sampleRate: 48_000, channelCount: 2)
    )
    let ingestor = try NetworkAudioPacketIngestor(
      configuration: try NetworkAudioReceiverConfiguration(port: 48_620, format: format),
      frameBuffer: frameBuffer
    )
    var random = SplitMix64(seed: Corpus.seed)
    let valid = try NetworkAudioPacketCodec.encode(try validPacket())
    var acceptedFrames = 0

    for index in 0..<Corpus.arbitraryDatagramCount {
      var datagram = index.isMultiple(of: 3) ? valid : Data()
      if datagram.isEmpty {
        let length = Int(random.next() % UInt64(Corpus.maximumArbitraryLength + 1))
        datagram = Data(count: length)
        for byteIndex in 0..<length {
          datagram[byteIndex] = UInt8(truncatingIfNeeded: random.next())
        }
      } else {
        let byteIndex = Int(random.next() % UInt64(datagram.count))
        datagram[byteIndex] ^= UInt8(truncatingIfNeeded: random.next())
      }
      if case .accepted(let frameCount) = ingestor.ingest(datagram, now: UInt64(index)) {
        acceptedFrames += frameCount
      }
    }

    let statistics = ingestor.statistics()
    #expect(
      statistics.acceptedPacketCount + statistics.rejectedPacketCount
        + statistics.foreignSessionPacketCount + statistics.stalePacketCount
        == UInt64(Corpus.arbitraryDatagramCount))
    #expect(acceptedFrames >= 0)
    #expect(
      statistics.frameBuffer.writtenFrameCount <= UInt64(frameBuffer.capacityFrameCount)
        + statistics.frameBuffer.readFrameCount)
  }

  private func validPacket() throws -> NetworkAudioPacket {
    try NetworkAudioPacket(
      sessionID: UUID(
        uuid: (
          0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD,
          0xEF
        )),
      sequence: 7,
      format: try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 2),
      frameCount: 4,
      payload: Data(count: 4 * 2 * MemoryLayout<Float>.stride)
    )
  }

  private func decodeIgnoringTypedErrors(_ data: Data) -> NetworkAudioPacket? {
    do {
      return try NetworkAudioPacketCodec.decode(data)
    } catch is NetworkAudioPacketError {
      return nil
    } catch is NetworkAudioSecurityError {
      // Corrupting the flags can set the encrypted bit, which a decoder without a key refuses.
      return nil
    } catch {
      Issue.record("Decoding produced an untyped error: \(error)")
      return nil
    }
  }

  private func expectSelfConsistent(_ packet: NetworkAudioPacket) {
    #expect(packet.frameCount > 0)
    #expect((1...AudioProcessingFormat.maximumChannelCount).contains(packet.format.channelCount))
    #expect(packet.format.sampleRate >= 1 && packet.format.sampleRate <= 768_000)
    #expect(
      packet.payload.count
        == packet.frameCount * packet.format.channelCount * MemoryLayout<Float>.stride
    )
  }
}

/// A fixed-seed generator so a failing corpus is reproducible without storing it.
private struct SplitMix64 {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var result = state
    result = (result ^ (result >> 30)) &* 0xBF58_476D_1CE4_E5B9
    result = (result ^ (result >> 27)) &* 0x94D0_49BB_1331_11EB
    return result ^ (result >> 31)
  }
}
