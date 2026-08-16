// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A graph resource whose configured construction bound was exceeded.
public enum AudioGraphResource: String, Equatable, Sendable {
  /// Node instances.
  case nodes

  /// Connections, including disabled connections.
  case connections

  /// Ports exposed by one node instance.
  case portsPerNode
}

/// A reason one requested connection is not valid in the current graph.
public enum AudioGraphConnectionIssue: Error, Equatable, LocalizedError, Sendable {
  /// The source node does not exist.
  case missingSourceNode(AudioGraphNodeID)

  /// The target node does not exist.
  case missingTargetNode(AudioGraphNodeID)

  /// The source port does not exist on its node.
  case missingSourcePort(AudioGraphPortAddress)

  /// The target port does not exist on its node.
  case missingTargetPort(AudioGraphPortAddress)

  /// The proposed source is not an output port.
  case sourceIsNotOutput(AudioGraphPortAddress)

  /// The proposed target is not an input port.
  case targetIsNotInput(AudioGraphPortAddress)

  /// The two ports carry incompatible values.
  case incompatibleSignals(AudioGraphSignalIncompatibility)

  /// The target's single-input capacity is already occupied.
  case targetAlreadyConnected(AudioGraphPortAddress)

  /// The same source and target are already connected.
  case duplicateEndpoints

  /// The configured graph connection bound has been reached.
  case connectionLimitReached(Int)

  /// A localized explanation of the denied connection.
  public var errorDescription: String? {
    switch self {
    case .missingSourceNode:
      return "The source node does not exist in this graph."
    case .missingTargetNode:
      return "The target node does not exist in this graph."
    case .missingSourcePort(let address):
      return "The source node does not expose port '\(address.portID.rawValue)'."
    case .missingTargetPort(let address):
      return "The target node does not expose port '\(address.portID.rawValue)'."
    case .sourceIsNotOutput:
      return "A graph connection must begin at an output port."
    case .targetIsNotInput:
      return "A graph connection must end at an input port."
    case .incompatibleSignals(let issue):
      return "The source and target signals are incompatible: \(issue.description)."
    case .targetAlreadyConnected:
      return "The target accepts only one enabled input connection."
    case .duplicateEndpoints:
      return "The same source and target ports are already connected."
    case .connectionLimitReached(let limit):
      return "The graph has reached its configured connection limit of \(limit)."
    }
  }
}

extension AudioGraphSignalIncompatibility {
  fileprivate var description: String {
    switch self {
    case .differentSignalFamilies:
      return "different signal families"
    case .incompatibleChannelCount:
      return "incompatible audio channel counts"
    case .incompatibleSampleRate:
      return "incompatible audio sample rates"
    case .incompatibleScalarTypes:
      return "an unsupported scalar conversion"
    case .incompatibleCategoryDomains:
      return "different category domains"
    case .incompatibleStructures:
      return "different nominal structure schemas"
    }
  }
}

/// The result of previewing a connection against the current graph.
public enum AudioGraphConnectionDecision: Equatable, Sendable {
  /// The connection is valid, optionally through one lossless implicit conversion.
  case allowed(conversion: AudioGraphImplicitConversion?)

  /// The connection is invalid for the reported reason.
  case denied(AudioGraphConnectionIssue)
}

/// A graph mutation that could not be applied safely.
public enum AudioGraphMutationError: Error, Equatable, LocalizedError, Sendable {
  /// A node instance already uses the supplied identity.
  case duplicateNodeID(AudioGraphNodeID)

  /// A connection instance already uses the supplied identity.
  case duplicateConnectionID(AudioGraphConnectionID)

  /// The requested node does not exist.
  case missingNode(AudioGraphNodeID)

  /// Configuration for a different node definition cannot replace an existing node.
  case nodeTypeMismatch(expected: AudioGraphNodeTypeID, actual: AudioGraphNodeTypeID)

  /// Updated node configuration made an existing connection invalid.
  case nodeUpdateInvalidatedConnection(AudioGraphConnectionID, AudioGraphConnectionIssue)

  /// A node type supplied an empty stable identity.
  case emptyNodeTypeID

