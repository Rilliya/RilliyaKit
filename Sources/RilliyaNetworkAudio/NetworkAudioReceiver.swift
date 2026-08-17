// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network
import RilliyaRealtime

/// Bounded controls for one direct UDP network-audio receiver.
public struct NetworkAudioReceiverConfiguration: Equatable, Hashable, Sendable {
  /// The deepest reorder window, past which holding costs more delay than a tunnel ever saves.
  public static let maximumReorderDepth = 64

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

  /// Whether a gap is asked for again rather than only waited out.
  ///
  /// Asking costs a datagram and only helps where the answer can arrive before the audio is
  /// needed, so a receiver measures the round trip and stops asking when its own buffer is
  /// shallower than that.
  public let requestsRetransmission: Bool

  /// How many packets may be held while waiting for one that arrived out of order.
  ///
  /// A wired local network barely reorders, and a tunnel does. Holding costs nothing while the
  /// order is right; a packet that is genuinely lost delays the stream by at most this many
  /// packets before the gap is conceded. `1` holds nothing.
  public let reorderDepth: Int

  /// The key both peers share, or `nil` to accept audio in the clear.
  ///
  /// A configured key also rejects unencrypted datagrams, so reaching the port is not enough to
  /// be heard.
  public let sharedKey: NetworkAudioSharedKey?

