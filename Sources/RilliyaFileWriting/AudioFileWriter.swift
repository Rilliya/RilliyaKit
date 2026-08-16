// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import Foundation
import RilliyaRealtime

/// Writes realtime planar Float32 PCM to a bounded queue and encodes it on a background task.
///
/// The producer writes only to ``frameBuffer``. File creation, conversion, encoding, disk IO, and
/// finalization never run on the realtime thread. Call ``stop()`` after stopping the producer so
/// the writer can drain accepted frames and finalize the file header.
public actor AudioFileWriter {
  /// Receives completion or failure away from the realtime producer.
  public typealias EventHandler = @Sendable (AudioFileWriterEvent) -> Void

  /// The immutable session configuration.
  public nonisolated let configuration: AudioFileWriterConfiguration

  /// The bounded queue written by one realtime producer.
  public nonisolated let frameBuffer: AudioRealtimeFrameBuffer

  private enum State {
    case idle
    case starting(UUID)
    case running(
      url: URL,
      signal: AudioFileWriterStopSignal,
      task: Task<Result<AudioFileWriterCompletion, AudioFileWriterError>, Never>
    )
    case stopping(Task<Result<AudioFileWriterCompletion, AudioFileWriterError>, Never>)
  }

  private let capabilities: AudioFileWritingCapabilities
  private let eventHandler: EventHandler
  private var state = State.idle

  /// Allocates the fixed producer queue without opening or creating the destination.
  public init(
    configuration: AudioFileWriterConfiguration,
    capabilities: AudioFileWritingCapabilities = .current(),
    eventHandler: @escaping EventHandler = { _ in }
  ) throws {
    self.configuration = configuration
    self.capabilities = capabilities
    self.eventHandler = eventHandler
    guard capabilities.supports(configuration.encoding) else {
      throw AudioFileWriterError.encoderUnavailable(configuration.encoding)
    }
    frameBuffer = try AudioRealtimeFrameBuffer(
      format: AudioProcessingFormat(
        sampleRate: configuration.sampleRate,
        channelCount: configuration.channelCount
      ),
      capacityFrameCount: configuration.capacityFrameCount
    )
  }

  deinit {
    switch state {
    case .running(_, let signal, let task):
      signal.requestStop()
      task.cancel()
    case .stopping(let task):
      task.cancel()
    case .idle, .starting:
      break
    }
  }

  /// Creates the destination and starts the background consumer.
  ///
  /// Repeated calls while running return the active session URL. Concurrent startup calls fail
  /// deterministically instead of creating multiple files.
  @discardableResult
  public func start() async throws -> URL {
    switch state {
    case .running(let url, _, _): return url
    case .starting, .stopping: throw AudioFileWriterError.cancelled
    case .idle: break
    }

    let token = UUID()
    state = .starting(token)
    let configuration = configuration
    let result = await Task.detached(priority: .utility) {
      Result { try AudioFileWritingSession(configuration: configuration) }
    }.value
    let session = try result.get()
    guard case .starting(token) = state else {
      session.close()
      throw AudioFileWriterError.cancelled
    }

    let signal = AudioFileWriterStopSignal()
    let frameBuffer = frameBuffer
    let eventHandler = eventHandler
    let task = Task.detached(priority: .utility) {
      let result: Result<AudioFileWriterCompletion, AudioFileWriterError>
      do {
        result = .success(
          try await session.consume(
            frameBuffer: frameBuffer,
            chunkFrameCount: configuration.chunkFrameCount,
            stopSignal: signal
          ))
      } catch let error as AudioFileWriterError {
        result = .failure(error)
      } catch {
        result = .failure(.writeFailed(status: Int32(kAudioFileUnspecifiedError)))
      }
      switch result {
      case .success(let completion):
        eventHandler(.completed(url: completion.url, frameCount: completion.frameCount))
      case .failure(let error):
        eventHandler(.failed(error))
      }
      return result
    }
    state = .running(url: session.url, signal: signal, task: task)
    return session.url
  }

  /// Requests a drain, waits for file finalization, and returns the terminal result.
  @discardableResult
  public func stop() async -> Result<URL?, AudioFileWriterError> {
    switch state {
    case .idle:
      return .success(nil)
    case .starting:
      state = .idle
      return .success(nil)
    case .running(_, let signal, let task):
      signal.requestStop()
      state = .stopping(task)
      let result = await task.value
      state = .idle
      return result.map(\.url)
    case .stopping(let task):
      let result = await task.value
      state = .idle
      return result.map(\.url)
    }
  }

  /// The active file URL, if startup has completed.
  public var outputURL: URL? {
    guard case .running(let url, _, _) = state else { return nil }
    return url
  }
}

