// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network
import RilliyaRealtime

/// Bounded controls for one direct UDP network-audio receiver.
public struct NetworkAudioReceiverConfiguration: Equatable, Hashable, Sendable {
  /// The local UDP port.
  public let port: UInt16

  /// The exact PCM format accepted from a peer.
  public let format: NetworkAudioStreamFormat

  /// The fixed network-to-render queue capacity.
  public let capacityFrameCount: Int

  /// The largest accepted datagram, including its protocol header.
  public let maximumDatagramByteCount: Int

  /// The quiet interval after which a different sender session may take ownership.
  public let sessionTakeoverInterval: Duration

  /// How much audio the receiver holds before a render callback may read it.
  public let jitter: AudioJitterBufferConfiguration

  /// Creates validated receiver controls with bounded packet and PCM storage.
  public init(
    port: UInt16,
    format: NetworkAudioStreamFormat,
    capacityFrameCount: Int = 32_768,
    maximumDatagramByteCount: Int = NetworkAudioSenderConfiguration
      .defaultMaximumDatagramByteCount,
    sessionTakeoverInterval: Duration = .seconds(1),
    jitter: AudioJitterBufferConfiguration = .localNetwork
  ) throws {
    guard port > 0 else { throw NetworkAudioReceiverError.invalidPort }
    let minimumDatagramByteCount =
      NetworkAudioPacketCodec.headerByteCount
      + format.channelCount * MemoryLayout<Float>.stride
    guard
      (minimumDatagramByteCount...NetworkAudioPacketCodec.maximumDatagramByteCount)
        .contains(maximumDatagramByteCount)
    else {
      throw NetworkAudioReceiverError.invalidDatagramBound
    }
    guard
      (2...AudioRealtimeFrameBuffer.maximumCapacityFrameCount).contains(capacityFrameCount)
    else {
      throw NetworkAudioReceiverError.invalidBufferCapacity
    }
    guard sessionTakeoverInterval >= .zero, sessionTakeoverInterval <= .seconds(60) else {
      throw NetworkAudioReceiverError.invalidTakeoverInterval
    }
    self.port = port
    self.format = format
    self.capacityFrameCount = capacityFrameCount
    self.maximumDatagramByteCount = maximumDatagramByteCount
    self.sessionTakeoverInterval = sessionTakeoverInterval
    self.jitter = jitter
  }
}

/// A typed direct-network receiver failure.
public enum NetworkAudioReceiverError: Error, Equatable, LocalizedError, Sendable {
  /// UDP port zero is not a valid listener endpoint.
  case invalidPort

  /// The packet size cannot carry one complete frame or exceeds the protocol bound.
  case invalidDatagramBound

  /// The consumer queue capacity is outside the realtime buffer bound.
  case invalidBufferCapacity

  /// The sender takeover interval is outside the bounded policy.
  case invalidTakeoverInterval

  /// A stopped receiver cannot be started again.
  case alreadyStopped

  /// Network.framework could not create or maintain the listener.
  case transport(NetworkAudioTransportFailure)

  /// A human-readable explanation suitable for application diagnostics.
  public var errorDescription: String? {
    switch self {
    case .invalidPort:
      "The network audio listener port must be between 1 and 65,535."
    case .invalidDatagramBound:
      "The network audio packet bound must fit one complete frame and remain below 16,384 bytes."
    case .invalidBufferCapacity:
      "The network audio receiver buffer capacity must be between 2 and 65,536 frames."
    case .invalidTakeoverInterval:
      "The network audio session takeover interval must be between zero and 60 seconds."
    case .alreadyStopped:
      "A stopped network audio receiver cannot be restarted."
    case .transport(let failure):
      "The network audio receiver failed: \(failure.description)."
    }
  }
}

/// Monotonic diagnostics for one network-audio receiver.
public struct NetworkAudioReceiverStatistics: Equatable, Sendable {
  /// Datagrams accepted into the PCM queue.
  public let acceptedPacketCount: UInt64

