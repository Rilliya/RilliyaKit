// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import RilliyaRealtime
import Testing

@testable import RilliyaNetworkAudio

@Suite("Network audio security")
struct NetworkAudioSecurityTests {
  private enum Fixture {
    static let sessionID = UUID(
      uuid: (
        0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD,
        0xEF
      ))
    static let otherSessionID = UUID(
      uuid: (
        0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10, 0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32,
        0x10
      ))
    static let payloadByteCount = 1_024
    static let headerByteCount = 48
  }

  // MARK: - Key handling

  @Test("A generated key round-trips through the text a user copies")
  func keyTextRoundTrip() throws {
    let key = NetworkAudioSharedKey.random()
    let text = key.base64EncodedString

    #expect(try NetworkAudioSharedKey(base64Encoded: text) == key)
    #expect(Data(base64Encoded: text)?.count == NetworkAudioSharedKey.byteCount)
  }

  @Test("Surrounding whitespace in a pasted key is ignored")
  func keyTextTolerantOfWhitespace() throws {
    let key = NetworkAudioSharedKey.random()

    #expect(try NetworkAudioSharedKey(base64Encoded: "  \(key.base64EncodedString)\n") == key)
  }

  @Test("Two generated keys differ")
  func keysAreRandom() {
    #expect(NetworkAudioSharedKey.random() != NetworkAudioSharedKey.random())
  }

