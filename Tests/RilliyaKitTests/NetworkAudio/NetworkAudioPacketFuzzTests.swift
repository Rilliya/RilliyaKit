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

  @Test("The ingestor survives hostile datagrams without writing unclaimed frames")
  func ingestorSurvivesHostileDatagrams() throws {
    let format = try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 2)
    let frameBuffer = try AudioRealtimeFrameBuffer(
      format: AudioProcessingFormat(sampleRate: 48_000, channelCount: 2)
    )
    let ingestor = NetworkAudioPacketIngestor(
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
      sessionID: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
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
