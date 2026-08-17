// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network

/// Why discovering a sender's format did not finish.
public enum NetworkAudioFormatDiscoveryError: Error, Equatable, Sendable {
  /// No packet a receiver would accept arrived before the deadline.
  case timedOut

  /// The local UDP port is outside the valid range.
  case invalidPort

  /// The deadline is not a positive duration.
  case invalidTimeout

  /// Network.framework could not open or maintain the listener.
  case transport(NetworkAudioTransportFailure)
}

extension NetworkAudioFormatDiscoveryError: LocalizedError {
  /// A human-readable explanation suitable for application diagnostics.
  public var errorDescription: String? {
    switch self {
    case .timedOut:
      "No network audio arrived on this port, so its format is still unknown."
    case .invalidPort:
      "The network audio listener port must be between 1 and 65,535."
    case .invalidTimeout:
      "The format discovery deadline must be a positive duration."
    case .transport(let failure):
      "Listening for the sender's format failed: \(failure.description)."
    }
  }
}

/// Reports the PCM format a sender is using, by listening for one packet of it.
///
/// A receiver is built around one fixed format: its queues, its jitter target and the graph that
/// drains it all size themselves from it. Discovering the format first and building afterwards
/// keeps that so, at the cost of the packets that arrive while the port is handed over — which
/// the receiver's own prefill would be discarding anyway.
///
/// A packet is only believed once it decodes, so a configured key is what decides whose format is
/// adopted. Reading the header alone would let anyone who can reach the port choose it.
public enum NetworkAudioFormatDiscovery {
  /// Listens on `port` until one acceptable packet arrives, and reports the format it carries.
  ///
  /// - Parameters:
  ///   - port: the local UDP port to listen on.
  ///   - sharedKey: the key the sender is using, or `nil` to accept audio in the clear.
  ///   - maximumDatagramByteCount: the largest datagram considered.
  ///   - timeout: how long to wait before giving up.
  /// - Returns: the format the first accepted packet declares.
  /// - Throws: ``NetworkAudioFormatDiscoveryError`` when the port cannot be opened, the deadline
  ///   passes with nothing acceptable on it, or the controls are outside the bounded policy.
  public static func discover(
    port: UInt16,
    sharedKey: NetworkAudioSharedKey? = nil,
    maximumDatagramByteCount: Int = NetworkAudioSenderConfiguration
      .defaultMaximumDatagramByteCount,
    timeout: Duration = .seconds(30)
  ) async throws -> NetworkAudioStreamFormat {
    // Port zero is a valid endpoint meaning "any port", which is never what a listener wants.
    guard port > 0, let listenerPort = NWEndpoint.Port(rawValue: port) else {
      throw NetworkAudioFormatDiscoveryError.invalidPort
    }
    guard timeout > .zero else { throw NetworkAudioFormatDiscoveryError.invalidTimeout }

    let session = DiscoverySession(
      sharedKey: sharedKey,
      maximumDatagramByteCount: maximumDatagramByteCount
    )
    return try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: NetworkAudioStreamFormat.self) { group in
        group.addTask { try await session.listen(on: listenerPort) }
        group.addTask {
          try await Task.sleep(for: timeout)
          throw NetworkAudioFormatDiscoveryError.timedOut
        }
        // Closing before the group waits on its children is what ends the listen: a continuation
        // does not answer cancellation, so whichever task loses has to be resumed here.
        defer {
          session.close()
          group.cancelAll()
        }
        guard let format = try await group.next() else {
          throw NetworkAudioFormatDiscoveryError.timedOut
        }
        return format
      }
    } onCancel: {
      session.close()
    }
  }
}

/// Owns one short-lived listener, so cancelling from any task closes the same port.
private final class DiscoverySession: @unchecked Sendable {
  private let sharedKey: NetworkAudioSharedKey?
  private let maximumDatagramByteCount: Int
  private let queue = DispatchQueue(
    label: "moe.uwucocoa.RilliyaKit.network-audio-format-discovery",
    qos: .userInitiated
  )
  private let lock = NSLock()
  private var listener: NWListener?
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var continuation: CheckedContinuation<NetworkAudioStreamFormat, any Error>?
  private var isFinished = false
  private var cipherSessionID: UUID?
  private var cipher: NetworkAudioSessionCipher?

