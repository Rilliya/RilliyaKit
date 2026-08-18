// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import Foundation
import RilliyaCore
import RilliyaRealtime
import os

/// The number of complete passes a file stream performs before finishing.
public enum AudioFileLoopMode: Equatable, Hashable, Sendable {
  /// Plays the file once.
  case once

  /// Plays the file a finite number of times, including the first pass.
  case playCount(Int)

  /// Repeats until the stream is stopped.
  case infinite
}

/// Immutable source metadata reported before streaming begins.
public struct AudioFileDescription: Equatable, Hashable, Sendable {
  /// The file's native sample rate.
  public let sampleRate: Double

  /// The number of decoded channels.
  public let channelCount: Int

  /// The file length in native sample frames, when reported by the decoder.
  public let frameCount: Int64?

  /// Creates source metadata for custom file-stream adapters and tests.
  public init(sampleRate: Double, channelCount: Int, frameCount: Int64?) throws {
    guard sampleRate.isFinite, sampleRate > 0 else {
      throw AudioFileFrameStreamError.invalidSampleRate(sampleRate)
    }
    guard (1...AudioProcessingFormat.maximumChannelCount).contains(channelCount) else {
      throw AudioFileFrameStreamError.unsupportedChannelCount(channelCount)
    }
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.frameCount = frameCount
  }
}

/// Bounded streaming controls for one audio file.
public struct AudioFileFrameStreamConfiguration: Equatable, Hashable, Sendable {
  /// The largest accepted finite play count.
  public static let maximumPlayCount = 10_000

  /// The destination graph sample rate.
  ///
  /// Core Audio converts supported file formats to this rate.
  public let sampleRate: Double

  /// The number of complete file passes.
  public let loopMode: AudioFileLoopMode

  /// The fixed PCM queue capacity prepared for each destination.
  public let capacityFrameCount: Int

  /// How many destinations may read this file at once, each on its own clock.
  public let maximumDestinationCount: Int

  /// The destinations a file is given room for when the caller does not say.
  public static let preferredDestinationCount = 8

  /// The largest file read performed by the background producer.
  public let chunkFrameCount: Int

  /// How many times a second the meter reports what has been decoded.
  ///
  /// Only what draws it cares, so it is here rather than fixed.
  public let waveformUpdatesPerSecond: Int

  /// Creates validated, bounded file-streaming controls.
  public init(
    sampleRate: Double,
    loopMode: AudioFileLoopMode = .once,
    capacityFrameCount: Int = 16_384,
    chunkFrameCount: Int = 1_024,
    waveformUpdatesPerSecond: Int = AudioWaveformMeter.defaultUpdatesPerSecond,
    maximumDestinationCount: Int? = nil
  ) throws {
    guard sampleRate.isFinite, sampleRate > 0 else {
      throw AudioFileFrameStreamError.invalidSampleRate(sampleRate)
    }
    guard Self.isValid(loopMode: loopMode) else {
      throw AudioFileFrameStreamError.invalidLoopMode
    }
    guard
      (2...AudioRealtimeFrameBuffer.maximumCapacityFrameCount).contains(
        capacityFrameCount
      ),
      (1...capacityFrameCount).contains(chunkFrameCount)
    else {
      throw AudioFileFrameStreamError.invalidBufferConfiguration
    }
    self.sampleRate = sampleRate
    self.loopMode = loopMode
    self.capacityFrameCount = capacityFrameCount
    self.maximumDestinationCount = maximumDestinationCount ?? Self.preferredDestinationCount
    self.chunkFrameCount = chunkFrameCount
    self.waveformUpdatesPerSecond = waveformUpdatesPerSecond
  }

  private static func isValid(loopMode: AudioFileLoopMode) -> Bool {
    switch loopMode {
    case .once, .infinite:
      true
    case .playCount(let count):
      (1...maximumPlayCount).contains(count)
    }
  }
}

/// A file-stream setup or background decoding failure.
public enum AudioFileFrameStreamError: Error, Equatable, LocalizedError, Sendable {
  /// The source must be a local file URL.
  case nonFileURL

  /// The requested destination sample rate is invalid.
  case invalidSampleRate(Double)

  /// A finite loop count is outside the supported bound.
  case invalidLoopMode

  /// The requested queue or chunk size is invalid.
  case invalidBufferConfiguration

  /// The decoded channel count is outside the processing bound.
  case unsupportedChannelCount(Int)

  /// Core Audio could not open or inspect the source.
  case openFailed(status: Int32)

  /// Core Audio could not configure decoded Float32 output.
  case formatConfigurationFailed(status: Int32)

  /// Core Audio could not decode the next file chunk.
  case readFailed(status: Int32)

  /// Core Audio could not return to the beginning for another pass.
  case seekFailed(status: Int32)