private struct AudioFileWriterCompletion: Sendable {
  let url: URL
  let frameCount: UInt64
}

private final class AudioFileWriterStopSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var isRequested: Bool { lock.withLock { value } }

  func requestStop() {
    lock.withLock { value = true }
  }
}

private final class AudioFileWritingSession: @unchecked Sendable {
  private static let maximumCollisionSequenceNumber = 10_000

  let url: URL

  private let file: ExtAudioFileRef
  private let storage: AudioFileWriteStorage
  private let closeLock = NSLock()
  private var isClosed = false

  init(configuration: AudioFileWriterConfiguration) throws {
    url = try Self.resolveDestination(for: configuration)
    var destinationFormat = try Self.destinationFormat(for: configuration)
    var createdFile: ExtAudioFileRef?
    let flags: UInt32 =
      configuration.collisionPolicy == .replace
      ? AudioFileFlags.eraseFile.rawValue : 0
    let createStatus = ExtAudioFileCreateWithURL(
      url as CFURL,
      configuration.container.audioFileTypeID,
      &destinationFormat,
      nil,
      flags,
      &createdFile
    )
    guard createStatus == noErr, let createdFile else {
      throw AudioFileWriterError.createFailed(
        operation: "ExtAudioFileCreateWithURL",
        status: createStatus
      )
    }
    file = createdFile
    storage = AudioFileWriteStorage(
      channelCount: configuration.channelCount,
      capacityFrameCount: configuration.chunkFrameCount
    )

    do {
      try Self.configureClientFormat(file: createdFile, configuration: configuration)
      try Self.configureEncoder(file: createdFile, encoding: configuration.encoding)
    } catch {
      ExtAudioFileDispose(createdFile)
      throw error
    }
  }

  deinit { close() }

  func consume(
    frameBuffer: AudioRealtimeFrameBuffer,
    chunkFrameCount: Int,
    stopSignal: AudioFileWriterStopSignal
  ) async throws -> AudioFileWriterCompletion {
    defer { close() }
    var writtenFrameCount: UInt64 = 0
    while !stopSignal.isRequested || frameBuffer.statistics().availableFrameCount > 0 {
      let availableFrameCount = frameBuffer.statistics().availableFrameCount
      guard availableFrameCount > 0 else {
        try await Task.sleep(for: .milliseconds(2))
        continue
      }
      let requestedFrameCount = min(chunkFrameCount, availableFrameCount)
      let result = storage.withMutableChannelPointers { pointers in
        frameBuffer.read(into: pointers, frameCount: requestedFrameCount)
      }
      guard case .read(let copiedFrameCount, _) = result, copiedFrameCount > 0 else {
        continue
      }
      let writeStatus = ExtAudioFileWrite(
        file,
        UInt32(copiedFrameCount),
        storage.prepare(frameCount: copiedFrameCount)
      )
      guard writeStatus == noErr else {
        throw AudioFileWriterError.writeFailed(status: writeStatus)
      }
      writtenFrameCount &+= UInt64(copiedFrameCount)
    }
    return AudioFileWriterCompletion(url: url, frameCount: writtenFrameCount)
  }

