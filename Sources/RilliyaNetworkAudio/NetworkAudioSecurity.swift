// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// A failure while establishing or applying network audio encryption.
public enum NetworkAudioSecurityError: Error, Equatable, LocalizedError, Sendable {
  /// A shared key must carry the full key length.
  case invalidKeyLength(Int)

  /// The pasted key is not valid base64.
  case malformedKeyText

  /// The datagram is encrypted and this receiver has no key.
  case encryptionRequired

  /// The datagram is unencrypted and this receiver expects encryption.
  ///
  /// Accepting it would let anyone who can reach the port bypass the key entirely.
  case unexpectedPlaintext

  /// The datagram did not authenticate under this key.
  case authenticationFailed

  /// A localized explanation suitable for diagnostics.
  public var errorDescription: String? {
    switch self {
    case .invalidKeyLength(let count):
      "A network audio key must be \(NetworkAudioSharedKey.byteCount) bytes; received \(count)."
    case .malformedKeyText:
      "The network audio key is not valid base64."
    case .encryptionRequired:
      "The peer encrypted this audio and no key is configured."
    case .unexpectedPlaintext:
      "The peer sent unencrypted audio while a key is configured."
    case .authenticationFailed:
      "The network audio datagram did not authenticate."
    }
  }
}

/// The secret two peers share so each can tell the other's audio from anyone else's.
///
/// The key is random rather than derived from a passphrase: a passphrase would need a password
/// hash to resist guessing, and pairing two machines the user owns can just move 32 random bytes.
public struct NetworkAudioSharedKey: Equatable, Hashable, Sendable {
  /// The key length, matching AES-256.
  public static let byteCount = 32

  let key: SymmetricKey

  /// Wraps key material already known to be the right length.
  private init(validated key: SymmetricKey) {
    self.key = key
  }

  /// Wraps existing key material.
  public init(_ key: SymmetricKey) throws {
    guard key.bitCount == Self.byteCount * 8 else {
      throw NetworkAudioSecurityError.invalidKeyLength(key.bitCount / 8)
    }
    self.key = key
  }

  /// Generates a key to show the user for pairing.
  public static func random() -> NetworkAudioSharedKey {
    NetworkAudioSharedKey(validated: SymmetricKey(size: SymmetricKeySize(bitCount: byteCount * 8)))
  }

  /// Reads a key the user pasted from the other machine.
  public init(base64Encoded text: String) throws {
    guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      throw NetworkAudioSecurityError.malformedKeyText
    }
    guard data.count == Self.byteCount else {
      throw NetworkAudioSecurityError.invalidKeyLength(data.count)
    }
    key = SymmetricKey(data: data)
  }

  /// The key as text the user can copy to the other machine.
  public var base64EncodedString: String {
    key.withUnsafeBytes { Data($0).base64EncodedString() }
  }

  /// Compares the key material itself, so two wrappers around one key are equal.
  public static func == (lhs: NetworkAudioSharedKey, rhs: NetworkAudioSharedKey) -> Bool {
    lhs.key == rhs.key
  }

  /// Hashes the key material, matching ``==(_:_:)``.
  public func hash(into hasher: inout Hasher) {
    key.withUnsafeBytes { hasher.combine(bytes: $0) }
  }
}

extension NetworkAudioSharedKey: CustomStringConvertible, CustomDebugStringConvertible {
  /// Redacted, so a configuration that reaches a log does not carry the key with it.
  ///
  /// ``base64EncodedString`` is the deliberate way to read it.
  public var description: String { "NetworkAudioSharedKey(redacted)" }

  /// Redacted, matching ``description``.
  public var debugDescription: String { description }
}

/// Authenticated encryption for one sender session.
///
/// The session key is derived from the shared key and the sender's session identifier, and the
/// nonce is the packet sequence. Together those give every packet a nonce that is unique under
/// its key without any state to keep in sync, and a restart derives a fresh key rather than
/// replaying nonces under the old one.
///
/// Measured here, sealing 1024 bytes costs about a microsecond, so this runs on the sender's
/// realtime thread rather than adding a handoff.
public struct NetworkAudioSessionCipher: Sendable {
  /// The authentication tag appended to every encrypted datagram.
  public static let tagByteCount = 16

  /// The AES-GCM nonce length.
  static let nonceByteCount = 12

  private static let derivationInfo = Data("moe.uwucocoa.rilliya.network-audio.v1".utf8)

  private let sessionKey: SymmetricKey

  /// Derives the key one session uses.
  public init(sharedKey: NetworkAudioSharedKey, sessionID: UUID) {
    let salt = withUnsafeBytes(of: sessionID.uuid) { Data($0) }
    sessionKey = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: sharedKey.key,
      salt: salt,
      info: Self.derivationInfo,
      outputByteCount: NetworkAudioSharedKey.byteCount
    )
  }

  /// Encrypts a payload in place and appends its tag.
  ///
  /// - Returns: the bytes written, which is the payload length plus the tag.
  @discardableResult
  public func seal(
    payload: UnsafeMutableRawBufferPointer,
    sequence: UInt64,
    authenticating header: UnsafeRawBufferPointer
  ) throws -> Int {
    guard let base = payload.baseAddress else {
      throw NetworkAudioSecurityError.encryptionRequired
    }
    let box = try AES.GCM.seal(
      UnsafeRawBufferPointer(payload),
      using: sessionKey,
      nonce: try Self.nonce(sequence: sequence),
      authenticating: header
    )
    guard box.ciphertext.count == payload.count else {
      throw NetworkAudioSecurityError.encryptionRequired
    }
    box.ciphertext.copyBytes(to: payload)
    box.tag.copyBytes(
      to: UnsafeMutableRawBufferPointer(
        start: base.advanced(by: payload.count),
        count: Self.tagByteCount
      )
    )
    return payload.count + Self.tagByteCount
  }

  /// Decrypts a payload in place after checking its tag.
  public func open(
    payload: UnsafeMutableRawBufferPointer,
    tag: UnsafeRawBufferPointer,
    sequence: UInt64,
    authenticating header: UnsafeRawBufferPointer
  ) throws {
    let box: AES.GCM.SealedBox
    do {
      box = try AES.GCM.SealedBox(
        nonce: try Self.nonce(sequence: sequence),
        ciphertext: UnsafeRawBufferPointer(payload),
        tag: tag
      )
    } catch {
      throw NetworkAudioSecurityError.authenticationFailed
    }
    guard
      let plaintext = try? AES.GCM.open(box, using: sessionKey, authenticating: header)
    else {
      throw NetworkAudioSecurityError.authenticationFailed
    }
    precondition(plaintext.count == payload.count)
    plaintext.copyBytes(to: payload)
  }

  /// The nonce for one packet.
  ///
  /// Every packet in a session has a distinct sequence, and every session derives its own key, so
  /// no nonce is ever used twice under one key.
  static func nonce(sequence: UInt64) throws -> AES.GCM.Nonce {
    var bytes = [UInt8](repeating: 0, count: nonceByteCount)
    withUnsafeBytes(of: sequence.bigEndian) { source in
      for index in 0..<source.count { bytes[nonceByteCount - source.count + index] = source[index] }
    }
    return try AES.GCM.Nonce(data: bytes)
  }
}