  /// A node supplied an empty port identity.
  case emptyPortID

  /// A node supplied the same semantic port identity more than once.
  case duplicatePortID(AudioGraphPortID)

  /// An output did not use fan-out semantics, or an input used fan-out semantics.
  case invalidPortConnectionPolicy(AudioGraphPortID)

  /// An audio port supplied an invalid channel-count or sample-rate constraint.
  case invalidAudioSignalConstraint(AudioGraphPortID)

  /// A namespaced category, structure, or field identity was empty.
  case emptySemanticID(AudioGraphPortID)

  /// A configured construction bound was exceeded.
  case resourceLimitExceeded(AudioGraphResource, limit: Int)

  /// A requested connection was denied by the shared evaluator.
  case connectionDenied(AudioGraphConnectionIssue)

  /// The graph contains validation errors and cannot become a snapshot.
  case validationFailed(AudioGraphValidationReport)

  /// A localized explanation of the failed mutation.
  public var errorDescription: String? {
    switch self {
    case .duplicateNodeID:
      return "The graph already contains a node with this identity."
    case .duplicateConnectionID:
      return "The graph already contains a connection with this identity."
    case .missingNode:
      return "The requested graph node does not exist."
    case .nodeTypeMismatch(let expected, let actual):
      return
        "Node configuration for '\(actual.rawValue)' cannot replace a node of type '\(expected.rawValue)'."
    case .nodeUpdateInvalidatedConnection(_, let issue):
      return issue.errorDescription
    case .emptyNodeTypeID:
      return "Graph node type identities cannot be empty."
    case .emptyPortID:
      return "Graph port identities cannot be empty."
    case .duplicatePortID(let portID):
      return "The node defines port '\(portID.rawValue)' more than once."
    case .invalidPortConnectionPolicy(let portID):
      return "Port '\(portID.rawValue)' has a connection policy that does not match its direction."
    case .invalidAudioSignalConstraint(let portID):
      return "Port '\(portID.rawValue)' has an invalid audio signal constraint."
    case .emptySemanticID(let portID):
      return "Port '\(portID.rawValue)' contains an empty semantic signal identity."
    case .resourceLimitExceeded(let resource, let limit):
      return "The graph exceeds the configured \(resource.rawValue) limit of \(limit)."
    case .connectionDenied(let issue):
      return issue.errorDescription
    case .validationFailed(let report):
      return report.diagnostics.first?.message
        ?? "The graph contains validation errors and cannot be prepared."
    }
  }
}

private struct AudioGraphConnectionEndpoints: Hashable, Sendable {
  let source: AudioGraphPortAddress
  let target: AudioGraphPortAddress
}

/// A mutable audio graph with stable identities, typed node handles, and bounded storage.
public struct AudioGraph: Sendable {
  /// The policy and resource bounds used by this graph.
  public let configuration: AudioGraphConfiguration

  private var nodeStorage: [AudioGraphNodeInstance] = []
  private var nodeIndices: [AudioGraphNodeID: Int] = [:]
  private var connectionStorage: [AudioGraphConnection] = []
  private var connectionIndices: [AudioGraphConnectionID: Int] = [:]
  private var connectionIDsByEndpoint: [AudioGraphConnectionEndpoints: AudioGraphConnectionID] = [:]
  private var enabledIncomingConnectionCounts: [AudioGraphPortAddress: Int] = [:]

  /// Creates an empty graph.
  public init(configuration: AudioGraphConfiguration = AudioGraphConfiguration()) {
    self.configuration = configuration
  }

  /// The number of inserted nodes.
  public var nodeCount: Int { nodeStorage.count }

  /// The number of inserted connections, including disabled connections.
  public var connectionCount: Int { connectionStorage.count }

  /// Nodes in stable insertion order.
  public var nodes: [AudioGraphNodeInstance] { nodeStorage }

  /// Connections in stable insertion order, including disabled connections.
  public var connections: [AudioGraphConnection] { connectionStorage }

  /// Returns one node by stable identity.
  public func node(id: AudioGraphNodeID) -> AudioGraphNodeInstance? {
    guard let index = nodeIndices[id] else { return nil }
    return nodeStorage[index]
  }

