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
    let destination = try source.subscribe()
    source.start()
    let event = await events.stream.first { _ in true }
    #expect(event == .completed)

    let rendered = read(destination, frameCount: 4)
    #expect(rendered == [0.25, -0.5, 0.75, -1])
    #expect(destination.statistics().frameBuffer.droppedFrameCount == 0)
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

    let destination = try source.subscribe()
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
    let destination = try source.subscribe()
    source.start()
    let event = await events.stream.first { _ in true }
    #expect(event == .completed)

    #expect(read(destination, frameCount: 4) == [0.25, -0.25, 0.25, -0.25])
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

/// One file reaching several destinations at once.
///
/// A file owes every destination the same fixed sequence, which is what separates it from a live
/// source: a destination that falls behind is owed audio, not late, so nothing may be dropped to
/// catch it up. The file advances at the pace of whichever destination is furthest behind.
@Suite("Audio file fan-out")
struct AudioFileFanOutTests {
  private static func stream(
    samples: [Float],
    capacityFrameCount: Int = 8,
    chunkFrameCount: Int = 4
  ) throws -> (file: TemporaryPCMFile, source: AudioFileFrameStream) {
    let fixture = try TemporaryPCMFile(samples: samples)
    return (
      fixture,
      try AudioFileFrameStream(
        url: fixture.url,
        configuration: AudioFileFrameStreamConfiguration(
          sampleRate: 48_000,
          capacityFrameCount: capacityFrameCount,
          chunkFrameCount: chunkFrameCount
        )
      ) { _ in }
    )
  }

  @Test("Two destinations each receive the whole file")
  func twoDestinationsEachReceiveEverything() async throws {
    let samples: [Float] = [0.25, -0.5, 0.75, -1]
    let (fixture, source) = try Self.stream(samples: samples)
    defer { _ = fixture }
    let first = try source.subscribe()
    let second = try source.subscribe()
    source.start()
    defer { Task { await source.stop() } }

    #expect(await Self.settles { first.statistics().frameBuffer.availableFrameCount >= 4 })
    #expect(await Self.settles { second.statistics().frameBuffer.availableFrameCount >= 4 })
    // Read the second first: sharing one queue would leave whichever read later with nothing.
    #expect(read(second, frameCount: 4) == samples)
    #expect(read(first, frameCount: 4) == samples)
  }

  /// The property that separates a file from a live source: nothing is dropped to catch anyone up.
  @Test("A destination that never reads holds the file rather than losing its audio")
  func aSlowDestinationIsWaitedFor() async throws {
    // Longer than one queue, so the file can only finish if the reader is actually waited for.
    let samples = (0..<64).map { Float($0 % 8) / 8 - 0.5 }
    let (fixture, source) = try Self.stream(samples: samples, capacityFrameCount: 8)
    defer { _ = fixture }
    let attentive = try source.subscribe()
    let stalled = try source.subscribe()
    source.start()
    defer { Task { await source.stop() } }

    // A read of an empty queue is zero-filled, so only take what has actually arrived.
    var received: [Float] = []
    for _ in 0..<200 where received.count < samples.count {
      if attentive.statistics().frameBuffer.availableFrameCount >= 4 {
        received += read(attentive, frameCount: 4)
      } else {
        try await Task.sleep(for: .milliseconds(5))
      }
    }

    // The stalled destination never read, so its queue is full and stayed full.
    #expect(stalled.statistics().frameBuffer.availableFrameCount > 0)
    #expect(
      stalled.statistics().frameBuffer.droppedFrameCount == 0,
      "a file destination lost audio")
    #expect(
      Array(received.prefix(8)) == Array(samples.prefix(8)),
      "the attentive destination did not receive the file in order")
  }

  /// A file decoded into queues nobody holds is audio read and thrown away.
  @Test("A file with no destination does not advance")
  func aFileWithNoDestinationDoesNotAdvance() async throws {
    let (fixture, source) = try Self.stream(samples: [0.25, -0.5, 0.75, -1])
    defer { _ = fixture }
    source.start()
    defer { Task { await source.stop() } }
    try await Task.sleep(for: .milliseconds(60))

    let destination = try source.subscribe()
    #expect(await Self.settles { destination.statistics().frameBuffer.availableFrameCount >= 4 })
    #expect(
      read(destination, frameCount: 4) == [0.25, -0.5, 0.75, -1],
      "a destination that arrived late missed the start of the file")
  }

  private static func settles(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<200 {
      if predicate() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return false
  }
}

private func read(_ destination: AudioRealtimeFrameSubscription, frameCount: Int) -> [Float] {
  let storage = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
  storage.initialize(repeating: .nan, count: frameCount)
  defer {
    storage.deinitialize(count: frameCount)
    storage.deallocate()
  }
  let channels = [storage]
  channels.withUnsafeBufferPointer {
    _ = destination.read(into: $0, frameCount: frameCount)
  }
  return Array(UnsafeBufferPointer(start: storage, count: frameCount))
}
