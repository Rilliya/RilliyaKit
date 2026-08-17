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

    // The sequences asked for must not be readable without the key: compare what is on the wire
    // against the same request written in the clear.
    let clear = try request.encoded()
    let headerByteCount = NetworkAudioRetransmissionRequest.headerByteCount
    #expect(datagram.dropFirst(headerByteCount) != clear.dropFirst(headerByteCount))
    #expect(datagram.count == clear.count + NetworkAudioSessionCipher.tagByteCount)
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

/// What a sender keeps, and how much it is willing to resend.
@Suite("Network audio sender history")
struct NetworkAudioSenderHistoryTests {
  @Test("A recorded datagram is found again")
  func recordedDatagramIsFound() {
    let history = NetworkAudioSenderHistory(depth: 8, maximumDatagramByteCount: 64)
    let bytes: [UInt8] = Array(0..<32)
    bytes.withUnsafeBytes { history.record(sequence: 5, datagram: $0) }

    var destination = [UInt8](repeating: 0, count: 64)
    let length = destination.withUnsafeMutableBytes {
      history.takeDatagram(for: 5, into: $0)
    }

    #expect(length == 32)
    #expect(Array(destination.prefix(32)) == bytes)
  }

  /// A packet older than the window is past any receiver's reach, so keeping it would be storage
  /// spent on audio nobody can still place.
  @Test("A datagram older than the window is gone")
  func oldDatagramIsForgotten() {
    let history = NetworkAudioSenderHistory(depth: 4, maximumDatagramByteCount: 64)
    for sequence in UInt64(0)..<8 {
      let bytes = [UInt8(sequence)]
      bytes.withUnsafeBytes { history.record(sequence: sequence, datagram: $0) }
    }

    var destination = [UInt8](repeating: 0, count: 64)
    let lengths = destination.withUnsafeMutableBytes { bytes in
      [
        history.takeDatagram(for: 0, into: bytes),
        history.takeDatagram(for: 3, into: bytes),
        history.takeDatagram(for: 7, into: bytes),
      ]
    }

    #expect(lengths[0] == nil)
    #expect(lengths[1] == nil)
    #expect(lengths[2] == 1)
  }

  @Test("A sequence never sent is not invented")
  func unknownSequenceIsAbsent() {
    let history = NetworkAudioSenderHistory(depth: 4, maximumDatagramByteCount: 64)
    var destination = [UInt8](repeating: 0, count: 64)

    let found = destination.withUnsafeMutableBytes { history.takeDatagram(for: 99, into: $0) }
    #expect(found == nil)
  }

  @Test("A new session keeps nothing from the last")
  func resetForgetsEverything() {
    let history = NetworkAudioSenderHistory(depth: 4, maximumDatagramByteCount: 64)
    let bytes: [UInt8] = [1, 2, 3]
    bytes.withUnsafeBytes { history.record(sequence: 1, datagram: $0) }
    history.reset()

    var destination = [UInt8](repeating: 0, count: 64)
    let found = destination.withUnsafeMutableBytes { history.takeDatagram(for: 1, into: $0) }
    #expect(found == nil)
  }

  /// The ceiling is what keeps a stream of requests from turning retransmission into the larger
  /// half of the flow.
  @Test("Resending is capped at a share of what the sender already sends")
  func budgetCapsTheRate() {
    // A hundred packets a second, a quarter of which may be resent: twenty-five per second.
    var budget = NetworkAudioRetransmissionBudget(packetsPerSecond: 100, fraction: 0.25)
    let second: UInt64 = 1_000_000_000

    // The burst is allowed at once, and then nothing until the bucket refills.
    var allowed = 0
    for _ in 0..<100 where budget.allows(now: 0) { allowed += 1 }
    #expect(allowed == Int(NetworkAudioRetransmissionBudget.burst))

    let exhausted = budget.allows(now: 0)
    #expect(!exhausted)

    // One second later the bucket has refilled to its burst, not to twenty-five.
    var afterASecond = 0
    for _ in 0..<100 where budget.allows(now: second) { afterASecond += 1 }
    #expect(afterASecond == Int(NetworkAudioRetransmissionBudget.burst))
  }

