// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaRealtime

/// The concrete PCM format carried by one Rilliya network-audio session.
public struct NetworkAudioStreamFormat: Equatable, Hashable, Sendable {
  /// The number of complete sample frames per second.
  public let sampleRate: Double

  /// The number of interleaved Float32 channels in every packet.
  public let channelCount: Int

  /// Creates a validated network stream format.
  public init(sampleRate: Double, channelCount: Int) throws {
    guard sampleRate.isFinite,
      sampleRate >= 1,
      sampleRate <= 768_000,
      abs(sampleRate.rounded() - sampleRate) < 0.001
    else {
      throw NetworkAudioPacketError.invalidSampleRate(sampleRate)
    }
    guard (1...AudioProcessingFormat.maximumChannelCount).contains(channelCount) else {
      throw NetworkAudioPacketError.invalidChannelCount(channelCount)
    }
    self.sampleRate = sampleRate
    self.channelCount = channelCount
  }
}

/// A validated version-1 PCM datagram.
public struct NetworkAudioPacket: Equatable, Sendable {
  /// The sender session that owns the monotonically increasing sequence.
  public let sessionID: UUID

  /// The zero-based packet sequence within the sender session.
  public let sequence: UInt64

  /// The PCM format represented by the payload.
  public let format: NetworkAudioStreamFormat

  /// The complete sample-frame count represented by the payload.
  public let frameCount: Int

  /// Interleaved little-endian Float32 samples.
  public let payload: Data

  /// Creates a packet after validating its exact payload size.
  public init(
    sessionID: UUID,
    sequence: UInt64,
    format: NetworkAudioStreamFormat,
    frameCount: Int,
    payload: Data
  ) throws {
    guard frameCount > 0 else {
      throw NetworkAudioPacketError.invalidFrameCount(frameCount)
    }
    let expectedByteCount = try Self.payloadByteCount(
      channelCount: format.channelCount,
      frameCount: frameCount
    )
    guard payload.count == expectedByteCount else {
      throw NetworkAudioPacketError.payloadSizeMismatch(
        expected: expectedByteCount,
        actual: payload.count
      )
    }
    self.sessionID = sessionID
    self.sequence = sequence
    self.format = format
    self.frameCount = frameCount
    self.payload = payload
  }

  private static func payloadByteCount(channelCount: Int, frameCount: Int) throws -> Int {
    let sampleCount = channelCount.multipliedReportingOverflow(by: frameCount)
    guard !sampleCount.overflow else { throw NetworkAudioPacketError.datagramTooLarge }
    let byteCount = sampleCount.partialValue.multipliedReportingOverflow(
      by: MemoryLayout<Float>.stride
    )
    guard !byteCount.overflow,
      byteCount.partialValue <= NetworkAudioPacketCodec.maximumPayloadByteCount
    else {
      throw NetworkAudioPacketError.datagramTooLarge
    }
    return byteCount.partialValue
  }
}

/// A framing or validation failure for an untrusted network datagram.
public enum NetworkAudioPacketError: Error, Equatable, LocalizedError, Sendable {
  /// The datagram does not begin with the Rilliya network-audio marker.
  case invalidMagic

  /// The peer uses a protocol version this decoder does not understand.
  case unsupportedVersion(UInt8)

  /// The datagram advertises an unsupported PCM encoding.
  case unsupportedEncoding(UInt8)

  /// Reserved protocol bits are nonzero.
  case unsupportedFlags(UInt16)

  /// The advertised sample rate cannot be represented safely.
  case invalidSampleRate(Double)

  /// The advertised channel count is outside the processing bound.
  case invalidChannelCount(Int)

  /// The advertised frame count is empty or outside the datagram bound.
  case invalidFrameCount(Int)

  /// The datagram ended before its fixed header or advertised payload.
  case truncated

  /// The payload length does not match its channel and frame metadata.
  case payloadSizeMismatch(expected: Int, actual: Int)

  /// The complete datagram exceeds the protocol's defensive limit.
  case datagramTooLarge

  /// A human-readable explanation suitable for diagnostics.
  public var errorDescription: String? {
    switch self {
    case .invalidMagic:
      "The datagram is not Rilliya network audio."
    case .unsupportedVersion(let version):
      "Network audio protocol version \(version) is not supported."
    case .unsupportedEncoding(let encoding):
      "Network audio encoding \(encoding) is not supported."
    case .unsupportedFlags(let flags):
      "Network audio flags \(flags) are not supported."
    case .invalidSampleRate(let sampleRate):
      "The network sample rate must be a whole value between 1 and 768,000 Hz; received \(sampleRate)."
    case .invalidChannelCount(let channelCount):
      "The network channel count must be between 1 and 256; received \(channelCount)."
    case .invalidFrameCount(let frameCount):
      "The network packet must contain at least one bounded sample frame; received \(frameCount)."
    case .truncated:
      "The network audio datagram is incomplete."
    case .payloadSizeMismatch(let expected, let actual):
      "The network audio payload contains \(actual) bytes instead of \(expected)."
    case .datagramTooLarge:
      "The network audio datagram exceeds the bounded protocol size."
    }
  }
}

