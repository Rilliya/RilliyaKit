// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network
import RilliyaRealtime

/// Bounded controls for one direct UDP network-audio sender.
public struct NetworkAudioSenderConfiguration: Equatable, Hashable, Sendable {
  /// A conservative datagram size that avoids fragmentation on ordinary local networks.
  public static let defaultMaximumDatagramByteCount = 1_200

  /// The destination host name or numeric address.
  public let host: String

  /// The destination UDP port.
  public let port: UInt16

  /// The PCM format emitted by the sender.
  public let format: NetworkAudioStreamFormat

  /// The sender session represented in every datagram.
  public let sessionID: UUID

  /// The fixed producer-to-network queue capacity.
  public let capacityFrameCount: Int

  /// The largest emitted datagram, including its protocol header.
  public let maximumDatagramByteCount: Int

  /// Creates validated sender controls with bounded queue and packet storage.
  public init(
    host: String,
    port: UInt16,
    format: NetworkAudioStreamFormat,
    sessionID: UUID = UUID(),
    capacityFrameCount: Int = 16_384,
    maximumDatagramByteCount: Int = defaultMaximumDatagramByteCount
  ) throws {
    let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedHost.isEmpty, normalizedHost.utf8.count <= 255 else {
      throw NetworkAudioSenderError.invalidHost
    }
    guard port > 0 else { throw NetworkAudioSenderError.invalidPort }
    let minimumDatagramByteCount =
      NetworkAudioPacketCodec.headerByteCount
      + format.channelCount * MemoryLayout<Float>.stride
    guard
      (minimumDatagramByteCount...NetworkAudioPacketCodec.maximumDatagramByteCount)
        .contains(maximumDatagramByteCount)
    else {
      throw NetworkAudioSenderError.invalidDatagramBound
    }
    guard
      (2...AudioRealtimeFrameBuffer.maximumCapacityFrameCount).contains(capacityFrameCount)
    else {
      throw NetworkAudioSenderError.invalidBufferCapacity
    }
    self.host = normalizedHost
    self.port = port
    self.format = format
    self.sessionID = sessionID
    self.capacityFrameCount = capacityFrameCount
    self.maximumDatagramByteCount = maximumDatagramByteCount
  }

  var maximumFrameCountPerPacket: Int {
    (maximumDatagramByteCount - NetworkAudioPacketCodec.headerByteCount)
      / format.channelCount / MemoryLayout<Float>.stride
  }
}

/// A typed direct-network sender failure.
public enum NetworkAudioSenderError: Error, Equatable, LocalizedError, Sendable {
  /// The destination host is empty or exceeds the bounded textual representation.
  case invalidHost

  /// UDP port zero is not a valid destination.
  case invalidPort

  /// The packet size cannot carry one complete frame or exceeds the protocol bound.
  case invalidDatagramBound

  /// The producer queue capacity is outside the realtime buffer bound.
  case invalidBufferCapacity

  /// A stopped sender cannot be started again.
  case alreadyStopped

  /// Network.framework rejected a datagram.
  case transport(NetworkAudioTransportFailure)

  /// Packet encoding rejected internally produced metadata.
  case packet(NetworkAudioPacketError)

  /// A human-readable explanation suitable for application diagnostics.
  public var errorDescription: String? {
    switch self {
    case .invalidHost:
      "The network audio destination host is empty or too long."
    case .invalidPort:
      "The network audio destination port must be between 1 and 65,535."
    case .invalidDatagramBound:
      "The network audio packet bound must fit one complete frame and remain below 16,384 bytes."
    case .invalidBufferCapacity:
      "The network audio sender buffer capacity must be between 2 and 65,536 frames."
    case .alreadyStopped:
      "A stopped network audio sender cannot be restarted."
    case .transport(let failure):
      "The network audio sender failed: \(failure.description)."
    case .packet(let error):
      error.localizedDescription
    }
  }
}

/// A stable representation of an underlying Network.framework error.
public enum NetworkAudioTransportFailure: Equatable, Hashable, Sendable {
  /// A POSIX socket failure.
  case posix(Int32)

  /// A DNS resolution failure.
  case dns(Int32)

  /// A TLS failure, reserved for future encrypted transports.
  case tls(Int32)

  /// A future Network.framework error domain.
  case unknown(String)

  init(_ error: NWError) {
    switch error {
    case .posix(let code):
      self = .posix(code.rawValue)
    case .dns(let code):
      self = .dns(code)
    case .tls(let status):
      self = .tls(status)
    case .wifiAware(let error):
      self = .unknown(String(describing: error))
    @unknown default:
      self = .unknown(String(describing: error))
    }
  }

  var description: String {
    switch self {
    case .posix(let code): "POSIX error \(code)"
    case .dns(let code): "DNS error \(code)"
    case .tls(let code): "TLS error \(code)"
    case .unknown(let description): description
    }
  }
}

/// Streams bounded planar Float32 PCM to one direct UDP peer.
///
/// A graph producer writes only to ``frameBuffer``. A background worker performs interleaving,
/// packet allocation, name resolution, and network IO. When the consumer falls behind, new frames
/// are dropped by the bounded buffer rather than blocking or growing memory on the render path.
public final class NetworkAudioSender: @unchecked Sendable {
  /// Receives the first asynchronous sender failure away from the render path.
  public typealias FailureHandler = @Sendable (NetworkAudioSenderError) -> Void

