// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import RilliyaKit

@Suite("Prepared audio processors")
struct PreparedAudioProcessorTests {
  @Test("Channel controls validate and retain gain independently from mute")
  func channelControlsAreIndependent() throws {
    let controls = try AudioChannelGainControlBank(channelCount: 2)

    try controls.setLinearGain(0.25, at: 1)
    try controls.setMuted(true, at: 1)

    #expect(try controls.control(at: 0) == AudioChannelGainControl())
    #expect(
      try controls.control(at: 1)
        == AudioChannelGainControl(linearGain: 0.25, isMuted: true)
    )
    #expect(throws: AudioChannelControlError.channelOutOfRange(2)) {
      try controls.setMuted(true, at: 2)
    }
    #expect(throws: AudioDSPConfigurationError.invalidChannelGain(-1)) {
      try AudioChannelGainControl(linearGain: -1)
    }
  }

  @Test("Prepared gain applies independent channel controls without temporary allocation")
  func preparedGainProcessesChannelsIndependently() throws {
    let format = try AudioProcessingFormat(sampleRate: 48_000, channelCount: 2)
    let preparation = try AudioRenderPreparation(format: format, maximumFrameCount: 4)
    let controls = try AudioChannelGainControlBank(channelCount: 2)
    try controls.setLinearGain(0.5, at: 0)
    try controls.setMuted(true, at: 1)
    let processor = try PreparedAudioChannelGainProcessor(
      preparation: preparation,
      controls: controls,
      rampDurationSeconds: 0
    )
    let firstInput: [Float] = [1, -1, 0.5, -0.5]
    let secondInput: [Float] = [0.25, 0.5, -0.25, -0.5]
    var firstOutput = [Float](repeating: 9, count: 4)
    var secondOutput = [Float](repeating: 9, count: 4)

    let result = firstInput.withUnsafeBufferPointer { firstInputBuffer in
      secondInput.withUnsafeBufferPointer { secondInputBuffer in
        firstOutput.withUnsafeMutableBufferPointer { firstOutputBuffer in
          secondOutput.withUnsafeMutableBufferPointer { secondOutputBuffer in
            guard let firstInputAddress = firstInputBuffer.baseAddress,
              let secondInputAddress = secondInputBuffer.baseAddress,
              let firstOutputAddress = firstOutputBuffer.baseAddress,
              let secondOutputAddress = secondOutputBuffer.baseAddress
            else { return AudioRenderResult.insufficientChannels }
            let inputs = [firstInputAddress, secondInputAddress]
            let outputs = [firstOutputAddress, secondOutputAddress]
            return inputs.withUnsafeBufferPointer { inputChannels in
              outputs.withUnsafeBufferPointer { outputChannels in
                processor.process(
                  inputChannels: inputChannels,
                  outputChannels: outputChannels,
                  frameCount: 4
                )
              }
            }
          }
        }
      }
    }

    #expect(result == .rendered)
    #expect(firstOutput == [0.5, -0.5, 0.25, -0.25])
    #expect(secondOutput == [0, 0, 0, 0])
  }

  @Test("Prepared gain ramps continuously across render calls")
  func preparedGainRampsAcrossRenderCalls() throws {
    let format = try AudioProcessingFormat(sampleRate: 1_000, channelCount: 1)
    let preparation = try AudioRenderPreparation(format: format, maximumFrameCount: 3)
    let controls = try AudioChannelGainControlBank(channelCount: 1)
    let processor = try PreparedAudioChannelGainProcessor(
      preparation: preparation,
      controls: controls,
      rampDurationSeconds: 0.004
    )
    try controls.setMuted(true, at: 0)
    var firstOutput = [Float](repeating: 0, count: 2)
    var secondOutput = [Float](repeating: 0, count: 3)

    #expect(processMono(processor, frameCount: 2, output: &firstOutput) == .rendered)
    #expect(processMono(processor, frameCount: 3, output: &secondOutput) == .rendered)
    #expect(firstOutput == [1, 0.75])
    #expect(secondOutput == [0.5, 0.25, 0])
  }

  @Test("Prepared gain begins at controls published before preparation")
  func preparedGainStartsAtPublishedControls() throws {
    let format = try AudioProcessingFormat(sampleRate: 1_000, channelCount: 1)
    let preparation = try AudioRenderPreparation(format: format, maximumFrameCount: 2)
    let controls = try AudioChannelGainControlBank(channelCount: 1)
    try controls.setMuted(true, at: 0)
    let processor = try PreparedAudioChannelGainProcessor(
      preparation: preparation,
      controls: controls,
      rampDurationSeconds: 0.005
    )
    var output = [Float](repeating: 1, count: 2)

    #expect(processMono(processor, frameCount: 2, output: &output) == .rendered)
    #expect(output == [0, 0])
  }

  @Test("Prepared gain rejects buffers outside its immutable preparation")
  func preparedGainRejectsInvalidBuffers() throws {
    let format = try AudioProcessingFormat(sampleRate: 48_000, channelCount: 1)
    let preparation = try AudioRenderPreparation(format: format, maximumFrameCount: 2)
    let processor = try PreparedAudioChannelGainProcessor(preparation: preparation)
    let noInputs: [UnsafePointer<Float>] = []
    let noOutputs: [UnsafeMutablePointer<Float>] = []

    #expect(
      noInputs.withUnsafeBufferPointer { inputs in
        noOutputs.withUnsafeBufferPointer { outputs in
          processor.process(inputChannels: inputs, outputChannels: outputs, frameCount: 1)
        }
      } == .insufficientChannels
    )
    #expect(
      noInputs.withUnsafeBufferPointer { inputs in
        noOutputs.withUnsafeBufferPointer { outputs in
          processor.process(inputChannels: inputs, outputChannels: outputs, frameCount: 3)
        }
      } == .invalidFrameCount
    )
  }

  private func processMono(
    _ processor: PreparedAudioChannelGainProcessor,
    frameCount: Int,
    output: inout [Float]
  ) -> AudioRenderResult {
    let input = [Float](repeating: 1, count: frameCount)
    return input.withUnsafeBufferPointer { inputBuffer in
      output.withUnsafeMutableBufferPointer { outputBuffer in
        guard let inputAddress = inputBuffer.baseAddress,
          let outputAddress = outputBuffer.baseAddress
        else { return .insufficientChannels }
        let inputs = [inputAddress]
        let outputs = [outputAddress]
        return inputs.withUnsafeBufferPointer { inputChannels in
          outputs.withUnsafeBufferPointer { outputChannels in
            processor.process(
              inputChannels: inputChannels,
              outputChannels: outputChannels,
              frameCount: frameCount
            )
          }
        }
      }
    }
  }
}
