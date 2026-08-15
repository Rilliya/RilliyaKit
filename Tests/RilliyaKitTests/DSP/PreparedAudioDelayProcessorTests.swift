// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RilliyaKit

struct PreparedAudioDelayProcessorTests {
  @Test
  func fullWetDelayCarriesItsTailAcrossRenderQuanta() throws {
    let processor = try makeProcessor(delaySeconds: 0.25)

    let first = process(processor, inputs: [[1, 2, 3, 4]])
    let second = process(processor, inputs: [[0, 0, 0, 0]])

    #expect(first.result == .rendered)
    #expect(first.channels == [[0, 0, 1, 2]])
    #expect(second.channels == [[3, 4, 0, 0]])
    #expect(processor.delayFrameCount == 2)
    #expect(processor.timing.intentionalDelayFrames == 2)
    #expect(processor.timing.tail == .finiteFrames(2))
  }

  @Test
  func feedbackAndDryWetMixRemainChannelIsolated() throws {
    let processor = try makeProcessor(
      channelCount: 2,
      delaySeconds: 0.25,
      feedback: 0.5,
      dryWetMix: 0.5
    )

    let first = process(processor, inputs: [[1, 0, 0, 0], [0, -1, 0, 0]])
    let second = process(processor, inputs: [[0, 0, 0, 0], [0, 0, 0, 0]])

    #expect(first.channels == [[0.5, 0, 0.5, 0], [0, -0.5, 0, -0.5]])
    #expect(second.channels == [[0.25, 0, 0.125, 0], [0, -0.25, 0, -0.125]])
    #expect(processor.timing.tail == .unbounded)
  }

  @Test
  func inPlaceProcessingReadsInputBeforeReplacingIt() throws {
    let processor = try makeProcessor(delaySeconds: 0.25)
    let samples = UnsafeMutablePointer<Float>.allocate(capacity: 4)
    samples.initialize(from: [1, 2, 3, 4], count: 4)
    defer {
      samples.deinitialize(count: 4)
      samples.deallocate()
    }
    let inputs = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: 1)
    let outputs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1)
    inputs.initialize(to: UnsafePointer(samples))
    outputs.initialize(to: samples)
    defer {
      inputs.deinitialize(count: 1)
      outputs.deinitialize(count: 1)
      inputs.deallocate()
      outputs.deallocate()
    }

    let result = processor.process(
      inputChannels: UnsafeBufferPointer(start: inputs, count: 1),
      outputChannels: UnsafeBufferPointer(start: outputs, count: 1),
      frameCount: 4
    )

    #expect(result == .rendered)
    #expect(Array(UnsafeBufferPointer(start: samples, count: 4)) == [0, 0, 1, 2])
  }

  @Test
  func resetClearsEveryChannelHistory() throws {
    let processor = try makeProcessor(channelCount: 2, delaySeconds: 0.25)
    _ = process(processor, inputs: [[1, 2], [3, 4]])

    processor.reset()
    let rendered = process(processor, inputs: [[0, 0], [0, 0]])

    #expect(rendered.channels == [[0, 0], [0, 0]])
  }

  @Test
  func configurationAndStorageBoundsRejectUnsafeRequests() throws {
    #expect(throws: AudioDSPConfigurationError.invalidDelayDuration(0)) {
      try AudioDelayConfiguration(delaySeconds: 0)
    }
    #expect(throws: AudioDSPConfigurationError.invalidDelayFeedback(1)) {
      try AudioDelayConfiguration(delaySeconds: 1, feedback: 1)
    }
    #expect(throws: AudioDSPConfigurationError.invalidDryWetMix(1.1)) {
      try AudioDelayConfiguration(delaySeconds: 1, dryWetMix: 1.1)
    }
    let preparation = try AudioRenderPreparation(
      format: AudioProcessingFormat(sampleRate: 192_000, channelCount: 256),
      maximumFrameCount: 512
    )
    let configuration = try AudioDelayConfiguration(delaySeconds: 1)
    #expect(throws: AudioDSPConfigurationError.delayStorageTooLarge(49_152_000)) {
      try PreparedAudioDelayProcessor(
        preparation: preparation,
        configuration: configuration
      )
    }
  }

  @Test
  func decodingCannotBypassConfigurationBounds() throws {
    let invalid = Data(
      #"{"delaySeconds":0,"feedback":0,"dryWetMix":1}"#.utf8
    )

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(AudioDelayConfiguration.self, from: invalid)
    }
  }

  @Test
  func renderBoundsReturnErrorsWithoutMutatingPreparedStorage() throws {
    let processor = try makeProcessor(delaySeconds: 0.25)
    let rendered = process(processor, inputs: [[1, 2, 3, 4, 5]])

    #expect(rendered.result == .invalidFrameCount)
    let valid = process(processor, inputs: [[0, 0]])
    #expect(valid.channels == [[0, 0]])
  }

  private func makeProcessor(
    channelCount: Int = 1,
    delaySeconds: Double,
    feedback: Float = 0,
    dryWetMix: Float = 1
  ) throws -> PreparedAudioDelayProcessor {
    try PreparedAudioDelayProcessor(
      preparation: AudioRenderPreparation(
        format: AudioProcessingFormat(sampleRate: 8, channelCount: channelCount),
        maximumFrameCount: 4
      ),
      configuration: AudioDelayConfiguration(
        delaySeconds: delaySeconds,
        feedback: feedback,
        dryWetMix: dryWetMix
      )
    )
  }

  private func process(
    _ processor: PreparedAudioDelayProcessor,
    inputs: [[Float]]
  ) -> (result: AudioRenderResult, channels: [[Float]]) {
    precondition(!inputs.isEmpty)
    let frameCount = inputs.first?.count ?? 0
    let inputSamples = inputs.map { values -> UnsafeMutablePointer<Float> in
      let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(frameCount, 1))
      if frameCount > 0 {
        pointer.initialize(from: values, count: frameCount)
      } else {
        pointer.initialize(to: 0)
      }
      return pointer
    }
    let outputSamples = inputs.map { _ -> UnsafeMutablePointer<Float> in
      let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(frameCount, 1))
      pointer.initialize(repeating: .nan, count: max(frameCount, 1))
      return pointer
    }
    defer {
      for pointer in inputSamples {
        pointer.deinitialize(count: max(frameCount, 1))
        pointer.deallocate()
      }
      for pointer in outputSamples {
        pointer.deinitialize(count: max(frameCount, 1))
        pointer.deallocate()
      }
    }
    let inputPointers = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(
      capacity: max(inputs.count, 1)
    )
    let outputPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(
      capacity: max(inputs.count, 1)
    )
    defer {
      inputPointers.deinitialize(count: max(inputs.count, 1))
      outputPointers.deinitialize(count: max(inputs.count, 1))
      inputPointers.deallocate()
      outputPointers.deallocate()
    }
    for index in inputs.indices {
      inputPointers.advanced(by: index).initialize(to: UnsafePointer(inputSamples[index]))
      outputPointers.advanced(by: index).initialize(to: outputSamples[index])
    }
    let result = processor.process(
      inputChannels: UnsafeBufferPointer(start: inputPointers, count: inputs.count),
      outputChannels: UnsafeBufferPointer(start: outputPointers, count: inputs.count),
      frameCount: frameCount
    )
    return (
      result,
      outputSamples.map { Array(UnsafeBufferPointer(start: $0, count: frameCount)) }
    )
  }
}
