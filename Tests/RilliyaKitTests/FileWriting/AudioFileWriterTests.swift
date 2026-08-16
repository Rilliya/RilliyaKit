// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import Foundation
import RilliyaRealtime
import Testing

@testable import RilliyaFileWriting

@Suite("Audio file writer")
struct AudioFileWriterTests {
  @Test("Writes accepted realtime frames and finalizes a Wave file")
  func writesWaveFile() async throws {
    let directory = try TemporaryDirectory()
    let destination = directory.url.appendingPathComponent("capture.wav")
    let configuration = try AudioFileWriterConfiguration(
      destinationURL: destination,
      container: .wave,
      encoding: .integerPCM(bitDepth: 24),
      sampleRate: 48_000,
      channelCount: 2,
      capacityFrameCount: 512,
      chunkFrameCount: 64,
      collisionPolicy: .fail
    )
    let writer = try AudioFileWriter(configuration: configuration)
    let actualURL = try await writer.start()
    #expect(actualURL == destination)

    let left = (0..<256).map { Float($0) / 255 }
    let right = left.map { -$0 }
    let accepted = left.withUnsafeBufferPointer { left in
      right.withUnsafeBufferPointer { right in
        let channels = [left.baseAddress!, right.baseAddress!]
        return channels.withUnsafeBufferPointer {
          writer.frameBuffer.writePlanar($0, frameCount: left.count)
        }
      }
    }
    #expect(accepted == 256)
    #expect(await writer.stop() == .success(destination))

    let description = try inspect(destination)
    #expect(description.sampleRate == 48_000)
    #expect(description.channelCount == 2)
    #expect(description.frameCount == 256)
  }

  @Test("Sequence collision policy preserves an existing recording")
  func preservesExistingRecording() async throws {
    let directory = try TemporaryDirectory()
    let destination = directory.url.appendingPathComponent("capture.caf")
    try Data("existing".utf8).write(to: destination)
    let configuration = try AudioFileWriterConfiguration(
      destinationURL: destination,
      container: .coreAudioFormat,
      encoding: .float32PCM,
      sampleRate: 48_000,
      channelCount: 1,
      collisionPolicy: .appendSequenceNumber
    )
    let writer = try AudioFileWriter(configuration: configuration)
    let actualURL = try await writer.start()
    #expect(actualURL.lastPathComponent == "capture 2.caf")
    #expect(await writer.stop() == .success(actualURL))
    #expect(try Data(contentsOf: destination) == Data("existing".utf8))
  }

  @Test("Rejects incompatible and unavailable encodings")
  func rejectsInvalidEncoding() throws {
    let destination = URL(fileURLWithPath: "/tmp/capture.m4a")
    #expect(throws: AudioFileWriterError.incompatibleContainerAndEncoding) {
      _ = try AudioFileWriterConfiguration(
        destinationURL: destination,
        container: .m4a,
        encoding: .integerPCM(bitDepth: 16),
        sampleRate: 48_000,
        channelCount: 2
      )
    }

    let configuration = try AudioFileWriterConfiguration(
      destinationURL: destination,
      container: .m4a,
      encoding: .aac(bitRate: 192_000),
      sampleRate: 48_000,
      channelCount: 2
    )
    #expect(throws: AudioFileWriterError.encoderUnavailable(.aac(bitRate: 192_000))) {
      _ = try AudioFileWriter(
        configuration: configuration,
        capabilities: AudioFileWritingCapabilities(
          supportsAAC: false,
          supportsAppleLossless: false
        )
      )
    }
  }

  @Test("Filters common AAC targets through advertised encoder ranges")
  func filtersAACBitRates() {
    let candidates = [64_000, 128_000, 192_000, 256_000, 320_000]
    let capabilities = AudioFileWritingCapabilities(
      supportsAAC: true,
      supportsAppleLossless: false,
      aacBitRateRanges: [
        AudioFileBitRateRange(lowerBound: 96_000, upperBound: 256_000)
      ]
    )
    #expect(
      capabilities.supportedAACBitRates(from: candidates)
        == [128_000, 192_000, 256_000]
    )
    #expect(
      AudioFileWritingCapabilities(
        supportsAAC: false,
        supportsAppleLossless: false
      ).supportedAACBitRates(from: candidates).isEmpty
    )
  }

  @Test("Uses installed public M4A encoders")
  func writesAvailableM4AEncoders() async throws {
    let capabilities = AudioFileWritingCapabilities.current()
    let encodings: [AudioFileEncoding] = [
      capabilities.supportsAAC ? .aac(bitRate: 192_000) : nil,
      capabilities.supportsAppleLossless ? .appleLossless(bitDepth: 24) : nil,
    ].compactMap { $0 }
    let directory = try TemporaryDirectory()
    for (index, encoding) in encodings.enumerated() {
      let destination = directory.url
        .appendingPathComponent("encoded-\(index)")
        .appendingPathExtension("m4a")
      let configuration = try AudioFileWriterConfiguration(
        destinationURL: destination,
        container: .m4a,
        encoding: encoding,
        sampleRate: 48_000,
        channelCount: 2,
        capacityFrameCount: 512,
        chunkFrameCount: 128,
        collisionPolicy: .fail
      )
      let writer = try AudioFileWriter(configuration: configuration)
      _ = try await writer.start()
      let samples = [Float](repeating: 0.125, count: 128)
      _ = samples.withUnsafeBufferPointer { samples in
        let channels = [samples.baseAddress!, samples.baseAddress!]
        return channels.withUnsafeBufferPointer {
          writer.frameBuffer.writePlanar($0, frameCount: samples.count)
        }
      }
      #expect(await writer.stop() == .success(destination))
      #expect(try inspect(destination).frameCount == 128)
    }
  }
}

private struct AudioFileInspection {
  let sampleRate: Double
  let channelCount: Int
  let frameCount: Int64
}

private func inspect(_ url: URL) throws -> AudioFileInspection {
  var file: ExtAudioFileRef?
  let openStatus = ExtAudioFileOpenURL(url as CFURL, &file)
  guard openStatus == noErr, let file else { throw InspectionError.status(openStatus) }
  defer { ExtAudioFileDispose(file) }

  var format = AudioStreamBasicDescription()
  var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
  let formatStatus = ExtAudioFileGetProperty(
    file,
    kExtAudioFileProperty_FileDataFormat,
    &formatSize,
    &format
  )
  guard formatStatus == noErr else { throw InspectionError.status(formatStatus) }

  var frameCount: Int64 = 0
  var frameCountSize = UInt32(MemoryLayout<Int64>.size)
  let frameCountStatus = ExtAudioFileGetProperty(
    file,
    kExtAudioFileProperty_FileLengthFrames,
    &frameCountSize,
    &frameCount
  )
  guard frameCountStatus == noErr else { throw InspectionError.status(frameCountStatus) }
  return AudioFileInspection(
    sampleRate: format.mSampleRate,
    channelCount: Int(format.mChannelsPerFrame),
    frameCount: frameCount
  )
}

private enum InspectionError: Error {
  case status(OSStatus)
}

private final class TemporaryDirectory {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RilliyaFileWriterTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: false
    )
  }

  deinit { try? FileManager.default.removeItem(at: url) }
}