  @Test(
    "Text that is not a full-length key is rejected",
    arguments: ["", "not base64!!", "c2hvcnQ=", String(repeating: "A", count: 64)]
  )
  func rejectsMalformedKeyText(text: String) {
    #expect(throws: NetworkAudioSecurityError.self) {
      _ = try NetworkAudioSharedKey(base64Encoded: text)
    }
  }

  @Test("A key of the wrong length is rejected")
  func rejectsShortKey() {
    #expect(throws: NetworkAudioSecurityError.invalidKeyLength(16)) {
      _ = try NetworkAudioSharedKey(SymmetricKey(size: .bits128))
    }
  }

  // MARK: - Nonces

  /// Reusing a nonce under one key breaks AES-GCM completely, so this is the property the whole
  /// construction rests on.
  @Test("Every sequence produces a distinct nonce")
  func noncesAreDistinct() throws {
    var seen = Set<Data>()
    for sequence in [UInt64(0), 1, 2, 375, 1_000_000, .max - 1, .max] {
      let nonce = Data(try NetworkAudioSessionCipher.nonce(sequence: sequence))
      #expect(nonce.count == 12)
      #expect(seen.insert(nonce).inserted)
    }
  }

  @Test("Sequence zero is a usable nonce")
  func sequenceZeroIsUsable() throws {
    // The sender's first packet is sequence zero, so a construction that reserved it would drop
    // the first packet of every session.
    let harness = try Harness()
    let sealed = try harness.seal(sequence: 0)

    #expect(try harness.open(sealed, sequence: 0) == harness.plaintext)
  }

  // MARK: - Sealing and opening

  @Test("A sealed payload round-trips under the same key and session")
  func roundTrip() throws {
    let harness = try Harness()

    for sequence in [UInt64(0), 1, 42, 1_000_000] {
      let sealed = try harness.seal(sequence: sequence)
      #expect(sealed.count == Fixture.payloadByteCount + NetworkAudioSessionCipher.tagByteCount)
      #expect(try harness.open(sealed, sequence: sequence) == harness.plaintext)
    }
  }

  @Test("The ciphertext does not carry the plaintext")
  func ciphertextDiffersFromPlaintext() throws {
    let harness = try Harness()
    let sealed = try harness.seal(sequence: 7)

    #expect(sealed.prefix(Fixture.payloadByteCount) != harness.plaintext)
  }

  @Test("A different shared key cannot open the payload")
  func wrongKeyFails() throws {
    let harness = try Harness()
    let sealed = try harness.seal(sequence: 3)
    let other = try Harness(sharedKey: .random())

    #expect(throws: NetworkAudioSecurityError.authenticationFailed) {
      _ = try other.open(sealed, sequence: 3)
    }
  }

  /// A restart derives a new session key, so a packet from the old session must not open under
  /// the new one even though the shared key is unchanged.
  @Test("A different session cannot open the payload")
  func wrongSessionFails() throws {
    let sharedKey = NetworkAudioSharedKey.random()
    let harness = try Harness(sharedKey: sharedKey)
    let sealed = try harness.seal(sequence: 3)
    let restarted = try Harness(sharedKey: sharedKey, sessionID: Fixture.otherSessionID)

    #expect(throws: NetworkAudioSecurityError.authenticationFailed) {
      _ = try restarted.open(sealed, sequence: 3)
    }
  }

  @Test("A packet replayed under a different sequence does not open")
  func wrongSequenceFails() throws {
    let harness = try Harness()
    let sealed = try harness.seal(sequence: 10)

    #expect(throws: NetworkAudioSecurityError.authenticationFailed) {
      _ = try harness.open(sealed, sequence: 11)
    }
  }

  @Test("Altering the authenticated header rejects the payload")
  func tamperedHeaderFails() throws {
    let harness = try Harness()
    let sealed = try harness.seal(sequence: 5)
    var header = harness.header
    header[7] ^= 0x01

    #expect(throws: NetworkAudioSecurityError.authenticationFailed) {
      _ = try harness.open(sealed, sequence: 5, header: header)
    }
  }

  @Test("Altering any single byte of the ciphertext or tag rejects the payload")
  func tamperedCiphertextFails() throws {
    let harness = try Harness()
    let sealed = try harness.seal(sequence: 5)

    for offset in stride(from: 0, to: sealed.count, by: 37) {
      var corrupted = sealed
      corrupted[offset] ^= 0x80
      #expect(throws: NetworkAudioSecurityError.authenticationFailed) {
        _ = try harness.open(corrupted, sequence: 5)
      }
    }
  }

  @Test("A truncated datagram does not open")
  func truncatedFails() throws {
    let harness = try Harness()
    let sealed = try harness.seal(sequence: 5)

    #expect(throws: NetworkAudioSecurityError.authenticationFailed) {
      _ = try harness.open(sealed.dropLast(1), sequence: 5)
    }
  }

  private struct Harness {
    let cipher: NetworkAudioSessionCipher
    let plaintext: Data
    let header: Data

    init(
      sharedKey: NetworkAudioSharedKey = .random(),
      sessionID: UUID = Fixture.sessionID
    ) throws {
      cipher = NetworkAudioSessionCipher(sharedKey: sharedKey, sessionID: sessionID)
      plaintext = Data((0..<Fixture.payloadByteCount).map { UInt8($0 % 251) })
      header = Data((0..<Fixture.headerByteCount).map { UInt8($0) })
    }

    /// Returns ciphertext followed by its tag, as the wire carries them.
    func seal(sequence: UInt64) throws -> Data {
      let storage = UnsafeMutableRawBufferPointer.allocate(
        byteCount: plaintext.count + NetworkAudioSessionCipher.tagByteCount,
        alignment: 16
      )
      defer { storage.deallocate() }
      plaintext.copyBytes(to: storage.bindMemory(to: UInt8.self), count: plaintext.count)
      let payload = UnsafeMutableRawBufferPointer(rebasing: storage[..<plaintext.count])
      let written = try header.withUnsafeBytes {
        try cipher.seal(payload: payload, sequence: sequence, authenticating: $0)
      }
      return Data(storage.prefix(written))
    }

    func open(_ sealed: Data, sequence: UInt64, header: Data? = nil) throws -> Data {
      let tagByteCount = NetworkAudioSessionCipher.tagByteCount
      guard sealed.count > tagByteCount else {
        throw NetworkAudioSecurityError.authenticationFailed
      }
      let payloadByteCount = sealed.count - tagByteCount
      let storage = UnsafeMutableRawBufferPointer.allocate(
        byteCount: payloadByteCount, alignment: 16)
      defer { storage.deallocate() }
      sealed.copyBytes(to: storage.bindMemory(to: UInt8.self), count: payloadByteCount)
      let tag = Data(sealed.suffix(tagByteCount))
      try (header ?? self.header).withUnsafeBytes { headerBytes in
        try tag.withUnsafeBytes { tagBytes in
          try cipher.open(
            payload: storage,
            tag: tagBytes,
            sequence: sequence,
            authenticating: headerBytes
          )
        }
      }
      return Data(storage)
    }
  }
}

@Suite("Network audio encrypted wire format")
struct NetworkAudioEncryptedWireTests {
  private enum Fixture {
    static let sessionID = UUID(
      uuid: (
        0x0F, 0x0E, 0x0D, 0x0C, 0x0B, 0x0A, 0x49, 0x08, 0x87, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
        0x00
      ))
    static let frameCount = 128
    static let channelCount = 2

