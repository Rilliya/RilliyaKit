// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaRealtime
import Testing

@testable import RilliyaNetworkAudio

@Suite("Network audio in-place encoding")
struct NetworkAudioPacketEncodingTests {
  private enum Fixture {
    static let sessionID = UUID(
      uuid: (
        0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD,
        0xEF
      ))
    static let sequence: UInt64 = 4_242
  }

  /// The realtime path must produce exactly what the allocating path produces, byte for byte,
  /// or a receiver would see two different wire formats depending on which sender it met.
  @Test(
    "In-place encoding matches the allocating encoder",
    arguments: [(1, 1), (2, 4), (2, 144), (6, 32), (8, 36)]
  )
  func inPlaceMatchesAllocating(channelCount: Int, frameCount: Int) throws {
    let format = try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: channelCount)
    let channels = (0..<channelCount).map { channel in
      (0..<frameCount).map { frame in
        Float(channel + 1) * 0.25 - Float(frame) * 0.001
      }
    }

    let interleaved = (0..<frameCount).flatMap { frame in
      (0..<channelCount).map { channels[$0][frame] }
    }
    var payload = Data()
    for sample in interleaved {
      withUnsafeBytes(of: sample.bitPattern.littleEndian) { payload.append(contentsOf: $0) }
    }
    let allocating = try NetworkAudioPacketCodec.encode(
      NetworkAudioPacket(
        sessionID: Fixture.sessionID,
        sequence: Fixture.sequence,
        format: format,
        frameCount: frameCount,
        payload: payload
      )
    )

    let storage = UnsafeMutableRawBufferPointer.allocate(
      byteCount: NetworkAudioPacketCodec.maximumDatagramByteCount,
      alignment: 16
    )
    defer { storage.deallocate() }
    let pointers = channels.map { channel -> UnsafeMutablePointer<Float> in
      let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
      buffer.initialize(from: channel, count: frameCount)
      return buffer
    }
    defer {
      for pointer in pointers {
        pointer.deinitialize(count: frameCount)
        pointer.deallocate()
      }
    }
    let readOnly = pointers.map { UnsafePointer($0) }
    let written = try readOnly.withUnsafeBufferPointer {
      try NetworkAudioPacketCodec.encode(
        sessionID: Fixture.sessionID,
        sequence: Fixture.sequence,
        format: format,
        frameCount: frameCount,
        planarChannels: $0,
        into: storage
      )
    }

    #expect(written == allocating.count)
    #expect(
      written
        == NetworkAudioPacketCodec.datagramByteCount(
          channelCount: channelCount, frameCount: frameCount))
    #expect(Data(storage.prefix(written)) == allocating)
    #expect(
      try NetworkAudioPacketCodec.decode(Data(storage.prefix(written))).frameCount
        == frameCount)
  }

  @Test("In-place encoding refuses storage it would overrun")
  func rejectsUndersizedStorage() throws {
    let format = try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 2)
    let channel = UnsafeMutablePointer<Float>.allocate(capacity: 16)
    channel.initialize(repeating: 0, count: 16)
    defer {
      channel.deinitialize(count: 16)
      channel.deallocate()
    }
    let readOnly = [UnsafePointer(channel), UnsafePointer(channel)]
    let tooSmall = UnsafeMutableRawBufferPointer.allocate(byteCount: 32, alignment: 16)
    defer { tooSmall.deallocate() }

    #expect(throws: NetworkAudioPacketError.datagramTooLarge) {
      _ = try readOnly.withUnsafeBufferPointer {
        try NetworkAudioPacketCodec.encode(
          sessionID: Fixture.sessionID,
          sequence: 0,
          format: format,
          frameCount: 16,
          planarChannels: $0,
          into: tooSmall
        )
      }
    }
  }

  @Test("In-place encoding replaces a nonfinite sample with silence")
  func nonfiniteSamplesBecomeSilence() throws {
    let format = try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 1)
    let channel = UnsafeMutablePointer<Float>.allocate(capacity: 3)
    channel.initialize(to: .nan)
    channel[1] = .infinity
    channel[2] = 0.5
    defer {
      channel.deinitialize(count: 3)
      channel.deallocate()
    }
    let storage = UnsafeMutableRawBufferPointer.allocate(byteCount: 256, alignment: 16)
    defer { storage.deallocate() }

    let written = try [UnsafePointer(channel)].withUnsafeBufferPointer {
      try NetworkAudioPacketCodec.encode(
        sessionID: Fixture.sessionID,
        sequence: 0,
        format: format,
        frameCount: 3,
        planarChannels: $0,
        into: storage
      )
    }
    let decoded = try NetworkAudioPacketCodec.decode(Data(storage.prefix(written)))
    let samples = decoded.payload.withUnsafeBytes { raw in
      (0..<3).map {
        Float(
          bitPattern: UInt32(
            littleEndian: raw.loadUnaligned(
              fromByteOffset: $0 * 4, as: UInt32.self)))
      }
    }

    #expect(samples == [0, 0, 0.5])
  }
}