  /// A localized explanation suitable for a host application's error surface.
  public var errorDescription: String? {
    switch self {
    case .nonFileURL:
      "Audio file playback requires a local file URL."
    case .invalidSampleRate(let sampleRate):
      "The file playback sample rate must be finite and positive; received \(sampleRate)."
    case .invalidLoopMode:
      "The finite file playback count must be between 1 and 10,000."
    case .invalidBufferConfiguration:
      "The file playback queue and read chunk must be positive and remain within bounded storage."
    case .unsupportedChannelCount(let count):
      "The decoded file channel count must be between 1 and 256; received \(count)."
    case .openFailed(let status):
      "Core Audio could not open the audio file (status \(status))."
    case .formatConfigurationFailed(let status):
      "Core Audio could not prepare the requested decoded format (status \(status))."
    case .readFailed(let status):
      "Core Audio could not decode the audio file (status \(status))."
    case .seekFailed(let status):
      "Core Audio could not restart the audio file loop (status \(status))."
    }
  }
}

/// A terminal event from the non-realtime file producer.
public enum AudioFileFrameStreamEvent: Equatable, Sendable {
  /// Every requested pass reached end of file.
  case completed

  /// Background decoding stopped after a typed failure.
  case failed(AudioFileFrameStreamError)
}

/// The one way to see why a file is or is not moving, and only while building for debugging.
///
/// A producer keeping its queues full says so on every cycle, so what is worth reading is never
/// one line but whether it stays at the same one. That is a question asked while diagnosing, not
/// something a shipped build should spend anything on, so outside a debug build this is nothing.
private enum ProducerDiagnostics {
  #if DEBUG
    private static let log = Logger(
      subsystem: "moe.uwucocoa.rilliyakit",
      category: "file-playback"
    )
  #endif

  /// Reports one change in why the producer is or is not moving.
  static func report(_ message: @autoclosure () -> String) {
    #if DEBUG
      let text = message()
      log.debug("\(text, privacy: .public)")
    #endif
  }
}

/// What the producer last said about why it is or is not moving, so it says it once per change.
private enum ProducerReport {
  case advancing
  case noDestination
  case destinationFull
}

/// Streams a supported local audio file into one bounded realtime PCM buffer.
///
/// File IO, decoding, sample-rate conversion, and loop seeking run on a background task. The
/// realtime consumer only reads the queue it claimed. One stream serves several destinations and
/// never loads the complete file into memory.
public final class AudioFileFrameStream: @unchecked Sendable {
  /// Receives completion or failure away from the realtime thread.
  public typealias EventHandler = @Sendable (AudioFileFrameStreamEvent) -> Void

  /// Source metadata discovered during initialization.
  public let sourceDescription: AudioFileDescription

  /// The decoded audio every destination is served from.
  ///
  /// A file source owes each destination the same fixed sequence, so each gets a queue of its own
  /// and the reader advances no faster than the fullest of them: writing past that would not slow
  /// a destination down, it would drop what did not fit, which here is audio skipped.
  public let distributor: AudioRealtimeFrameDistributor

  /// Claims one destination's queue.
  ///
  /// Reading a destination's queue is what lets the file advance, so a claimed destination that is
  /// never read holds playback for every other. Releasing the subscription gives its slot back.
  public func subscribe() throws -> AudioRealtimeFrameSubscription {
    try distributor.subscribe()
  }

  /// What the file currently sounds like, one entry per channel.
  ///
  /// Reading a destination's queue would take the audio away from whatever is playing it, so
  /// anything that wants to draw the file reads this instead.
  public func meterSnapshot() -> [AudioChannelMeterSnapshot] { meter.snapshot() }

  /// Called whenever there is a new waveform to draw, on the thread that decoded it.
  ///
  /// Polling ``meterSnapshot()`` is not enough for anything that draws: with nothing to say the
  /// audio moved, an interface redraws only when something else happens to change.
  public func onMeter(_ handler: (@Sendable ([AudioChannelMeterSnapshot]) -> Void)?) {
    meter.onPublish(handler)
  }

  private let meter: AudioWaveformMeter
  private let streamID = UUID()
  private let url: URL
  private let configuration: AudioFileFrameStreamConfiguration
  private let eventHandler: EventHandler
  private let lock = NSLock()
  private var task: Task<Void, Never>?

  /// Inspects a file using the same public Core Audio decoder used for streaming.
  public static func inspect(_ url: URL) throws -> AudioFileDescription {
    guard url.isFileURL else { throw AudioFileFrameStreamError.nonFileURL }
    var file: ExtAudioFileRef?
    let openStatus = ExtAudioFileOpenURL(url as CFURL, &file)
    guard openStatus == noErr, let file else {
      throw AudioFileFrameStreamError.openFailed(status: openStatus)
    }
    defer { ExtAudioFileDispose(file) }
    return try description(of: file)
  }