  func close() {
    closeLock.withLock {
      guard !isClosed else { return }
      isClosed = true
      ExtAudioFileDispose(file)
    }
  }

  private static func resolveDestination(
    for configuration: AudioFileWriterConfiguration
  ) throws -> URL {
    let baseURL = configuration.destinationURL
    switch configuration.collisionPolicy {
    case .replace:
      return baseURL
    case .fail:
      guard !FileManager.default.fileExists(atPath: baseURL.path) else {
        throw AudioFileWriterError.destinationExists(baseURL)
      }
      return baseURL
    case .appendSequenceNumber:
      guard FileManager.default.fileExists(atPath: baseURL.path) else { return baseURL }
      let directory = baseURL.deletingLastPathComponent()
      let fileExtension = baseURL.pathExtension
      let stem = baseURL.deletingPathExtension().lastPathComponent
      for suffix in 2...maximumCollisionSequenceNumber {
        var candidate = directory.appendingPathComponent("\(stem) \(suffix)")
        if !fileExtension.isEmpty {
          candidate.appendPathExtension(fileExtension)
        }
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
      }
      throw AudioFileWriterError.destinationExists(baseURL)
    }
  }

  private static func destinationFormat(
    for configuration: AudioFileWriterConfiguration
  ) throws -> AudioStreamBasicDescription {
    let channelCount = UInt32(configuration.channelCount)
    switch configuration.encoding {
    case .integerPCM(let bitDepth):
      let bytesPerSample = UInt32(bitDepth / 8)
      var flags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
      if configuration.container == .aiff { flags |= kAudioFormatFlagIsBigEndian }
      return AudioStreamBasicDescription(
        mSampleRate: configuration.sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: flags,
        mBytesPerPacket: bytesPerSample * channelCount,
        mFramesPerPacket: 1,
        mBytesPerFrame: bytesPerSample * channelCount,
        mChannelsPerFrame: channelCount,
        mBitsPerChannel: UInt32(bitDepth),
        mReserved: 0
      )
    case .float32PCM:
      let bytesPerSample = UInt32(MemoryLayout<Float>.stride)
      return AudioStreamBasicDescription(
        mSampleRate: configuration.sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
        mBytesPerPacket: bytesPerSample * channelCount,
        mFramesPerPacket: 1,
        mBytesPerFrame: bytesPerSample * channelCount,
        mChannelsPerFrame: channelCount,
        mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
        mReserved: 0
      )
    case .aac:
      return try filledCompressedFormat(
        sampleRate: configuration.sampleRate,
        formatID: kAudioFormatMPEG4AAC,
        formatFlags: 0,
        channelCount: channelCount
      )
    case .appleLossless(let bitDepth):
      let flag: AudioFormatFlags =
        switch bitDepth {
        case 16: kAppleLosslessFormatFlag_16BitSourceData
        case 20: kAppleLosslessFormatFlag_20BitSourceData
        case 24: kAppleLosslessFormatFlag_24BitSourceData
        default: kAppleLosslessFormatFlag_32BitSourceData
        }
      return try filledCompressedFormat(
        sampleRate: configuration.sampleRate,
        formatID: kAudioFormatAppleLossless,
        formatFlags: flag,
        channelCount: channelCount
      )
    }
  }

