// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RilliyaNetworkAudio

@Suite("Network audio retransmission requests")
struct NetworkAudioRetransmissionRequestTests {
  private enum Fixture {
    static let sessionID = UUID(
      uuid: (
        0x3C, 0x2D, 0x1E, 0x0F, 0xA9, 0xB8, 0x4C, 0x7D,
        0x86, 0x95, 0xA4, 0xB3, 0xC2, 0xD1, 0xE0, 0xFF
      )
    )
    static let otherSessionID = UUID(
      uuid: (
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x47, 0x88,
        0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00
      )
    )
  }

  @Test("A request round-trips in the clear")
  func requestRoundTrips() throws {
    let request = try NetworkAudioRetransmissionRequest(
      sessionID: Fixture.sessionID,
      sequence: 7,
      sequences: [104, 101, 99]
    )

    let decoded = try NetworkAudioRetransmissionRequest.decode(try request.encoded())

    #expect(decoded == request)
    // Sorted, so a sender answers in the order the stream needs.
    #expect(decoded.sequences == [99, 101, 104])
  }

  @Test("A request round-trips under a key")
  func requestRoundTripsEncrypted() throws {
    let key = NetworkAudioSharedKey.random()
    let cipher = NetworkAudioSessionCipher(sharedKey: key, sessionID: Fixture.sessionID)
    let request = try NetworkAudioRetransmissionRequest(
      sessionID: Fixture.sessionID,
      sequence: 3,
      sequences: [50, 51]
    )

    let datagram = try request.encoded(cipher: cipher)
    let decoded = try NetworkAudioRetransmissionRequest.decode(datagram, cipher: cipher)

    #expect(decoded == request)
    // The sequences asked for must not be readable without the key.
    #expect(!datagram.dropFirst(NetworkAudioRetransmissionRequest.headerByteCount).contains(50))
  }

