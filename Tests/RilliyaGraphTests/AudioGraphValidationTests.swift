// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaGraph
import Testing

@Suite("Audio graph validation")
struct AudioGraphValidationTests {
  @Test("Evaluates typed signal compatibility")
  func evaluatesSignalCompatibility() {
    let stereo = AudioGraphSignalType.audio(
      AudioGraphAudioSignalType(channelCount: .fixed(2), sampleRate: .fixed(48_000))
    )
    let anyAudio = AudioGraphSignalType.audio(AudioGraphAudioSignalType())
    let mono = AudioGraphSignalType.audio(
      AudioGraphAudioSignalType(channelCount: .fixed(1), sampleRate: .fixed(48_000))
    )
    let category = AudioGraphCategoryDomainID(rawValue: "test.emotion")
    let otherCategory = AudioGraphCategoryDomainID(rawValue: "test.genre")
    let structure = AudioGraphStructureID(rawValue: "test.analysis.v1")

    #expect(stereo.compatibility(with: anyAudio) == .compatible(conversion: nil))
    #expect(
      anyAudio.compatibility(with: stereo) == .incompatible(.incompatibleChannelCount)
    )
    #expect(stereo.compatibility(with: mono) == .incompatible(.incompatibleChannelCount))
    #expect(
      AudioGraphSignalType.scalar(.integer).compatibility(with: .scalar(.floatingPoint))
        == .compatible(conversion: .integerToFloatingPoint)
    )
    #expect(
      AudioGraphSignalType.scalar(.floatingPoint).compatibility(with: .scalar(.integer))
        == .incompatible(.incompatibleScalarTypes)
    )
    #expect(
      AudioGraphSignalType.category(domain: category).compatibility(with: .category(domain: nil))
        == .compatible(conversion: nil)
    )
    #expect(
      AudioGraphSignalType.category(domain: nil).compatibility(
        with: .category(domain: category)
      ) == .incompatible(.incompatibleCategoryDomains)
    )
    #expect(
      AudioGraphSignalType.category(domain: category).compatibility(
        with: .category(domain: otherCategory)
      ) == .incompatible(.incompatibleCategoryDomains)
    )
    #expect(
      AudioGraphSignalType.structure(structure).compatibility(with: .structure(structure))
        == .compatible(conversion: nil)
    )
    #expect(
      AudioGraphSignalType.structure(structure).compatibility(with: .scalar(.integer))
        == .incompatible(.differentSignalFamilies)
    )
  }

  @Test("Rejects malformed third-party node definitions")
  func rejectsMalformedDefinitions() throws {
    var graph = AudioGraph()
    try expectDefinitionFailure(
      graph: &graph,
      node: EmptyTypeIDNode(),
      issue: .emptyNodeTypeID
    )
    try expectDefinitionFailure(
      graph: &graph,
      node: BadPortsNode(),
      issue: .duplicatePortID(BadPortsNode.ports.value)
    )
    try expectDefinitionFailure(
      graph: &graph,
      node: BadPolicyNode(),
      issue: .invalidPortConnectionPolicy(BadPolicyNode.ports.input)
    )
    try expectDefinitionFailure(
      graph: &graph,
      node: BadAudioNode(),
      issue: .invalidAudioSignalConstraint(BadAudioNode.ports.audio)
    )
  }

  @Test("Retains a node package's typed descriptor error with node context")
  func retainsDescriptorFailure() throws {
    var graph = AudioGraph()
    let nodeID = AudioGraphNodeID()

    let error = #expect(throws: AudioGraphMutationError.self) {
      try graph.add(ThrowingDescriptorNode(), id: nodeID)
    }
    guard let error, case .nodeDescriptorFailed(let failure) = error else {
      Issue.record("Expected a contextual descriptor failure")
      return
    }

    #expect(failure.nodeID == nodeID)
    #expect(failure.nodeTypeID == ThrowingDescriptorNode.typeID)
    #expect(failure.underlyingError as? TestNodeDefinitionError == .invalidConfiguration)
    #expect(error.underlyingError as? TestNodeDefinitionError == .invalidConfiguration)
    #expect(error.nodeIDs == [nodeID])
  }

  @Test("Enforces checked configurable resource limits")
  func enforcesLimits() throws {
    let limits = try AudioGraphLimits(
      maximumNodeCount: 1,
      maximumConnectionCount: 0,
      maximumPortCountPerNode: 2,
      maximumDiagnosticCount: 1
    )
    var graph = AudioGraph(configuration: AudioGraphConfiguration(limits: limits))
    _ = try graph.add(OnePortSource())

    let error = #expect(throws: AudioGraphMutationError.self) {
      try graph.add(OnePortSource())
    }
    guard let error, case .resourceLimitExceeded(let resource, let limit) = error else {
      Issue.record("Expected the configured graph bound to reject the node")
      return
    }
    #expect(resource == .nodes)
    #expect(limit == 1)
    #expect(throws: AudioGraphLimitConfigurationError.invalidMaximumNodeCount(0)) {
      try AudioGraphLimits(maximumNodeCount: 0)
    }
  }

  @Test("Validates a ten-thousand-node graph without recursive traversal")
  func validatesLargeGraph() throws {
    let nodeCount = 10_000
    let limits = try AudioGraphLimits(
      maximumNodeCount: nodeCount,
      maximumConnectionCount: nodeCount - 1,
      maximumPortCountPerNode: 2,
      maximumDiagnosticCount: 16
    )
    var graph = AudioGraph(configuration: AudioGraphConfiguration(limits: limits))
    var previous: AudioGraphNodeHandle<LargeRelay>?
    for _ in 0..<nodeCount {
      let current = try graph.add(LargeRelay())
      if let previous {
        try graph.connect(previous.output, to: current.input)
      }
      previous = current
    }

    let snapshot = try graph.snapshot()
    #expect(snapshot.nodes.count == nodeCount)
    #expect(snapshot.connections.count == nodeCount - 1)
  }

  private func expectDefinitionFailure<Node: AudioGraphNode>(
    graph: inout AudioGraph,
    node: Node,
    issue: AudioGraphNodeDefinitionIssue
  ) throws {
    let nodeID = AudioGraphNodeID()
    let error = #expect(throws: AudioGraphMutationError.self) {
      try graph.add(node, id: nodeID)
    }
    guard let error, case .invalidNodeDefinition(let failure) = error else {
      Issue.record("Expected a contextual invalid-node-definition failure")
      return
    }
    #expect(failure.nodeID == nodeID)
    #expect(failure.nodeTypeID == Node.typeID)
    #expect(failure.issue == issue)
    #expect(error.nodeIDs == [nodeID])
  }
}