  /// Returns one connection by stable identity.
  public func connection(id: AudioGraphConnectionID) -> AudioGraphConnection? {
    guard let index = connectionIndices[id] else { return nil }
    return connectionStorage[index]
  }

  /// Inserts one configured node value and retains it for preparation.
  @discardableResult
  public mutating func add<Node: AudioGraphNode>(
    _ node: Node,
    id: AudioGraphNodeID = AudioGraphNodeID()
  ) throws -> AudioGraphNodeHandle<Node> {
    guard nodeIndices[id] == nil else {
      throw AudioGraphMutationError.duplicateNodeID(id)
    }
    guard nodeStorage.count < self.configuration.limits.maximumNodeCount else {
      throw AudioGraphMutationError.resourceLimitExceeded(
        .nodes,
        limit: self.configuration.limits.maximumNodeCount
      )
    }
    guard !Node.typeID.rawValue.isEmpty else {
      throw AudioGraphMutationError.emptyNodeTypeID
    }
    let descriptor = try node.makeDescriptor()
    try validate(descriptor: descriptor)

    let instance = AudioGraphNodeInstance(
      id: id,
      typeID: Node.typeID,
      descriptor: descriptor,
      value: node
    )
    nodeIndices[id] = nodeStorage.count
    nodeStorage.append(instance)
    return AudioGraphNodeHandle(id: id)
  }

  /// Re-resolves one configured node value without changing its stable identity.
  ///
  /// The update is transactional. It is rejected when it removes or changes a connected port in a
  /// way that would invalidate an existing connection or same-render cycle validation.
  public mutating func update<Node: AudioGraphNode>(
    _ node: Node,
    at handle: AudioGraphNodeHandle<Node>
  ) throws {
    try update(node, nodeID: handle.id)
  }

  /// Re-resolves one configured node value addressed by its stable identity.
  public mutating func update<Node: AudioGraphNode>(
    _ node: Node,
    nodeID: AudioGraphNodeID
  ) throws {
    guard let index = nodeIndices[nodeID] else {
      throw AudioGraphMutationError.missingNode(nodeID)
    }
    let existingNode = nodeStorage[index]
    guard existingNode.typeID == Node.typeID else {
      throw AudioGraphMutationError.nodeTypeMismatch(
        expected: existingNode.typeID,
        actual: Node.typeID
      )
    }
    let descriptor = try node.makeDescriptor()
    try validate(descriptor: descriptor)

    var candidate = self
    candidate.nodeStorage[index] = AudioGraphNodeInstance(
      id: nodeID,
      typeID: Node.typeID,
      descriptor: descriptor,
      value: node
    )
    for connectionIndex in candidate.connectionStorage.indices {
      let connection = candidate.connectionStorage[connectionIndex]
      guard connection.source.nodeID == nodeID || connection.target.nodeID == nodeID else {
        continue
      }
      switch candidate.connectionDecision(
        from: connection.source,
        to: connection.target,
        excluding: connection.id,
        wouldBeEnabled: connection.isEnabled
      ) {
      case .allowed(let conversion):
        candidate.connectionStorage[connectionIndex] = AudioGraphConnection(
          id: connection.id,
          source: connection.source,
          target: connection.target,
          implicitConversion: conversion,
          isEnabled: connection.isEnabled
        )
      case .denied(let issue):
        throw AudioGraphMutationError.nodeUpdateInvalidatedConnection(connection.id, issue)
      }
    }
    let report = candidate.validate()
    guard report.isValid else {
      throw AudioGraphMutationError.validationFailed(report)
    }
    self = candidate
  }

  /// Removes a node and every connection that references one of its ports.
  @discardableResult
  public mutating func removeNode(id: AudioGraphNodeID) -> Bool {
    guard let index = nodeIndices[id] else { return false }
    nodeStorage.remove(at: index)
    connectionStorage.removeAll { $0.source.nodeID == id || $0.target.nodeID == id }
    rebuildIndices()
    return true
  }

  /// Returns the connection decision used by both preview and committed mutations.
  public func connectionDecision(
    from source: AudioGraphPortAddress,
    to target: AudioGraphPortAddress
  ) -> AudioGraphConnectionDecision {
    connectionDecision(from: source, to: target, excluding: nil)
  }

