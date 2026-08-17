// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import Foundation
import RilliyaRealtime
import Testing

@testable import RilliyaFilePlayback

@Suite("Audio file frame stream")
struct AudioFileFrameStreamTests {
  @Test("Inspects and streams a supported file without whole-file storage")
  func streamsSupportedFile() async throws {
    let fixture = try TemporaryPCMFile(samples: [0.25, -0.5, 0.75, -1])
    let description = try AudioFileFrameStream.inspect(fixture.url)
    #expect(description.sampleRate == 48_000)
    #expect(description.channelCount == 1)
    #expect(description.frameCount == 4)

    let events = AsyncStream.makeStream(of: AudioFileFrameStreamEvent.self)
    let source = try AudioFileFrameStream(
      url: fixture.url,
      configuration: AudioFileFrameStreamConfiguration(
        sampleRate: 48_000,
        capacityFrameCount: 8,
        chunkFrameCount: 4
      )
    ) { event in
      events.continuation.yield(event)
    }
    source.start()
    let event = await events.stream.first { _ in true }
    #expect(event == .completed)

    let rendered = read(source.frameBuffer, frameCount: 4)
    #expect(rendered == [0.25, -0.5, 0.75, -1])
    #expect(source.frameBuffer.statistics().droppedFrameCount == 0)
    await source.stop()
  }

  /// A file being played has no capture device to meter it, so it meters what it decodes.
  ///
  /// Without this an interface can draw nothing for a file, however audibly it is playing —
  /// which is exactly what a visualizer connected to one used to show.
  @Test("A playing file reports what it sounds like")
  func fileReportsWhatItSoundsLike() async throws {
    // Enough frames that a metering interval fills: fifty milliseconds at 48 kHz is 2400.
    let frameCount = 6_000
    let samples = (0..<frameCount).map { frame in
      Float(0.5 * sin(2 * .pi * 440 * Double(frame) / 48_000))
    }
    let fixture = try TemporaryPCMFile(samples: samples)
    let events = AsyncStream.makeStream(of: AudioFileFrameStreamEvent.self)
    let source = try AudioFileFrameStream(
      url: fixture.url,
      configuration: AudioFileFrameStreamConfiguration(
        sampleRate: 48_000,
        capacityFrameCount: 16_384,
        chunkFrameCount: 1_024
      )
    ) { event in
      events.continuation.yield(event)
    }

    #expect(source.meterSnapshot().isEmpty, "nothing has been decoded yet")

    source.start()
    _ = await events.stream.first { _ in true }

    let snapshot = source.meterSnapshot()
    #expect(snapshot.count == 1, "one entry for the file's one channel")
    let channel = try #require(snapshot.first)
    #expect(!channel.waveform.isEmpty)
    #expect(channel.rootMeanSquare > 0.1, "the file metered as silence")
    #expect(channel.waveform.contains { abs($0) > 0.1 })
    await source.stop()
  }

  @Test("Finite looping counts complete file passes")
  func finiteLooping() async throws {
    let fixture = try TemporaryPCMFile(samples: [0.25, -0.25])
    let events = AsyncStream.makeStream(of: AudioFileFrameStreamEvent.self)
    let source = try AudioFileFrameStream(
      url: fixture.url,
      configuration: AudioFileFrameStreamConfiguration(
        sampleRate: 48_000,
        loopMode: .playCount(2),
        capacityFrameCount: 8,
        chunkFrameCount: 2
      )
    ) { event in
      events.continuation.yield(event)
    }
    source.start()
    let event = await events.stream.first { _ in true }
    #expect(event == .completed)

    #expect(read(source.frameBuffer, frameCount: 4) == [0.25, -0.25, 0.25, -0.25])
    await source.stop()
  }

  @Test("Rejects invalid bounded configurations")
  func rejectsInvalidConfiguration() {
    #expect(throws: AudioFileFrameStreamError.invalidSampleRate(0)) {
      _ = try AudioFileFrameStreamConfiguration(sampleRate: 0)
    }
    #expect(throws: AudioFileFrameStreamError.invalidLoopMode) {
      _ = try AudioFileFrameStreamConfiguration(
        sampleRate: 48_000,
        loopMode: .playCount(0)
      )
    }
    #expect(throws: AudioFileFrameStreamError.invalidBufferConfiguration) {
      _ = try AudioFileFrameStreamConfiguration(
        sampleRate: 48_000,
        capacityFrameCount: 32,
        chunkFrameCount: 64
      )
    }
  }
}

private final class TemporaryPCMFile {
  let url: URL

  init(samples: [Float]) throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("caf")

    var format = AudioStreamBasicDescription(
      mSampleRate: 48_000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
      mBytesPerPacket: UInt32(MemoryLayout<Float>.stride),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(MemoryLayout<Float>.stride),
      mChannelsPerFrame: 1,
      mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
      mReserved: 0
    )
    var file: AudioFileID?
    let createStatus = AudioFileCreateWithURL(
      url as CFURL,
      kAudioFileCAFType,
      &format,
      .eraseFile,
      &file
    )
    guard createStatus == noErr, let file else {
      throw TestFixtureError.createFailed(createStatus)
    }
    defer { AudioFileClose(file) }

    var byteCount = UInt32(samples.count * MemoryLayout<Float>.stride)
    let writeStatus = samples.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else {
        return kAudioFileUnspecifiedError
      }
      return AudioFileWriteBytes(file, false, 0, &byteCount, baseAddress)
    }
    guard writeStatus == noErr else {
      throw TestFixtureError.writeFailed(writeStatus)
    }
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}

private enum TestFixtureError: Error {
  case createFailed(OSStatus)
  case writeFailed(OSStatus)
}

private func read(_ buffer: AudioRealtimeFrameBuffer, frameCount: Int) -> [Float] {
  let storage = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
  storage.initialize(repeating: .nan, count: frameCount)
  defer {
    storage.deinitialize(count: frameCount)
    storage.deallocate()
  }
  let channels = [storage]
  channels.withUnsafeBufferPointer {
    _ = buffer.read(into: $0, frameCount: frameCount)
  }
  return Array(UnsafeBufferPointer(start: storage, count: frameCount))
}