/// Encodes and validates the stable version-1 Rilliya network-audio wire format.
public enum NetworkAudioPacketCodec {
  /// The current wire-format version.
  public static let version: UInt8 = 1

  /// The byte count of the fixed version-1 header.
  public static let headerByteCount = 48

  /// The largest accepted UDP datagram, including the fixed header.
  public static let maximumDatagramByteCount = 16_384

  /// The largest accepted encoded PCM payload.
  public static let maximumPayloadByteCount =
    maximumDatagramByteCount - headerByteCount

  private static let magic: UInt32 = 0x524C_5941  // RLYA
  private static let interleavedFloat32Encoding: UInt8 = 1

  /// Serializes a validated packet using network byte order and little-endian Float32 payloads.
  public static func encode(_ packet: NetworkAudioPacket) throws -> Data {
    let datagramByteCount = headerByteCount + packet.payload.count
    guard datagramByteCount <= maximumDatagramByteCount else {
      throw NetworkAudioPacketError.datagramTooLarge
    }

    var data = Data(capacity: datagramByteCount)
    data.appendInteger(magic)
    data.append(version)
    data.append(interleavedFloat32Encoding)
    data.appendInteger(UInt16(0))
    withUnsafeBytes(of: packet.sessionID.uuid) { data.append(contentsOf: $0) }
    data.appendInteger(packet.sequence)
    data.appendInteger(UInt32(packet.format.sampleRate.rounded()))
    data.appendInteger(UInt16(packet.format.channelCount))
    data.appendInteger(UInt16(packet.frameCount))
    data.appendInteger(UInt32(packet.payload.count))
    data.appendInteger(UInt32(0))
    data.append(packet.payload)
    return data
  }

  /// The datagram size for a planar frame count, without building the packet.
  public static func datagramByteCount(
    channelCount: Int,
    frameCount: Int
  ) -> Int {
    headerByteCount + channelCount * frameCount * MemoryLayout<Float>.stride
  }

  /// Serialises directly into caller-owned storage, interleaving planar channels as it goes.
  ///
  /// The realtime sender calls this once per packet, so it allocates nothing and makes one pass
  /// over the samples rather than building an interleaved payload first.
  public static func encode(
    sessionID: UUID,
    sequence: UInt64,
    format: NetworkAudioStreamFormat,
    frameCount: Int,
    planarChannels: UnsafeBufferPointer<UnsafePointer<Float>>,
    into destination: UnsafeMutableRawBufferPointer
  ) throws -> Int {
    guard frameCount > 0, frameCount <= Int(UInt16.max) else {
      throw NetworkAudioPacketError.invalidFrameCount(frameCount)
    }
    guard planarChannels.count >= format.channelCount else {
      throw NetworkAudioPacketError.invalidChannelCount(planarChannels.count)
    }
    let payloadByteCount = format.channelCount * frameCount * MemoryLayout<Float>.stride
    let datagramByteCount = headerByteCount + payloadByteCount
    guard datagramByteCount <= maximumDatagramByteCount,
      destination.count >= datagramByteCount
    else {
      throw NetworkAudioPacketError.datagramTooLarge
    }

    var cursor = DatagramWriter(destination: destination)
    cursor.appendInteger(magic)
    cursor.appendByte(version)
    cursor.appendByte(interleavedFloat32Encoding)
    cursor.appendInteger(UInt16(0))
    withUnsafeBytes(of: sessionID.uuid) { cursor.appendBytes($0) }
    cursor.appendInteger(sequence)
    cursor.appendInteger(UInt32(format.sampleRate.rounded()))
    cursor.appendInteger(UInt16(format.channelCount))
    cursor.appendInteger(UInt16(frameCount))
    cursor.appendInteger(UInt32(payloadByteCount))
    cursor.appendInteger(UInt32(0))

    let samples = destination.baseAddress!
      .advanced(by: headerByteCount)
      .assumingMemoryBound(to: UInt32.self)
    var index = 0
    for frame in 0..<frameCount {
      for channel in 0..<format.channelCount {
        let sample = planarChannels[channel][frame]
        samples[index] = (sample.isFinite ? sample : 0).bitPattern.littleEndian
        index += 1
      }
    }
    return datagramByteCount
  }

