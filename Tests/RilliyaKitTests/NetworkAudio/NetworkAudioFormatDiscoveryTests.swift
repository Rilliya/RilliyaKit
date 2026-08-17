// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RilliyaNetworkAudio

@Suite("Network audio format discovery")
struct NetworkAudioFormatDiscoveryTests {
  @Test("The format of the first acceptable packet is reported")
  func discoversTheSenderFormat() async throws {
    let port = Fixture.port(offset: 0)
    let format = try NetworkAudioStreamFormat(sampleRate: 44_100, channelCount: 1)

    async let discovered = NetworkAudioFormatDiscovery.discover(
      port: port,
      timeout: .seconds(5)
    )
    let sender = try Fixture.repeatedlySend(
      Fixture.datagram(format: format),
      to: port
    )
    defer { sender.cancel() }

    #expect(try await discovered == format)
  }

  @Test(
    "Each format a sender might use is reported as it is",
    arguments: [(48_000.0, 2), (96_000.0, 8), (44_100.0, 1)]
  )
  func discoversEveryFormat(sampleRate: Double, channelCount: Int) async throws {
    let port = Fixture.port(offset: channelCount)
    let format = try NetworkAudioStreamFormat(
      sampleRate: sampleRate,
      channelCount: channelCount
    )

    async let discovered = NetworkAudioFormatDiscovery.discover(port: port, timeout: .seconds(5))
    let sender = try Fixture.repeatedlySend(Fixture.datagram(format: format), to: port)
    defer { sender.cancel() }

    #expect(try await discovered == format)
  }

  @Test("A port nobody is sending to gives up rather than waiting forever")
  func timesOutOnSilence() async throws {
    await #expect(throws: NetworkAudioFormatDiscoveryError.timedOut) {
      _ = try await NetworkAudioFormatDiscovery.discover(
        port: Fixture.port(offset: 20),
        timeout: .milliseconds(300)
      )
    }
  }

  /// Believing a header without opening the payload would let anyone who can reach the port
  /// choose the format a keyed receiver is then built around.
  @Test("A packet in the clear does not decide a keyed listener's format")
  func plaintextDoesNotDecideAKeyedFormat() async throws {
    let port = Fixture.port(offset: 30)
    let format = try NetworkAudioStreamFormat(sampleRate: 96_000, channelCount: 8)

    let sender = try Fixture.repeatedlySend(Fixture.datagram(format: format), to: port)
    defer { sender.cancel() }

    await #expect(throws: NetworkAudioFormatDiscoveryError.timedOut) {
      _ = try await NetworkAudioFormatDiscovery.discover(
        port: port,
        keyProvider: NetworkAudioStaticKeyProvider(.random()),
        timeout: .milliseconds(400)
      )
    }
  }

  @Test("A packet under the wrong key does not decide the format either")
  func wrongKeyDoesNotDecideTheFormat() async throws {
    let port = Fixture.port(offset: 40)
    let format = try NetworkAudioStreamFormat(sampleRate: 96_000, channelCount: 8)
    let datagram = try Fixture.datagram(format: format, key: .random())

    let sender = try Fixture.repeatedlySend(datagram, to: port)
    defer { sender.cancel() }

    await #expect(throws: NetworkAudioFormatDiscoveryError.timedOut) {
      _ = try await NetworkAudioFormatDiscovery.discover(
        port: port,
        keyProvider: NetworkAudioStaticKeyProvider(.random()),
        timeout: .milliseconds(400)
      )
    }
  }

  @Test("A packet under the shared key is believed")
  func matchingKeyDecidesTheFormat() async throws {
    let port = Fixture.port(offset: 50)
    let key = NetworkAudioSharedKey.random()
    let format = try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 2)

    async let discovered = NetworkAudioFormatDiscovery.discover(
      port: port,
      keyProvider: NetworkAudioStaticKeyProvider(key),
      timeout: .seconds(5)
    )
    let sender = try Fixture.repeatedlySend(
      Fixture.datagram(format: format, key: key),
      to: port
    )
    defer { sender.cancel() }

    #expect(try await discovered == format)
  }

  @Test("Controls outside the bounded policy are rejected")
  func invalidControlsAreRejected() async {
    await #expect(throws: NetworkAudioFormatDiscoveryError.invalidPort) {
      _ = try await NetworkAudioFormatDiscovery.discover(port: 0, timeout: .milliseconds(200))
    }
    await #expect(throws: NetworkAudioFormatDiscoveryError.invalidTimeout) {
      _ = try await NetworkAudioFormatDiscovery.discover(
        port: Fixture.port(offset: 60),
        timeout: .zero
      )
    }
  }

  private enum Fixture {
    /// Ports are spread out so tests running in parallel never share one.
    static func port(offset: Int) -> UInt16 {
      UInt16(47_300 + offset)
    }

    static func datagram(
      format: NetworkAudioStreamFormat,
      key: NetworkAudioSharedKey? = nil
    ) throws -> Data {
      let frameCount = 4
      let channels = (0..<format.channelCount).map { channel -> UnsafeMutablePointer<Float> in
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        samples.initialize(repeating: Float(channel + 1) * 0.1, count: frameCount)
        return samples
      }
      defer {
        for samples in channels {
          samples.deinitialize(count: frameCount)
          samples.deallocate()
        }
      }
      let byteCount =
        NetworkAudioPacketCodec.datagramByteCount(
          channelCount: format.channelCount,
          frameCount: frameCount
        ) + (key == nil ? 0 : NetworkAudioSessionCipher.tagByteCount)
      var datagram = Data(count: byteCount)
      let cipher = key.map {
        NetworkAudioSessionCipher(sharedKey: $0, sessionID: Fixture.sessionID)
      }
      let readOnly = channels.map { UnsafePointer<Float>($0) }
      let written = try readOnly.withUnsafeBufferPointer { planarChannels in
        try datagram.withUnsafeMutableBytes { destination in
          try NetworkAudioPacketCodec.encode(
            sessionID: Fixture.sessionID,
            sequence: 0,
            format: format,
            frameCount: frameCount,
            planarChannels: planarChannels,
            into: destination,
            cipher: cipher
          )
        }
      }
      return datagram.prefix(written)
    }

    static let sessionID = UUID(
      uuid: (
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x47, 0x88,
        0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00
      )
    )

    /// Sends the datagram every few milliseconds, so a listener that starts late still sees one.
    static func repeatedlySend(_ datagram: Data, to port: UInt16) throws -> Task<Void, Never> {
      Task.detached {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard socket >= 0 else { return }
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        while !Task.isCancelled {
          datagram.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
              pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { destination in
                _ = sendto(
                  socket,
                  bytes.baseAddress,
                  bytes.count,
                  0,
                  destination,
                  socklen_t(MemoryLayout<sockaddr_in>.size)
                )
              }
            }
          }
          try? await Task.sleep(for: .milliseconds(10))
        }
      }
    }
  }
}
