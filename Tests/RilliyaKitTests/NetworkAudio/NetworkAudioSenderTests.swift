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
        keyProvider: sharedKey.map(NetworkAudioStaticKeyProvider.init)
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

    try await first.start()
    try await second.start()
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
    try await sender.start()
    let ran = sender.activeSessionID
    await sender.stop()

    #expect(ran != nil)
    await #expect(throws: NetworkAudioSenderError.alreadyStopped) {
      try await sender.start()
    }
  }

  /// Starting a running sender does nothing, so a caller that cannot tell whether it already
  /// started does not open a second connection by asking again.
  @Test("Starting a running sender changes nothing")
  func doubleStartIsANoOp() async throws {
    let sender = try NetworkAudioSender(configuration: try Fixture.configuration())
    try await sender.start()
    let first = sender.activeSessionID
    try await sender.start()
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

/// A network stream has no capture device to meter it, so the receiver meters what it writes —
/// otherwise nothing can draw a stream that is audibly playing.
@Suite("Network audio metering")
struct NetworkAudioMeteringTests {
  @Test("A receiver reports what it is putting out")
  func receiverPublishesAWaveform() async throws {
    let format = try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 2)
    let receiver = try NetworkAudioReceiver(
      configuration: try NetworkAudioReceiverConfiguration(port: 48_993, format: format)
    )
    let sender = try NetworkAudioSender(
      configuration: try NetworkAudioSenderConfiguration(
        host: "127.0.0.1", port: 48_993, format: format)
    )

    #expect(receiver.meterSnapshot().isEmpty, "nothing has arrived yet")

    try await receiver.start()
    try await sender.start()
    defer {
      Task {
        await sender.stop()
        receiver.stop()
      }
    }

    let quantum = 512
    var left = [Float](repeating: 0, count: quantum)
    var right = [Float](repeating: 0, count: quantum)
    var phase = 0.0
    for _ in 0..<60 {
      for frame in 0..<quantum {
        left[frame] = Float(0.25 * sin(phase))
        right[frame] = Float(0.25 * sin(phase))
        phase += 2 * .pi * 440 / 48_000
      }
      left.withUnsafeBufferPointer { l in
        right.withUnsafeBufferPointer { r in
          guard let lb = l.baseAddress, let rb = r.baseAddress else { return }
          [lb, rb].withUnsafeBufferPointer { channels in
            _ = sender.frameBuffer.writePlanar(channels, frameCount: quantum)
          }
        }
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(200))

    let snapshot = receiver.meterSnapshot()

    #expect(snapshot.count == 2, "a channel per channel of the stream")
    for channel in snapshot {
      #expect(!channel.waveform.isEmpty)
      #expect(channel.rootMeanSquare > 0.05, "the stream metered as silence")
      #expect(channel.waveform.contains { abs($0) > 0.1 })
    }
    // The channels are named apart, which is what lets each be drawn on its own.
    #expect(Set(snapshot.map(\.channelID.index.rawValue)) == [0, 1])
  }

  /// How often the meter has something new to say, which is the ceiling on how often anything
  /// drawing it can move.
  @Test("A receiver reports a new waveform many times a second")
  func meterPublishesOftenEnoughToDraw() async throws {
    let format = try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 2)
    let receiver = try NetworkAudioReceiver(
      configuration: try NetworkAudioReceiverConfiguration(port: 48_997, format: format)
    )
    let sender = try NetworkAudioSender(
      configuration: try NetworkAudioSenderConfiguration(
        host: "127.0.0.1", port: 48_997, format: format, framesPerPacket: 128)
    )
    try await receiver.start()
    try await sender.start()

    let feeding = Task {
      let quantum = 128
      var left = [Float](repeating: 0, count: quantum)
      var right = [Float](repeating: 0, count: quantum)
      var phase = 0.0
      for _ in 0..<800 {
        for frame in 0..<quantum {
          left[frame] = Float(0.25 * sin(phase))
          right[frame] = Float(0.25 * sin(phase * 3))
          phase += 2 * .pi * 440 / 48_000
        }
        left.withUnsafeBufferPointer { l in
          right.withUnsafeBufferPointer { r in
            guard let lb = l.baseAddress, let rb = r.baseAddress else { return }
            [lb, rb].withUnsafeBufferPointer { channels in
              _ = sender.frameBuffer.writePlanar(channels, frameCount: quantum)
            }
          }
        }
        try? await Task.sleep(for: .microseconds(2_666))
      }
    }

    // Sample far faster than the meter publishes, and count how often what it says changes.
    try await Task.sleep(for: .milliseconds(300))
    var distinct = 0
    var previous: [Float] = []
    let started = ContinuousClock().now
    while ContinuousClock().now - started < .seconds(1) {
      let waveform = receiver.meterSnapshot().first?.waveform ?? []
      if !waveform.isEmpty, waveform != previous {
        distinct += 1
        previous = waveform
      }
      try? await Task.sleep(for: .milliseconds(2))
    }
    feeding.cancel()
    await sender.stop()
    receiver.stop()

    // Fifty milliseconds of audio per report is twenty a second; anything near one a second could
    // not carry a moving waveform.
    #expect(distinct >= 10, "the meter reported \(distinct) times in a second")
  }
}