  /// Creates validated receiver controls with bounded packet and PCM storage.
  public init(
    port: UInt16,
    format: NetworkAudioStreamFormat,
    capacityFrameCount: Int = 32_768,
    maximumDatagramByteCount: Int = NetworkAudioSenderConfiguration
      .defaultMaximumDatagramByteCount,
    sessionTakeoverInterval: Duration = .seconds(1),
    jitter: AudioJitterBufferConfiguration = .localNetwork,
    reorderDepth: Int = 8,
    requestsRetransmission: Bool = true,
    sharedKey: NetworkAudioSharedKey? = nil
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
    guard (1...Self.maximumReorderDepth).contains(reorderDepth) else {
      throw NetworkAudioReceiverError.invalidReorderDepth
    }
    self.port = port
    self.format = format
    self.capacityFrameCount = capacityFrameCount
    self.maximumDatagramByteCount = maximumDatagramByteCount
    self.sessionTakeoverInterval = sessionTakeoverInterval
    self.jitter = jitter
    self.reorderDepth = reorderDepth
    self.requestsRetransmission = requestsRetransmission
    self.sharedKey = sharedKey
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

  /// The reorder window is outside the bounded policy.
  case invalidReorderDepth

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
    case .invalidReorderDepth:
      "The network audio reorder window must be between 1 and 64 packets."
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

  /// Packets this receiver asked the sender to send again.
  public let retransmissionRequestCount: UInt64

  /// Packets that arrived because they were asked for.
  public let retransmissionRecoveredCount: UInt64

  /// Current bounded PCM queue diagnostics.
  public let frameBuffer: AudioRealtimeFrameBufferStatistics
}

/// Receives one versioned direct UDP audio session into a bounded realtime buffer.
///
/// Every datagram is length- and format-validated before its samples reach ``frameBuffer``, and
/// malformed traffic is discarded. Confidentiality and peer authentication come from
/// ``NetworkAudioReceiverConfiguration/sharedKey`` and are absent without one: UDP itself offers
/// neither, so an unkeyed session can be read and written by anything that can reach the port.
/// Congestion control this does not provide at all, which is what confines it to a local network.
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
    ingestor = try NetworkAudioPacketIngestor(
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
        let now = DispatchTime.now().uptimeNanoseconds
        ingestor.ingest(content, now: now)
        // The reply goes back along the flow the audio arrived on, so the sender hears it without
        // a second port and nobody else can pose as this receiver.
        if let request = ingestor.retransmissionRequest(now: now),
          let datagram = try? request.encoded(cipher: ingestor.requestCipher())
        {
          connection.send(content: datagram, completion: .idempotent)
        }
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
  /// The samples ``interleavedStorage`` holds, which bounds every write into it.
  private let sampleCapacity: Int
  private let statisticsLock = NSLock()
  private var acceptedPacketCount: UInt64 = 0
  private var rejectedPacketCount: UInt64 = 0
  private var foreignSessionPacketCount: UInt64 = 0
  private var stalePacketCount: UInt64 = 0
  private var missingPacketCount: UInt64 = 0
  private var activeSessionID: UUID?
  private var cipherSessionID: UUID?
  private var cipher: NetworkAudioSessionCipher?
  private let reorderBuffer: NetworkAudioPacketReorderBuffer
  private var lastFrameCount = 0
  /// Built when the first compressed packet says which format and block length the sender chose.
  private var decoder: NetworkAudioCompressedDecoder?
  private let reassembler: NetworkAudioFragmentReassembler
  private var configurationBytes = Data()
  private var asker = NetworkAudioRetransmissionAsker()
  private var requestSequence: UInt64 = 0
  private var retransmissionRequestCount: UInt64 = 0
  private var retransmissionRecoveredCount: UInt64 = 0
  private var lastAcceptedTime: UInt64 = 0

  init(
    configuration: NetworkAudioReceiverConfiguration,
    frameBuffer: AudioRealtimeFrameBuffer
  ) throws {
    self.configuration = configuration
    self.frameBuffer = frameBuffer
    // Uncompressed, a datagram's size bounds the block it can carry. Compressed, it does not:
    // one small datagram can carry the longest block Opus defines, so storage covers both.
    let uncompressedFrames =
      (configuration.maximumDatagramByteCount - NetworkAudioPacketCodec.headerByteCount)
      / configuration.format.channelCount / MemoryLayout<Float>.stride
    let compressedFrames =
      NetworkAudioCodec.all.flatMap {
        $0.frameCounts(
          sampleRate: configuration.format.sampleRate,
          channelCount: configuration.format.channelCount
        )
      }.max() ?? 0
    maximumFrameCount = max(uncompressedFrames, compressedFrames)
    let sampleCapacity = maximumFrameCount * configuration.format.channelCount
    reorderBuffer = try NetworkAudioPacketReorderBuffer(
      depth: configuration.reorderDepth,
      maximumFrameCount: maximumFrameCount,
      channelCount: configuration.format.channelCount
    )
    reassembler = try NetworkAudioFragmentReassembler(
      blockCount: 2,
      maximumFragmentByteCount: configuration.maximumDatagramByteCount
    )
    self.sampleCapacity = sampleCapacity
    interleavedStorage = .allocate(capacity: sampleCapacity)
    // Initialized rather than left raw: anything that reads further than the last packet wrote
    // then reads silence instead of whatever the heap happened to hold.
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
      packet = try NetworkAudioPacketCodec.decode(data, cipher: try cipher(for: data))
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

    let decodedFrameCount: Int
    switch packet.encoding {
    case .interleavedFloat32:
      decodePayload(packet.payload)
      decodedFrameCount = packet.frameCount
    case .opus, .aacEnhancedLowDelay, .aacLowDelay, .appleLossless:
      if !packet.codecConfiguration.isEmpty {
        configurationBytes = packet.codecConfiguration
      }
      // A block wider than a datagram is not audio until every piece of it is present, and the
      // reassembler releases whole blocks in the order they were sent, so a split stream needs no
      // further reordering.
      if let fragment = packet.fragment {
        let outcome = reassembler.admit(
          sequence: packet.sequence, fragment: fragment, payload: packet.payload)
        switch outcome {
        case .completed(let blocks):
          var written = 0
          for block in blocks {
            guard let frames = decodeCompressed(packet, block: block) else { continue }
            writeDecoded(frameCount: frames)
            written += frames
          }
          lastFrameCount = written
          lastAcceptedTime = now
          increment(\Self.acceptedPacketCount)
          return .accepted(frameCount: written)
        case .held:
          lastAcceptedTime = now
          increment(\Self.acceptedPacketCount)
          return .accepted(frameCount: 0)
        case .tooLate, .duplicate:
          increment(\Self.stalePacketCount)
          return .stale
        }
      }
      guard let frames = decodeCompressed(packet, block: packet.payload) else {
        increment(\Self.rejectedPacketCount)
        return .rejected
      }
      decodedFrameCount = frames
    }
    var missing: UInt64 = 0
    let admission = reorderBuffer.admit(
      sequence: packet.sequence,
      samples: interleavedStorage,
      frameCount: decodedFrameCount
    ) { [frameBuffer, configuration] samples, frameCount in
      guard frameCount > 0 else { return }
      if let samples {
        _ = frameBuffer.writeInterleaved(
          samples,
          channelCount: configuration.format.channelCount,
          frameCount: frameCount
        )
      } else {
        missing &+= 1
        _ = frameBuffer.writeInterleaved(
          self.silenceStorage,
          channelCount: configuration.format.channelCount,
          frameCount: frameCount
        )
      }
    }
    if missing > 0 { add(missing, to: \Self.missingPacketCount) }
    guard admission == .queued else {
      increment(\Self.stalePacketCount)
      return .stale
    }
    lastFrameCount = decodedFrameCount
    lastAcceptedTime = now
    increment(\Self.acceptedPacketCount)
    if statisticsLock.withLock({ asker.noteArrival(sequence: packet.sequence, now: now) }) {
      increment(\Self.retransmissionRecoveredCount)
    }
    return .accepted(frameCount: decodedFrameCount)
  }

  func statistics() -> NetworkAudioReceiverStatistics {
    statisticsLock.withLock {
      NetworkAudioReceiverStatistics(
        acceptedPacketCount: acceptedPacketCount,
        rejectedPacketCount: rejectedPacketCount,
        foreignSessionPacketCount: foreignSessionPacketCount,
        stalePacketCount: stalePacketCount,
        missingPacketCount: missingPacketCount,
        retransmissionRequestCount: retransmissionRequestCount,
        retransmissionRecoveredCount: retransmissionRecoveredCount,
        frameBuffer: frameBuffer.statistics()
      )
    }
  }

  /// Derives the session key once per sender session rather than once per packet.
  ///
  /// The session identifier is authenticated but not encrypted, precisely so a receiver can read
  /// it before opening the payload.
  private func cipher(for data: Data) throws -> NetworkAudioSessionCipher? {
    guard let sharedKey = configuration.sharedKey else { return nil }
    let sessionID = try NetworkAudioPacketCodec.sessionID(of: data)
    if cipherSessionID != sessionID {
      cipher = NetworkAudioSessionCipher(sharedKey: sharedKey, sessionID: sessionID)
      cipherSessionID = sessionID
    }
    return cipher
  }

  /// Drops whatever the previous session left held rather than placing it in the new one.
  private func resetSession(to sessionID: UUID) {
    activeSessionID = sessionID
    reorderBuffer.reset()
    resetDecoder()
    lastFrameCount = 0
  }

  /// Writes what the decoder produced straight to the queue.
  ///
  /// A reassembled block is already in order, so it does not pass through the reorder buffer.
  private func writeDecoded(frameCount: Int) {
    guard frameCount > 0 else { return }
    _ = frameBuffer.writeInterleaved(
      interleavedStorage,
      channelCount: configuration.format.channelCount,
      frameCount: frameCount
    )
  }

  /// Expands one compressed packet, building the decoder the first time a shape is seen.
  ///
  /// A codec that looks ahead yields fewer frames from the opening packets than they carry. What
  /// it yields is what is written.
  private func decodeCompressed(_ packet: NetworkAudioPacket, block: Data) -> Int? {
    if decoder?.codec.encoding != packet.encoding
      || decoder?.frameCountPerPacket != packet.frameCount
    {
      decoder = NetworkAudioCodec.codec(for: packet.encoding).flatMap {
        try? NetworkAudioCompressedDecoder(
          codec: $0,
          sampleRate: packet.format.sampleRate,
          channelCount: packet.format.channelCount,
          frameCountPerPacket: packet.frameCount,
          configuration: configurationBytes
        )
      }
    }
    guard let decoder, packet.frameCount <= maximumFrameCount else { return nil }
    return try? block.withUnsafeBytes { bytes in
      try decoder.decode(packet: bytes, into: interleavedStorage)
    }
  }

  /// Drops the decoder along with everything else the previous session left behind.
  private func resetDecoder() {
    decoder = nil
    configurationBytes = Data()
    reassembler.reset()
    statisticsLock.withLock { asker.reset() }
  }

  /// The sequences worth asking the sender for, given what the queue is still holding.
  ///
  /// Empty whenever asking is switched off, whenever nothing is missing, and whenever the round
  /// trip measured so far leaves no time to place an answer.
  func retransmissionRequest(now: UInt64) -> NetworkAudioRetransmissionRequest? {
    guard configuration.requestsRetransmission, let sessionID = activeSessionID else { return nil }
    let limit = NetworkAudioRetransmissionRequest.maximumSequenceCount
    var missing = reassembler.missingSequences(limit: limit)
    if missing.count < limit {
      missing += reorderBuffer.missingSequences(limit: limit - missing.count)
    }
    guard !missing.isEmpty else { return nil }
    let queuedFrames = frameBuffer.statistics().availableFrameCount
    let queued = Duration.nanoseconds(
      Int64(Double(queuedFrames) / configuration.format.sampleRate * 1_000_000_000))
    return statisticsLock.withLock { () -> NetworkAudioRetransmissionRequest? in
      let wanted = asker.sequencesToAsk(missing: missing, queued: queued, now: now)
      guard !wanted.isEmpty else { return nil }
      let request = try? NetworkAudioRetransmissionRequest(
        sessionID: sessionID,
        sequence: requestSequence,
        sequences: wanted
      )
      guard let request else { return nil }
      requestSequence &+= 1
      retransmissionRequestCount &+= UInt64(wanted.count)
      return request
    }
  }

  /// The cipher a request is sealed with, which is the one the active session uses.
  func requestCipher() -> NetworkAudioSessionCipher? {
    statisticsLock.withLock { cipher }
  }

  private func decodePayload(_ payload: Data) {
    payload.withUnsafeBytes { rawBytes in
      let bytes = rawBytes.bindMemory(to: UInt8.self)
      // Bounded by the storage as well as by the payload. The header rules ahead of this already
      // tie the two together; this is what makes a mistake in them a short packet rather than a
      // write past the buffer.
      let sampleCount = min(payload.count / MemoryLayout<Float>.stride, sampleCapacity)
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
