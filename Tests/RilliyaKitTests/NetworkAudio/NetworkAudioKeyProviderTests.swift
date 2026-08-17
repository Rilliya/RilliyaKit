// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import os.lock

@testable import RilliyaNetworkAudio

/// Where the key two peers share comes from.
///
/// The transport needs 32 bytes and nothing else, so anything that can produce the same bytes on
/// both machines can supply them: a key typed in, one in a keychain, one released after a sign-in.
/// These are the promises such a thing is held to.
@Suite("Network audio key providers", .serialized)
struct NetworkAudioKeyProviderTests {
  private enum Fixture {
    static let host = "127.0.0.1"
    static let port: UInt16 = 49_701

    static func format() throws -> NetworkAudioStreamFormat {
      try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 2)
    }
  }

  /// A provider that counts how often it is asked and can be made to fail.
  private final class CountingProvider: NetworkAudioKeyProvider {
    private let key: NetworkAudioSharedKey
    private let failure: (any Error)?
    private let calls = OSAllocatedUnfairLock<Int>(initialState: 0)

    init(key: NetworkAudioSharedKey = .random(), failure: (any Error)? = nil) {
      self.key = key
      self.failure = failure
    }

    var callCount: Int { calls.withLock { $0 } }

    func sharedKey() async throws -> NetworkAudioSharedKey {
      calls.withLock { $0 += 1 }
      // A sign-in takes time; a provider is allowed to.
      try await Task.sleep(for: .milliseconds(5))
      if let failure { throw failure }
      return key
    }
  }

  private enum ProviderFailure: Error, Equatable {
    case signedOut
  }

  @Test("A key already in hand needs no asking")
  func staticProviderReturnsItsKey() async throws {
    let key = NetworkAudioSharedKey.random()

    #expect(try await NetworkAudioStaticKeyProvider(key).sharedKey() == key)
  }

  /// A provider is asked once and what it gave is held for the run: the session key is derived
  /// from those bytes, so asking again mid-run could change them underneath the stream.
  @Test("A sender asks once for a whole run")
  func senderAsksOnce() async throws {
    let provider = CountingProvider()
    let sender = try NetworkAudioSender(
      configuration: try NetworkAudioSenderConfiguration(
        host: Fixture.host,
        port: Fixture.port,
        format: try Fixture.format(),
        keyProvider: provider
      )
    )

    try await sender.start()
    // Starting a running sender changes nothing, so it must not ask again either.
    try await sender.start()
    try await Task.sleep(for: .milliseconds(50))
    await sender.stop()

    #expect(provider.callCount == 1, "asked \(provider.callCount) times for one run")
  }

  @Test("A receiver asks once for a whole run")
  func receiverAsksOnce() async throws {
    let provider = CountingProvider()
    let receiver = try NetworkAudioReceiver(
      configuration: try NetworkAudioReceiverConfiguration(
        port: 49_702,
        format: try Fixture.format(),
        keyProvider: provider
      )
    )

    try await receiver.start()
    try await receiver.start()
    receiver.stop()

    #expect(provider.callCount == 1, "asked \(provider.callCount) times for one run")
  }

  /// A credential that has expired fails the next start rather than changing under a running
  /// session, so what a provider throws has to stop the start.
  @Test("A sender that cannot get a key does not start")
  func senderFailsWhenTheProviderFails() async throws {
    let provider = CountingProvider(failure: ProviderFailure.signedOut)
    let sender = try NetworkAudioSender(
      configuration: try NetworkAudioSenderConfiguration(
        host: Fixture.host,
        port: 49_703,
        format: try Fixture.format(),
        keyProvider: provider
      )
    )

    await #expect(throws: ProviderFailure.signedOut) {
      try await sender.start()
    }
    #expect(sender.activeSessionID == nil, "a sender that could not get a key claimed a run")
  }

  @Test("A receiver that cannot get a key does not start")
  func receiverFailsWhenTheProviderFails() async throws {
    let port: UInt16 = 49_704
    let provider = CountingProvider(failure: ProviderFailure.signedOut)
    let receiver = try NetworkAudioReceiver(
      configuration: try NetworkAudioReceiverConfiguration(
        port: port,
        format: try Fixture.format(),
        keyProvider: provider
      )
    )

    await #expect(throws: ProviderFailure.signedOut) {
      try await receiver.start()
    }
    // Nothing was bound, so the port is still free for whoever wants it.
    #expect(Self.isFree(port), "a receiver that could not get a key kept the port")
  }

  /// The whole point: two peers agree because their providers produce the same bytes, whatever
  /// each did to get them.
  @Test("Two peers whose providers agree can hear each other")
  func peersWithAgreeingProvidersAgree() async throws {
    let port: UInt16 = 49_705
    let key = NetworkAudioSharedKey.random()
    let receiver = try NetworkAudioReceiver(
      configuration: try NetworkAudioReceiverConfiguration(
        port: port,
        format: try Fixture.format(),
        keyProvider: CountingProvider(key: key)
      )
    )
    let sender = try NetworkAudioSender(
      configuration: try NetworkAudioSenderConfiguration(
        host: Fixture.host,
        port: port,
        format: try Fixture.format(),
        keyProvider: CountingProvider(key: key)
      )
    )
    try await receiver.start()
    try await sender.start()

    try await Self.feed(sender)

    let statistics = receiver.statistics()
    await sender.stop()
    receiver.stop()

    #expect(statistics.acceptedPacketCount > 0, "nothing was heard")
    #expect(statistics.rejectedPacketCount == 0, "audio was refused under an agreed key")
  }

  /// And two whose providers disagree hear nothing, which is what the key is for.
  @Test("Two peers whose providers disagree hear nothing")
  func peersWithDisagreeingProvidersHearNothing() async throws {
    let port: UInt16 = 49_706
    let receiver = try NetworkAudioReceiver(
      configuration: try NetworkAudioReceiverConfiguration(
        port: port,
        format: try Fixture.format(),
        keyProvider: CountingProvider()
      )
    )
    let sender = try NetworkAudioSender(
      configuration: try NetworkAudioSenderConfiguration(
        host: Fixture.host,
        port: port,
        format: try Fixture.format(),
        keyProvider: CountingProvider()
      )
    )
    try await receiver.start()
    try await sender.start()

    try await Self.feed(sender)

    let statistics = receiver.statistics()
    await sender.stop()
    receiver.stop()

    #expect(statistics.acceptedPacketCount == 0, "audio under another key was accepted")
    #expect(statistics.rejectedPacketCount > 0, "nothing arrived to be refused")
  }

  private static func feed(_ sender: NetworkAudioSender) async throws {
    let quantum = 512
    var left = [Float](repeating: 0.2, count: quantum)
    var right = [Float](repeating: 0.2, count: quantum)
    for _ in 0..<20 {
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
  }

  private static func isFree(_ port: UInt16) -> Bool {
    let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = INADDR_ANY
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    } == 0
  }
}
