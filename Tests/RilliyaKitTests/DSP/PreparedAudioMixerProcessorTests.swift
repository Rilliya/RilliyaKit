// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import RilliyaKit

@Suite("Prepared audio mixer")
struct PreparedAudioMixerProcessorTests {
  @Test("Matrix routes remap and sum inputs without clipping")
  func routesRemapAndSum() throws {
    let mono = try AudioProcessingFormat(sampleRate: 48_000, channelCount: 1)
    let stereo = try AudioProcessingFormat(sampleRate: 48_000, channelCount: 2)
    let output = try AudioRenderPreparation(format: stereo, maximumFrameCount: 3)
    let preparation = try AudioMixerRenderPreparation(
      inputFormats: [mono, stereo],
      output: output
    )
    let processor = try PreparedAudioMixerProcessor(
      preparation: preparation,
      routes: [
        try AudioChannelRoute(
          inputIndex: 0,
          sourceChannel: 0,
          destinationChannel: 0,
          gain: 0.5
        ),
        try AudioChannelRoute(inputIndex: 1, sourceChannel: 1, destinationChannel: 0),
        try AudioChannelRoute(inputIndex: 1, sourceChannel: 0, destinationChannel: 1),
      ],
      rampDurationSeconds: 0
    )
    let monoInput: [Float] = [1, -1, 0.5]
    let leftInput: [Float] = [0.25, 0.5, 0.75]
    let rightInput: [Float] = [0.75, -0.5, 1]
    var leftOutput = [Float](repeating: 0, count: 3)
    var rightOutput = [Float](repeating: 0, count: 3)

    let result = process(
      processor,
      firstInput: monoInput,
      secondInput: leftInput,
      thirdInput: rightInput,
      leftOutput: &leftOutput,
      rightOutput: &rightOutput
    )

    #expect(result == .rendered)
    #expect(leftOutput == [1.25, -1, 1.25])
    #expect(rightOutput == leftInput)
  }

  @Test("Output controls mute independently and permit aliased buffers")
  func controlsAndAliasing() throws {
    let stereo = try AudioProcessingFormat(sampleRate: 48_000, channelCount: 2)
    let output = try AudioRenderPreparation(format: stereo, maximumFrameCount: 2)
    let preparation = try AudioMixerRenderPreparation(inputFormats: [stereo], output: output)
    let controls = try AudioChannelGainControlBank(channelCount: 2)
    try controls.setLinearGain(2, at: 0)
    try controls.setMuted(true, at: 1)
    let processor = try PreparedAudioMixerProcessor(
      preparation: preparation,
      routes: [
        try AudioChannelRoute(inputIndex: 0, sourceChannel: 0, destinationChannel: 0),
        try AudioChannelRoute(inputIndex: 0, sourceChannel: 1, destinationChannel: 1),
      ],
      outputControls: controls,
      rampDurationSeconds: 0
    )
    var left: [Float] = [0.25, -0.5]
    var right: [Float] = [0.5, -0.25]

    let result = processAliased(processor, left: &left, right: &right)

    #expect(result == .rendered)
    #expect(left == [0.5, -1])
    #expect(right == [0, 0])
  }

  @Test("Prepared mixer begins at controls published before preparation")
  func startsAtPublishedOutputControls() throws {
    let mono = try AudioProcessingFormat(sampleRate: 1_000, channelCount: 1)
    let output = try AudioRenderPreparation(format: mono, maximumFrameCount: 2)
    let preparation = try AudioMixerRenderPreparation(inputFormats: [mono], output: output)
    let controls = try AudioChannelGainControlBank(channelCount: 1)
    try controls.setMuted(true, at: 0)
    let processor = try PreparedAudioMixerProcessor(
      preparation: preparation,
      routes: [
        try AudioChannelRoute(inputIndex: 0, sourceChannel: 0, destinationChannel: 0)
      ],
      outputControls: controls,
      rampDurationSeconds: 0.005
    )
    var samples: [Float] = [1, -1]

    let result = samples.withUnsafeMutableBufferPointer { buffer in
      guard let address = buffer.baseAddress else { return AudioRenderResult.insufficientChannels }
      let inputs = [UnsafePointer(address)]
      let outputs = [address]
      return inputs.withUnsafeBufferPointer { inputChannels in
        outputs.withUnsafeBufferPointer { outputChannels in
          processor.process(
            inputChannels: inputChannels,
            outputChannels: outputChannels,
            frameCount: buffer.count
          )
        }
      }
    }

    #expect(result == .rendered)
    #expect(samples == [0, 0])
  }

