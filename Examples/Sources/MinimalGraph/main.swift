// SPDX-License-Identifier: Apache-2.0

import RilliyaGraph

@main
enum MinimalGraphExample {
  static func main() throws {
    var graph = AudioGraph()
    let source = try graph.add(StereoSource())
    let gain = try graph.add(Gain(linearGain: 0.5))
    let output = try graph.add(StereoOutput())

    try graph.connect(source.audio, to: gain.input)
    try graph.connect(gain.output, to: output.audio)

    let snapshot = try graph.snapshot()
    print("Validated \(snapshot.nodes.count) nodes and \(snapshot.connections.count) connections.")
  }
}

private struct StereoSource: AudioGraphNode {
  struct Ports: AudioGraphNodePorts {
    let audio = AudioGraphPortID(rawValue: "audio")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "example.stereo-source")
  static let ports = Ports()

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        AudioGraphPortDescriptor(
          id: Self.ports.audio,
          direction: .output,
          signalType: .audio(
            AudioGraphAudioSignalType(
              channelCount: .fixed(2),
              sampleRate: .fixed(48_000)
            )
          ),
          connectionPolicy: .fanOut
        )
      ]
    )
  }
}

private struct Gain: AudioGraphNode {
  struct Ports: AudioGraphNodePorts {
    let input = AudioGraphPortID(rawValue: "input")
    let output = AudioGraphPortID(rawValue: "output")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "example.gain")
  static let ports = Ports()
  let linearGain: Float

  init(linearGain: Float = 1) {
    self.linearGain = linearGain
  }

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    let stereo = AudioGraphSignalType.audio(
      AudioGraphAudioSignalType(channelCount: .fixed(2), sampleRate: .fixed(48_000))
    )
    return AudioGraphNodeDescriptor(
      ports: [
        AudioGraphPortDescriptor(
          id: Self.ports.input,
          direction: .input,
          signalType: stereo,
          connectionPolicy: .singleInput
        ),
        AudioGraphPortDescriptor(
          id: Self.ports.output,
          direction: .output,
          signalType: stereo,
          connectionPolicy: .fanOut
        ),
      ]
    )
  }
}

private struct StereoOutput: AudioGraphNode {
  struct Ports: AudioGraphNodePorts {
    let audio = AudioGraphPortID(rawValue: "audio")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "example.stereo-output")
  static let ports = Ports()

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        AudioGraphPortDescriptor(
          id: Self.ports.audio,
          direction: .input,
          signalType: .audio(
            AudioGraphAudioSignalType(
              channelCount: .fixed(2),
              sampleRate: .fixed(48_000)
            )
          ),
          connectionPolicy: .singleInput
        )
      ]
    )
  }
}
