// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaRealtime
import Testing

@testable import RilliyaNetworkAudio

/// The sender's own lifecycle, which decides what identity its packets are sealed under.
@Suite("Network audio sender")
struct NetworkAudioSenderTests {
  private enum Fixture {
    static let host = "127.0.0.1"
    static let port: UInt16 = 48_991
    static let sampleRate = 48_000.0
    static let channelCount = 2

    static func format() throws -> NetworkAudioStreamFormat {
      try NetworkAudioStreamFormat(sampleRate: sampleRate, channelCount: channelCount)
    }

    static func configuration(
      sharedKey: NetworkAudioSharedKey? = nil,
      encoding: NetworkAudioWireEncoding = .interleavedFloat32
    ) throws -> NetworkAudioSenderConfiguration {
      try NetworkAudioSenderConfiguration(
        host: host,
        port: port,
        format: try format(),
        encoding: encoding,
        sharedKey: sharedKey
      )
    }
  }

  /// The nonce a packet is sealed under is built from a sequence that restarts at zero every run,
  /// so two runs sharing an identity would derive one key and spend the same nonce twice — the one
  /// failure AES-GCM does not survive.
  ///
  /// The identity used to live in the configuration, where one value handed to two senders pinned
  /// the same key for both. It is minted per run now, so this is what stops that.
  @Test("Two senders from one configuration do not share an identity")
  func sendersFromOneConfigurationDiffer() async throws {
    let configuration = try Fixture.configuration(sharedKey: .random())
    let first = try NetworkAudioSender(configuration: configuration)
    let second = try NetworkAudioSender(configuration: configuration)

    #expect(first.activeSessionID == nil)

    try first.start()
    try second.start()
    let left = first.activeSessionID
    let right = second.activeSessionID
    await first.stop()
    await second.stop()

    #expect(left != nil)
    #expect(right != nil)
    #expect(left != right)
  }

  /// A sender runs once.
  ///
  /// Starting a stopped one has to be refused rather than quietly reusing the identity the
  /// stopped run sealed under.
  @Test("A stopped sender is not started again")
  func stoppedSenderIsNotRestarted() async throws {
    let sender = try NetworkAudioSender(configuration: try Fixture.configuration())
    try sender.start()
    let ran = sender.activeSessionID
    await sender.stop()

    #expect(ran != nil)
    #expect(throws: NetworkAudioSenderError.alreadyStopped) {
      try sender.start()
    }
  }

  /// Starting a running sender does nothing, so a caller that cannot tell whether it already
  /// started does not open a second connection by asking again.
  @Test("Starting a running sender changes nothing")
  func doubleStartIsANoOp() async throws {
    let sender = try NetworkAudioSender(configuration: try Fixture.configuration())
    try sender.start()
    let first = sender.activeSessionID
    try sender.start()
    let second = sender.activeSessionID
    await sender.stop()

    #expect(first != nil)
    #expect(first == second)
  }

  @Test("A depth beyond the bound is refused rather than allocated")
  func invalidRetransmissionDepthIsRefused() throws {
    #expect(throws: NetworkAudioSenderError.invalidRetransmissionDepth) {
      _ = try NetworkAudioSenderConfiguration(
        host: Fixture.host,
        port: Fixture.port,
        format: try Fixture.format(),
        retransmissionDepth: NetworkAudioSenderConfiguration.maximumRetransmissionDepth + 1
      )
    }
  }

  /// Keeping no history is what a sender on a link that loses nothing wants, and it has to be
  /// reachable rather than clamped up to the default.
  @Test("Keeping no history is allowed")
  func zeroRetransmissionDepthIsAllowed() throws {
    let configuration = try NetworkAudioSenderConfiguration(
      host: Fixture.host,
      port: Fixture.port,
      format: try Fixture.format(),
      retransmissionDepth: 0
    )

    #expect(configuration.retransmissionDepth == 0)
  }

  /// A codec decides the block length, so asking for one it does not define has to fail at
  /// configuration rather than at the first packet.
  @Test("A block length the codec does not define is refused")
  func unsupportedBlockLengthIsRefused() throws {
    #expect(throws: (any Error).self) {
      _ = try NetworkAudioSenderConfiguration(
        host: Fixture.host,
        port: Fixture.port,
        format: try Fixture.format(),
        framesPerPacket: 333,
        encoding: .opus
      )
    }
  }

  /// A sample rate Opus does not carry has to be refused at configuration too: the wire format is
  /// chosen in one place and the audio arrives in another.
  @Test("A sample rate the codec does not carry is refused")
  func unsupportedSampleRateIsRefused() throws {
    #expect(throws: (any Error).self) {
      _ = try NetworkAudioSenderConfiguration(
        host: Fixture.host,
        port: Fixture.port,
        format: try NetworkAudioStreamFormat(sampleRate: 44_100, channelCount: 2),
        encoding: .opus
      )
    }
  }

  /// A lossless block is wider than a datagram, so the sender has to accept the format and split
  /// it rather than refusing the configuration.
  @Test("A lossless configuration is accepted even though its blocks exceed a datagram")
  func losslessConfigurationIsAccepted() throws {
    let configuration = try Fixture.configuration(encoding: .appleLossless)

    #expect(configuration.framesPerPacket > 0)
    #expect(
      configuration.framesPerPacket * Fixture.channelCount * MemoryLayout<Float>.stride
        > configuration.maximumDatagramByteCount
    )
  }
}
