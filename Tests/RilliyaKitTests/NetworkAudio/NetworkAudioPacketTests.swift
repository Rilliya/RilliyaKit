// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaRealtime
import Testing

@testable import RilliyaNetworkAudio

@Suite("Network audio packet protocol")
struct NetworkAudioPacketTests {
  @Test("Versioned packets round-trip exact metadata and Float32 payload")
  func packetRoundTrip() throws {
    let sessionID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
    let format = try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 2)
    let packet = try NetworkAudioPacket(
      sessionID: sessionID,
      sequence: 42,
      format: format,
      frameCount: 2,
      payload: payload([0.25, -0.5, 0.75, -1])
    )

    let data = try NetworkAudioPacketCodec.encode(packet)
    let decoded = try NetworkAudioPacketCodec.decode(data)

    #expect(data.count == NetworkAudioPacketCodec.headerByteCount + 16)
    #expect(decoded == packet)
  }

  @Test("Malformed and unsupported datagrams fail before exposing PCM")
  func rejectsMalformedDatagrams() throws {
    let format = try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 1)
    let packet = try NetworkAudioPacket(
      sessionID: UUID(),
      sequence: 0,
      format: format,
      frameCount: 1,
      payload: payload([0.5])
    )
    let encoded = try NetworkAudioPacketCodec.encode(packet)

    #expect(throws: NetworkAudioPacketError.truncated) {
      _ = try NetworkAudioPacketCodec.decode(encoded.prefix(12))
    }

    var wrongVersion = encoded
    wrongVersion[4] = 99
    #expect(throws: NetworkAudioPacketError.unsupportedVersion(99)) {
      _ = try NetworkAudioPacketCodec.decode(wrongVersion)
    }

    var extraPayload = encoded
    extraPayload.append(0)
    #expect(
      throws: NetworkAudioPacketError.payloadSizeMismatch(expected: 4, actual: 5)
    ) {
      _ = try NetworkAudioPacketCodec.decode(extraPayload)
    }
  }

  @Test("Receiver inserts bounded silence for sequence loss and rejects a live foreign session")
  func ingestsSequenceWithLossAndSessionOwnership() throws {
    let format = try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 1)
    let configuration = try NetworkAudioReceiverConfiguration(
      port: 48_620,
      format: format,
      capacityFrameCount: 32,
      sessionTakeoverInterval: .seconds(1)
    )
    let buffer = try AudioRealtimeFrameBuffer(
      format: AudioProcessingFormat(sampleRate: 48_000, channelCount: 1),
      capacityFrameCount: 32
    )
    let ingestor = NetworkAudioPacketIngestor(
      configuration: configuration,
      frameBuffer: buffer
    )
    let firstSession = UUID()
    let secondSession = UUID()

    #expect(
      ingestor.ingest(
        try datagram(sessionID: firstSession, sequence: 0, samples: [0.25, 0.5]),
        now: 1_000
      ) == .accepted(frameCount: 2)
    )
    #expect(
      ingestor.ingest(
        try datagram(sessionID: secondSession, sequence: 0, samples: [1, 1]),
        now: 2_000
      ) == .foreignSession
    )
    #expect(
      ingestor.ingest(
        try datagram(sessionID: firstSession, sequence: 2, samples: [0.75, 1]),
        now: 3_000
      ) == .accepted(frameCount: 2)
    )

    #expect(read(buffer, frameCount: 6) == [0.25, 0.5, 0, 0, 0.75, 1])
    let statistics = ingestor.statistics()
    #expect(statistics.acceptedPacketCount == 2)
    #expect(statistics.foreignSessionPacketCount == 1)
    #expect(statistics.missingPacketCount == 1)
  }

  private func datagram(
    sessionID: UUID,
    sequence: UInt64,
    samples: [Float]
  ) throws -> Data {
    let packet = try NetworkAudioPacket(
      sessionID: sessionID,
      sequence: sequence,
      format: NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 1),
      frameCount: samples.count,
      payload: payload(samples)
    )
    return try NetworkAudioPacketCodec.encode(packet)
  }
}

private func payload(_ samples: [Float]) -> Data {
  var data = Data(capacity: samples.count * MemoryLayout<Float>.stride)
  for sample in samples {
    var bits = sample.bitPattern.littleEndian
    withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
  }
  return data
}

private func read(_ buffer: AudioRealtimeFrameBuffer, frameCount: Int) -> [Float] {
  let storage = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
  storage.initialize(repeating: .nan, count: frameCount)
  defer {
    storage.deinitialize(count: frameCount)
    storage.deallocate()
  }
  [storage].withUnsafeBufferPointer {
    _ = buffer.read(into: $0, frameCount: frameCount)
  }
  return Array(UnsafeBufferPointer(start: storage, count: frameCount))
}