  @Test("A sender sending nothing resends nothing")
  func silentSenderSpendsNothing() {
    var budget = NetworkAudioRetransmissionBudget(packetsPerSecond: 0)
    for _ in 0..<Int(NetworkAudioRetransmissionBudget.burst) { _ = budget.allows(now: 0) }

    let refilled = budget.allows(now: 10_000_000_000)
    #expect(!refilled)
  }
}

/// When asking is worth a datagram, and when it is not.
@Suite("Network audio retransmission asking")
struct NetworkAudioRetransmissionAskerTests {
  private let second: UInt64 = 1_000_000_000

  /// A queue deeper than the round trip has time to place an answer, so the gap is worth asking
  /// about.
  @Test("A gap is asked for when the queue has time for the answer")
  func gapIsAskedForWhenThereIsTime() {
    var asker = NetworkAudioRetransmissionAsker()

    let wanted = asker.sequencesToAsk(
      missing: [4, 5],
      queued: .milliseconds(60),
      now: 0
    )

    #expect(wanted == [4, 5])
    #expect(asker.outstandingCount == 2)
  }

  /// A queue shallower than the round trip would receive the answer after the audio was due, so
  /// the datagram would buy nothing.
  @Test("A gap is not asked for when the answer would arrive too late")
  func gapIsNotAskedForWithoutTime() {
    var asker = NetworkAudioRetransmissionAsker()

    let wanted = asker.sequencesToAsk(
      missing: [4],
      queued: .milliseconds(5),
      now: 0
    )

    #expect(wanted.isEmpty)
  }

  /// A request lost on a link that lost the audio is likely lost for the same reason, so asking
  /// again doubles the cost of one loss without improving the odds.
  @Test("A sequence is asked for only once")
  func sequenceIsAskedOnce() {
    var asker = NetworkAudioRetransmissionAsker()

    let first = asker.sequencesToAsk(missing: [7], queued: .milliseconds(60), now: 0)
    let second = asker.sequencesToAsk(missing: [7], queued: .milliseconds(60), now: 1_000_000)

    #expect(first == [7])
    #expect(second.isEmpty)
  }

  @Test("No more are asked for than one request may name")
  func requestCapIsHonoured() {
    var asker = NetworkAudioRetransmissionAsker()
    let missing = (0..<32).map(UInt64.init)

    let wanted = asker.sequencesToAsk(missing: missing, queued: .milliseconds(200), now: 0)

    #expect(wanted.count == NetworkAudioRetransmissionRequest.maximumSequenceCount)
  }

  /// Measuring rather than assuming is what lets a receiver on a slow link stop asking.
  @Test("The round trip is measured from the answer")
  func roundTripIsMeasured() {
    var asker = NetworkAudioRetransmissionAsker()
    _ = asker.sequencesToAsk(missing: [1], queued: .milliseconds(200), now: 0)

    #expect(asker.roundTrip == nil)
    let answered = asker.noteArrival(sequence: 1, now: 20_000_000)

    #expect(answered)
    #expect(asker.roundTrip == .milliseconds(20))
    #expect(asker.outstandingCount == 0)
  }

  @Test("A packet nobody asked for does not count as an answer")
  func unaskedArrivalIsNotAnAnswer() {
    var asker = NetworkAudioRetransmissionAsker()

    let answered = asker.noteArrival(sequence: 99, now: 1_000)

    #expect(!answered)
    #expect(asker.roundTrip == nil)
  }

  /// This is the property that matters on a tunnel: once the answer cannot arrive in time, the
  /// receiver stops spending datagrams on it.
  @Test("A measured round trip longer than the queue stops the asking")
  func slowLinkStopsAsking() {
    var asker = NetworkAudioRetransmissionAsker()
    _ = asker.sequencesToAsk(missing: [1], queued: .milliseconds(200), now: 0)
    asker.noteArrival(sequence: 1, now: 80_000_000)

    // Eighty milliseconds there and back against a queue holding sixty.
    let wanted = asker.sequencesToAsk(missing: [2], queued: .milliseconds(60), now: second)

    #expect(wanted.isEmpty)
  }

