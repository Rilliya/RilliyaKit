// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import RilliyaKit

@Suite("Realtime audio DSP")
struct RealtimeAudioDSPTests {
  @Test("Pass-through preserves every sample exactly")
  func passThroughIsBitExact() {
    let input: [Float] = [0, -0.25, 0.5, 1.25, .nan]
    var output = [Float](repeating: 0, count: input.count)

    input.withUnsafeBufferPointer { inputBuffer in
      output.withUnsafeMutableBufferPointer { outputBuffer in
        AudioPassThroughDSP.copy(
          input: inputBuffer.baseAddress!,
          output: outputBuffer.baseAddress!,
          frameCount: input.count
        )
      }
    }

    #expect(output.dropLast() == input.dropLast())
    #expect(output.last?.isNaN == true)
  }

  @Test("Gain ramps remain continuous across render quanta")
  func gainRampIsContinuousAcrossQuanta() {
    var state = AudioGainRampState(gain: 0)
    state.setTarget(1, durationFrames: 4)
    var first = [Float](repeating: 0, count: 2)
    var second = [Float](repeating: 0, count: 4)

    first.withUnsafeMutableBufferPointer {
      state.writeEnvelope(to: $0.baseAddress!, frameCount: $0.count)
    }
    second.withUnsafeMutableBufferPointer {
      state.writeEnvelope(to: $0.baseAddress!, frameCount: $0.count)
    }

    #expect(first == [0, 0.25])
    #expect(second == [0.5, 0.75, 1, 1])
    #expect(state.currentGain == 1)
    #expect(state.remainingFrameCount == 0)
  }

  @Test("Gain processing uses caller-owned envelope storage")
  func appliesGainEnvelope() {
    let input: [Float] = [1, 1, -1, -1]
    let envelope: [Float] = [0, 0.25, 0.5, 1]
    var output = [Float](repeating: 0, count: input.count)

    input.withUnsafeBufferPointer { inputBuffer in
      envelope.withUnsafeBufferPointer { envelopeBuffer in
        output.withUnsafeMutableBufferPointer { outputBuffer in
          AudioGainDSP.apply(
            input: inputBuffer.baseAddress!,
            envelope: envelopeBuffer.baseAddress!,
            output: outputBuffer.baseAddress!,
            frameCount: input.count
          )
        }
      }
    }

    #expect(output == [0, 0.25, -0.5, -1])
  }

  @Test("Mixer sums without averaging or clipping Float32 headroom")
  func mixerUsesUnitySum() {
    let first: [Float] = [0.75, -0.75, 0.5]
    let second: [Float] = [0.75, -0.75, -0.25]
    var output = [Float](repeating: 9, count: first.count)

    output.withUnsafeMutableBufferPointer { outputBuffer in
      AudioMixerDSP.clear(outputBuffer.baseAddress!, frameCount: outputBuffer.count)
      first.withUnsafeBufferPointer { inputBuffer in
        AudioMixerDSP.accumulate(
          input: inputBuffer.baseAddress!,
          gain: 1,
          output: outputBuffer.baseAddress!,
          frameCount: inputBuffer.count
        )
      }
      second.withUnsafeBufferPointer { inputBuffer in
        AudioMixerDSP.accumulate(
          input: inputBuffer.baseAddress!,
          gain: 1,
          output: outputBuffer.baseAddress!,
          frameCount: inputBuffer.count
        )
      }
    }

    #expect(output == [1.5, -1.5, 0.25])
  }
}