    static func format() throws -> NetworkAudioStreamFormat {
      try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: channelCount)
    }
  }

  @Test("An encrypted datagram round-trips and carries a tag")
  func encryptedRoundTrip() throws {
    let key = NetworkAudioSharedKey.random()
    let cipher = NetworkAudioSessionCipher(sharedKey: key, sessionID: Fixture.sessionID)
    let harness = try WireHarness()

    let sealed = try harness.encode(sequence: 9, cipher: cipher)
    let plain = try harness.encode(sequence: 9, cipher: nil)
    #expect(sealed.count == plain.count + NetworkAudioSessionCipher.tagByteCount)
    #expect(
      sealed.dropFirst(NetworkAudioPacketCodec.headerByteCount)
        != plain.dropFirst(NetworkAudioPacketCodec.headerByteCount))

    let decoded = try NetworkAudioPacketCodec.decode(sealed, cipher: cipher)
    #expect(decoded.frameCount == Fixture.frameCount)
    #expect(decoded.payload == plain.dropFirst(NetworkAudioPacketCodec.headerByteCount))
  }

  /// A receiver holding a key must not accept unencrypted audio, or anyone able to reach the port
  /// could bypass the key by simply not using it.
  @Test("A receiver with a key rejects plaintext")
  func rejectsDowngrade() throws {
    let cipher = NetworkAudioSessionCipher(
      sharedKey: .random(), sessionID: Fixture.sessionID)
    let harness = try WireHarness()
    let plain = try harness.encode(sequence: 1, cipher: nil)

    #expect(throws: NetworkAudioSecurityError.unexpectedPlaintext) {
      _ = try NetworkAudioPacketCodec.decode(plain, cipher: cipher)
    }
  }

  @Test("A receiver without a key rejects encrypted audio")
  func rejectsUnreadableCiphertext() throws {
    let cipher = NetworkAudioSessionCipher(
      sharedKey: .random(), sessionID: Fixture.sessionID)
    let harness = try WireHarness()
    let sealed = try harness.encode(sequence: 1, cipher: cipher)

    #expect(throws: NetworkAudioSecurityError.encryptionRequired) {
      _ = try NetworkAudioPacketCodec.decode(sealed)
    }
  }

  @Test("A peer with a different key cannot read the audio")
  func rejectsWrongKey() throws {
    let harness = try WireHarness()
    let sealed = try harness.encode(
      sequence: 1,
      cipher: NetworkAudioSessionCipher(sharedKey: .random(), sessionID: Fixture.sessionID)
    )
    let eavesdropper = NetworkAudioSessionCipher(
      sharedKey: .random(), sessionID: Fixture.sessionID)

    #expect(throws: NetworkAudioSecurityError.authenticationFailed) {
      _ = try NetworkAudioPacketCodec.decode(sealed, cipher: eavesdropper)
    }
  }

  @Test("Corrupting an encrypted datagram anywhere rejects it")
  func rejectsCorruption() throws {
    let key = NetworkAudioSharedKey.random()
    let cipher = NetworkAudioSessionCipher(sharedKey: key, sessionID: Fixture.sessionID)
    let harness = try WireHarness()
    let sealed = try harness.encode(sequence: 3, cipher: cipher)

    for offset in stride(from: 0, to: sealed.count, by: 53) {
      var corrupted = sealed
      corrupted[offset] ^= 0x40
      #expect(throws: (any Error).self) {
        _ = try NetworkAudioPacketCodec.decode(corrupted, cipher: cipher)
      }
    }
  }

  @Test("An unknown flag is still refused")
  func rejectsUnknownFlags() throws {
    let harness = try WireHarness()
    var plain = try harness.encode(sequence: 1, cipher: nil)
    plain[7] = 0x80

    #expect(throws: NetworkAudioPacketError.self) {
      _ = try NetworkAudioPacketCodec.decode(plain)
    }
  }

  private struct WireHarness {
    private let storage: UnsafeMutableRawBufferPointer
    private let channels: [UnsafeMutablePointer<Float>]

    init() throws {
      storage = UnsafeMutableRawBufferPointer.allocate(
        byteCount: NetworkAudioPacketCodec.maximumDatagramByteCount,
        alignment: 16
      )
      channels = (0..<Fixture.channelCount).map { channel in
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: Fixture.frameCount)
        for frame in 0..<Fixture.frameCount {
          buffer[frame] = Float(channel) + Float(frame) * 0.01
        }
        return buffer
      }
    }

    func encode(sequence: UInt64, cipher: NetworkAudioSessionCipher?) throws -> Data {
      let readOnly = channels.map { UnsafePointer($0) }
      let written = try readOnly.withUnsafeBufferPointer {
        try NetworkAudioPacketCodec.encode(
          sessionID: Fixture.sessionID,
          sequence: sequence,
          format: try Fixture.format(),
          frameCount: Fixture.frameCount,
          planarChannels: $0,
          into: storage,
          cipher: cipher
        )
      }
      return Data(storage.prefix(written))
    }
  }
}

