// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaRealtime
import Testing

@testable import RilliyaNetworkAudio

/// One received stream reaching several places at once.
///
/// Headphones, a virtual device and a recording all want the same audio, and each reads on its own
/// clock. A single queue can serve only one of them: whoever reads first takes the audio away, and
/// the amount of slack that suits one reader is the wrong amount for every other.
@Suite("Network audio fan-out", .serialized)
struct NetworkAudioFanOutTests {
  private enum Fixture {
    static let host = "127.0.0.1"
    static let quantum = 512
    static let level: Float = 0.35

    static func format() throws -> NetworkAudioStreamFormat {
      try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 2)
    }
  }

  /// The promise the whole shape rests on: what one destination reads, another still gets.
  @Test("Two destinations each hear the whole stream")
  func twoDestinationsEachHearEverything() async throws {
    let port: UInt16 = 49_801
    let receiver = try NetworkAudioReceiver(
      configuration: try NetworkAudioReceiverConfiguration(port: port, format: try Fixture.format())
    )
    let first = try receiver.subscribeWithJitterBuffer()
    let second = try receiver.subscribeWithJitterBuffer()
    try await receiver.start()
    defer { receiver.stop() }

    let sender = try NetworkAudioSender(
      configuration: try NetworkAudioSenderConfiguration(
        host: Fixture.host,
        port: port,
        format: try Fixture.format()
      )
    )
    try await sender.start()
    try await Self.feed(sender)
    await sender.stop()

    #expect(receiver.statistics().destinationCount == 2)
    // Read the second one first: if they shared a queue, whichever read first would leave the
    // other with silence, and the order would decide which destination worked.
    let secondHeard = Self.drain(second)
    let firstHeard = Self.drain(first)
    #expect(secondHeard > 0, "the second destination heard nothing")
    #expect(firstHeard > 0, "the first destination heard nothing")
  }

  /// A destination that stops reading must cost the others nothing.
  @Test("A destination that stalls does not starve the others")
  func aStalledDestinationDoesNotStarveTheOthers() async throws {
    let port: UInt16 = 49_802
    let receiver = try NetworkAudioReceiver(
      configuration: try NetworkAudioReceiverConfiguration(port: port, format: try Fixture.format())
    )
    let attentive = try receiver.subscribeWithJitterBuffer()
    let stalled = try receiver.subscribeWithJitterBuffer()
    try await receiver.start()
    defer { receiver.stop() }

    let sender = try NetworkAudioSender(
      configuration: try NetworkAudioSenderConfiguration(
        host: Fixture.host,
        port: port,
        format: try Fixture.format()
      )
    )
    try await sender.start()
    try await Self.feed(sender)
    await sender.stop()

    // `stalled` is never read, so its queue fills and stays full.
    #expect(Self.drain(attentive) > 0, "a stalled destination took the audio from a reading one")
    _ = stalled
  }

  /// Releasing a destination gives its slot back, or a long-lived stream would run out.
  @Test("Releasing a destination frees its slot")
  func releasingADestinationFreesItsSlot() async throws {
    let receiver = try NetworkAudioReceiver(
      configuration: try NetworkAudioReceiverConfiguration(
        port: 49_803,
        format: try Fixture.format(),
        maximumDestinationCount: 1
      )
    )

    do {
      let only = try receiver.subscribeWithJitterBuffer()
      #expect(receiver.statistics().destinationCount == 1)
      #expect(throws: (any Error).self) { _ = try receiver.subscribeWithJitterBuffer() }
      _ = only
    }

    #expect(receiver.statistics().destinationCount == 0)
    _ = try receiver.subscribeWithJitterBuffer()
  }

  /// Nothing is reading, so there is no deadline to beat and no request worth spending.
  @Test("A stream nobody is reading reports no queued audio")
  func anUnreadStreamHasNoQueue() throws {
    let receiver = try NetworkAudioReceiver(
      configuration: try NetworkAudioReceiverConfiguration(
        port: 49_804,
        format: try Fixture.format()
      )
    )

    #expect(receiver.distributor.minimumAvailableFrameCount == nil)
    #expect(receiver.statistics().destinationCount == 0)
  }

  /// A stream too wide to preallocate eight destinations for still plays to one.
  ///
  /// Every destination is preallocated, so a wide format affords fewer of them. Refusing the
  /// stream outright would trade a working single destination for none at all.
  @Test("A stream too wide for the usual destination count still starts")
  func aWideStreamStillStarts() throws {
    let wide = try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 64)
    let receiver = try NetworkAudioReceiver(
      configuration: try NetworkAudioReceiverConfiguration(port: 49_805, format: wide)
    )

    #expect(receiver.configuration.maximumDestinationCount >= 1)
    #expect(
      receiver.configuration.maximumDestinationCount
        < NetworkAudioReceiverConfiguration.preferredDestinationCount,
      "a 64-channel stream should not have been given the usual number of destinations"
    )
    _ = try receiver.subscribeWithJitterBuffer()
  }

  private static func feed(_ sender: NetworkAudioSender) async throws {
    var left = [Float](repeating: level, count: quantumCount)
    var right = [Float](repeating: level, count: quantumCount)
    for _ in 0..<20 {
      left.withUnsafeBufferPointer { l in
        right.withUnsafeBufferPointer { r in
          guard let lb = l.baseAddress, let rb = r.baseAddress else { return }
          [lb, rb].withUnsafeBufferPointer { channels in
            _ = sender.frameBuffer.writePlanar(channels, frameCount: quantumCount)
          }
        }
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(200))
  }

  private static let quantumCount = Fixture.quantum
  private static let level = Fixture.level

  /// The frames of real audio a destination can hand to a render callback.
  ///
  /// A jitter buffer silences whatever it could not supply, so the silenced tail says nothing about
  /// whether the stream reached this destination; only the copied frames do.
  private static func drain(_ jitterBuffer: AudioJitterBuffer) -> Int {
    let channelCount = jitterBuffer.frameBuffer.format.channelCount
    let channels = (0..<channelCount).map { _ -> UnsafeMutablePointer<Float> in
      let storage = UnsafeMutablePointer<Float>.allocate(capacity: quantumCount)
      storage.initialize(repeating: 0, count: quantumCount)
      return storage
    }
    defer {
      for storage in channels {
        storage.deinitialize(count: quantumCount)
        storage.deallocate()
      }
    }

    var total = 0
    channels.withUnsafeBufferPointer { buffer in
      for _ in 0..<40 {
        if case .read(let frameCount, _) = jitterBuffer.read(
          into: buffer,
          frameCount: quantumCount
        ) {
          total += frameCount
        }
      }
    }
    return total
  }
}
