// SPDX-License-Identifier: Apache-2.0

import RilliyaEngine
import RilliyaGraph
import RilliyaRealtime

@main
enum ExecutableGraphExample {
  static func main() async throws {
    let firstWindow = WindowLatch()
    var graph = AudioGraph()
    let source = try graph.add(ConstantSource(sample: 0.125))
    let analyzer = try graph.add(
      AudioWindowAnalyzerNode(
        configuration: AudioWindowSinkConfiguration(
          windowFrameCount: 512,
          hopFrameCount: 256,
          bufferCapacityFrameCount: 2_048
        )
      ) { window in
        await firstWindow.receive(window)
      }
    )

    try graph.connect(source.audio, to: analyzer.input)

    let engine = try await AudioGraphEngine.prepare(graph)
    let windowTask = Task { await firstWindow.next() }
    try await engine.start()
    let window = await windowTask.value
    try await engine.stop()

    print(
      "Analyzed \(window.frameCount) frames at \(window.format.sampleRate) Hz without an output node."
    )
  }
}

private actor WindowLatch {
  private var buffered: AudioAnalysisWindow?
  private var continuation: CheckedContinuation<AudioAnalysisWindow, Never>?

  func next() async -> AudioAnalysisWindow {
    if let buffered {
      self.buffered = nil
      return buffered
    }
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func receive(_ window: AudioAnalysisWindow) {
    if let continuation {
      self.continuation = nil
      continuation.resume(returning: window)
    } else if buffered == nil {
      buffered = window
    }
  }
}

private struct ConstantSource: AudioGraphExecutableNode {
  struct Ports: AudioGraphNodePorts {
    let audio = AudioGraphPortID(rawValue: "audio")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "example.engine.constant-source")
  static let ports = Ports()
  let sample: Float

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        .output(
          Self.ports.audio,
          signal: .audio(
            AudioGraphAudioSignalType(
              channelCount: .fixed(1),
              sampleRate: .fixed(48_000)
            )
          )
        )
      ]
    )
  }

  func prepare(
    context: AudioGraphNodePreparationContext
  ) async throws -> any PreparedAudioGraphNode {
    let format = try AudioProcessingFormat(sampleRate: 48_000, channelCount: 1)
    let preparation = try AudioRenderPreparation(
      format: format,
      maximumFrameCount: context.maximumFrameCount
    )
    return PreparedAudioSourceGraphNode(
      source: ConstantPreparedSource(preparation: preparation, sample: sample),
      outputPortID: Self.ports.audio
    )
  }
}

private final class ConstantPreparedSource: PreparedAudioSource, @unchecked Sendable {
  let preparation: AudioRenderPreparation
  let timing = AudioNodeTiming.transparent
  let sample: Float

  init(preparation: AudioRenderPreparation, sample: Float) {
    self.preparation = preparation
    self.sample = sample
  }

  func render(
    outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRenderResult {
    guard outputChannels.count >= preparation.format.channelCount else {
      return .insufficientChannels
    }
    for channel in 0..<preparation.format.channelCount {
      outputChannels[channel].update(repeating: sample, count: frameCount)
    }
    return .rendered
  }
}
