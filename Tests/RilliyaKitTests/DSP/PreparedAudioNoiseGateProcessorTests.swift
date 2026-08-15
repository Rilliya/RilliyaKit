// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaRealtime
import Testing

@testable import RilliyaDSP

struct PreparedAudioNoiseGateProcessorTests {
  @Test
  func quietInputUsesTheConfiguredClosedReduction() throws {
    let processor = try makeProcessor(reductionDecibels: 20)

    let rendered = process(processor, inputs: [[0.01, -0.01, 0.01, -0.01]])

    #expect(rendered.result == .rendered)
    expectChannels(rendered.channels, equalTo: [[0.001, -0.001, 0.001, -0.001]])
    #expect(processor.timing == .transparent)
  }

  @Test
  func linkedDetectionAppliesOneGainWithoutChangingTheStereoImage() throws {
    let processor = try makeProcessor(channelCount: 2, reductionDecibels: 40)

    let rendered = process(
      processor,
      inputs: [[0.5, 0.5, 0.5, 0.5], [0.05, 0.05, 0.05, 0.05]]
    )

    expectChannels(rendered.channels, equalTo: [[0.5, 0.5, 0.5, 0.5], [0.05, 0.05, 0.05, 0.05]])
  }

  @Test
  func hysteresisAndHoldPreventThresholdChatterAcrossRenderQuanta() throws {
    let processor = try makeProcessor(
      thresholdDecibels: -20,
      hysteresisDecibels: 6,
      holdSeconds: 0.5,
      reductionDecibels: 40
    )

    let first = process(processor, inputs: [[0.2, 0.04, 0.04, 0.04]])
    let second = process(processor, inputs: [[0.04, 0.04, 0.04, 0.04]])

    expectChannels(first.channels, equalTo: [[0.2, 0.04, 0.04, 0.04]])
    expectChannels(second.channels, equalTo: [[0.04, 0.0004, 0.0004, 0.0004]])
  }

  @Test
  func attackAndReleaseSmoothGainChanges() throws {
    let processor = try makeProcessor(
      attackSeconds: 0.125,
      releaseSeconds: 0.125,
      reductionDecibels: 40
    )

    let opened = process(processor, inputs: [[1, 1, 1, 1]])
    let closed = process(processor, inputs: [[0.01, 0.01, 0.01, 0.01]])

    let openValues = opened.channels[0]
    #expect(openValues[0] > 0.6)
    #expect(openValues[3] > openValues[0])
    let closeGains = closed.channels[0].map { $0 / 0.01 }
    #expect(closeGains[0] < 1)
    #expect(closeGains[3] < closeGains[0])
    #expect(closeGains[3] > 0.01)
  }

  @Test
  func inPlaceProcessingReadsEveryLinkedChannelBeforeWriting() throws {
    let processor = try makeProcessor(channelCount: 2, reductionDecibels: 40)
    let channels = [[Float](repeating: 0.01, count: 4), [Float](repeating: 0.5, count: 4)]

    let rendered = process(processor, inputs: channels, inPlace: true)

    expectChannels(rendered.channels, equalTo: channels)
  }

  @Test
  func configurationUpdatesApplyWithoutResettingDetectorState() throws {
    let processor = try makeProcessor(
      thresholdDecibels: -20,
      holdSeconds: 0.5,
      reductionDecibels: 40
    )
    _ = process(processor, inputs: [[0.2, 0.04, 0.04, 0.04]])

    try processor.setConfiguration(
      AudioNoiseGateConfiguration(
        thresholdDecibels: -10,
        hysteresisDecibels: 6,
        attackSeconds: 0,
        holdSeconds: 0.5,
        releaseSeconds: 0,
        reductionDecibels: 20
      )
    )
    let rendered = process(processor, inputs: [[0.04, 0.04, 0.04, 0.04]])

    expectChannels(rendered.channels, equalTo: [[0.04, 0.004, 0.004, 0.004]])
  }

  @Test
  func validationAndDecodingRejectUnsafeParameters() throws {
    #expect(throws: AudioDSPConfigurationError.invalidNoiseGateThreshold(1)) {
      try AudioNoiseGateConfiguration(thresholdDecibels: 1)
    }
    #expect(throws: AudioDSPConfigurationError.invalidNoiseGateHysteresis(25)) {
      try AudioNoiseGateConfiguration(hysteresisDecibels: 25)
    }
    #expect(throws: AudioDSPConfigurationError.invalidNoiseGateReduction(97)) {
      try AudioNoiseGateConfiguration(reductionDecibels: 97)
    }
    let invalid = Data(
      #"{"thresholdDecibels":1,"hysteresisDecibels":6,"attackSeconds":0.005,"holdSeconds":0.05,"releaseSeconds":0.15,"reductionDecibels":60}"#
        .utf8
    )
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(AudioNoiseGateConfiguration.self, from: invalid)
    }
  }

  @Test
  func renderBoundsReturnErrorsWithoutMutatingState() throws {
    let processor = try makeProcessor(reductionDecibels: 40)
    let oversized = process(processor, inputs: [[1, 1, 1, 1, 1]])
    let valid = process(processor, inputs: [[0.01]])

    #expect(oversized.result == .invalidFrameCount)
    expectChannels(valid.channels, equalTo: [[0.0001]])
  }

  private func makeProcessor(
    channelCount: Int = 1,
    thresholdDecibels: Float = -20,
    hysteresisDecibels: Float = 6,
    attackSeconds: Double = 0,
    holdSeconds: Double = 0,
    releaseSeconds: Double = 0,
    reductionDecibels: Float
  ) throws -> PreparedAudioNoiseGateProcessor {
    try PreparedAudioNoiseGateProcessor(
      preparation: AudioRenderPreparation(
        format: AudioProcessingFormat(sampleRate: 8, channelCount: channelCount),
        maximumFrameCount: 4
      ),
      configuration: AudioNoiseGateConfiguration(
        thresholdDecibels: thresholdDecibels,
        hysteresisDecibels: hysteresisDecibels,
        attackSeconds: attackSeconds,
        holdSeconds: holdSeconds,
        releaseSeconds: releaseSeconds,
        reductionDecibels: reductionDecibels
      )
    )
  }

  private func process(
    _ processor: PreparedAudioNoiseGateProcessor,
    inputs: [[Float]],
    inPlace: Bool = false
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
    let outputSamples = inputSamples.enumerated().map { index, input in
      guard !inPlace else { return input }
      let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(frameCount, 1))
      pointer.initialize(repeating: .nan, count: max(frameCount, 1))
      return pointer
    }
    defer {
      for pointer in inputSamples {
        pointer.deinitialize(count: max(frameCount, 1))
        pointer.deallocate()
      }
      if !inPlace {
        for pointer in outputSamples {
          pointer.deinitialize(count: max(frameCount, 1))
          pointer.deallocate()
        }
      }
    }
    let inputPointers = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(
      capacity: inputs.count
    )
    let outputPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(
      capacity: inputs.count
    )
    defer {
      inputPointers.deinitialize(count: inputs.count)
      outputPointers.deinitialize(count: inputs.count)
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

  private func expectChannels(_ actual: [[Float]], equalTo expected: [[Float]]) {
    #expect(actual.count == expected.count)
    for (actualChannel, expectedChannel) in zip(actual, expected) {
      #expect(actualChannel.count == expectedChannel.count)
      for (actualSample, expectedSample) in zip(actualChannel, expectedChannel) {
        #expect(abs(actualSample - expectedSample) < 0.000_01)
      }
    }
  }
}