  private func connectionDecision(
    from source: AudioGraphPortAddress,
    to target: AudioGraphPortAddress,
    excluding excludedConnectionID: AudioGraphConnectionID?,
    wouldBeEnabled: Bool = true
  ) -> AudioGraphConnectionDecision {
    guard let sourceNode = node(id: source.nodeID) else {
      return .denied(.missingSourceNode(source.nodeID))
    }
    guard let targetNode = node(id: target.nodeID) else {
      return .denied(.missingTargetNode(target.nodeID))
    }
    guard let sourcePort = sourceNode.port(source.portID) else {
      return .denied(.missingSourcePort(source))
    }
    guard let targetPort = targetNode.port(target.portID) else {
      return .denied(.missingTargetPort(target))
    }
    guard sourcePort.direction == .output else {
      return .denied(.sourceIsNotOutput(source))
    }
    guard targetPort.direction == .input else {
      return .denied(.targetIsNotInput(target))
    }
    let endpoints = AudioGraphConnectionEndpoints(source: source, target: target)
    guard
      connectionIDsByEndpoint[endpoints] == nil
        || connectionIDsByEndpoint[endpoints] == excludedConnectionID
    else {
      return .denied(.duplicateEndpoints)
    }
    var enabledIncomingCount = enabledIncomingConnectionCounts[target, default: 0]
    if let excludedConnectionID,
      let excludedConnection = connection(id: excludedConnectionID),
      excludedConnection.isEnabled,
      excludedConnection.target == target
    {
      enabledIncomingCount -= 1
    }
    if wouldBeEnabled, targetPort.connectionPolicy == .singleInput, enabledIncomingCount > 0 {
      return .denied(.targetAlreadyConnected(target))
    }
    guard
      excludedConnectionID != nil
        || connectionStorage.count < configuration.limits.maximumConnectionCount
    else {
      return .denied(
        .connectionLimitReached(configuration.limits.maximumConnectionCount)
      )
    }
    switch sourcePort.signalType.compatibility(with: targetPort.signalType) {
    case .compatible(let conversion):
      return .allowed(conversion: conversion)
    case .incompatible(let issue):
      return .denied(.incompatibleSignals(issue))
    }
  }

  /// Inserts one enabled directed connection after evaluating the shared compatibility rules.
  @discardableResult
  public mutating func connect(
    _ source: AudioGraphPortAddress,
    to target: AudioGraphPortAddress,
    id: AudioGraphConnectionID = AudioGraphConnectionID()
  ) throws -> AudioGraphConnectionID {
    guard connectionIndices[id] == nil else {
      throw AudioGraphMutationError.duplicateConnectionID(id)
    }
    let conversion: AudioGraphImplicitConversion?
    switch connectionDecision(from: source, to: target) {
    case .allowed(let selectedConversion):
      conversion = selectedConversion
    case .denied(let issue):
      throw AudioGraphMutationError.connectionDenied(issue)
    }
    let connection = AudioGraphConnection(
      id: id,
      source: source,
      target: target,
      implicitConversion: conversion,
      isEnabled: true
    )
    connectionIndices[id] = connectionStorage.count
    connectionStorage.append(connection)
    connectionIDsByEndpoint[
      AudioGraphConnectionEndpoints(source: source, target: target)
    ] = id
    enabledIncomingConnectionCounts[target, default: 0] += 1
    return id
  }

  /// Removes one connection by stable identity.
  @discardableResult
  public mutating func removeConnection(id: AudioGraphConnectionID) -> Bool {
    guard let index = connectionIndices[id] else { return false }
    connectionStorage.remove(at: index)
    rebuildConnectionIndices()
    return true
  }

