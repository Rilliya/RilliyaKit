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

  /// A practical next step suitable for developer tools and workflow UI.
  public var recoverySuggestion: String? {
    switch self {
    case .missingSourceNode, .missingTargetNode, .missingSourcePort, .missingTargetPort:
      "Refresh the workflow topology and reconnect using an address that still exists."
    case .sourceIsNotOutput, .targetIsNotInput:
      "Connect an output port to an input port."
    case .incompatibleSignals:
      "Insert an explicit converter or select ports with compatible signal types."
    case .targetAlreadyConnected:
      "Disconnect the existing source or use an input that explicitly supports mixing."
    case .duplicateEndpoints:
      "Reuse or update the existing connection instead of creating a duplicate."
    case .connectionLimitReached:
      "Remove unused connections or prepare the graph with a larger checked connection limit."
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

/// Complete context for one denied graph connection.
public struct AudioGraphConnectionFailure: AudioGraphContextualError, Equatable, LocalizedError,
  Sendable
{
  /// The output address supplied by the caller.
  public let source: AudioGraphPortAddress

  /// The input address supplied by the caller.
  public let target: AudioGraphPortAddress

  /// The machine-readable reason the connection was denied.
  public let issue: AudioGraphConnectionIssue

  /// Creates a self-contained connection failure suitable for logs and workflow UI.
  public init(
    source: AudioGraphPortAddress,
    target: AudioGraphPortAddress,
    issue: AudioGraphConnectionIssue
  ) {
    self.source = source
    self.target = target
    self.issue = issue
  }

  /// A concise explanation that retains both attempted endpoints.
  public var errorDescription: String? {
    let reason = issue.errorDescription ?? "The connection is invalid."
    return
      "Cannot connect port '\(source.portID.rawValue)' on node \(source.nodeID.rawValue.uuidString) to port '\(target.portID.rawValue)' on node \(target.nodeID.rawValue.uuidString): \(reason)"
  }

  /// A practical next step derived from the machine-readable issue.
  public var recoverySuggestion: String? { issue.recoverySuggestion }

  /// The two node instances addressed by this attempted connection.
  public var nodeIDs: [AudioGraphNodeID] {
    source.nodeID == target.nodeID ? [source.nodeID] : [source.nodeID, target.nodeID]
  }

  /// The two attempted port addresses in source-to-target order.
  public var portAddresses: [AudioGraphPortAddress] { [source, target] }
}

/// The result of previewing a connection against the current graph.
public enum AudioGraphConnectionDecision: Equatable, Sendable {
  /// The connection is valid, optionally through one lossless implicit conversion.
  case allowed(conversion: AudioGraphImplicitConversion?)

  /// The connection is invalid for the reported reason.
  case denied(AudioGraphConnectionFailure)
}

/// A malformed semantic definition supplied by one graph node value.
public enum AudioGraphNodeDefinitionIssue: Error, Equatable, LocalizedError, Sendable {
  /// The resolved descriptor contains more ports than the configured safety bound.
  case portLimitExceeded(actual: Int, limit: Int)

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

  /// A concise explanation of the malformed definition.
  public var errorDescription: String? {
    switch self {
    case .portLimitExceeded(let actual, let limit):
      "The node defines \(actual) ports, exceeding the configured limit of \(limit)."
    case .emptyNodeTypeID:
      "Graph node type identities cannot be empty."
    case .emptyPortID:
      "Graph port identities cannot be empty."
    case .duplicatePortID(let portID):
      "The node defines port '\(portID.rawValue)' more than once."
    case .invalidPortConnectionPolicy(let portID):
      "Port '\(portID.rawValue)' has a connection policy that does not match its direction."
    case .invalidAudioSignalConstraint(let portID):
      "Port '\(portID.rawValue)' has an invalid audio signal constraint."
    case .emptySemanticID(let portID):
      "Port '\(portID.rawValue)' contains an empty semantic signal identity."
    }
  }

  /// The malformed port when this issue refers to one.
  public var portID: AudioGraphPortID? {
    switch self {
    case .duplicatePortID(let portID), .invalidPortConnectionPolicy(let portID),
      .invalidAudioSignalConstraint(let portID), .emptySemanticID(let portID):
      portID
    case .portLimitExceeded, .emptyNodeTypeID, .emptyPortID:
      nil
    }
  }
}

/// Node identity and type context around one malformed semantic definition.
public struct AudioGraphNodeDefinitionFailure: Error, Equatable, LocalizedError, Sendable {
  /// The node instance being inserted or updated.
  public let nodeID: AudioGraphNodeID

  /// The package-defined node type.
  public let nodeTypeID: AudioGraphNodeTypeID

  /// The machine-readable definition problem.
  public let issue: AudioGraphNodeDefinitionIssue

  /// Creates a contextual node-definition failure.
  public init(
    nodeID: AudioGraphNodeID,
    nodeTypeID: AudioGraphNodeTypeID,
    issue: AudioGraphNodeDefinitionIssue
  ) {
    self.nodeID = nodeID
    self.nodeTypeID = nodeTypeID
    self.issue = issue
  }

  /// A concise explanation that identifies the node package and instance.
  public var errorDescription: String? {
    "Node '\(nodeTypeID.rawValue)' (\(nodeID.rawValue.uuidString)) is invalid: \(issue.errorDescription ?? "invalid definition")"
  }
}

/// Context around an error thrown while a node value resolves its descriptor.
public struct AudioGraphNodeDescriptorFailure: Error, LocalizedError, @unchecked Sendable {
  /// The node instance being inserted or updated.
  public let nodeID: AudioGraphNodeID

  /// The package-defined node type.
  public let nodeTypeID: AudioGraphNodeTypeID

  /// The original concrete error thrown by the node package.
  public let underlyingError: any Error

  /// Creates failure context without erasing the original error value.
  public init(
    nodeID: AudioGraphNodeID,
    nodeTypeID: AudioGraphNodeTypeID,
    underlyingError: any Error
  ) {
    self.nodeID = nodeID
    self.nodeTypeID = nodeTypeID
    self.underlyingError = underlyingError
  }

  /// A concise explanation that identifies the failing node value.
  public var errorDescription: String? {
    "Node '\(nodeTypeID.rawValue)' (\(nodeID.rawValue.uuidString)) could not resolve its descriptor: \(underlyingError.localizedDescription)"
  }
}

/// A graph mutation that could not be applied safely.
public enum AudioGraphMutationError: AudioGraphContextualError, LocalizedError,
  @unchecked Sendable
{
  /// A node instance already uses the supplied identity.
  case duplicateNodeID(AudioGraphNodeID)

  /// A connection instance already uses the supplied identity.
  case duplicateConnectionID(AudioGraphConnectionID)

  /// The requested node does not exist.
  case missingNode(AudioGraphNodeID)

  /// The requested connection does not exist.
  case missingConnection(AudioGraphConnectionID)

  /// Configuration for a different node definition cannot replace an existing node.
  case nodeTypeMismatch(
    nodeID: AudioGraphNodeID,
    expected: AudioGraphNodeTypeID,
    actual: AudioGraphNodeTypeID
  )

  /// Updated node configuration made an existing connection invalid.
  case nodeUpdateInvalidatedConnection(AudioGraphConnectionID, AudioGraphConnectionFailure)

  /// A node package threw while resolving its configured semantic descriptor.
  case nodeDescriptorFailed(AudioGraphNodeDescriptorFailure)

  /// A node's resolved semantic descriptor is malformed.
  case invalidNodeDefinition(AudioGraphNodeDefinitionFailure)

  /// A configured construction bound was exceeded.
  case resourceLimitExceeded(AudioGraphResource, limit: Int)

  /// A requested connection was denied by the shared evaluator.
  case connectionDenied(AudioGraphConnectionFailure)

  /// The graph contains validation errors and cannot become a snapshot.
  case validationFailed(AudioGraphValidationReport)

  /// A localized explanation of the failed mutation.
  public var errorDescription: String? {
    switch self {
    case .duplicateNodeID(let nodeID):
      return "The graph already contains node \(nodeID.rawValue.uuidString)."
    case .duplicateConnectionID(let connectionID):
      return "The graph already contains connection \(connectionID.rawValue.uuidString)."
    case .missingNode(let nodeID):
      return "Graph node \(nodeID.rawValue.uuidString) does not exist."
    case .missingConnection(let connectionID):
      return "Graph connection \(connectionID.rawValue.uuidString) does not exist."
    case .nodeTypeMismatch(let nodeID, let expected, let actual):
      return
        "Node \(nodeID.rawValue.uuidString) has type '\(expected.rawValue)' and cannot accept configuration for '\(actual.rawValue)'."
    case .nodeUpdateInvalidatedConnection(let connectionID, let failure):
      return
        "Updating the node invalidated connection \(connectionID.rawValue.uuidString): \(failure.errorDescription ?? "invalid connection")"
    case .nodeDescriptorFailed(let failure):
      return failure.errorDescription
    case .invalidNodeDefinition(let failure):
      return failure.errorDescription
    case .resourceLimitExceeded(let resource, let limit):
      return "The graph exceeds the configured \(resource.rawValue) limit of \(limit)."
    case .connectionDenied(let failure):
      return failure.errorDescription
    case .validationFailed(let report):
      return report.diagnostics.first?.message
        ?? "The graph contains validation errors and cannot be prepared."
    }
  }

  /// A practical next step suitable for developer tools and workflow UI.
  public var recoverySuggestion: String? {
    switch self {
    case .duplicateNodeID:
      "Generate a new node identity or update the existing node."
    case .duplicateConnectionID:
      "Generate a new connection identity or update the existing connection."
    case .missingNode, .missingConnection:
      "Refresh the workflow topology before applying this stale mutation."
    case .nodeTypeMismatch:
      "Remove and replace the node when changing its package-defined type."
    case .nodeUpdateInvalidatedConnection(_, let failure), .connectionDenied(let failure):
      failure.recoverySuggestion
    case .nodeDescriptorFailed:
      "Inspect underlyingError for the node package's typed recovery information."
    case .invalidNodeDefinition:
      "Correct the node package's descriptor before inserting this node."
    case .resourceLimitExceeded:
      "Reduce the graph or raise the checked construction limit explicitly."
    case .validationFailed:
      "Use the report's node and connection identities to correct every diagnostic."
    }
  }

  /// Node instances directly implicated by this failure.
  public var nodeIDs: [AudioGraphNodeID] {
    switch self {
    case .duplicateNodeID(let nodeID), .missingNode(let nodeID):
      [nodeID]
    case .nodeTypeMismatch(let nodeID, _, _):
      [nodeID]
    case .nodeUpdateInvalidatedConnection(_, let failure), .connectionDenied(let failure):
      failure.nodeIDs
    case .nodeDescriptorFailed(let failure):
      [failure.nodeID]
    case .invalidNodeDefinition(let failure):
      [failure.nodeID]
    case .validationFailed(let report):
      Array(Set(report.diagnostics.flatMap(\.nodeIDs))).sorted(by: audioGraphNodeIDLessThan)
    case .duplicateConnectionID, .missingConnection, .resourceLimitExceeded:
      []
    }
  }

  /// Connection instances directly implicated by this failure.
  public var connectionIDs: [AudioGraphConnectionID] {
    switch self {
    case .duplicateConnectionID(let connectionID), .missingConnection(let connectionID),
      .nodeUpdateInvalidatedConnection(let connectionID, _):
      [connectionID]
    case .validationFailed(let report):
      Array(Set(report.diagnostics.flatMap(\.connectionIDs))).sorted(
        by: audioGraphConnectionIDLessThan
      )
    default:
      []
    }
  }

  /// Port addresses directly implicated by this failure.
  public var portAddresses: [AudioGraphPortAddress] {
    switch self {
    case .nodeUpdateInvalidatedConnection(_, let failure), .connectionDenied(let failure):
      failure.portAddresses
    case .invalidNodeDefinition(let failure):
      failure.issue.portID.map {
        [AudioGraphPortAddress(nodeID: failure.nodeID, portID: $0)]
      } ?? []
    default:
      []
    }
  }

  /// The original concrete node-package error when descriptor resolution failed.
  public var underlyingError: (any Error)? {
    guard case .nodeDescriptorFailed(let failure) = self else { return nil }
    return failure.underlyingError
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
      throw AudioGraphMutationError.invalidNodeDefinition(
        AudioGraphNodeDefinitionFailure(
          nodeID: id,
          nodeTypeID: Node.typeID,
          issue: .emptyNodeTypeID
        )
      )
    }
    let descriptor: AudioGraphNodeDescriptor
    do {
      descriptor = try node.makeDescriptor()
    } catch {
      throw AudioGraphMutationError.nodeDescriptorFailed(
        AudioGraphNodeDescriptorFailure(
          nodeID: id,
          nodeTypeID: Node.typeID,
          underlyingError: error
        )
      )
    }
    try validate(descriptor: descriptor, nodeID: id, nodeTypeID: Node.typeID)

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
        nodeID: nodeID,
        expected: existingNode.typeID,
        actual: Node.typeID
      )
    }
    let descriptor: AudioGraphNodeDescriptor
    do {
      descriptor = try node.makeDescriptor()
    } catch {
      throw AudioGraphMutationError.nodeDescriptorFailed(
        AudioGraphNodeDescriptorFailure(
          nodeID: nodeID,
          nodeTypeID: Node.typeID,
          underlyingError: error
        )
      )
    }
    try validate(
      descriptor: descriptor,
      nodeID: nodeID,
      nodeTypeID: Node.typeID
    )

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
      case .denied(let failure):
        throw AudioGraphMutationError.nodeUpdateInvalidatedConnection(connection.id, failure)
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
    func denied(_ issue: AudioGraphConnectionIssue) -> AudioGraphConnectionDecision {
      .denied(
        AudioGraphConnectionFailure(
          source: source,
          target: target,
          issue: issue
        )
      )
    }

    guard let sourceNode = node(id: source.nodeID) else {
      return denied(.missingSourceNode(source.nodeID))
    }
    guard let targetNode = node(id: target.nodeID) else {
      return denied(.missingTargetNode(target.nodeID))
    }
    guard let sourcePort = sourceNode.port(source.portID) else {
      return denied(.missingSourcePort(source))
    }
    guard let targetPort = targetNode.port(target.portID) else {
      return denied(.missingTargetPort(target))
    }
    guard sourcePort.direction == .output else {
      return denied(.sourceIsNotOutput(source))
    }
    guard targetPort.direction == .input else {
      return denied(.targetIsNotInput(target))
    }
    let endpoints = AudioGraphConnectionEndpoints(source: source, target: target)
    guard
      connectionIDsByEndpoint[endpoints] == nil
        || connectionIDsByEndpoint[endpoints] == excludedConnectionID
    else {
      return denied(.duplicateEndpoints)
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
      return denied(.targetAlreadyConnected(target))
    }
    guard
      excludedConnectionID != nil
        || connectionStorage.count < configuration.limits.maximumConnectionCount
    else {
      return denied(
        .connectionLimitReached(configuration.limits.maximumConnectionCount)
      )
    }
    switch sourcePort.signalType.compatibility(with: targetPort.signalType) {
    case .compatible(let conversion):
      return .allowed(conversion: conversion)
    case .incompatible(let issue):
      return denied(.incompatibleSignals(issue))
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
    case .denied(let failure):
      throw AudioGraphMutationError.connectionDenied(failure)
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
  ///
  /// Unlike idempotent removal, changing a missing connection is reported as a mutation error so
  /// a workflow editor cannot silently apply an update to stale state.
  public mutating func setConnection(
    id: AudioGraphConnectionID,
    isEnabled: Bool
  ) throws {
    guard let index = connectionIndices[id] else {
      throw AudioGraphMutationError.missingConnection(id)
    }
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
      case .denied(let failure):
        throw AudioGraphMutationError.connectionDenied(failure)
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

  private func validate(
    descriptor: AudioGraphNodeDescriptor,
    nodeID: AudioGraphNodeID,
    nodeTypeID: AudioGraphNodeTypeID
  ) throws {
    guard descriptor.ports.count <= configuration.limits.maximumPortCountPerNode else {
      throw invalidDefinition(
        nodeID: nodeID,
        nodeTypeID: nodeTypeID,
        issue: .portLimitExceeded(
          actual: descriptor.ports.count,
          limit: configuration.limits.maximumPortCountPerNode
        )
      )
    }
    var portIDs = Set<AudioGraphPortID>()
    portIDs.reserveCapacity(descriptor.ports.count)
    for port in descriptor.ports {
      guard !port.id.rawValue.isEmpty else {
        throw invalidDefinition(
          nodeID: nodeID,
          nodeTypeID: nodeTypeID,
          issue: .emptyPortID
        )
      }
      guard portIDs.insert(port.id).inserted else {
        throw invalidDefinition(
          nodeID: nodeID,
          nodeTypeID: nodeTypeID,
          issue: .duplicatePortID(port.id)
        )
      }
      switch (port.direction, port.connectionPolicy) {
      case (.output, .fanOut), (.input, .singleInput), (.input, .mixingInput):
        break
      default:
        throw invalidDefinition(
          nodeID: nodeID,
          nodeTypeID: nodeTypeID,
          issue: .invalidPortConnectionPolicy(port.id)
        )
      }
      try validate(
        signalType: port.signalType,
        portID: port.id,
        nodeID: nodeID,
        nodeTypeID: nodeTypeID
      )
    }
  }

  private func validate(
    signalType: AudioGraphSignalType,
    portID: AudioGraphPortID,
    nodeID: AudioGraphNodeID,
    nodeTypeID: AudioGraphNodeTypeID
  ) throws {
    switch signalType {
    case .audio(let audio):
      if case .fixed(let count) = audio.channelCount, count <= 0 {
        throw invalidDefinition(
          nodeID: nodeID,
          nodeTypeID: nodeTypeID,
          issue: .invalidAudioSignalConstraint(portID)
        )
      }
      if case .fixed(let rate) = audio.sampleRate, !rate.isFinite || rate <= 0 {
        throw invalidDefinition(
          nodeID: nodeID,
          nodeTypeID: nodeTypeID,
          issue: .invalidAudioSignalConstraint(portID)
        )
      }
    case .category(let domain):
      if let domain, domain.rawValue.isEmpty {
        throw invalidDefinition(
          nodeID: nodeID,
          nodeTypeID: nodeTypeID,
          issue: .emptySemanticID(portID)
        )
      }
    case .structure(let structure):
      if structure.rawValue.isEmpty {
        throw invalidDefinition(
          nodeID: nodeID,
          nodeTypeID: nodeTypeID,
          issue: .emptySemanticID(portID)
        )
      }
    case .scalar:
      break
    }
  }

  private func invalidDefinition(
    nodeID: AudioGraphNodeID,
    nodeTypeID: AudioGraphNodeTypeID,
    issue: AudioGraphNodeDefinitionIssue
  ) -> AudioGraphMutationError {
    .invalidNodeDefinition(
      AudioGraphNodeDefinitionFailure(
        nodeID: nodeID,
        nodeTypeID: nodeTypeID,
        issue: issue
      )
    )
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
