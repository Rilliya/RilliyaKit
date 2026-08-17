// SPDX-License-Identifier: Apache-2.0

import Atomics
import Foundation
import Network
import RilliyaRealtime

/// Bounded controls for one direct UDP network-audio sender.
public struct NetworkAudioSenderConfiguration: Equatable, Hashable, Sendable {
  /// The recent packets a sender keeps by default.
  ///
  /// Enough to answer for a round trip plus the window a receiver reorders over, which at ten
  /// milliseconds a packet is about half a second of history.
  public static let defaultRetransmissionDepth = 48

  /// The deepest history a sender will keep.
  public static let maximumRetransmissionDepth = 512

  /// The bit rate Opus is asked for when nothing else is said.
  ///
  /// Measured here, this leaves stereo at 48 kHz costing about a twentieth of what the samples
  /// themselves would, at a quality no listener has to accept anything for.
  public static let defaultOpusBitRate = 128_000

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

  /// How the payload is represented on the wire.
  public let encoding: NetworkAudioWireEncoding

  /// The bits per second Opus is asked for, which the uncompressed encoding ignores.
  public let opusBitRate: Int

  /// How many recent packets are kept so a receiver can ask for one again.
  ///
  /// Zero keeps none and answers nothing, which is what a sender on a link that loses nothing
  /// wants. The default covers a round trip and a reorder window on a tunnel.
  public let retransmissionDepth: Int

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
    encoding: NetworkAudioWireEncoding = .interleavedFloat32,
    opusBitRate: Int = NetworkAudioSenderConfiguration.defaultOpusBitRate,
    retransmissionDepth: Int = NetworkAudioSenderConfiguration.defaultRetransmissionDepth,
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
    guard (0...Self.maximumRetransmissionDepth).contains(retransmissionDepth) else {
      throw NetworkAudioSenderError.invalidRetransmissionDepth
    }
    self.encoding = encoding
    self.opusBitRate = opusBitRate
    self.retransmissionDepth = retransmissionDepth
    self.sharedKey = sharedKey
    let payloadRoom =
      maximumDatagramByteCount - NetworkAudioPacketCodec.headerByteCount
      - (sharedKey == nil ? 0 : NetworkAudioSessionCipher.tagByteCount)
    guard payloadRoom >= 1 else { throw NetworkAudioSenderError.invalidDatagramBound }