  init(sharedKey: NetworkAudioSharedKey?, maximumDatagramByteCount: Int) {
    self.sharedKey = sharedKey
    self.maximumDatagramByteCount = maximumDatagramByteCount
  }

  func listen(on port: NWEndpoint.Port) async throws -> NetworkAudioStreamFormat {
    try await withCheckedThrowingContinuation { continuation in
      let shouldStart = lock.withLock { () -> Bool in
        guard !isFinished else { return false }
        self.continuation = continuation
        return true
      }
      guard shouldStart else {
        continuation.resume(throwing: CancellationError())
        return
      }
      do {
        let listener = try NWListener(using: .udp, on: port)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
          guard case .failed(let error) = state else { return }
          self?.finish(.failure(NetworkAudioFormatDiscoveryError.transport(.init(error))))
        }
        // Published and started only if nothing closed the session while it was being built.
        // `close()` cancels what it can see, and until this runs it can see nothing — so a
        // listener started regardless would hold its port with nobody left to release it.
        let shouldListen = lock.withLock { () -> Bool in
          guard !isFinished else { return false }
          self.listener = listener
          return true
        }
        guard shouldListen else {
          listener.cancel()
          return
        }
        listener.start(queue: queue)
      } catch let error as NWError {
        finish(.failure(NetworkAudioFormatDiscoveryError.transport(.init(error))))
      } catch {
        finish(.failure(error))
      }
    }
  }

  /// Tears the listener down and resumes anyone still waiting on it.
  func close() {
    let resources = lock.withLock { () -> (NWListener?, [NWConnection]) in
      let resources = (listener, Array(connections.values))
      listener = nil
      connections.removeAll(keepingCapacity: false)
      return resources
    }
    resources.0?.cancel()
    for connection in resources.1 { connection.cancel() }
    finish(.failure(CancellationError()))
  }

  private func accept(_ connection: NWConnection) {
    let shouldAccept = lock.withLock { () -> Bool in
      guard !isFinished else { return false }
      connections[ObjectIdentifier(connection)] = connection
      return true
    }
    guard shouldAccept else {
      connection.cancel()
      return
    }
    connection.start(queue: queue)
    receiveNext(on: connection)
  }

  private func receiveNext(on connection: NWConnection) {
    connection.receiveMessage { [weak self, weak connection] content, _, _, error in
      guard let self, let connection else { return }
      if let content, let format = format(of: content) {
        finish(.success(format))
        return
      }
      if error == nil {
        receiveNext(on: connection)
      } else {
        lock.withLock { connections[ObjectIdentifier(connection)] = nil }
      }
    }
  }

  /// The format of one datagram, or `nil` when a receiver would not have accepted it.
  private func format(of data: Data) -> NetworkAudioStreamFormat? {
    guard data.count <= maximumDatagramByteCount else { return nil }
    return lock.withLock {
      do {
        let cipher = try resolveCipher(for: data)
        return try NetworkAudioPacketCodec.decode(data, cipher: cipher).format
      } catch {
        return nil
      }
    }
  }

  private func resolveCipher(for data: Data) throws -> NetworkAudioSessionCipher? {
    guard let sharedKey else { return nil }
    let sessionID = try NetworkAudioPacketCodec.sessionID(of: data)
    if cipherSessionID != sessionID {
      cipher = NetworkAudioSessionCipher(sharedKey: sharedKey, sessionID: sessionID)
      cipherSessionID = sessionID
    }
    return cipher
  }

  private func finish(_ result: Result<NetworkAudioStreamFormat, any Error>) {
    let continuation = lock.withLock {
      () -> CheckedContinuation<NetworkAudioStreamFormat, any Error>? in
      guard !isFinished else { return nil }
      isFinished = true
      let pending = self.continuation
      self.continuation = nil
      return pending
    }
    continuation?.resume(with: result)
  }
}