  /// Validates the source and allocates its fixed queue without starting file IO.
  public init(
    url: URL,
    configuration: AudioFileFrameStreamConfiguration,
    eventHandler: @escaping EventHandler = { _ in }
  ) throws {
    sourceDescription = try Self.inspect(url)
    self.url = url
    self.configuration = configuration
    self.eventHandler = eventHandler
    // Every destination is preallocated, so a wide file affords fewer of them. Playing to one
    // place is worth more than refusing the file outright, so the count comes down to what the
    // file's own width leaves room for.
    let affordableDestinationCount =
      AudioRealtimeFrameDistributor.maximumAggregateSampleCapacity
      / max(1, sourceDescription.channelCount * configuration.capacityFrameCount)
    distributor = try AudioRealtimeFrameDistributor(
      format: AudioProcessingFormat(
        sampleRate: configuration.sampleRate,
        channelCount: sourceDescription.channelCount
      ),
      capacityFrameCount: configuration.capacityFrameCount,
      maximumSubscriberCount: max(
        1,
        min(configuration.maximumDestinationCount, affordableDestinationCount)
      )
    )
    let streamID = self.streamID
    meter = AudioWaveformMeter(
      channelIDs: (0..<sourceDescription.channelCount).compactMap { index in
        AudioChannelIndex(rawValue: index).map {
          AudioChannelID(ownerID: .source(.stream(streamID)), index: $0)
        }
      },
      sampleRate: configuration.sampleRate,
      interval: AudioWaveformMeter.interval(
        forUpdatesPerSecond: configuration.waveformUpdatesPerSecond)
    )
  }

  deinit {
    lock.withLock { task?.cancel() }
  }

  /// Starts one background producer.
  ///
  /// Repeated calls while active are idempotent.
  public func start() {
    lock.withLock {
      guard task == nil else { return }
      let url = url
      let configuration = configuration
      let channelCount = sourceDescription.channelCount
      let distributor = distributor
      let meter = meter
      let eventHandler = eventHandler
      task = Task.detached(priority: .userInitiated) {
        do {
          try await Self.produce(
            url: url,
            configuration: configuration,
            channelCount: channelCount,
            distributor: distributor,
            meter: meter
          )
          if !Task.isCancelled {
            eventHandler(.completed)
          }
        } catch is CancellationError {
          return
        } catch let error as AudioFileFrameStreamError {
          if !Task.isCancelled {
            eventHandler(.failed(error))
          }
        } catch {
          if !Task.isCancelled {
            eventHandler(.failed(.readFailed(status: Int32(kAudioFileUnspecifiedError))))
          }
        }
      }
    }
  }

  /// Stops the producer and waits for its file handle and temporary storage to be released.
  public func stop() async {
    let activeTask = lock.withLock { () -> Task<Void, Never>? in
      let activeTask = task
      task = nil
      return activeTask
    }
    activeTask?.cancel()
    await activeTask?.value
  }

  private static func description(of file: ExtAudioFileRef) throws -> AudioFileDescription {
    var format = AudioStreamBasicDescription()
    var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let formatStatus = ExtAudioFileGetProperty(
      file,
      kExtAudioFileProperty_FileDataFormat,
      &formatSize,
      &format
    )
    guard formatStatus == noErr else {
      throw AudioFileFrameStreamError.openFailed(status: formatStatus)
    }
    let channelCount = Int(format.mChannelsPerFrame)
    guard (1...AudioProcessingFormat.maximumChannelCount).contains(channelCount) else {
      throw AudioFileFrameStreamError.unsupportedChannelCount(channelCount)
    }

    var frameCount: Int64 = 0
    var frameCountSize = UInt32(MemoryLayout<Int64>.size)
    let frameCountStatus = ExtAudioFileGetProperty(
      file,
      kExtAudioFileProperty_FileLengthFrames,
      &frameCountSize,
      &frameCount
    )
    return try AudioFileDescription(
      sampleRate: format.mSampleRate,
      channelCount: channelCount,
      frameCount: frameCountStatus == noErr && frameCount >= 0 ? frameCount : nil
    )
  }

