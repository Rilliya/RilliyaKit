// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaGraph

@main
enum CustomNodeExample {
  static func main() throws {
    var graph = AudioGraph()
    let source = try graph.add(AudioSource())
    let analyzer = try graph.add(WindowedAnalyzer(windowFrameCount: 2_048))

    try graph.connect(source.audio, to: analyzer.input)

    let snapshot = try graph.snapshot()
    let configuredWindow = snapshot.node(id: analyzer.id)?
      .value(as: WindowedAnalyzer.self)?.windowFrameCount
    print("Validated a custom sink with a \(configuredWindow ?? 0)-frame analysis window.")
  }
}

private enum ExampleConfigurationError: Error {
  case invalidWindowFrameCount
}

private struct AudioSource: AudioGraphNode {
  struct Ports: AudioGraphNodePorts {
    let audio = AudioGraphPortID(rawValue: "audio")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "example.custom.audio-source")
  static let ports = Ports()

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        AudioGraphPortDescriptor(
          id: Self.ports.audio,
          direction: .output,
          signalType: .audio(AudioGraphAudioSignalType(channelCount: .fixed(2))),
          connectionPolicy: .fanOut
        )
      ]
    )
  }
}

private struct WindowedAnalyzer: AudioGraphNode {
  struct Ports: AudioGraphNodePorts {
    let input = AudioGraphPortID(rawValue: "input")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "example.custom.windowed-analyzer")
  static let ports = Ports()
  let windowFrameCount: Int

  init(windowFrameCount: Int = 1_024) {
    self.windowFrameCount = windowFrameCount
  }

  func makeDescriptor() throws -> AudioGraphNodeDescriptor {
    guard (1...65_536).contains(windowFrameCount) else {
      throw ExampleConfigurationError.invalidWindowFrameCount
    }
    return AudioGraphNodeDescriptor(
      ports: [
        AudioGraphPortDescriptor(
          id: Self.ports.input,
          direction: .input,
          signalType: .audio(AudioGraphAudioSignalType(channelCount: .fixed(2))),
          connectionPolicy: .singleInput
        )
      ]
    )
  }
}