  /// Invalid, truncated, oversized, or format-mismatched datagrams.
  public let rejectedPacketCount: UInt64

  /// Datagrams ignored while a different live session owns the port.
  public let foreignSessionPacketCount: UInt64

  /// Duplicate or out-of-order datagrams ignored within the active session.
  public let stalePacketCount: UInt64

  /// Missing packet sequences observed before a later packet arrived.
  public let missingPacketCount: UInt64

  /// Current bounded PCM queue diagnostics.
  public let frameBuffer: AudioRealtimeFrameBufferStatistics
}

/// Receives one versioned direct UDP PCM session into a bounded realtime buffer.
///
/// UDP provides no confidentiality, peer authentication, retransmission, or congestion control.
/// This transport is intended for a trusted local network. Every datagram is length- and
/// format-validated before its samples reach ``frameBuffer``; malformed traffic is discarded.
public final class NetworkAudioReceiver: @unchecked Sendable {
  /// Receives an asynchronous listener failure away from a render callback.
  public typealias FailureHandler = @Sendable (NetworkAudioReceiverError) -> Void

  /// The immutable receiver controls.
  public let configuration: NetworkAudioReceiverConfiguration

  /// The single-consumer PCM queue the ingestor fills.
  public let frameBuffer: AudioRealtimeFrameBuffer

  /// The paced view of ``frameBuffer`` a prepared graph reads.
  ///
  /// Reading the queue directly drains it to empty, which turns every late packet into a gap and
  /// leaves the inserted silence behind as delay.
  public let jitterBuffer: AudioJitterBuffer

  private enum State {
    case ready
    case running
    case stopped
  }

  private let failureHandler: FailureHandler
  private let lock = NSLock()
  private let queue = DispatchQueue(
    label: "moe.uwucocoa.RilliyaKit.network-audio-receiver",
    qos: .userInitiated
  )
  private let ingestor: NetworkAudioPacketIngestor
  private var state = State.ready
  private var listener: NWListener?
  private var connections: [ObjectIdentifier: NWConnection] = [:]

  /// Allocates fixed packet and PCM storage without opening a UDP port.
  public init(
    configuration: NetworkAudioReceiverConfiguration,
    failureHandler: @escaping FailureHandler = { _ in }
  ) throws {
    self.configuration = configuration
    self.failureHandler = failureHandler
    frameBuffer = try AudioRealtimeFrameBuffer(
      format: AudioProcessingFormat(
        sampleRate: configuration.format.sampleRate,
        channelCount: configuration.format.channelCount
      ),
      capacityFrameCount: configuration.capacityFrameCount
    )
    jitterBuffer = try AudioJitterBuffer(
      frameBuffer: frameBuffer,
      configuration: configuration.jitter
    )
    ingestor = NetworkAudioPacketIngestor(
      configuration: configuration,
      frameBuffer: frameBuffer
    )
  }

  deinit {
    lock.withLock {
      listener?.cancel()
      for connection in connections.values { connection.cancel() }
    }
  }

