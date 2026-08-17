// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Why a retransmission request could not be read or written.
public enum NetworkAudioRetransmissionError: Error, Equatable, Sendable {
  /// The datagram is not a retransmission request.
  case invalidMagic

  /// The request names a protocol version this build does not speak.
  case unsupportedVersion(UInt8)

  /// The request names a message type this build does not speak.
  case unsupportedType(UInt8)

  /// The request sets flags this build does not speak.
  case unsupportedFlags(UInt16)

  /// The request ended before what it declared.
  case truncated

  /// The request asks for more sequences than one request may carry.
  case tooManySequences(Int)

  /// The request asks for nothing.
  case empty

  /// The request is encrypted and this sender has no key, or the reverse.
  case security(NetworkAudioSecurityError)
}

extension NetworkAudioRetransmissionError: LocalizedError {
  /// A human-readable explanation suitable for application diagnostics.
  public var errorDescription: String? {
    switch self {
    case .invalidMagic:
      "The datagram is not a Rilliya retransmission request."
    case .unsupportedVersion(let version):
      "Retransmission protocol version \(version) is not supported."
    case .unsupportedType(let type):
      "Retransmission message type \(type) is not supported."
    case .unsupportedFlags(let flags):
      "Retransmission flags \(flags) are not supported."
    case .truncated:
      "The retransmission request ended before its declared sequences."
    case .tooManySequences(let count):
      "A retransmission request may name at most "
        + "\(NetworkAudioRetransmissionRequest.maximumSequenceCount) sequences; it named \(count)."
    case .empty:
      "A retransmission request must name at least one sequence."
    case .security(let error):
      error.errorDescription
    }
  }
}

/// A receiver asking a sender to send named packets again.
///
/// The request travels back along the flow the audio arrived on, so it reaches the sender without
/// a second port and can only be produced by whoever holds that flow's addresses. Where a key is
/// configured it is also sealed under the session key, in a nonce space disjoint from the audio's.
public struct NetworkAudioRetransmissionRequest: Equatable, Sendable {
  /// The sender session the sequences belong to.
  ///
  /// A sender that has restarted derives a new session, and a request naming the old one asks for
  /// audio that no longer exists.
  public let sessionID: UUID

  /// The request's own sequence, which orders requests and gives each its own nonce.
  public let sequence: UInt64

  /// The packet sequences being asked for, in ascending order.
  public let sequences: [UInt64]

  /// The most sequences one request may name.
  ///
  /// A request is small and its answer is not, so what one request can ask for is capped: this
  /// bounds how much a single datagram can make a sender send.
  public static let maximumSequenceCount = 8

  /// The bytes ahead of the sequences.
  ///
  /// Magic, version, type and flags, then the session, the request's sequence, how many it names,
  /// and a reserved word.
  public static let headerByteCount = 4 + 1 + 1 + 2 + 16 + 8 + 2 + 2

  /// The largest request this build writes or reads.
  public static let maximumByteCount =
    headerByteCount + maximumSequenceCount * MemoryLayout<UInt64>.size
    + NetworkAudioSessionCipher.tagByteCount

  private static let magic: UInt32 = 0x524C_5943  // RLYC
  private static let version: UInt8 = 1
  private static let requestType: UInt8 = 1
  private static let encryptedFlag: UInt16 = 0x0001

  /// Creates a request after validating what it names.
  public init(sessionID: UUID, sequence: UInt64, sequences: [UInt64]) throws {
    guard !sequences.isEmpty else { throw NetworkAudioRetransmissionError.empty }
    guard sequences.count <= Self.maximumSequenceCount else {
      throw NetworkAudioRetransmissionError.tooManySequences(sequences.count)
    }
    self.sessionID = sessionID
    self.sequence = sequence
    self.sequences = sequences.sorted()
  }

