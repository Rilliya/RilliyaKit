// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import RilliyaRealtime

@Suite("Audio processing model")
struct AudioProcessingModelTests {
  @Test("Validates processing bounds")
  func validatesProcessingBounds() throws {
    let format = try AudioProcessingFormat(sampleRate: 48_000, channelCount: 2)
    let preparation = try AudioRenderPreparation(format: format, maximumFrameCount: 512)

    #expect(preparation.format == format)
    #expect(preparation.maximumFrameCount == 512)
    #expect(throws: AudioDSPConfigurationError.invalidSampleRate(0)) {
      try AudioProcessingFormat(sampleRate: 0, channelCount: 2)
    }
    #expect(throws: AudioDSPConfigurationError.invalidChannelCount(257)) {
      try AudioProcessingFormat(sampleRate: 48_000, channelCount: 257)
    }
    #expect(throws: AudioDSPConfigurationError.invalidMaximumFrameCount(0)) {
      try AudioRenderPreparation(format: format, maximumFrameCount: 0)
    }
    #expect(throws: AudioDSPConfigurationError.invalidTiming) {
      try AudioNodeTiming(
        processingLatencyFrames: -1,
        intentionalDelayFrames: 0,
        tail: .none
      )
    }
    #expect(AudioNodeTiming.transparent.tail == .none)
  }

  @Test("Retains explicit mixer routes without clamping linear gain")
  func retainsMixerRoute() throws {
    let route = try AudioChannelRoute(
      inputIndex: 3,
      sourceChannel: 47,
      destinationChannel: 1,
      gain: 1.5
    )

    #expect(route.inputIndex == 3)
    #expect(route.sourceChannel == 47)
    #expect(route.destinationChannel == 1)
    #expect(route.gain == 1.5)
    #expect(throws: AudioDSPConfigurationError.invalidChannelRoute) {
      try AudioChannelRoute(inputIndex: -1, sourceChannel: 0, destinationChannel: 0)
    }
    #expect(throws: AudioDSPConfigurationError.nonfiniteGain) {
      try AudioChannelRoute(
        inputIndex: 0,
        sourceChannel: 0,
        destinationChannel: 0,
        gain: .nan
      )
    }
  }
}