  @Test("A new session asks afresh")
  func resetForgetsTheSession() {
    var asker = NetworkAudioRetransmissionAsker()
    _ = asker.sequencesToAsk(missing: [3], queued: .milliseconds(60), now: 0)

    asker.reset()

    #expect(asker.roundTrip == nil)
    #expect(asker.outstandingCount == 0)
    let afresh = asker.sequencesToAsk(missing: [3], queued: .milliseconds(60), now: 0)
    #expect(afresh == [3])
  }

  /// A stream running for hours must not accumulate one entry per packet ever sent.
  @Test("What has been asked for is forgotten as the stream moves on")
  func memoryIsBounded() {
    var asker = NetworkAudioRetransmissionAsker(memory: 64)

    for sequence in stride(from: UInt64(0), to: 2_000, by: 1) {
      _ = asker.sequencesToAsk(missing: [sequence], queued: .milliseconds(200), now: 0)
    }

    // Long-passed sequences are forgotten, so an old one would be asked for again rather than
    // being remembered forever.
    let forgotten = asker.sequencesToAsk(missing: [1], queued: .milliseconds(200), now: 0)
    #expect(forgotten == [1])
  }

  /// A request carries nothing that stops it being replayed.
  ///
  /// One captured off the network would otherwise make a sender resend the same audio for as long
  /// as an attacker repeated it. A receiver asks once per gap by design, so answering once is what
  /// it expects anyway.
  @Test("A sequence already resent is not resent again")
  func aSequenceIsAnsweredOnce() {
    let history = NetworkAudioSenderHistory(depth: 8, maximumDatagramByteCount: 64)
    let bytes: [UInt8] = Array(0..<16)
    bytes.withUnsafeBytes { history.record(sequence: 3, datagram: $0) }

    var destination = [UInt8](repeating: 0, count: 64)
    let lengths = destination.withUnsafeMutableBytes { buffer in
      [
        history.takeDatagram(for: 3, into: buffer),
        history.takeDatagram(for: 3, into: buffer),
        history.takeDatagram(for: 3, into: buffer),
      ]
    }

    #expect(lengths[0] == 16)
    #expect(lengths[1] == nil)
    #expect(lengths[2] == nil)
  }

  /// The slot is reused by a later packet, and that packet has not been answered.
  @Test("A packet occupying a used slot may still be resent")
  func aFreshPacketInAUsedSlotIsAnswerable() {
    let history = NetworkAudioSenderHistory(depth: 4, maximumDatagramByteCount: 64)
    let bytes: [UInt8] = [7]
    bytes.withUnsafeBytes { history.record(sequence: 1, datagram: $0) }

    var destination = [UInt8](repeating: 0, count: 64)
    let first = destination.withUnsafeMutableBytes { history.takeDatagram(for: 1, into: $0) }
    bytes.withUnsafeBytes { history.record(sequence: 5, datagram: $0) }
    let second = destination.withUnsafeMutableBytes { history.takeDatagram(for: 5, into: $0) }

    #expect(first == 1)
    #expect(second == 1)
  }
}

/// A request arrives on the network queue and is answered on the realtime thread, so it has to
/// cross as data: two threads writing one packet buffer put one packet's bytes on the wire under
/// another's sequence, and the realtime body runs where a lock is unsafe.
@Suite("Network audio retransmission mailbox")
struct NetworkAudioRetransmissionMailboxTests {
  @Test("What was deposited is what comes back")
  func depositIsTakenBack() {
    let mailbox = NetworkAudioRetransmissionMailbox(capacity: 2)
    let wanted: [UInt64] = [4, 9, 11]
    let destination = UnsafeMutablePointer<UInt64>.allocate(
      capacity: NetworkAudioRetransmissionMailbox.strideCount)
    defer { destination.deallocate() }

    #expect(mailbox.deposit(wanted))
    let count = mailbox.take(into: destination)

    #expect(count == 3)
    #expect(Array(UnsafeBufferPointer(start: destination, count: 3)) == wanted)
  }

