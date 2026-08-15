// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import RilliyaRealtime

@Suite("Prepared audio sources")
struct PreparedAudioSourceTests {
  @Test("Frame-buffer source renders capture data and underflow silence")
  func rendersCaptureDataAndSilence() throws {
    let format = try AudioProcessingFormat(sampleRate: 48_000, channelCount: 1)
    let buffer = try AudioRealtimeFrameBuffer(format: format, capacityFrameCount: 4)
    let source = try PreparedAudioFrameBufferSource(
      frameBuffer: buffer,
      maximumFrameCount: 8
    )
    let input = UnsafeMutablePointer<Float>.allocate(capacity: 2)
    input.initialize(from: [0.25, -0.5], count: 2)
    defer {
      input.deinitialize(count: 2)
      input.deallocate()
    }
    let inputChannels: [UnsafePointer<Float>] = [UnsafePointer(input)]
    inputChannels.withUnsafeBufferPointer {
      #expect(buffer.writePlanar($0, frameCount: 2) == 2)
    }

    let output = UnsafeMutablePointer<Float>.allocate(capacity: 4)
    output.initialize(repeating: .nan, count: 4)
    defer {
      output.deinitialize(count: 4)
      output.deallocate()
    }
    let outputChannels = [output]
    let result = outputChannels.withUnsafeBufferPointer {
      source.render(outputChannels: $0, frameCount: 4)
    }

    #expect(result == .rendered)
    #expect(Array(UnsafeBufferPointer(start: output, count: 4)) == [0.25, -0.5, 0, 0])
    #expect(buffer.statistics().silencedFrameCount == 2)
  }

  @Test("Frame-buffer source retains its immutable frame bound")
  func rejectsOversizedRender() throws {
    let format = try AudioProcessingFormat(sampleRate: 48_000, channelCount: 1)
    let buffer = try AudioRealtimeFrameBuffer(format: format, capacityFrameCount: 4)
    let source = try PreparedAudioFrameBufferSource(
      frameBuffer: buffer,
      maximumFrameCount: 2
    )
    let output = UnsafeMutablePointer<Float>.allocate(capacity: 3)
    output.initialize(repeating: 0, count: 3)
    defer {
      output.deinitialize(count: 3)
      output.deallocate()
    }
    let outputChannels = [output]

    #expect(
      outputChannels.withUnsafeBufferPointer {
        source.render(outputChannels: $0, frameCount: 3)
      } == .invalidFrameCount
    )
  }
}
