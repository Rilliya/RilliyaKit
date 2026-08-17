// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Supplies the key two peers share for one session.
///
/// The transport needs 32 bytes and nothing else. Where they come from is a question this
/// deliberately does not answer: a key typed by hand, one kept in a keychain, one released by a
/// key management service after a sign-in, one held on a hardware token. Anything that can produce
/// the same bytes on both machines belongs here, and none of it belongs in a transport.
///
/// ## Asked once a run
///
/// A sender or receiver asks before it starts and holds what it is given for that whole run. The
/// session key is derived from these bytes and the run's identity, so a provider that returned
/// something different partway through would leave the two peers unable to hear each other with
/// nothing to say why.
///
/// A credential that expires should therefore fail the next start rather than change under a
/// running session — throw, and let the run end and be started again.
///
/// ## What a provider is trusted with
///
/// Everything. These bytes are the whole of the confidentiality and the whole of the peer
/// authentication: anything that knows them can read the audio and can send audio that will be
/// accepted. A provider that hands the same bytes to two different people has joined them to the
/// same session, whatever it checked before doing so.
public protocol NetworkAudioKeyProvider: Sendable {
  /// The key both peers share.
  ///
  /// - Throws: whatever stopped it. A sender or receiver reports the failure and does not start.
  func sharedKey() async throws -> NetworkAudioSharedKey
}

/// A provider for a key already in hand.
///
/// What a caller uses when it has the bytes: typed in, read from a file, unwrapped from a keychain
/// before starting. Providers that have to go and ask for something are the reason the protocol
/// exists; this is the case that does not.
public struct NetworkAudioStaticKeyProvider: NetworkAudioKeyProvider {
  private let key: NetworkAudioSharedKey

  /// Wraps a key that is already known.
  public init(_ key: NetworkAudioSharedKey) {
    self.key = key
  }

  /// The key this was created with.
  public func sharedKey() async throws -> NetworkAudioSharedKey {
    key
  }
}