  /// Acting on a request in the clear while a key is configured would let anyone who can reach
  /// the flow make the sender send.
  @Test("A request in the clear is refused by a keyed sender")
  func plaintextIsRefusedWhenKeyed() throws {
    let request = try NetworkAudioRetransmissionRequest(
      sessionID: Fixture.sessionID,
      sequence: 1,
      sequences: [10]
    )
    let cipher = NetworkAudioSessionCipher(
      sharedKey: .random(), sessionID: Fixture.sessionID)

    #expect(throws: (any Error).self) {
      _ = try NetworkAudioRetransmissionRequest.decode(try request.encoded(), cipher: cipher)
    }
  }

  @Test("A request under another key is refused")
  func wrongKeyIsRefused() throws {
    let request = try NetworkAudioRetransmissionRequest(
      sessionID: Fixture.sessionID,
      sequence: 1,
      sequences: [10]
    )
    let sealed = try request.encoded(
      cipher: NetworkAudioSessionCipher(sharedKey: .random(), sessionID: Fixture.sessionID))
    let other = NetworkAudioSessionCipher(sharedKey: .random(), sessionID: Fixture.sessionID)

    #expect(throws: (any Error).self) {
      _ = try NetworkAudioRetransmissionRequest.decode(sealed, cipher: other)
    }
  }

  @Test("An encrypted request is refused by a sender with no key")
  func encryptedIsRefusedWhenUnkeyed() throws {
    let sealed = try NetworkAudioRetransmissionRequest(
      sessionID: Fixture.sessionID,
      sequence: 1,
      sequences: [10]
    ).encoded(cipher: NetworkAudioSessionCipher(sharedKey: .random(), sessionID: Fixture.sessionID))

    #expect(throws: (any Error).self) {
      _ = try NetworkAudioRetransmissionRequest.decode(sealed)
    }
  }

  /// The sequences are what the sender acts on, so they sit inside what the tag covers.
  @Test("Changing what a sealed request asks for is refused")
  func sequencesAreAuthenticated() throws {
    let key = NetworkAudioSharedKey.random()
    let cipher = NetworkAudioSessionCipher(sharedKey: key, sessionID: Fixture.sessionID)
    var datagram = try NetworkAudioRetransmissionRequest(
      sessionID: Fixture.sessionID,
      sequence: 4,
      sequences: [20, 21]
    ).encoded(cipher: cipher)

    datagram[NetworkAudioRetransmissionRequest.headerByteCount] ^= 0xFF

    #expect(throws: (any Error).self) {
      _ = try NetworkAudioRetransmissionRequest.decode(datagram, cipher: cipher)
    }
  }

  /// A small request must not be able to make a sender send an unbounded amount.
  @Test("A request naming more sequences than the cap is refused")
  func oversizedRequestIsRefused() throws {
    let tooMany = (0..<(NetworkAudioRetransmissionRequest.maximumSequenceCount + 1))
      .map(UInt64.init)

    #expect(throws: NetworkAudioRetransmissionError.self) {
      _ = try NetworkAudioRetransmissionRequest(
        sessionID: Fixture.sessionID,
        sequence: 0,
        sequences: tooMany
      )
    }
  }

  @Test("A request naming nothing is refused")
  func emptyRequestIsRefused() {
    #expect(throws: NetworkAudioRetransmissionError.empty) {
      _ = try NetworkAudioRetransmissionRequest(
        sessionID: Fixture.sessionID,
        sequence: 0,
        sequences: []
      )
    }
  }

  /// A sender must never mistake audio for a request or the reverse.
  @Test("An audio datagram is not read as a request")
  func audioIsNotARequest() throws {
    let format = try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 2)
    var datagram = Data(count: NetworkAudioPacketCodec.maximumDatagramByteCount)
    let samples = [Float](repeating: 0.1, count: 4)
    let written = try samples.withUnsafeBufferPointer { channel -> Int in
      let pointers = [channel.baseAddress!, channel.baseAddress!]
      return try pointers.withUnsafeBufferPointer { channels in
        try datagram.withUnsafeMutableBytes { destination in
          try NetworkAudioPacketCodec.encode(
            sessionID: Fixture.sessionID,
            sequence: 0,
            format: format,
            frameCount: 4,
            planarChannels: channels,
            into: destination
          )
        }
      }
    }

    #expect(throws: (any Error).self) {
      _ = try NetworkAudioRetransmissionRequest.decode(datagram.prefix(written))
    }
  }

  @Test("A request is not read as audio")
  func requestIsNotAudio() throws {
    let datagram = try NetworkAudioRetransmissionRequest(
      sessionID: Fixture.sessionID,
      sequence: 0,
      sequences: [1]
    ).encoded()

    #expect(throws: (any Error).self) {
      _ = try NetworkAudioPacketCodec.decode(datagram)
    }
  }

  /// The two nonce spaces must not meet.
  ///
  /// A session's key seals both audio and requests, and two messages picking one nonce under one
  /// key is the failure AES-GCM does not survive.
  @Test("Audio and requests never share a nonce")
  func nonceSpacesAreDisjoint() throws {
    var seen = Set<Data>()
    for sequence in [UInt64(0), 1, 2, 1_000, .max] {
      for domain in [
        NetworkAudioSessionCipher.NonceDomain.audio, .control,
      ] {
        let nonce = Data(try NetworkAudioSessionCipher.nonce(sequence: sequence, domain: domain))
        #expect(nonce.count == 12)
        #expect(seen.insert(nonce).inserted, "sequence \(sequence) repeated a nonce")
      }
    }
  }

  @Test(
    "Arbitrary bytes decode to a request or a typed error, never a trap",
    arguments: [UInt64(1), 2, 3, 4, 5]
  )
  func arbitraryBytesNeverTrap(seedValue: UInt64) throws {
    var seed = seedValue &* 0x9E37_79B9_7F4A_7C15
    for _ in 0..<400 {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      let byteCount = Int(seed % UInt64(NetworkAudioRetransmissionRequest.maximumByteCount + 8))
      var bytes = Data(count: byteCount)
      for index in 0..<byteCount {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        bytes[index] = UInt8(truncatingIfNeeded: seed >> 33)
      }
      _ = try? NetworkAudioRetransmissionRequest.decode(bytes)
      _ = try? NetworkAudioRetransmissionRequest.decode(
        bytes,
        cipher: NetworkAudioSessionCipher(sharedKey: .random(), sessionID: Fixture.otherSessionID)
      )
    }
  }
}