  /// The immutable sender controls.
  public let configuration: NetworkAudioSenderConfiguration

  /// The single-producer queue written by a prepared graph.
  public let frameBuffer: AudioRealtimeFrameBuffer

  private enum State {
    case ready
    case running
    case stopped
  }

  private let failureHandler: FailureHandler
  private let lock = NSLock()
  private var state = State.ready
  private var connection: NWConnection?
  private var workerTask: Task<Void, Never>?

  /// Allocates the fixed PCM queue without opening a network connection.
  public init(
    configuration: NetworkAudioSenderConfiguration,
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
  }

  deinit {
    lock.withLock {
      workerTask?.cancel()
      connection?.cancel()
    }
  }

  /// Starts one serial background packet and network worker.
  public func start() throws {
    try lock.withLock {
      switch state {
      case .running:
        return
      case .stopped:
        throw NetworkAudioSenderError.alreadyStopped
      case .ready:
        break
      }

      guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
        throw NetworkAudioSenderError.invalidPort
      }

      let connection = NWConnection(
        host: NWEndpoint.Host(configuration.host),
        port: port,
        using: .udp
      )
      let queue = DispatchQueue(
        label: "moe.uwucocoa.RilliyaKit.network-audio-sender",
        qos: .userInitiated
      )
      connection.start(queue: queue)
      self.connection = connection
      let configuration = configuration
      let frameBuffer = frameBuffer
      let failureHandler = failureHandler
      workerTask = Task.detached(priority: .userInitiated) {
        let worker = NetworkAudioSenderWorker(configuration: configuration)
        do {
          try await worker.run(frameBuffer: frameBuffer, connection: connection)
        } catch is CancellationError {
          return
        } catch let error as NetworkAudioSenderError {
          if !Task.isCancelled { failureHandler(error) }
        } catch {
          if !Task.isCancelled {
            failureHandler(.transport(.unknown(String(describing: error))))
          }
        }
      }
      state = .running
    }
  }

  /// Cancels network IO and waits for temporary packet storage to be released.
  public func stop() async {
    let resources = lock.withLock { () -> (Task<Void, Never>?, NWConnection?) in
      state = .stopped
      let resources = (workerTask, connection)
      workerTask = nil
      connection = nil
      return resources
    }
    resources.0?.cancel()
    resources.1?.cancel()
    await resources.0?.value
  }
}

private final class NetworkAudioSenderWorker {
  private let configuration: NetworkAudioSenderConfiguration
  private let channelStorage: [UnsafeMutablePointer<Float>]
  private let mutablePointers: [UnsafeMutablePointer<Float>]

  init(configuration: NetworkAudioSenderConfiguration) {
    self.configuration = configuration
    let storage = (0..<configuration.format.channelCount).map { _ in
      UnsafeMutablePointer<Float>.allocate(capacity: configuration.maximumFrameCountPerPacket)
    }
    channelStorage = storage
    mutablePointers = storage
  }

  deinit {
    for pointer in channelStorage { pointer.deallocate() }
  }

  func run(frameBuffer: AudioRealtimeFrameBuffer, connection: NWConnection) async throws {
    var sequence: UInt64 = 0
    while !Task.isCancelled {
      let available = frameBuffer.statistics().availableFrameCount
      guard available > 0 else {
        try await Task.sleep(for: .milliseconds(1))
        continue
      }
      let frameCount = min(available, configuration.maximumFrameCountPerPacket)
      let result = mutablePointers.withUnsafeBufferPointer {
        frameBuffer.read(into: $0, frameCount: frameCount)
      }
      guard case .read(let readFrameCount, _) = result, readFrameCount > 0 else { continue }
      let payload = makePayload(frameCount: readFrameCount)
      let packet: NetworkAudioPacket
      do {
        packet = try NetworkAudioPacket(
          sessionID: configuration.sessionID,
          sequence: sequence,
          format: configuration.format,
          frameCount: readFrameCount,
          payload: payload
        )
      } catch let error as NetworkAudioPacketError {
        throw NetworkAudioSenderError.packet(error)
      }
      let datagram: Data
      do {
        datagram = try NetworkAudioPacketCodec.encode(packet)
      } catch let error as NetworkAudioPacketError {
        throw NetworkAudioSenderError.packet(error)
      }
      try await send(datagram, through: connection)
      sequence &+= 1
    }
  }

  private func makePayload(frameCount: Int) -> Data {
    var payload = Data(
      capacity: frameCount * configuration.format.channelCount * MemoryLayout<Float>.stride
    )
    for frame in 0..<frameCount {
      for channel in 0..<configuration.format.channelCount {
        let sample = channelStorage[channel][frame]
        var bits = (sample.isFinite ? sample : 0).bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { payload.append(contentsOf: $0) }
      }
    }
    return payload
  }

  private func send(_ data: Data, through connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      connection.send(
        content: data,
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: NetworkAudioSenderError.transport(.init(error)))
          } else {
            continuation.resume(returning: ())
          }
        })
    }
  }
}
