// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaRealtime
import Testing

@testable import RilliyaDSP

@Suite("Prepared audio compressor")
struct PreparedAudioCompressorProcessorTests {
  @Test("Hard-knee transfer follows threshold and ratio")
  func hardKneeTransferIsDeterministic() throws {
    let processor = try makeProcessor(
      configuration: AudioCompressorConfiguration(
        thresholdDecibels: -20,
        ratio: 4,
        kneeDecibels: 0,
        attackSeconds: 0,
        releaseSeconds: 0,
        makeupGainDecibels: 0
      ),
      channelCount: 1,
      maximumFrameCount: 2
    )
    let output = process(processor, channels: [[0.1, 1]])

    #expect(abs(try #require(output?.first?[0]) - 0.1) < 0.000_001)
    #expect(
      abs(try #require(output?.first?[1]) - Float(pow(10.0, -15.0 / 20))) < 0.000_001
    )
  }

  @Test("Linked detection applies one gain envelope to every channel")
  func linkedDetectionPreservesChannelBalance() throws {
    let processor = try makeProcessor(
      configuration: AudioCompressorConfiguration(
        thresholdDecibels: -20,
        ratio: 4,
        kneeDecibels: 0,
        attackSeconds: 0,
        releaseSeconds: 0,
        makeupGainDecibels: 0
      ),
      channelCount: 2,
      maximumFrameCount: 1
    )
    let output = try #require(process(processor, channels: [[1], [0.25]]))

    #expect(abs(output[0][0] / output[1][0] - 4) < 0.000_001)
  }

  @Test("Configuration updates preserve preparation and apply without allocation")
  func configurationUpdatesApplyToTheNextQuantum() throws {
    let processor = try makeProcessor(
      configuration: AudioCompressorConfiguration(
        thresholdDecibels: -20,
        ratio: 1,
        kneeDecibels: 0,
        attackSeconds: 0,
        releaseSeconds: 0,
        makeupGainDecibels: 0
      ),
      channelCount: 1,
      maximumFrameCount: 1
    )
    #expect(process(processor, channels: [[1]]) == [[1]])

    processor.setConfiguration(
      try AudioCompressorConfiguration(
        thresholdDecibels: -20,
        ratio: 100,
        kneeDecibels: 0,
        attackSeconds: 0,
        releaseSeconds: 0,
        makeupGainDecibels: 0
      )
    )
    let output = try #require(process(processor, channels: [[1]]))

    #expect(output[0][0] < 0.11)
    #expect(output[0][0] > 0.1)
  }

  @Test("Concurrent publication never exposes a torn parameter set")
  func concurrentPublicationKeepsConfigurationsCoherent() throws {
    let first = try AudioCompressorConfiguration(
      thresholdDecibels: -20,
      ratio: 1,
      kneeDecibels: 0,
      attackSeconds: 0,
      releaseSeconds: 0,
      makeupGainDecibels: 0
    )
    let second = try AudioCompressorConfiguration(
      thresholdDecibels: -40,
      ratio: 100,
      kneeDecibels: 24,
      attackSeconds: 0,
      releaseSeconds: 0,
      makeupGainDecibels: 12
    )
    let processor = try makeProcessor(
      configuration: first,
      channelCount: 1,
      maximumFrameCount: 1
    )
    let secondOutput = Float(pow(10, (-39.6 + 12) / 20))
    let publication = DispatchGroup()
    publication.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      for iteration in 0..<20_000 {
        processor.setConfiguration(iteration.isMultiple(of: 2) ? first : second)
      }
      publication.leave()
    }