    switch encoding {
    case .interleavedFloat32:
      // Every frame costs its own bytes, so the block is what the datagram has room for.
      let maximumFrames = payloadRoom / format.channelCount / MemoryLayout<Float>.stride
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
    case .opus, .aacEnhancedLowDelay, .aacLowDelay, .appleLossless:
      // A compressed block costs what the encoder makes of it, so the datagram no longer decides
      // the length: the codec does, and each defines only a handful.
      guard let codec = NetworkAudioCodec.codec(for: encoding) else {
        throw NetworkAudioSenderError.codec(.unavailable(0))
      }
      guard codec.supportedSampleRates.contains(format.sampleRate) else {
        throw NetworkAudioSenderError.codec(.unsupportedSampleRate(format.sampleRate))
      }
      guard codec.supportedChannelCounts.contains(format.channelCount) else {
        throw NetworkAudioSenderError.codec(.unsupportedChannelCount(format.channelCount))
      }
      let resolved =
        framesPerPacket
        ?? codec.frameCount(
          nearestTo: Self.preferredBlockMilliseconds,
          sampleRate: format.sampleRate,
          channelCount: format.channelCount
        )
      guard let resolved,
        codec.carries(
          frameCount: resolved,
          sampleRate: format.sampleRate,
          channelCount: format.channelCount
        )
      else {
        throw NetworkAudioSenderError.codec(.unsupportedFrameCount(framesPerPacket ?? 0))
      }
      guard resolved <= capacityFrameCount else {
        throw NetworkAudioSenderError.invalidPacketFrameCount(resolved)
      }
      self.framesPerPacket = resolved
    }
  }

  /// The block length a codec is asked for when nothing else is said.
  ///
  /// Ten milliseconds is where a codec stops paying much per packet for its own overhead without
  /// adding delay a listener notices. A codec offering nothing that short reports what it has.
  static let preferredBlockMilliseconds = 10.0

  /// The compressed bytes one packet may carry, which the datagram bound decides.
  var maximumCompressedPacketByteCount: Int {
    min(
      NetworkAudioCodec.maximumPacketByteCount,
      maximumDatagramByteCount - NetworkAudioPacketCodec.headerByteCount
        - (sharedKey == nil ? 0 : NetworkAudioSessionCipher.tagByteCount)
    )
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

  /// The chosen wire format cannot carry what this sender was asked to carry.
  case codec(NetworkAudioCodecError)

  /// The retransmission history is outside the bounded policy.
  case invalidRetransmissionDepth

  /// Packet encoding rejected internally produced metadata.
  case packet(NetworkAudioPacketError)

  /// A human-readable explanation suitable for application diagnostics.
  public var errorDescription: String? {
    switch self {
    case .invalidHost:
      "The network audio destination host is empty or too long."
    case .invalidPort:
      "The network audio destination port must be between 1 and 65,535."
    case .codec(let error):
      error.errorDescription
    case .invalidRetransmissionDepth:
      "The network audio retransmission history must be between 0 and 512 packets."
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
    if configuration.retransmissionDepth > 0 {
      Self.receiveRequest(on: connection, answeredBy: packets)
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

  /// Listens for retransmission requests on the flow the audio goes out on.
  ///
  /// The reply travels back along that same flow, so a request can only come from whoever holds
  /// its addresses; a datagram from anywhere else never reaches this at all.
  private static func receiveRequest(
    on connection: NWConnection,
    answeredBy packets: NetworkAudioSenderPacketizer
  ) {
    connection.receiveMessage { [weak connection] content, _, _, error in
      guard let connection else { return }
      if let content, let request = packets.decodeRequest(content) {
        packets.answer(request, through: connection)
      }
      guard error == nil else { return }
      receiveRequest(on: connection, answeredBy: packets)
    }
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
  private let compression: CompressionStaging?
  private let history: NetworkAudioSenderHistory?
  private var budget: NetworkAudioRetransmissionBudget
  private var sequence: UInt64 = 0

  /// What compressing a block needs beyond the planar channels already read.
  private struct CompressionStaging {
    let encoder: NetworkAudioCompressedEncoder
    let interleaved: UnsafeMutablePointer<Float>
    let interleavedSampleCount: Int
    let packet: UnsafeMutableRawBufferPointer
  }

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
    // A compressed block is usually smaller than the samples it replaces, but a short block at a
    // high bit rate need not be, so the datagram is sized for whichever is larger.
    let uncompressed =
      NetworkAudioPacketCodec.datagramByteCount(
        channelCount: configuration.format.channelCount,
        frameCount: configuration.framesPerPacket
      ) + NetworkAudioSessionCipher.tagByteCount
    let compressed =
      NetworkAudioPacketCodec.headerByteCount + configuration.maximumCompressedPacketByteCount
      + NetworkAudioSessionCipher.tagByteCount
    datagram = UnsafeMutableRawBufferPointer.allocate(
      byteCount: configuration.encoding == .interleavedFloat32
        ? uncompressed : max(uncompressed, compressed),
      alignment: MemoryLayout<UInt64>.alignment
    )
    compression = Self.staging(for: configuration)
    history =
      configuration.retransmissionDepth > 0
      ? NetworkAudioSenderHistory(
        depth: configuration.retransmissionDepth,
        maximumDatagramByteCount: configuration.maximumDatagramByteCount
      ) : nil
    budget = NetworkAudioRetransmissionBudget(
      packetsPerSecond: configuration.format.sampleRate / Double(configuration.framesPerPacket)
    )
  }

  deinit {
    for pointer in channelStorage { pointer.deallocate() }
    datagram.deallocate()
    guard let compression else { return }
    compression.interleaved.deinitialize(count: compression.interleavedSampleCount)
    compression.interleaved.deallocate()
    compression.packet.deallocate()
  }

  /// Prepares compression, or nothing when the wire carries samples as they are.
  ///
  /// The configuration has already refused a format Opus cannot carry, so an encoder that still
  /// cannot be built means the system withdrew the codec and the sender falls back to reporting
  /// every packet rather than trapping here.
  private static func staging(
    for configuration: NetworkAudioSenderConfiguration
  ) -> CompressionStaging? {
    guard let codec = NetworkAudioCodec.codec(for: configuration.encoding),
      let encoder = try? NetworkAudioCompressedEncoder(
        codec: codec,
        sampleRate: configuration.format.sampleRate,
        channelCount: configuration.format.channelCount,
        frameCountPerPacket: configuration.framesPerPacket,
        bitRate: configuration.opusBitRate
      )
    else { return nil }
    let sampleCount = configuration.framesPerPacket * configuration.format.channelCount
    let interleaved = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
    interleaved.initialize(repeating: 0, count: sampleCount)
    return CompressionStaging(
      encoder: encoder,
      interleaved: interleaved,
      interleavedSampleCount: sampleCount,
      packet: UnsafeMutableRawBufferPointer.allocate(
        byteCount: configuration.maximumCompressedPacketByteCount,
        alignment: 16
      )
    )
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
      if let compression {
        written = try compress(compression, frameCount: frameCount)
      } else {
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
      }
    } catch {
      return
    }
    guard written > 0, let base = datagram.baseAddress else { return }
    history?.record(
      sequence: sequence,
      datagram: UnsafeRawBufferPointer(start: base, count: written)
    )
    sequence &+= 1
    connection.send(
      content: Data(bytes: base, count: written),
      completion: .idempotent
    )
  }

  /// Sends again whatever a request names and this sender still holds.
  ///
  /// A request naming another session asks for audio that no longer exists, and the budget is
  /// what keeps a stream of requests from turning retransmission into the larger half of the flow.
  func answer(_ request: NetworkAudioRetransmissionRequest, through connection: NWConnection) {
    guard let history, request.sessionID == configuration.sessionID else { return }
    let now = DispatchTime.now().uptimeNanoseconds
    for wanted in request.sequences {
      guard budget.allows(now: now) else { return }
      guard let length = history.datagram(for: wanted, into: datagram),
        let base = datagram.baseAddress
      else { continue }
      connection.send(
        content: Data(bytes: base, count: length),
        completion: .idempotent
      )
    }
  }

  /// Reads a request from the flow the audio goes out on.
  ///
  /// Only that flow is listened to, so a datagram from anywhere else never reaches this.
  func decodeRequest(_ data: Data) -> NetworkAudioRetransmissionRequest? {
    try? NetworkAudioRetransmissionRequest.decode(data, cipher: cipher)
  }

  /// Weaves the channels together, compresses them, and writes the datagram.
  private func compress(_ compression: CompressionStaging, frameCount: Int) throws -> Int {
    let channelCount = configuration.format.channelCount
    for frame in 0..<frameCount {
      for channel in 0..<channelCount {
        compression.interleaved[frame * channelCount + channel] = channelStorage[channel][frame]
      }
    }
    let byteCount = try compression.encoder.encode(
      input: compression.interleaved, into: compression.packet)
    // A codec still filling produces no packet from this block, so there is nothing to send and
    // the sequence must not move on without one.
    guard byteCount > 0 else { return 0 }
    return try NetworkAudioPacketCodec.encode(
      sessionID: configuration.sessionID,
      sequence: sequence,
      format: configuration.format,
      frameCount: frameCount,
      encoding: configuration.encoding,
      payload: UnsafeRawBufferPointer(rebasing: compression.packet[..<byteCount]),
      into: datagram,
      cipher: cipher
    )
  }
}