  /// Enables or disables one connection without changing its stable identity.
  @discardableResult
  public mutating func setConnection(
    id: AudioGraphConnectionID,
    isEnabled: Bool
  ) throws -> Bool {
    guard let index = connectionIndices[id] else { return false }
    let connection = connectionStorage[index]
    if isEnabled, !connection.isEnabled {
      switch connectionDecision(
        from: connection.source,
        to: connection.target,
        excluding: connection.id
      ) {
      case .allowed(let conversion):
        connectionStorage[index] = AudioGraphConnection(
          id: connection.id,
          source: connection.source,
          target: connection.target,
          implicitConversion: conversion,
          isEnabled: true
        )
      case .denied(let issue):
        throw AudioGraphMutationError.connectionDenied(issue)
      }
    } else {
      connectionStorage[index] = AudioGraphConnection(
        id: connection.id,
        source: connection.source,
        target: connection.target,
        implicitConversion: connection.implicitConversion,
        isEnabled: isEnabled
      )
    }
    rebuildConnectionIndices()
    return true
  }

  /// Validates the complete graph and returns bounded, deterministic diagnostics.
  public func validate() -> AudioGraphValidationReport {
    AudioGraphValidator.validate(
      nodes: nodes,
      connections: connectionStorage,
      configuration: configuration
    )
  }

  /// Produces an immutable snapshot when the complete graph is valid.
  public func snapshot() throws -> AudioGraphSnapshot {
    let report = validate()
    guard report.isValid else {
      throw AudioGraphMutationError.validationFailed(report)
    }
    return AudioGraphSnapshot(
      nodes: nodeStorage,
      connections: connectionStorage,
      configuration: configuration
    )
  }

  private func validate(descriptor: AudioGraphNodeDescriptor) throws {
    guard descriptor.ports.count <= configuration.limits.maximumPortCountPerNode else {
      throw AudioGraphMutationError.resourceLimitExceeded(
        .portsPerNode,
        limit: configuration.limits.maximumPortCountPerNode
      )
    }
    var portIDs = Set<AudioGraphPortID>()
    portIDs.reserveCapacity(descriptor.ports.count)
    for port in descriptor.ports {
      guard !port.id.rawValue.isEmpty else {
        throw AudioGraphMutationError.emptyPortID
      }
      guard portIDs.insert(port.id).inserted else {
        throw AudioGraphMutationError.duplicatePortID(port.id)
      }
      switch (port.direction, port.connectionPolicy) {
      case (.output, .fanOut), (.input, .singleInput), (.input, .mixingInput):
        break
      default:
        throw AudioGraphMutationError.invalidPortConnectionPolicy(port.id)
      }
      try validate(signalType: port.signalType, portID: port.id)
    }
  }

  private func validate(
    signalType: AudioGraphSignalType,
    portID: AudioGraphPortID
  ) throws {
    switch signalType {
    case .audio(let audio):
      if case .fixed(let count) = audio.channelCount, count <= 0 {
        throw AudioGraphMutationError.invalidAudioSignalConstraint(portID)
      }
      if case .fixed(let rate) = audio.sampleRate, !rate.isFinite || rate <= 0 {
        throw AudioGraphMutationError.invalidAudioSignalConstraint(portID)
      }
    case .category(let domain):
      if let domain, domain.rawValue.isEmpty {
        throw AudioGraphMutationError.emptySemanticID(portID)
      }
    case .structure(let structure):
      if structure.rawValue.isEmpty {
        throw AudioGraphMutationError.emptySemanticID(portID)
      }
    case .scalar:
      break
    }
  }

  private mutating func rebuildIndices() {
    nodeIndices = Dictionary(
      uniqueKeysWithValues: nodeStorage.enumerated().map { ($0.element.id, $0.offset) }
    )
    rebuildConnectionIndices()
  }

  private mutating func rebuildConnectionIndices() {
    connectionIndices = Dictionary(
      uniqueKeysWithValues: connectionStorage.enumerated().map { ($0.element.id, $0.offset) }
    )
    connectionIDsByEndpoint = Dictionary(
      uniqueKeysWithValues: connectionStorage.map {
        (
          AudioGraphConnectionEndpoints(source: $0.source, target: $0.target),
          $0.id
        )
      }
    )
    enabledIncomingConnectionCounts.removeAll(keepingCapacity: true)
    for connection in connectionStorage where connection.isEnabled {
      enabledIncomingConnectionCounts[connection.target, default: 0] += 1
    }
  }
}
