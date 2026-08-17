// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Network
import RilliyaCore
import RilliyaRealtime
import Testing

@testable import RilliyaNetworkAudio

/// The guards that decide when a receiver is allowed to act, and what it says when it cannot.
@Suite("Network audio receiver guards", .serialized)
struct NetworkAudioReceiverGuardTests {
  /// Silence has more than one cause, so they have to be told apart.
  ///
  /// A codec needing a configuration produces nothing until one arrives, a codec the system no
  /// longer installs produces nothing at all, and a sender that stopped sounds the same as both.
  /// A block that arrived whole and could not be decoded is counted for that reason.
  @Test("A block that cannot be decoded is counted rather than passed over")
  func undecodableBlockIsCounted() throws {
    let format = try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 2)
    let frameBuffer = try AudioRealtimeFrameBuffer(
      format: AudioProcessingFormat(sampleRate: 48_000, channelCount: 2)
    )
    let ingestor = try NetworkAudioPacketIngestor(
      configuration: try NetworkAudioReceiverConfiguration(port: 49_501, format: format),
      frameBuffer: frameBuffer
    )
    // Apple Lossless without the configuration its decoder needs: a whole block, undecodable.
    let codec = NetworkAudioCodec.appleLossless
    let frames = try #require(
      codec.frameCount(nearestTo: 10, sampleRate: 48_000, channelCount: 2))
    let packet = try NetworkAudioPacket(
      sessionID: UUID(),
      sequence: 0,
      format: format,
      frameCount: frames,
      payload: Data((0..<200).map { UInt8($0 % 251) }),
      encoding: .appleLossless
    )

    let outcome = ingestor.ingest(try NetworkAudioPacketCodec.encode(packet), now: 0)

    #expect(ingestor.statistics().undecodablePacketCount > 0)
    if case .accepted = outcome {
      Issue.record("a block with no configuration was accepted as audio")
    }
    #expect(frameBuffer.statistics().writtenFrameCount == 0)
  }

  /// Nothing may reach the queue once a receiver is stopped.
  ///
  /// A connection handler already queued when the listener was cancelled would otherwise start a
  /// connection the stopped receiver goes on reading audio from.
  @Test("A stopped receiver takes nothing more")
  func stoppedReceiverTakesNothing() async throws {
    let port: UInt16 = 49_502
    let format = try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 2)
    let receiver = try NetworkAudioReceiver(
      configuration: try NetworkAudioReceiverConfiguration(port: port, format: format)
    )
    let sender = try NetworkAudioSender(
      configuration: try NetworkAudioSenderConfiguration(
        host: "127.0.0.1", port: port, format: format)
    )
    try receiver.start()
    try sender.start()

    try await Self.feed(sender, blocks: 20)
    try await Task.sleep(for: .milliseconds(200))
    let whileRunning = receiver.statistics()
    #expect(whileRunning.acceptedPacketCount > 0, "nothing arrived while it was running")

    receiver.stop()
    try await Self.feed(sender, blocks: 20)
    try await Task.sleep(for: .milliseconds(300))
    await sender.stop()

    let afterStop = receiver.statistics()
    #expect(afterStop.acceptedPacketCount == whileRunning.acceptedPacketCount)
    #expect(
      afterStop.frameBuffer.writtenFrameCount == whileRunning.frameBuffer.writtenFrameCount,
      "a stopped receiver went on writing audio"
    )
  }

  /// The race itself, driven rather than waited for.
  ///
  /// A connection handler already queued when `stop()` ran would start a connection the stopped
  /// receiver goes on reading audio from. The window is too narrow to hit by timing, so the
  /// handler's own decision is driven directly: a stopped receiver must take nothing.
  @Test("A connection offered after a stop is refused rather than tracked")
  func connectionAfterStopIsRefused() throws {
    let port: UInt16 = 49_504
    let format = try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 2)
    let receiver = try NetworkAudioReceiver(
      configuration: try NetworkAudioReceiverConfiguration(port: port, format: format)
    )
    try receiver.start()

    let running = NWConnection(host: "127.0.0.1", port: 9, using: .udp)
    receiver.accept(running)
    #expect(receiver.trackedConnectionCount > 0, "a running receiver took nothing")

    receiver.stop()
    let afterStop = NWConnection(host: "127.0.0.1", port: 9, using: .udp)
    receiver.accept(afterStop)

    #expect(
      receiver.trackedConnectionCount == 0,
      "a stopped receiver took a connection and would read audio from it"
    )
    afterStop.cancel()
  }

  private static func feed(_ sender: NetworkAudioSender, blocks: Int) async throws {
    let quantum = 512
    var left = [Float](repeating: 0.2, count: quantum)
    var right = [Float](repeating: 0.2, count: quantum)
    for _ in 0..<blocks {
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
  }
}

/// Discovery binds a port to listen on, so giving up has to release it.
@Suite("Network audio discovery teardown", .serialized)
struct NetworkAudioDiscoveryTeardownTests {
  /// A cancelled discovery used to leave its listener running.
  ///
  /// It published and started the listener even when the session had already closed: `close()`
  /// cancels what it can see, and during the setup window it can see nothing. The port was then
  /// held by a listener nobody was left holding.
  ///
  /// The cancel instant is swept, because the window is a few microseconds wide and a single
  /// timing would miss it.
  @Test("A cancelled discovery leaves its port free")
  func cancelledDiscoveryReleasesItsPort() async throws {
    let port: UInt16 = 49_503

    for microseconds in stride(from: 0, through: 120, by: 4) {
      let task = Task {
        try await NetworkAudioFormatDiscovery.discover(port: port, timeout: .seconds(5))
      }
      if microseconds > 0 {
        try? await Task.sleep(for: .microseconds(microseconds))
      }
      task.cancel()
      _ = try? await task.value
    }

    // Every one of those gave up; nothing should still be holding the port.
    try await Task.sleep(for: .milliseconds(500))
    #expect(Self.isFree(port), "a cancelled discovery left its port bound")
  }

  private static func isFree(_ port: UInt16) -> Bool {
    for _ in 0..<20 {
      let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
      guard descriptor >= 0 else { return false }
      var address = sockaddr_in()
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = port.bigEndian
      address.sin_addr.s_addr = INADDR_ANY
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      close(descriptor)
      if bound == 0 { return true }
      // Network.framework releases a cancelled listener's port asynchronously.
      usleep(50_000)
    }
    return false
  }
}
