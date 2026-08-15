// SPDX-License-Identifier: Apache-2.0

import RilliyaDSP
import RilliyaRealtime
import Testing

@Suite("Custom audio extension surface")
struct CustomAudioExtensionSurfaceTests {
  @Test("A client can implement public source and processor contracts")
  func publicContractsSupportClientImplementations() throws {
    let format = try AudioProcessingFormat(sampleRate: 48_000, channelCount: 1)
    let preparation = try AudioRenderPreparation(format: format, maximumFrameCount: 4)
    let source = ClientConstantSource(preparation: preparation, sample: 0.5)
    let processor = ClientHalfGainProcessor(preparation: preparation)
    var sourceOutput = [Float](repeating: 0, count: 4)
    var processedOutput = [Float](repeating: 0, count: 4)

    let sourceResult = sourceOutput.withUnsafeMutableBufferPointer { output in
      guard let outputAddress = output.baseAddress else {
        return AudioRenderResult.insufficientChannels
      }
      let channels = [outputAddress]
      return channels.withUnsafeBufferPointer {
        source.render(outputChannels: $0, frameCount: output.count)
      }
    }
    let processorResult = sourceOutput.withUnsafeBufferPointer { input in
      processedOutput.withUnsafeMutableBufferPointer { output in
        guard let inputAddress = input.baseAddress, let outputAddress = output.baseAddress else {
          return AudioRenderResult.insufficientChannels
        }
        let inputs = [inputAddress]
        let outputs = [outputAddress]
        return inputs.withUnsafeBufferPointer { inputChannels in
          outputs.withUnsafeBufferPointer { outputChannels in
            processor.process(
              inputChannels: inputChannels,
              outputChannels: outputChannels,
              frameCount: input.count
            )
          }
        }
      }
    }

    #expect(sourceResult == .rendered)
    #expect(processorResult == .rendered)
    #expect(processedOutput == [0.25, 0.25, 0.25, 0.25])
  }
}

private final class ClientConstantSource: PreparedAudioSource, @unchecked Sendable {
  let preparation: AudioRenderPreparation
  let timing = AudioNodeTiming.transparent

  private let sample: Float

  init(preparation: AudioRenderPreparation, sample: Float) {
    self.preparation = preparation
    self.sample = sample
  }

  func render(
    outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRenderResult {
    guard (0...preparation.maximumFrameCount).contains(frameCount) else {
      return .invalidFrameCount
    }
    guard outputChannels.count >= preparation.format.channelCount else {
      return .insufficientChannels
    }
    for channel in 0..<preparation.format.channelCount {
      outputChannels[channel].update(repeating: sample, count: frameCount)
    }
    return .rendered
  }
}

private final class ClientHalfGainProcessor: PreparedAudioProcessor, @unchecked Sendable {
  let preparation: AudioRenderPreparation
  let timing = AudioNodeTiming.transparent

  init(preparation: AudioRenderPreparation) {
    self.preparation = preparation
  }

  func process(
    inputChannels: UnsafeBufferPointer<UnsafePointer<Float>>,
    outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRenderResult {
    guard (0...preparation.maximumFrameCount).contains(frameCount) else {
      return .invalidFrameCount
    }
    guard inputChannels.count >= preparation.format.channelCount,
      outputChannels.count >= preparation.format.channelCount
    else {
      return .insufficientChannels
    }
    for channel in 0..<preparation.format.channelCount {
      for frame in 0..<frameCount {
        outputChannels[channel][frame] = inputChannels[channel][frame] * 0.5
      }
    }
    return .rendered
  }
}