  /// Starts listening on the configured local UDP port.
  public func start() throws {
    try lock.withLock {
      switch state {
      case .running:
        return
      case .stopped:
        throw NetworkAudioReceiverError.alreadyStopped
      case .ready:
        break
      }
      guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
        throw NetworkAudioReceiverError.invalidPort
      }
      do {
        let listener = try NWListener(
          using: .udp,
          on: port
        )
        listener.newConnectionHandler = { [weak self] connection in
          self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
          guard case .failed(let error) = state else { return }
          self?.failureHandler(.transport(.init(error)))
        }
        listener.start(queue: queue)
        self.listener = listener
        state = .running
      } catch let error as NWError {
        throw NetworkAudioReceiverError.transport(.init(error))
      }
    }
  }

  /// Cancels the listener and every accepted UDP flow.
  public func stop() {
    let resources = lock.withLock { () -> (NWListener?, [NWConnection]) in
      state = .stopped
      let resources = (listener, Array(connections.values))
      listener = nil
      connections.removeAll(keepingCapacity: false)
      return resources
    }
    resources.0?.cancel()
    for connection in resources.1 { connection.cancel() }
  }

  /// Returns bounded transport and frame-buffer diagnostics.
  public func statistics() -> NetworkAudioReceiverStatistics {
    ingestor.statistics()
  }

  private func accept(_ connection: NWConnection) {
    lock.withLock { connections[ObjectIdentifier(connection)] = connection }
    connection.start(queue: queue)
    receiveNext(on: connection)
  }

  private func receiveNext(on connection: NWConnection) {
    connection.receiveMessage { [weak self, weak connection] content, _, _, error in
      guard let self, let connection else { return }
      if let content {
        ingestor.ingest(content, now: DispatchTime.now().uptimeNanoseconds)
      }
      if error == nil {
        receiveNext(on: connection)
      } else {
        lock.withLock { connections[ObjectIdentifier(connection)] = nil }
      }
    }
  }
}

enum NetworkAudioPacketIngestResult: Equatable {
  case accepted(frameCount: Int)
  case rejected
  case foreignSession
  case stale
}

final class NetworkAudioPacketIngestor {
  private let configuration: NetworkAudioReceiverConfiguration
  private let frameBuffer: AudioRealtimeFrameBuffer
  private let interleavedStorage: UnsafeMutablePointer<Float>
  private let silenceStorage: UnsafeMutablePointer<Float>
  private let maximumFrameCount: Int
  private let statisticsLock = NSLock()
  private var acceptedPacketCount: UInt64 = 0
  private var rejectedPacketCount: UInt64 = 0
  private var foreignSessionPacketCount: UInt64 = 0
  private var stalePacketCount: UInt64 = 0
  private var missingPacketCount: UInt64 = 0
  private var activeSessionID: UUID?
  private var lastSequence: UInt64?
  private var lastFrameCount = 0
  private var lastAcceptedTime: UInt64 = 0

  init(
    configuration: NetworkAudioReceiverConfiguration,
    frameBuffer: AudioRealtimeFrameBuffer
  ) {
    self.configuration = configuration
    self.frameBuffer = frameBuffer
    maximumFrameCount =
      (configuration.maximumDatagramByteCount - NetworkAudioPacketCodec.headerByteCount)
      / configuration.format.channelCount / MemoryLayout<Float>.stride
    let sampleCapacity = maximumFrameCount * configuration.format.channelCount
    interleavedStorage = .allocate(capacity: sampleCapacity)
    silenceStorage = .allocate(capacity: sampleCapacity)
    silenceStorage.initialize(repeating: 0, count: sampleCapacity)
  }

  deinit {
    interleavedStorage.deallocate()
    silenceStorage.deinitialize(
      count: maximumFrameCount * configuration.format.channelCount
    )
    silenceStorage.deallocate()
  }

  @discardableResult
  func ingest(_ data: Data, now: UInt64) -> NetworkAudioPacketIngestResult {
    guard data.count <= configuration.maximumDatagramByteCount else {
      increment(\Self.rejectedPacketCount)
      return .rejected
    }
    let packet: NetworkAudioPacket
    do {
      packet = try NetworkAudioPacketCodec.decode(data)
    } catch {
      increment(\Self.rejectedPacketCount)
      return .rejected
    }
    guard packet.format == configuration.format,
      packet.frameCount <= maximumFrameCount
    else {
      increment(\Self.rejectedPacketCount)
      return .rejected
    }

    if let activeSessionID, activeSessionID != packet.sessionID {
      let elapsed = now >= lastAcceptedTime ? now - lastAcceptedTime : 0
      guard elapsed >= configuration.sessionTakeoverInterval.nanoseconds else {
        increment(\Self.foreignSessionPacketCount)
        return .foreignSession
      }
      resetSession(to: packet.sessionID)
    } else if activeSessionID == nil {
      resetSession(to: packet.sessionID)
    }

    if let lastSequence {
      guard packet.sequence > lastSequence else {
        increment(\Self.stalePacketCount)
        return .stale
      }
      let missing = packet.sequence - lastSequence - 1
      if missing > 0 {
        add(missing, to: \Self.missingPacketCount)
        writeMissingSilence(packetCount: missing)
      }
    }

    decodePayload(packet.payload)
    _ = frameBuffer.writeInterleaved(
      interleavedStorage,
      channelCount: configuration.format.channelCount,
      frameCount: packet.frameCount
    )
    lastSequence = packet.sequence
    lastFrameCount = packet.frameCount
    lastAcceptedTime = now
    increment(\Self.acceptedPacketCount)
    return .accepted(frameCount: packet.frameCount)
  }