  /// Writes this request as a datagram.
  public func encoded(cipher: NetworkAudioSessionCipher? = nil) throws -> Data {
    var data = Data(capacity: Self.maximumByteCount)
    data.appendInteger(Self.magic)
    data.append(Self.version)
    data.append(Self.requestType)
    data.appendInteger(cipher == nil ? UInt16(0) : Self.encryptedFlag)
    withUnsafeBytes(of: sessionID.uuid) { data.append(contentsOf: $0) }
    data.appendInteger(sequence)
    data.appendInteger(UInt16(sequences.count))
    data.appendInteger(UInt16(0))
    let headerByteCount = data.count
    precondition(headerByteCount == Self.headerByteCount)

    for value in sequences { data.appendInteger(value) }
    guard let cipher else { return data }

    let bodyByteCount = data.count - headerByteCount
    data.append(Data(count: NetworkAudioSessionCipher.tagByteCount))
    try data.withUnsafeMutableBytes { bytes in
      guard let base = bytes.baseAddress else {
        throw NetworkAudioRetransmissionError.truncated
      }
      _ = try cipher.seal(
        payload: UnsafeMutableRawBufferPointer(
          start: base.advanced(by: headerByteCount),
          count: bodyByteCount
        ),
        sequence: sequence,
        domain: .control,
        authenticating: UnsafeRawBufferPointer(start: base, count: headerByteCount)
      )
    }
    return data
  }

  /// Reads a request, refusing anything a sender should not act on.
  ///
  /// - Throws: ``NetworkAudioRetransmissionError`` for anything malformed, and
  ///   ``NetworkAudioSecurityError`` where the request and the sender disagree about encryption.
  public static func decode(
    _ data: Data,
    cipher: NetworkAudioSessionCipher? = nil
  ) throws -> NetworkAudioRetransmissionRequest {
    guard data.count <= maximumByteCount else {
      throw NetworkAudioRetransmissionError.tooManySequences(data.count)
    }
    guard data.count >= headerByteCount else {
      throw NetworkAudioRetransmissionError.truncated
    }
    var cursor = DataCursor(data: data)
    guard try cursor.readInteger(as: UInt32.self) == magic else {
      throw NetworkAudioRetransmissionError.invalidMagic
    }
    let decodedVersion = try cursor.readByte()
    guard decodedVersion == version else {
      throw NetworkAudioRetransmissionError.unsupportedVersion(decodedVersion)
    }
    let decodedType = try cursor.readByte()
    guard decodedType == requestType else {
      throw NetworkAudioRetransmissionError.unsupportedType(decodedType)
    }
    let flags = try cursor.readInteger(as: UInt16.self)
    guard flags & ~encryptedFlag == 0 else {
      throw NetworkAudioRetransmissionError.unsupportedFlags(flags)
    }
    let isEncrypted = flags & encryptedFlag != 0
    guard !isEncrypted || cipher != nil else {
      throw NetworkAudioRetransmissionError.security(.encryptionRequired)
    }
    // Acting on a request in the clear while a key is configured would let anyone who can reach
    // the flow make the sender send.
    guard isEncrypted || cipher == nil else {
      throw NetworkAudioRetransmissionError.security(.unexpectedPlaintext)
    }
    let sessionID = try cursor.readUUID()
    let sequence = try cursor.readInteger(as: UInt64.self)
    let count = Int(try cursor.readInteger(as: UInt16.self))
    _ = try cursor.readInteger(as: UInt16.self)
    guard count > 0 else { throw NetworkAudioRetransmissionError.empty }
    guard count <= maximumSequenceCount else {
      throw NetworkAudioRetransmissionError.tooManySequences(count)
    }

    let bodyByteCount = count * MemoryLayout<UInt64>.size
    let tagByteCount = isEncrypted ? NetworkAudioSessionCipher.tagByteCount : 0
    guard cursor.remainingByteCount == bodyByteCount + tagByteCount else {
      throw NetworkAudioRetransmissionError.truncated
    }
    var body = try cursor.readData(byteCount: bodyByteCount)
    if let cipher {
      let tag = try cursor.readData(byteCount: tagByteCount)
      try body.withUnsafeMutableBytes { plaintext in
        try data.prefix(headerByteCount).withUnsafeBytes { header in
          try tag.withUnsafeBytes { tagBytes in
            try cipher.open(
              payload: plaintext,
              tag: tagBytes,
              sequence: sequence,
              domain: .control,
              authenticating: header
            )
          }
        }
      }
    }

    var sequences: [UInt64] = []
    sequences.reserveCapacity(count)
    var bodyCursor = DataCursor(data: body)
    for _ in 0..<count { sequences.append(try bodyCursor.readInteger(as: UInt64.self)) }
    return try NetworkAudioRetransmissionRequest(
      sessionID: sessionID,
      sequence: sequence,
      sequences: sequences
    )
  }
}
