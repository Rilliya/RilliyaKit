// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import RilliyaRealtime

@Suite("Realtime audio frame buffer")
struct AudioRealtimeFrameBufferTests {
  @Test("Preserves planar channels across ring wrap")
  func preservesPlanarChannelsAcrossWrap() throws {
    let buffer = try makeBuffer(channelCount: 2, capacity: 4)

    try withPlanarInput([[0, 1, 2, 3], [10, 11, 12, 13]]) { input in
      #expect(buffer.writePlanar(input, frameCount: 4) == 4)
    }
    try withPlanarOutput(channelCount: 2, frameCount: 3) { output in
      #expect(
        buffer.read(into: output.pointers, frameCount: 3)
          == .read(
            frameCount: 3,
            silencedFrameCount: 0
          ))
      #expect(output.values == [[0, 1, 2], [10, 11, 12]])
    }
    try withPlanarInput([[4, 5, 6], [14, 15, 16]]) { input in
      #expect(buffer.writePlanar(input, frameCount: 3) == 3)
    }
    try withPlanarOutput(channelCount: 2, frameCount: 4) { output in
      #expect(
        buffer.read(into: output.pointers, frameCount: 4)
          == .read(
            frameCount: 4,
            silencedFrameCount: 0
          ))
      #expect(output.values == [[3, 4, 5, 6], [13, 14, 15, 16]])
    }
  }

  @Test("Drops new overflow and silences an unavailable read tail")
  func boundsOverflowAndUnderflow() throws {
    let buffer = try makeBuffer(channelCount: 1, capacity: 4)

    try withPlanarInput([[1, 2, 3, 4, 5, 6]]) { input in
      #expect(buffer.writePlanar(input, frameCount: 6) == 4)
    }
    try withPlanarOutput(channelCount: 1, frameCount: 6) { output in
      #expect(
        buffer.read(into: output.pointers, frameCount: 6)
          == .read(
            frameCount: 4,
            silencedFrameCount: 2
          ))
      #expect(output.values == [[1, 2, 3, 4, 0, 0]])
    }

    let statistics = buffer.statistics()
    #expect(statistics.writtenFrameCount == 4)
    #expect(statistics.readFrameCount == 4)
    #expect(statistics.droppedFrameCount == 2)
    #expect(statistics.silencedFrameCount == 2)
    #expect(statistics.availableFrameCount == 0)
  }

  @Test("Consumer can restore a live latency bound without producer overwrite")
  func consumerDiscardsOldestQueuedFrames() throws {
    let buffer = try makeBuffer(channelCount: 1, capacity: 8)
    let input: [Float] = [0, 1, 2, 3, 4, 5, 6, 7]
    var output = [Float](repeating: -1, count: 4)

    input.withUnsafeBufferPointer { samples in
      let channels = [samples.baseAddress!]
      channels.withUnsafeBufferPointer {
        #expect(buffer.writePlanar($0, frameCount: input.count) == input.count)
      }
    }
    #expect(buffer.discardOldestFrames(keepingLatest: 4) == 4)
    let outputFrameCount = output.count
    output.withUnsafeMutableBufferPointer { samples in
      let channels = [samples.baseAddress!]
      channels.withUnsafeBufferPointer {
        #expect(
          buffer.read(into: $0, frameCount: outputFrameCount)
            == .read(frameCount: 4, silencedFrameCount: 0)
        )
      }
    }

    #expect(output == [4, 5, 6, 7])
    #expect(buffer.statistics().discardedFrameCount == 4)
    #expect(buffer.statistics().droppedFrameCount == 0)
  }

  @Test("Deinterleaves native Float32 frames without allocation")
  func deinterleavesInput() throws {
    let buffer = try makeBuffer(channelCount: 2, capacity: 4)
    let interleaved: [Float] = [1, 10, 2, 20, 3, 30]

    interleaved.withUnsafeBufferPointer { samples in
      #expect(
        buffer.writeInterleaved(
          samples.baseAddress!,
          channelCount: 2,
          frameCount: 3
        ) == 3
      )
    }
    try withPlanarOutput(channelCount: 2, frameCount: 3) { output in
      _ = buffer.read(into: output.pointers, frameCount: 3)
      #expect(output.values == [[1, 2, 3], [10, 20, 30]])
    }
  }

  @Test("Rejects unbounded storage configurations")
  func rejectsUnboundedStorage() throws {
    let format = try AudioProcessingFormat(sampleRate: 48_000, channelCount: 256)

    #expect(throws: AudioRealtimeFrameBufferError.invalidCapacity(1)) {
      _ = try AudioRealtimeFrameBuffer(format: format, capacityFrameCount: 1)
    }
    #expect(
      throws: AudioRealtimeFrameBufferError.excessiveStorage(
        channelCount: 256,
        capacityFrameCount: 65_536
      )
    ) {
      _ = try AudioRealtimeFrameBuffer(format: format, capacityFrameCount: 65_536)
    }
  }

  private func makeBuffer(
    channelCount: Int,
    capacity: Int
  ) throws -> AudioRealtimeFrameBuffer {
    try AudioRealtimeFrameBuffer(
      format: AudioProcessingFormat(sampleRate: 48_000, channelCount: channelCount),
      capacityFrameCount: capacity
    )
  }
}

private func withPlanarInput<Result>(
  _ channels: [[Float]],
  body: (UnsafeBufferPointer<UnsafePointer<Float>>) throws -> Result
) throws -> Result {
  let frameCount = channels.first?.count ?? 0
  precondition(channels.allSatisfy { $0.count == frameCount })
  let storage = channels.map { channel -> UnsafeMutablePointer<Float> in
    let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
    pointer.initialize(from: channel, count: frameCount)
    return pointer
  }
  defer {
    for pointer in storage {
      pointer.deinitialize(count: frameCount)
      pointer.deallocate()
    }
  }
  let pointers: [UnsafePointer<Float>] = storage.map { UnsafePointer($0) }
  return try pointers.withUnsafeBufferPointer(body)
}

private func withPlanarOutput<Result>(
  channelCount: Int,
  frameCount: Int,
  body: (PlanarOutput) throws -> Result
) throws -> Result {
  let storage = (0..<channelCount).map { _ -> UnsafeMutablePointer<Float> in
    let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
    pointer.initialize(repeating: .nan, count: frameCount)
    return pointer
  }
  defer {
    for pointer in storage {
      pointer.deinitialize(count: frameCount)
      pointer.deallocate()
    }
  }
  return try storage.withUnsafeBufferPointer { pointers in
    try body(PlanarOutput(pointers: pointers, frameCount: frameCount))
  }
}

private struct PlanarOutput {
  let pointers: UnsafeBufferPointer<UnsafeMutablePointer<Float>>
  let frameCount: Int

  var values: [[Float]] {
    pointers.map { pointer in
      Array(UnsafeBufferPointer(start: pointer, count: frameCount))
    }
  }
}
