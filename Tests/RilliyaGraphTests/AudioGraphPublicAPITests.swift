// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaGraph
import Testing

@Suite("Audio graph public API")
struct AudioGraphPublicAPITests {
  @Test("Builds a minimal typed graph without application adapters")
  func buildsMinimalGraph() throws {
    var graph = AudioGraph()
    let source = try graph.add(TestStereoSource())
    let gain = try graph.add(TestGain(gain: 0.5))
    let output = try graph.add(TestStereoOutput())

    try graph.connect(source.output, to: gain.input)
    try graph.connect(gain.output, to: output.input)

    let snapshot = try graph.snapshot()
    #expect(snapshot.nodes.count == 3)
    #expect(snapshot.connections.count == 2)
    #expect(
      snapshot.node(id: gain.id)?.value(as: TestGain.self)?.gain == 0.5
    )
  }

  @Test("Updates typed node configuration without changing identity")
  func updatesTypedConfiguration() throws {
    var graph = AudioGraph()
    let gain = try graph.add(TestGain(gain: 0.5))

    try graph.update(TestGain(gain: 0.75), at: gain)

    #expect(graph.nodes.map(\.id) == [gain.id])
    #expect(graph.node(id: gain.id)?.value(as: TestGain.self)?.gain == 0.75)
  }

  @Test("Rejects a node update that would invalidate an existing connection")
  func rejectsInvalidatingNodeUpdate() throws {
    var graph = AudioGraph()
    let source = try graph.add(TestConfigurableSource(channelCount: 2))
    let output = try graph.add(TestStereoOutput())
    let connectionID = try graph.connect(source.output, to: output.input)
    let issue = AudioGraphConnectionIssue.incompatibleSignals(.incompatibleChannelCount)

    #expect(
      throws: AudioGraphMutationError.nodeUpdateInvalidatedConnection(connectionID, issue)
    ) {
      try graph.update(TestConfigurableSource(channelCount: 1), at: source)
    }
    #expect(
      graph.node(id: source.id)?.value(as: TestConfigurableSource.self)?.channelCount == 2
    )
    _ = try graph.snapshot()
  }

  @Test("Uses one compatibility decision for preview and commit")
  func previewMatchesCommittedConnection() throws {
    var graph = AudioGraph()
    let source = try graph.add(TestIntegerSource())
    let target = try graph.add(TestFloatingPointInput())
    let sourcePort = source.output
    let targetPort = target.input

    #expect(
      graph.connectionDecision(from: sourcePort, to: targetPort)
        == .allowed(conversion: .integerToFloatingPoint)
    )
    let connectionID = try graph.connect(sourcePort, to: targetPort)
    let snapshot = try graph.snapshot()
    #expect(snapshot.connections.first?.id == connectionID)
    #expect(snapshot.connections.first?.implicitConversion == .integerToFloatingPoint)
  }

  @Test("Rejects a second enabled source at a single input")
  func enforcesSingleInputCapacity() throws {
    var graph = AudioGraph()
    let first = try graph.add(TestStereoSource())
    let second = try graph.add(TestStereoSource())
    let output = try graph.add(TestStereoOutput())
    let target = output.input
    try graph.connect(first.output, to: target)

    let issue = AudioGraphConnectionIssue.targetAlreadyConnected(target)
    #expect(
      graph.connectionDecision(from: second.output, to: target)
        == .denied(issue)
    )
    #expect(throws: AudioGraphMutationError.connectionDenied(issue)) {
      try graph.connect(second.output, to: target)
    }
  }

  @Test("Reports every independent combinational cycle deterministically")
  func reportsIndependentCycles() throws {
    var graph = AudioGraph()
    let identifiers = (0..<4).map {
      AudioGraphNodeID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000\($0 + 1)")!
      )
    }
    let first = try graph.add(TestRelay(), id: identifiers[0])
    let second = try graph.add(TestRelay(), id: identifiers[1])
    let third = try graph.add(TestRelay(), id: identifiers[2])
    let fourth = try graph.add(TestRelay(), id: identifiers[3])
    try graph.connect(first.output, to: second.input)
    try graph.connect(second.output, to: first.input)
    try graph.connect(third.output, to: fourth.input)
    try graph.connect(fourth.output, to: third.input)

    let report = graph.validate()
    #expect(!report.isValid)
    #expect(report.diagnostics.map(\.code) == [.cycle, .cycle])
    #expect(report.diagnostics[0].nodeIDs == Array(identifiers[0...1]))
    #expect(report.diagnostics[1].nodeIDs == Array(identifiers[2...3]))
  }

  @Test("An explicit state-breaking node makes feedback valid")
  func stateBreakingNodeAllowsFeedback() throws {
    var graph = AudioGraph()
    let relay = try graph.add(TestRelay())
    let delay = try graph.add(TestStateBreaker())
    try graph.connect(relay.output, to: delay.input)
    try graph.connect(delay.output, to: relay.input)

    #expect(graph.validate().isValid)
    _ = try graph.snapshot()
  }

  @Test("Disabled connections retain identity without consuming input capacity")
  func disabledConnectionsRetainIdentity() throws {
    var graph = AudioGraph()
    let first = try graph.add(TestStereoSource())
    let second = try graph.add(TestStereoSource())
    let output = try graph.add(TestStereoOutput())
    let target = output.input
    let firstConnection = try graph.connect(first.output, to: target)
    try graph.setConnection(id: firstConnection, isEnabled: false)
    _ = try graph.connect(second.output, to: target)

    #expect(throws: AudioGraphMutationError.connectionDenied(.targetAlreadyConnected(target))) {
      try graph.setConnection(id: firstConnection, isEnabled: true)
    }
    let snapshot = try graph.snapshot()
    #expect(snapshot.connections.first?.id == firstConnection)
    #expect(snapshot.connections.first?.isEnabled == false)
  }

  @Test("Updates a disabled route without consuming occupied input capacity")
  func updatesDisabledRouteAlongsideEnabledRoute() throws {
    var graph = AudioGraph()
    let first = try graph.add(TestConfigurableSource(channelCount: 2))
    let second = try graph.add(TestStereoSource())
    let output = try graph.add(TestStereoOutput())
    let disabledConnection = try graph.connect(first.output, to: output.input)
    try graph.setConnection(id: disabledConnection, isEnabled: false)
    _ = try graph.connect(second.output, to: output.input)

    try graph.update(TestConfigurableSource(channelCount: 2), at: first)

    #expect(graph.connection(id: disabledConnection)?.isEnabled == false)
    _ = try graph.snapshot()
  }

  @Test("Removes a node and its connections without changing surviving identities")
  func removesNodeAndIncidentConnections() throws {
    var graph = AudioGraph()
    let source = try graph.add(TestStereoSource())
    let gain = try graph.add(TestGain())
    let output = try graph.add(TestStereoOutput())
    try graph.connect(source.output, to: gain.input)
    let survivingConnection = try graph.connect(gain.output, to: output.input)

    let didRemoveSource = graph.removeNode(id: source.id)
    #expect(didRemoveSource)
    let snapshot = try graph.snapshot()
    #expect(snapshot.nodes.map(\.id) == [gain.id, output.id])
    #expect(snapshot.connections.map(\.id) == [survivingConnection])
  }
}