/// What a sender declares to the realtime scheduler, which has to cover what a cycle actually does.
@Suite("Network audio sender budget")
struct NetworkAudioSenderBudgetTests {
  private static func configuration(
    encoding: NetworkAudioWireEncoding
  ) throws -> NetworkAudioSenderConfiguration {
    try NetworkAudioSenderConfiguration(
      host: "127.0.0.1",
      port: 48_995,
      format: try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 2),
      encoding: encoding
    )
  }

  /// A cycle sending one datagram costs one hand-over.
  @Test("A format that fits a datagram declares one hand-over")
  func wholeBlockDeclaresOneDatagram() throws {
    for encoding in [NetworkAudioWireEncoding.interleavedFloat32] {
      let budget = try Self.configuration(encoding: encoding).realtimeComputationBudget

      #expect(budget == NetworkAudioSenderConfiguration.datagramBudget, "\(encoding)")
    }
  }

  /// A lossless block is many datagrams wide.
  ///
  /// A cycle hands over every one of them, and declaring the cost of a single datagram for that
  /// cycle is how a thread is demoted out of the realtime scheduler.
  /// The comparison is against the format that carries a whole block in one datagram, which is
  /// the case the single-datagram declaration was written for.
  @Test("A format wider than a datagram declares what the whole cycle costs")
  func splitBlockDeclaresEveryPiece() throws {
    let whole = try Self.configuration(encoding: .interleavedFloat32).realtimeComputationBudget
    let split = try Self.configuration(encoding: .appleLossless).realtimeComputationBudget

    #expect(whole == NetworkAudioSenderConfiguration.datagramBudget)
    #expect(split > whole * 5, "a split block declared \(split) against \(whole)")
    // Measured on this hardware: eighteen pieces of a lossless block spanned 1089 µs at worst,
    // so a declaration below that makes the overrun the sustained case rather than the tail.
    #expect(split > Duration.microseconds(1_089))
  }

  /// A codec whose worst-case packet exceeds one datagram declares more than one hand-over even
  /// when a typical packet at its bit rate would fit, because the declaration has to cover the
  /// packet the codec is allowed to produce rather than the one it usually does.
  @Test("A codec is budgeted for the largest packet it may produce")
  func codecIsBudgetedForItsWorstCase() throws {
    let opus = try Self.configuration(encoding: .opus).realtimeComputationBudget
    let lossless = try Self.configuration(encoding: .appleLossless).realtimeComputationBudget

    #expect(opus > NetworkAudioSenderConfiguration.datagramBudget)
    #expect(opus < lossless)
  }

  /// The kernel refuses a computation past its own ceiling, so the declaration stays inside it
  /// however many pieces a block turns into.
  @Test("The declaration stays inside what the kernel accepts")
  func declarationStaysInsideTheKernelsCeiling() throws {
    for encoding in NetworkAudioWireEncoding.allCases {
      let budget = try Self.configuration(encoding: encoding).realtimeComputationBudget

      #expect(budget <= AudioRealtimeBudget.maximumComputation, "\(encoding)")
      #expect(budget >= NetworkAudioSenderConfiguration.datagramBudget, "\(encoding)")
    }
  }
}