private struct EmptyTypeIDNode: AudioGraphNode {
  static let typeID = AudioGraphNodeTypeID(rawValue: "")

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(ports: [])
  }
}

private enum TestNodeDefinitionError: Error, Equatable {
  case invalidConfiguration
}

private struct ThrowingDescriptorNode: AudioGraphNode {
  static let typeID = AudioGraphNodeTypeID(rawValue: "test.throwing-descriptor")

  func makeDescriptor() throws -> AudioGraphNodeDescriptor {
    throw TestNodeDefinitionError.invalidConfiguration
  }
}

private struct BadPortsNode: AudioGraphNode {
  struct Ports: AudioGraphNodePorts {
    let value = AudioGraphPortID(rawValue: "duplicate")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "test.bad-ports")
  static let ports = Ports()

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    let descriptor = AudioGraphPortDescriptor(
      id: Self.ports.value,
      direction: .output,
      signalType: .scalar(.integer),
      connectionPolicy: .fanOut
    )
    return AudioGraphNodeDescriptor(ports: [descriptor, descriptor])
  }
}

private struct BadPolicyNode: AudioGraphNode {
  struct Ports: AudioGraphNodePorts {
    let input = AudioGraphPortID(rawValue: "input")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "test.bad-policy")
  static let ports = Ports()

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        AudioGraphPortDescriptor(
          id: Self.ports.input,
          direction: .input,
          signalType: .scalar(.integer),
          connectionPolicy: .fanOut
        )
      ]
    )
  }
}

private struct BadAudioNode: AudioGraphNode {
  struct Ports: AudioGraphNodePorts {
    let audio = AudioGraphPortID(rawValue: "audio")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "test.bad-audio")
  static let ports = Ports()

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        AudioGraphPortDescriptor(
          id: Self.ports.audio,
          direction: .output,
          signalType: .audio(AudioGraphAudioSignalType(channelCount: .fixed(0))),
          connectionPolicy: .fanOut
        )
      ]
    )
  }
}

private struct OnePortSource: AudioGraphNode {
  struct Ports: AudioGraphNodePorts {
    let output = AudioGraphPortID(rawValue: "output")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "test.one-port-source")
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

private struct LargeRelay: AudioGraphNode {
  struct Ports: AudioGraphNodePorts {
    let input = AudioGraphPortID(rawValue: "input")
    let output = AudioGraphPortID(rawValue: "output")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "test.large-relay")
  static let ports = Ports()

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        AudioGraphPortDescriptor(
          id: Self.ports.input,
          direction: .input,
          signalType: .scalar(.floatingPoint),
          connectionPolicy: .singleInput
        ),
        AudioGraphPortDescriptor(
          id: Self.ports.output,
          direction: .output,
          signalType: .scalar(.floatingPoint),
          connectionPolicy: .fanOut
        ),
      ]
    )
  }
}