  private static func filledCompressedFormat(
    sampleRate: Double,
    formatID: AudioFormatID,
    formatFlags: AudioFormatFlags,
    channelCount: UInt32
  ) throws -> AudioStreamBasicDescription {
    var format = AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: formatID,
      mFormatFlags: formatFlags,
      mBytesPerPacket: 0,
      mFramesPerPacket: 0,
      mBytesPerFrame: 0,
      mChannelsPerFrame: channelCount,
      mBitsPerChannel: 0,
      mReserved: 0
    )
    var byteCount = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioFormatGetProperty(
      kAudioFormatProperty_FormatInfo,
      0,
      nil,
      &byteCount,
      &format
    )
    guard status == noErr else {
      throw AudioFileWriterError.formatConfigurationFailed(
        operation: "AudioFormatGetProperty(kAudioFormatProperty_FormatInfo)",
        status: status
      )
    }
    return format
  }

  private static func configureClientFormat(
    file: ExtAudioFileRef,
    configuration: AudioFileWriterConfiguration
  ) throws {
    var clientFormat = AudioStreamBasicDescription(
      mSampleRate: configuration.sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
      mBytesPerPacket: UInt32(MemoryLayout<Float>.stride),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(MemoryLayout<Float>.stride),
      mChannelsPerFrame: UInt32(configuration.channelCount),
      mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
      mReserved: 0
    )
    let status = ExtAudioFileSetProperty(
      file,
      kExtAudioFileProperty_ClientDataFormat,
      UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
      &clientFormat
    )
    guard status == noErr else {
      throw AudioFileWriterError.formatConfigurationFailed(
        operation: "ExtAudioFileSetProperty(kExtAudioFileProperty_ClientDataFormat)",
        status: status
      )
    }
  }

  private static func configureEncoder(
    file: ExtAudioFileRef,
    encoding: AudioFileEncoding
  ) throws {
    guard case .aac(let bitRate) = encoding else { return }
    var converter: AudioConverterRef?
    var propertySize = UInt32(MemoryLayout<AudioConverterRef?>.size)
    let converterStatus = ExtAudioFileGetProperty(
      file,
      kExtAudioFileProperty_AudioConverter,
      &propertySize,
      &converter
    )
    guard converterStatus == noErr, let converter else {
      throw AudioFileWriterError.formatConfigurationFailed(
        operation: "ExtAudioFileGetProperty(kExtAudioFileProperty_AudioConverter)",
        status: converterStatus
      )
    }
    var targetBitRate = UInt32(bitRate)
    let bitRateStatus = AudioConverterSetProperty(
      converter,
      kAudioConverterEncodeBitRate,
      UInt32(MemoryLayout<UInt32>.size),
      &targetBitRate
    )
    guard bitRateStatus == noErr else {
      throw AudioFileWriterError.formatConfigurationFailed(
        operation: "AudioConverterSetProperty(kAudioConverterEncodeBitRate)",
        status: bitRateStatus
      )
    }
  }
}

private final class AudioFileWriteStorage {
  private let bufferList: UnsafeMutableAudioBufferListPointer
  private let channelStorage: [UnsafeMutablePointer<Float>]
  private let capacityFrameCount: Int

  init(channelCount: Int, capacityFrameCount: Int) {
    self.capacityFrameCount = capacityFrameCount
    bufferList = AudioBufferList.allocate(maximumBuffers: channelCount)
    channelStorage = (0..<channelCount).map { _ in
      UnsafeMutablePointer<Float>.allocate(capacity: capacityFrameCount)
    }
    bufferList.count = channelCount
    for channel in 0..<channelCount {
      bufferList[channel] = AudioBuffer(
        mNumberChannels: 1,
        mDataByteSize: UInt32(capacityFrameCount * MemoryLayout<Float>.stride),
        mData: channelStorage[channel]
      )
    }
  }

  deinit {
    for pointer in channelStorage { pointer.deallocate() }
    bufferList.unsafeMutablePointer.deallocate()
  }

  func withMutableChannelPointers<Result>(
    _ body: (UnsafeBufferPointer<UnsafeMutablePointer<Float>>) throws -> Result
  ) rethrows -> Result {
    try channelStorage.withUnsafeBufferPointer(body)
  }

  func prepare(frameCount: Int) -> UnsafePointer<AudioBufferList> {
    precondition((0...capacityFrameCount).contains(frameCount))
    let byteCount = UInt32(frameCount * MemoryLayout<Float>.stride)
    for index in bufferList.indices { bufferList[index].mDataByteSize = byteCount }
    return UnsafePointer(bufferList.unsafeMutablePointer)
  }
}
