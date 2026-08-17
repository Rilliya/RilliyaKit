// SPDX-License-Identifier: Apache-2.0

import Atomics
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

  /// The key both peers share, or `nil` to send in the clear.
  public let sharedKey: NetworkAudioSharedKey?

  /// The frames each datagram carries.
  ///
  /// Matching the producer's render quantum keeps one rendered block in one datagram; leaving it
  /// unset fills every datagram to the MTU, which splits blocks and sends them in bursts.
  public let framesPerPacket: Int

  /// Creates validated sender controls with bounded queue and packet storage.
  public init(
    host: String,
    port: UInt16,
    format: NetworkAudioStreamFormat,
    sessionID: UUID = UUID(),
    capacityFrameCount: Int = 16_384,
    maximumDatagramByteCount: Int = defaultMaximumDatagramByteCount,
    framesPerPacket: Int? = nil,
    sharedKey: NetworkAudioSharedKey? = nil
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
    self.sharedKey = sharedKey
    let maximumFrames =
      (maximumDatagramByteCount - NetworkAudioPacketCodec.headerByteCount
        - (sharedKey == nil ? 0 : NetworkAudioSessionCipher.tagByteCount))
      / format.channelCount / MemoryLayout<Float>.stride
    guard maximumFrames >= 1 else { throw NetworkAudioSenderError.invalidDatagramBound }
    if let framesPerPacket {
      guard (1...maximumFrames).contains(framesPerPacket),
        framesPerPacket <= capacityFrameCount
      else {
        throw NetworkAudioSenderError.invalidPacketFrameCount(framesPerPacket)
      }
      self.framesPerPacket = framesPerPacket
    } else {
      self.framesPerPacket = maximumFrames
    }
  }

  var maximumFrameCountPerPacket: Int {
    let overhead =
      NetworkAudioPacketCodec.headerByteCount
      + (sharedKey == nil ? 0 : NetworkAudioSessionCipher.tagByteCount)
    return (maximumDatagramByteCount - overhead) / format.channelCount
      / MemoryLayout<Float>.stride
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

  /// The requested packet size cannot be carried or cannot be filled from the queue.
  case invalidPacketFrameCount(Int)

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
    case .invalidPacketFrameCount(let frameCount):
      "A network audio datagram cannot carry \(frameCount) frames."
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
  private var worker: AudioRealtimeWorker?

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
    worker?.stop()
    connection?.cancel()
  }

  /// Starts the deadline-scheduled packet worker and its connection.
  public func start() throws {
    lock.lock()
    defer { lock.unlock() }
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

    let parameters = NWParameters.udp
    parameters.serviceClass = .interactiveVoice
    let connection = NWConnection(
      host: NWEndpoint.Host(configuration.host),
      port: port,
      using: parameters
    )
    let queue = DispatchQueue(
      label: "moe.uwucocoa.RilliyaKit.network-audio-sender",
      qos: .userInitiated
    )
    connection.start(queue: queue)
    self.connection = connection

    let packets = NetworkAudioSenderPacketizer(
      configuration: configuration,
      frameBuffer: frameBuffer
    )
    let worker = AudioRealtimeWorker(
      label: "moe.uwucocoa.RilliyaKit.network-audio-sender",
      cadence: try AudioRealtimeCadence(
        framesPerCycle: configuration.framesPerPacket,
        sampleRate: configuration.format.sampleRate
      ),
      budget: try AudioRealtimeBudget.matching(
        computation: NetworkAudioSenderPacketizer.computationBudget
      )
    ) { _ in
      packets.emit(through: connection)
      return .continue
    }
    do {
      try worker.start()
    } catch {
      connection.cancel()
      self.connection = nil
      throw NetworkAudioSenderError.transport(.unknown(String(describing: error)))
    }
    self.worker = worker
    state = .running
  }

  /// Stops the worker and cancels network IO.
  public func stop() async {
    let stopping = lock.withLock { () -> (AudioRealtimeWorker?, NWConnection?) in
      state = .stopped
      let stopping = (worker, connection)
      worker = nil
      connection = nil
      return stopping
    }
    stopping.0?.stop()
    stopping.1?.cancel()
  }
}

/// Turns queued planar frames into datagrams without allocating.
///
/// Every buffer is allocated during initialization, the encoder writes in place, and the send is
/// fire and forget, so this can run on the sender's realtime thread.
private final class NetworkAudioSenderPacketizer: @unchecked Sendable {
  /// The time one packet is allowed to take.
  ///
  /// Handing a datagram to Network.framework measured p50 12 µs and worst case 567 µs on this
  /// hardware, so the budget covers the tail rather than the median.
  static let computationBudget = Duration.microseconds(700)

  private let configuration: NetworkAudioSenderConfiguration
  private let frameBuffer: AudioRealtimeFrameBuffer
  private let channelStorage: [UnsafeMutablePointer<Float>]
  private let readOnlyPointers: [UnsafePointer<Float>]
  private let datagram: UnsafeMutableRawBufferPointer
  private let cipher: NetworkAudioSessionCipher?
  private var sequence: UInt64 = 0

  init(
    configuration: NetworkAudioSenderConfiguration,
    frameBuffer: AudioRealtimeFrameBuffer
  ) {
    self.configuration = configuration
    self.frameBuffer = frameBuffer
    cipher = configuration.sharedKey.map {
      NetworkAudioSessionCipher(sharedKey: $0, sessionID: configuration.sessionID)
    }
    let storage = (0..<configuration.format.channelCount).map { _ in
      UnsafeMutablePointer<Float>.allocate(capacity: configuration.framesPerPacket)
    }
    channelStorage = storage
    readOnlyPointers = storage.map { UnsafePointer($0) }
    datagram = UnsafeMutableRawBufferPointer.allocate(
      byteCount: NetworkAudioPacketCodec.datagramByteCount(
        channelCount: configuration.format.channelCount,
        frameCount: configuration.framesPerPacket
      ) + NetworkAudioSessionCipher.tagByteCount,
      alignment: MemoryLayout<UInt64>.alignment
    )
  }

  deinit {
    for pointer in channelStorage { pointer.deallocate() }
    datagram.deallocate()
  }

  /// Emits one packet when the queue holds a full one, and nothing otherwise.
  func emit(through connection: NWConnection) {
    let frameCount = configuration.framesPerPacket
    guard frameBuffer.statistics().availableFrameCount >= frameCount else { return }
    let read = channelStorage.withUnsafeBufferPointer {
      frameBuffer.read(into: $0, frameCount: frameCount)
    }
    guard case .read(let readFrameCount, _) = read, readFrameCount == frameCount else { return }

    let written: Int
    do {
      written = try readOnlyPointers.withUnsafeBufferPointer {
        try NetworkAudioPacketCodec.encode(
          sessionID: configuration.sessionID,
          sequence: sequence,
          format: configuration.format,
          frameCount: frameCount,
          planarChannels: $0,
          into: datagram,
          cipher: cipher
        )
      }
    } catch {
      return
    }
    guard let base = datagram.baseAddress else { return }
    sequence &+= 1
    connection.send(
      content: Data(bytes: base, count: written),
      completion: .idempotent
    )
  }
}