  @Test("Nothing waiting reads as nothing")
  func emptyMailboxTakesNothing() {
    let mailbox = NetworkAudioRetransmissionMailbox(capacity: 2)
    let destination = UnsafeMutablePointer<UInt64>.allocate(
      capacity: NetworkAudioRetransmissionMailbox.strideCount)
    defer { destination.deallocate() }

    #expect(mailbox.take(into: destination) == nil)
  }

  @Test("Requests come back in the order they arrived")
  func orderIsKept() {
    let mailbox = NetworkAudioRetransmissionMailbox(capacity: 4)
    let destination = UnsafeMutablePointer<UInt64>.allocate(
      capacity: NetworkAudioRetransmissionMailbox.strideCount)
    defer { destination.deallocate() }

    #expect(mailbox.deposit([1]))
    #expect(mailbox.deposit([2]))

    #expect(mailbox.take(into: destination) == 1)
    #expect(destination[0] == 1)
    #expect(mailbox.take(into: destination) == 1)
    #expect(destination[0] == 2)
    #expect(mailbox.take(into: destination) == nil)
  }

  /// A queue serving a realtime thread cannot wait for it, so a mailbox that has filled drops what
  /// it cannot hold rather than blocking the network.
  @Test("A full mailbox refuses rather than waiting")
  func fullMailboxRefuses() {
    let mailbox = NetworkAudioRetransmissionMailbox(capacity: 2)

    #expect(mailbox.deposit([1]))
    #expect(mailbox.deposit([2]))
    #expect(!mailbox.deposit([3]))
  }

  @Test("Taking one makes room for another")
  func takingMakesRoom() {
    let mailbox = NetworkAudioRetransmissionMailbox(capacity: 1)
    let destination = UnsafeMutablePointer<UInt64>.allocate(
      capacity: NetworkAudioRetransmissionMailbox.strideCount)
    defer { destination.deallocate() }

    #expect(mailbox.deposit([1]))
    #expect(!mailbox.deposit([2]))
    _ = mailbox.take(into: destination)
    #expect(mailbox.deposit([2]))
  }

  @Test("A request naming more than a request may name is refused")
  func oversizedDepositIsRefused() {
    let mailbox = NetworkAudioRetransmissionMailbox(capacity: 2)
    let tooMany = (0..<UInt64(NetworkAudioRetransmissionMailbox.strideCount + 1)).map { $0 }

    #expect(!mailbox.deposit(tooMany))
    #expect(!mailbox.deposit([]))
  }

  /// The indices are the only synchronisation between the two threads, so they have to survive
  /// being driven hard from both at once.
  @Test("A producer and a consumer running together lose and invent nothing")
  func producerAndConsumerAgree() async {
    let mailbox = NetworkAudioRetransmissionMailbox(capacity: 4)
    let total = 20_000

    let consumer = Task.detached {
      let destination = UnsafeMutablePointer<UInt64>.allocate(
        capacity: NetworkAudioRetransmissionMailbox.strideCount)
      defer { destination.deallocate() }
      var seen: [UInt64] = []
      while seen.count < total {
        if let count = mailbox.take(into: destination), count > 0 {
          seen.append(destination[0])
        }
      }
      return seen
    }

    let producer = Task.detached {
      var sent: UInt64 = 0
      while sent < UInt64(total) {
        if mailbox.deposit([sent]) { sent &+= 1 }
      }
    }

    await producer.value
    let seen = await consumer.value

    #expect(seen.count == total)
    // Order preserved and nothing duplicated or dropped.
    #expect(seen == (0..<UInt64(total)).map { $0 })
  }
}