@Suite("Network audio encrypted ingest")
struct NetworkAudioEncryptedIngestTests {
  private enum Fixture {
    static let sessionID = UUID(
      uuid: (
        0x11, 0x11, 0x22, 0x22, 0x33, 0x33, 0x44, 0x44, 0x85, 0x55, 0x66, 0x66, 0x77, 0x77, 0x88,
        0x88
      ))
    static let frameCount = 128
    static let channelCount = 2
    static let port: UInt16 = 48_620
  }

  @Test("A receiver holding the key accepts the sender's audio")
  func acceptsMatchingKey() throws {
    let key = NetworkAudioSharedKey.random()
    let harness = try IngestHarness(receiverKey: key, senderKey: key)

    #expect(harness.ingest(sequence: 0) == .accepted(frameCount: Fixture.frameCount))
    #expect(harness.ingest(sequence: 1) == .accepted(frameCount: Fixture.frameCount))
    #expect(harness.statistics().acceptedPacketCount == 2)
  }

  @Test("A receiver holding a different key rejects everything")
  func rejectsWrongKey() throws {
    let harness = try IngestHarness(receiverKey: .random(), senderKey: .random())

    #expect(harness.ingest(sequence: 0) == .rejected)
    #expect(harness.statistics().acceptedPacketCount == 0)
    #expect(harness.statistics().rejectedPacketCount == 1)
  }

  /// Reaching the port must not be enough to be heard.
  @Test("A receiver holding a key rejects unencrypted audio")
  func rejectsPlaintextWhenKeyed() throws {
    let harness = try IngestHarness(receiverKey: .random(), senderKey: nil)

    #expect(harness.ingest(sequence: 0) == .rejected)
    #expect(harness.statistics().acceptedPacketCount == 0)
  }

  @Test("A receiver without a key rejects encrypted audio")
  func rejectsCiphertextWhenUnkeyed() throws {
    let harness = try IngestHarness(receiverKey: nil, senderKey: .random())

    #expect(harness.ingest(sequence: 0) == .rejected)
  }

  @Test("An unkeyed pair still works")
  func plaintextStillWorks() throws {
    let harness = try IngestHarness(receiverKey: nil, senderKey: nil)

    #expect(harness.ingest(sequence: 0) == .accepted(frameCount: Fixture.frameCount))
  }

  private struct IngestHarness {
    private let ingestor: NetworkAudioPacketIngestor
    private let cipher: NetworkAudioSessionCipher?
    private let storage: UnsafeMutableRawBufferPointer
    private let channels: [UnsafeMutablePointer<Float>]
    private let format: NetworkAudioStreamFormat

    init(receiverKey: NetworkAudioSharedKey?, senderKey: NetworkAudioSharedKey?) throws {
      format = try NetworkAudioStreamFormat(
        sampleRate: 48_000, channelCount: Fixture.channelCount)
      let frameBuffer = try AudioRealtimeFrameBuffer(
        format: AudioProcessingFormat(sampleRate: 48_000, channelCount: Fixture.channelCount),
        capacityFrameCount: 32_768
      )
      ingestor = NetworkAudioPacketIngestor(
        configuration: try NetworkAudioReceiverConfiguration(
          port: Fixture.port,
          format: format,
          sharedKey: receiverKey
        ),
        frameBuffer: frameBuffer
      )
      cipher = senderKey.map {
        NetworkAudioSessionCipher(sharedKey: $0, sessionID: Fixture.sessionID)
      }
      storage = UnsafeMutableRawBufferPointer.allocate(
        byteCount: NetworkAudioPacketCodec.maximumDatagramByteCount, alignment: 16)
      channels = (0..<Fixture.channelCount).map { _ in
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: Fixture.frameCount)
        buffer.initialize(repeating: 0.25, count: Fixture.frameCount)
        return buffer
      }
    }

    func ingest(sequence: UInt64) -> NetworkAudioPacketIngestResult {
      let readOnly = channels.map { UnsafePointer($0) }
      guard
        let written = try? readOnly.withUnsafeBufferPointer({
          try NetworkAudioPacketCodec.encode(
            sessionID: Fixture.sessionID,
            sequence: sequence,
            format: format,
            frameCount: Fixture.frameCount,
            planarChannels: $0,
            into: storage,
            cipher: cipher
          )
        })
      else { return .rejected }
      return ingestor.ingest(Data(storage.prefix(written)), now: sequence &+ 1)
    }

    func statistics() -> NetworkAudioReceiverStatistics { ingestor.statistics() }
  }
}