private struct TestStereoSource: AudioGraphNode {
  struct Ports: AudioGraphNodePorts {
    let output = AudioGraphPortID(rawValue: "audio")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "test.stereo-source")
  static let ports = Ports()

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        AudioGraphPortDescriptor(
          id: Self.ports.output,
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

private struct TestStereoOutput: AudioGraphNode {
  struct Ports: AudioGraphNodePorts {
    let input = AudioGraphPortID(rawValue: "audio")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "test.stereo-output")
  static let ports = Ports()

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        AudioGraphPortDescriptor(
          id: Self.ports.input,
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

private struct TestConfigurableSource: AudioGraphNode {
  struct Ports: AudioGraphNodePorts {
    let output = AudioGraphPortID(rawValue: "audio")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "test.configurable-source")
  static let ports = Ports()
  let channelCount: Int

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        AudioGraphPortDescriptor(
          id: Self.ports.output,
          direction: .output,
          signalType: .audio(
            AudioGraphAudioSignalType(
              channelCount: .fixed(channelCount),
              sampleRate: .fixed(48_000)
            )
          ),
          connectionPolicy: .fanOut
        )
      ]
    )
  }
}

private struct TestGain: AudioGraphNode {
  struct Ports: AudioGraphNodePorts {
    let input = AudioGraphPortID(rawValue: "input")
    let output = AudioGraphPortID(rawValue: "output")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "test.gain")
  static let ports = Ports()
  let gain: Float

  init(gain: Float = 1) {
    self.gain = gain
  }

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    let signal = AudioGraphSignalType.audio(
      AudioGraphAudioSignalType(channelCount: .fixed(2), sampleRate: .fixed(48_000))
    )
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

private struct TestRelay: AudioGraphNode {
  static let typeID = AudioGraphNodeTypeID(rawValue: "test.relay")
  static let ports = RelayPorts()

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    relayDescriptor(ports: Self.ports, cycleBehavior: .combinational)
  }
}

private struct TestStateBreaker: AudioGraphNode {
  static let typeID = AudioGraphNodeTypeID(rawValue: "test.state-breaker")
  static let ports = RelayPorts()

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    relayDescriptor(ports: Self.ports, cycleBehavior: .breaksCycle)
  }
}

private struct TestIntegerSource: AudioGraphNode {
  struct Ports: AudioGraphNodePorts {
    let output = AudioGraphPortID(rawValue: "value")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "test.integer-source")
  static let ports = Ports()

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        AudioGraphPortDescriptor(
          id: Self.ports.output,
          direction: .output,
          signalType: .scalar(.integer),
          connectionPolicy: .fanOut
        )
      ]
    )
  }
}

private struct TestFloatingPointInput: AudioGraphNode {
  struct Ports: AudioGraphNodePorts {
    let input = AudioGraphPortID(rawValue: "value")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "test.floating-point-input")
  static let ports = Ports()

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        AudioGraphPortDescriptor(
          id: Self.ports.input,
          direction: .input,
          signalType: .scalar(.floatingPoint),
          connectionPolicy: .singleInput
        )
      ]
    )
  }
}

private struct RelayPorts: AudioGraphNodePorts {
  let input = AudioGraphPortID(rawValue: "input")
  let output = AudioGraphPortID(rawValue: "output")
}

private func relayDescriptor(
  ports: RelayPorts,
  cycleBehavior: AudioGraphCycleBehavior
) -> AudioGraphNodeDescriptor {
  let signal = AudioGraphSignalType.audio(AudioGraphAudioSignalType(channelCount: .fixed(1)))
  return AudioGraphNodeDescriptor(
    ports: [
      AudioGraphPortDescriptor(
        id: ports.input,
        direction: .input,
        signalType: signal,
        connectionPolicy: .singleInput
      ),
      AudioGraphPortDescriptor(
        id: ports.output,
        direction: .output,
        signalType: signal,
        connectionPolicy: .fanOut
      ),
    ],
    cycleBehavior: cycleBehavior
  )
}