    for _ in 0..<20_000 {
      let sample = try #require(process(processor, channels: [[1]])?.first?.first)
      #expect(abs(sample - 1) < 0.000_001 || abs(sample - secondOutput) < 0.000_001)
    }
    publication.wait()
  }

  @Test("Validation and decoding reject unsafe parameters")
  func validationAndDecodingAreBounded() throws {
    #expect(throws: AudioDSPConfigurationError.invalidCompressorRatio(0.5)) {
      try AudioCompressorConfiguration(ratio: 0.5)
    }
    #expect(throws: AudioDSPConfigurationError.invalidCompressorAttack(2)) {
      try AudioCompressorConfiguration(attackSeconds: 2)
    }
    let invalid = """
      {
        "thresholdDecibels": -18,
        "ratio": 1000,
        "kneeDecibels": 6,
        "attackSeconds": 0.01,
        "releaseSeconds": 0.12,
        "makeupGainDecibels": 0
      }
      """.data(using: .utf8)!
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(AudioCompressorConfiguration.self, from: invalid)
    }
  }

  @Test("Render bounds fail without touching caller storage")
  func renderBoundsAreEnforced() throws {
    let processor = try makeProcessor(
      configuration: AudioCompressorConfiguration(),
      channelCount: 1,
      maximumFrameCount: 1
    )
    let noInputs: [UnsafePointer<Float>] = []
    let noOutputs: [UnsafeMutablePointer<Float>] = []

    #expect(
      noInputs.withUnsafeBufferPointer { inputs in
        noOutputs.withUnsafeBufferPointer { outputs in
          processor.process(inputChannels: inputs, outputChannels: outputs, frameCount: 2)
        }
      } == .invalidFrameCount
    )
  }

  @Test("Non-finite input is silenced without poisoning later samples")
  func nonFiniteInputIsContained() throws {
    let processor = try makeProcessor(
      configuration: AudioCompressorConfiguration(
        thresholdDecibels: -20,
        ratio: 1,
        kneeDecibels: 0,
        attackSeconds: 0,
        releaseSeconds: 0,
        makeupGainDecibels: 0
      ),
      channelCount: 1,
      maximumFrameCount: 3
    )
    let output = try #require(process(processor, channels: [[.nan, .infinity, 0.25]]))

    #expect(output[0][0] == 0)
    #expect(output[0][1] == 0)
    #expect(output[0][2].isFinite)
    #expect(abs(output[0][2] - 0.25) < 0.000_001)
  }

  private func makeProcessor(
    configuration: AudioCompressorConfiguration,
    channelCount: Int,
    maximumFrameCount: Int
  ) throws -> PreparedAudioCompressorProcessor {
    try PreparedAudioCompressorProcessor(
      preparation: AudioRenderPreparation(
        format: AudioProcessingFormat(sampleRate: 48_000, channelCount: channelCount),
        maximumFrameCount: maximumFrameCount
      ),
      configuration: configuration
    )
  }

  private func process(
    _ processor: PreparedAudioCompressorProcessor,
    channels: [[Float]]
  ) -> [[Float]]? {
    guard let frameCount = channels.first?.count,
      channels.count == processor.preparation.format.channelCount,
      channels.allSatisfy({ $0.count == frameCount })
    else {
      return nil
    }
    var output = channels.map { _ in [Float](repeating: 0, count: frameCount) }
    let inputPointers = channels.map { channel -> UnsafeMutablePointer<Float> in
      let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(frameCount, 1))
      channel.withUnsafeBufferPointer { source in
        if let sourceAddress = source.baseAddress {
          pointer.initialize(from: sourceAddress, count: frameCount)
        }
      }
      return pointer
    }
    let outputPointers = output.map { _ -> UnsafeMutablePointer<Float> in
      let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(frameCount, 1))
      pointer.initialize(repeating: 0, count: max(frameCount, 1))
      return pointer
    }
    defer {
      for pointer in inputPointers {
        pointer.deinitialize(count: frameCount)
        pointer.deallocate()
      }
      for pointer in outputPointers {
        pointer.deinitialize(count: max(frameCount, 1))
        pointer.deallocate()
      }
    }
    let immutableInputs = inputPointers.map { UnsafePointer<Float>($0) }
    let result = immutableInputs.withUnsafeBufferPointer { inputs in
      outputPointers.withUnsafeBufferPointer { outputs in
        processor.process(
          inputChannels: inputs,
          outputChannels: outputs,
          frameCount: frameCount
        )
      }
    }
    guard result == .rendered else { return nil }
    for channel in output.indices {
      output[channel] = Array(
        UnsafeBufferPointer(start: outputPointers[channel], count: frameCount)
      )
    }
    return output
  }
}