  private static func produce(
    url: URL,
    configuration: AudioFileFrameStreamConfiguration,
    channelCount: Int,
    distributor: AudioRealtimeFrameDistributor,
    meter: AudioWaveformMeter
  ) async throws {
    var file: ExtAudioFileRef?
    let openStatus = ExtAudioFileOpenURL(url as CFURL, &file)
    guard openStatus == noErr, let file else {
      throw AudioFileFrameStreamError.openFailed(status: openStatus)
    }
    defer { ExtAudioFileDispose(file) }

    var clientFormat = AudioStreamBasicDescription(
      mSampleRate: configuration.sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
      mBytesPerPacket: UInt32(MemoryLayout<Float>.stride),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(MemoryLayout<Float>.stride),
      mChannelsPerFrame: UInt32(channelCount),
      mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
      mReserved: 0
    )
    let formatStatus = ExtAudioFileSetProperty(
      file,
      kExtAudioFileProperty_ClientDataFormat,
      UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
      &clientFormat
    )
    guard formatStatus == noErr else {
      throw AudioFileFrameStreamError.formatConfigurationFailed(status: formatStatus)
    }

    let storage = AudioFileReadStorage(
      channelCount: channelCount,
      capacityFrameCount: configuration.chunkFrameCount
    )
    var completedPassCount = 0
    var stallReport = ProducerReport.advancing
    while !Task.isCancelled {
      // Paced by the fullest destination, and by nothing at all while none is reading: a file
      // read into queues nobody holds is audio decoded and then thrown away.
      guard let fullest = distributor.maximumAvailableFrameCount else {
        if stallReport != .noDestination {
          stallReport = .noDestination
          ProducerDiagnostics.report("no destination is reading this file")
        }
        try await Task.sleep(for: .milliseconds(2))
        continue
      }
      let writable = distributor.capacityFrameCount - fullest
      if writable == 0 {
        if stallReport != .destinationFull {
          stallReport = .destinationFull
          // The resting state of a throttled producer, not a fault: the file stays a queue ahead
          // of whichever destination is furthest behind, and only moves as that one reads.
          ProducerDiagnostics.report(
            "queues full at \(distributor.capacityFrameCount) frames, waiting for a read")
        }
        try await Task.sleep(for: .milliseconds(2))
        continue
      }
      if stallReport != .advancing {
        stallReport = .advancing
        ProducerDiagnostics.report(
          "advancing to \(distributor.activeSubscriberCount) destinations")
      }

      var requestedFrameCount = UInt32(min(configuration.chunkFrameCount, writable))
      let readStatus = ExtAudioFileRead(
        file,
        &requestedFrameCount,
        storage.prepare(frameCount: requestedFrameCount)
      )
      guard readStatus == noErr else {
        throw AudioFileFrameStreamError.readFailed(status: readStatus)
      }
      if requestedFrameCount > 0 {
        storage.withChannelPointers { pointers in
          _ = distributor.writePlanar(pointers, frameCount: Int(requestedFrameCount))
          meter.submit(planar: pointers, frameCount: Int(requestedFrameCount))
        }
        continue
      }

      completedPassCount += 1
      guard
        shouldRepeat(
          loopMode: configuration.loopMode,
          completedPassCount: completedPassCount
        )
      else {
        return
      }
      let seekStatus = ExtAudioFileSeek(file, 0)
      guard seekStatus == noErr else {
        throw AudioFileFrameStreamError.seekFailed(status: seekStatus)
      }
    }
    throw CancellationError()
  }

  private static func shouldRepeat(
    loopMode: AudioFileLoopMode,
    completedPassCount: Int
  ) -> Bool {
    switch loopMode {
    case .once:
      false
    case .playCount(let count):
      completedPassCount < count
    case .infinite:
      true
    }
  }
}

private final class AudioFileReadStorage {
  private let bufferList: UnsafeMutableAudioBufferListPointer
  private let channelStorage: [UnsafeMutablePointer<Float>]
  private let channelPointers: [UnsafePointer<Float>]
  private let capacityFrameCount: Int

  init(channelCount: Int, capacityFrameCount: Int) {
    self.capacityFrameCount = capacityFrameCount
    bufferList = AudioBufferList.allocate(maximumBuffers: channelCount)
    let storage = (0..<channelCount).map { _ -> UnsafeMutablePointer<Float> in
      UnsafeMutablePointer<Float>.allocate(capacity: capacityFrameCount)
    }
    channelStorage = storage
    channelPointers = storage.map { UnsafePointer<Float>($0) }
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
    for pointer in channelStorage {
      pointer.deallocate()
    }
    bufferList.unsafeMutablePointer.deallocate()
  }

  func prepare(frameCount: UInt32) -> UnsafeMutablePointer<AudioBufferList> {
    precondition(frameCount <= capacityFrameCount)
    let byteCount = frameCount * UInt32(MemoryLayout<Float>.stride)
    for index in bufferList.indices {
      bufferList[index].mDataByteSize = byteCount
    }
    return bufferList.unsafeMutablePointer
  }

  func withChannelPointers<Result>(
    _ body: (UnsafeBufferPointer<UnsafePointer<Float>>) throws -> Result
  ) rethrows -> Result {
    try channelPointers.withUnsafeBufferPointer(body)
  }
}
