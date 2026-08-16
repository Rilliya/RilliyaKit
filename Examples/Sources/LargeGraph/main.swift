// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaGraph

@main
enum LargeGraphExample {
  static func main() throws {
    let requestedNodeCount = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 25_000
    let nodeCount = max(requestedNodeCount, 1)
    let limits = try AudioGraphLimits(
      maximumNodeCount: nodeCount,
      maximumConnectionCount: nodeCount - 1,
      maximumPortCountPerNode: 2,
      maximumDiagnosticCount: 64
    )
    let start = ContinuousClock.now
    var graph = AudioGraph(configuration: AudioGraphConfiguration(limits: limits))
    var previous: AudioGraphNodeHandle<Relay>?

    for _ in 0..<nodeCount {
      let current = try graph.add(Relay())
      if let previous {
        try graph.connect(previous.output, to: current.input)
      }
      previous = current
    }

    let snapshot = try graph.snapshot()
    let elapsed = start.duration(to: .now)
    print(
      "Validated \(snapshot.nodes.count) nodes and \(snapshot.connections.count) connections in \(elapsed)."
    )
  }
}

private struct Relay: AudioGraphNode {
  struct Ports: AudioGraphNodePorts {
    let input = AudioGraphPortID(rawValue: "input")
    let output = AudioGraphPortID(rawValue: "output")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "example.large.relay")
  static let ports = Ports()

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    let signal = AudioGraphSignalType.audio(AudioGraphAudioSignalType(channelCount: .fixed(1)))
    return AudioGraphNodeDescriptor(
      ports: [
        AudioGraphPortDescriptor(
          id: Self.ports.input,
          direction: .input,
          signalType: signal,
          connectionPolicy: .singleInput
        ),
        AudioGraphPortDescriptor(
          id: Self.ports.output,
          direction: .output,
          signalType: signal,
          connectionPolicy: .fanOut
        ),
      ]
    )
  }
}