  func statistics() -> NetworkAudioReceiverStatistics {
    statisticsLock.withLock {
      NetworkAudioReceiverStatistics(
        acceptedPacketCount: acceptedPacketCount,
        rejectedPacketCount: rejectedPacketCount,
        foreignSessionPacketCount: foreignSessionPacketCount,
        stalePacketCount: stalePacketCount,
        missingPacketCount: missingPacketCount,
        frameBuffer: frameBuffer.statistics()
      )
    }
  }

  private func resetSession(to sessionID: UUID) {
    activeSessionID = sessionID
    lastSequence = nil
    lastFrameCount = 0
  }

  private func writeMissingSilence(packetCount: UInt64) {
    guard lastFrameCount > 0 else { return }
    let multiplication = packetCount.multipliedReportingOverflow(by: UInt64(lastFrameCount))
    let requested = multiplication.overflow ? UInt64.max : multiplication.partialValue
    var remaining = min(requested, UInt64(frameBuffer.capacityFrameCount))
    while remaining > 0 {
      let frameCount = min(Int(remaining), maximumFrameCount)
      _ = frameBuffer.writeInterleaved(
        silenceStorage,
        channelCount: configuration.format.channelCount,
        frameCount: frameCount
      )
      remaining -= UInt64(frameCount)
    }
  }

  private func decodePayload(_ payload: Data) {
    payload.withUnsafeBytes { rawBytes in
      let bytes = rawBytes.bindMemory(to: UInt8.self)
      let sampleCount = payload.count / MemoryLayout<Float>.stride
      for sampleIndex in 0..<sampleCount {
        let byteIndex = sampleIndex * MemoryLayout<Float>.stride
        let bits =
          UInt32(bytes[byteIndex])
          | UInt32(bytes[byteIndex + 1]) << 8
          | UInt32(bytes[byteIndex + 2]) << 16
          | UInt32(bytes[byteIndex + 3]) << 24
        let sample = Float(bitPattern: bits)
        interleavedStorage[sampleIndex] = sample.isFinite ? sample : 0
      }
    }
  }

  private func increment(_ keyPath: ReferenceWritableKeyPath<NetworkAudioPacketIngestor, UInt64>) {
    add(1, to: keyPath)
  }

  private func add(
    _ value: UInt64,
    to keyPath: ReferenceWritableKeyPath<NetworkAudioPacketIngestor, UInt64>
  ) {
    statisticsLock.withLock {
      let current = self[keyPath: keyPath]
      let sum = current.addingReportingOverflow(value)
      self[keyPath: keyPath] = sum.overflow ? UInt64.max : sum.partialValue
    }
  }
}

extension Duration {
  fileprivate var nanoseconds: UInt64 {
    let components = self.components
    guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
    let seconds = UInt64(components.seconds)
    let nanoseconds = UInt64(components.attoseconds / 1_000_000_000)
    let multiplication = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    guard !multiplication.overflow else { return UInt64.max }
    let addition = multiplication.partialValue.addingReportingOverflow(nanoseconds)
    return addition.overflow ? UInt64.max : addition.partialValue
  }
}