  @Test("Preparation rejects clock and route mismatches")
  func rejectsInvalidPreparation() throws {
    let input = try AudioProcessingFormat(sampleRate: 44_100, channelCount: 1)
    let outputFormat = try AudioProcessingFormat(sampleRate: 48_000, channelCount: 1)
    let output = try AudioRenderPreparation(format: outputFormat, maximumFrameCount: 2)

    #expect(throws: AudioDSPConfigurationError.incompatibleMixerSampleRates) {
      try AudioMixerRenderPreparation(inputFormats: [input], output: output)
    }
    let preparation = try AudioMixerRenderPreparation(inputFormats: [outputFormat], output: output)
    #expect(throws: AudioDSPConfigurationError.invalidChannelRoute) {
      try PreparedAudioMixerProcessor(
        preparation: preparation,
        routes: [
          try AudioChannelRoute(inputIndex: 0, sourceChannel: 1, destinationChannel: 0)
        ]
      )
    }
  }

  private func process(
    _ processor: PreparedAudioMixerProcessor,
    firstInput: [Float],
    secondInput: [Float],
    thirdInput: [Float],
    leftOutput: inout [Float],
    rightOutput: inout [Float]
  ) -> AudioRenderResult {
    firstInput.withUnsafeBufferPointer { first in
      secondInput.withUnsafeBufferPointer { second in
        thirdInput.withUnsafeBufferPointer { third in
          leftOutput.withUnsafeMutableBufferPointer { left in
            rightOutput.withUnsafeMutableBufferPointer { right in
              guard let firstAddress = first.baseAddress,
                let secondAddress = second.baseAddress,
                let thirdAddress = third.baseAddress,
                let leftAddress = left.baseAddress,
                let rightAddress = right.baseAddress
              else {
                return .insufficientChannels
              }
              let inputPointers = [firstAddress, secondAddress, thirdAddress]
              let outputPointers = [leftAddress, rightAddress]
              return inputPointers.withUnsafeBufferPointer { inputChannels in
                outputPointers.withUnsafeBufferPointer { outputChannels in
                  processor.process(
                    inputChannels: inputChannels,
                    outputChannels: outputChannels,
                    frameCount: left.count
                  )
                }
              }
            }
          }
        }
      }
    }
  }

  private func processAliased(
    _ processor: PreparedAudioMixerProcessor,
    left: inout [Float],
    right: inout [Float]
  ) -> AudioRenderResult {
    left.withUnsafeMutableBufferPointer { leftBuffer in
      right.withUnsafeMutableBufferPointer { rightBuffer in
        guard let leftAddress = leftBuffer.baseAddress,
          let rightAddress = rightBuffer.baseAddress
        else {
          return .insufficientChannels
        }
        let inputs = [
          UnsafePointer(leftAddress), UnsafePointer(rightAddress),
        ]
        let outputs = [leftAddress, rightAddress]
        return inputs.withUnsafeBufferPointer { inputChannels in
          outputs.withUnsafeBufferPointer { outputChannels in
            processor.process(
              inputChannels: inputChannels,
              outputChannels: outputChannels,
              frameCount: leftBuffer.count
            )
          }
        }
      }
    }
  }
}