  /// Parses one untrusted datagram and rejects malformed metadata before exposing its payload.
  public static func decode(_ data: Data) throws -> NetworkAudioPacket {
    guard data.count <= maximumDatagramByteCount else {
      throw NetworkAudioPacketError.datagramTooLarge
    }
    guard data.count >= headerByteCount else { throw NetworkAudioPacketError.truncated }
    var cursor = DataCursor(data: data)
    guard try cursor.readInteger(as: UInt32.self) == magic else {
      throw NetworkAudioPacketError.invalidMagic
    }
    let decodedVersion = try cursor.readByte()
    guard decodedVersion == version else {
      throw NetworkAudioPacketError.unsupportedVersion(decodedVersion)
    }
    let encoding = try cursor.readByte()
    guard encoding == interleavedFloat32Encoding else {
      throw NetworkAudioPacketError.unsupportedEncoding(encoding)
    }
    let flags = try cursor.readInteger(as: UInt16.self)
    guard flags == 0 else { throw NetworkAudioPacketError.unsupportedFlags(flags) }
    let sessionID = try cursor.readUUID()
    let sequence = try cursor.readInteger(as: UInt64.self)
    let sampleRateValue = try cursor.readInteger(as: UInt32.self)
    let channelCount = Int(try cursor.readInteger(as: UInt16.self))
    let frameCount = Int(try cursor.readInteger(as: UInt16.self))
    let payloadByteCount = Int(try cursor.readInteger(as: UInt32.self))
    _ = try cursor.readInteger(as: UInt32.self)

    let format = try NetworkAudioStreamFormat(
      sampleRate: Double(sampleRateValue),
      channelCount: channelCount
    )
    let expected = channelCount.multipliedReportingOverflow(by: frameCount)
    guard !expected.overflow else { throw NetworkAudioPacketError.datagramTooLarge }
    let expectedBytes = expected.partialValue.multipliedReportingOverflow(
      by: MemoryLayout<Float>.stride
    )
    guard !expectedBytes.overflow else { throw NetworkAudioPacketError.datagramTooLarge }
    guard frameCount > 0 else {
      throw NetworkAudioPacketError.invalidFrameCount(frameCount)
    }
    guard payloadByteCount == expectedBytes.partialValue else {
      throw NetworkAudioPacketError.payloadSizeMismatch(
        expected: expectedBytes.partialValue,
        actual: payloadByteCount
      )
    }
    guard cursor.remainingByteCount == payloadByteCount else {
      if cursor.remainingByteCount < payloadByteCount {
        throw NetworkAudioPacketError.truncated
      }
      throw NetworkAudioPacketError.payloadSizeMismatch(
        expected: payloadByteCount,
        actual: cursor.remainingByteCount
      )
    }
    return try NetworkAudioPacket(
      sessionID: sessionID,
      sequence: sequence,
      format: format,
      frameCount: frameCount,
      payload: try cursor.readData(byteCount: payloadByteCount)
    )
  }
}

extension Data {
  fileprivate mutating func appendInteger<Integer: FixedWidthInteger>(_ value: Integer) {
    var networkValue = value.bigEndian
    Swift.withUnsafeBytes(of: &networkValue) { append(contentsOf: $0) }
  }
}

private struct DatagramWriter {
  let destination: UnsafeMutableRawBufferPointer
  private var offset = 0

  init(destination: UnsafeMutableRawBufferPointer) {
    self.destination = destination
  }

  mutating func appendByte(_ value: UInt8) {
    destination[offset] = value
    offset += 1
  }

  mutating func appendInteger<Integer: FixedWidthInteger>(_ value: Integer) {
    withUnsafeBytes(of: value.bigEndian) { appendBytes($0) }
  }

  mutating func appendBytes(_ bytes: UnsafeRawBufferPointer) {
    for byte in bytes {
      destination[offset] = byte
      offset += 1
    }
  }
}

private struct DataCursor {
  let data: Data
  private(set) var offset = 0

  var remainingByteCount: Int { data.count - offset }

  mutating func readByte() throws -> UInt8 {
    guard offset < data.count else { throw NetworkAudioPacketError.truncated }
    defer { offset += 1 }
    return data[offset]
  }

  mutating func readInteger<Integer: FixedWidthInteger>(as: Integer.Type) throws -> Integer {
    let byteCount = MemoryLayout<Integer>.size
    guard remainingByteCount >= byteCount else { throw NetworkAudioPacketError.truncated }
    var value: Integer = 0
    for byte in data[offset..<(offset + byteCount)] {
      value = (value << 8) | Integer(byte)
    }
    offset += byteCount
    return value
  }

  mutating func readUUID() throws -> UUID {
    guard remainingByteCount >= 16 else { throw NetworkAudioPacketError.truncated }
    let bytes = Array(data[offset..<(offset + 16)])
    offset += 16
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
      )
    )
  }

  mutating func readData(byteCount: Int) throws -> Data {
    guard byteCount >= 0, remainingByteCount >= byteCount else {
      throw NetworkAudioPacketError.truncated
    }
    defer { offset += byteCount }
    return data.subdata(in: offset..<(offset + byteCount))
  }
}
