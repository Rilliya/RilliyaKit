// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A stable validation diagnostic code suitable for tests and tooling.
public enum AudioGraphDiagnosticCode: String, Hashable, Codable, Sendable {
  /// At least one same-render dependency cycle exists.
  case cycle

  /// Additional diagnostics were discarded at the configured report bound.
  case diagnosticsTruncated
}

/// One deterministic graph validation diagnostic.
public struct AudioGraphDiagnostic: Equatable, Sendable {
  /// The machine-readable diagnostic category.
  public let code: AudioGraphDiagnosticCode

  /// Nodes directly involved in this diagnostic, sorted by stable identity.
  public let nodeIDs: [AudioGraphNodeID]

  /// Connections directly involved in this diagnostic, sorted by stable identity.
  public let connectionIDs: [AudioGraphConnectionID]

  /// A concise human-readable explanation.
  public let message: String

  /// Creates one validation diagnostic.
  public init(
    code: AudioGraphDiagnosticCode,
    nodeIDs: [AudioGraphNodeID] = [],
    connectionIDs: [AudioGraphConnectionID] = [],
    message: String
  ) {
    self.code = code
    self.nodeIDs = nodeIDs
    self.connectionIDs = connectionIDs
    self.message = message
  }
}

/// The bounded result of validating a complete graph.
public struct AudioGraphValidationReport: Equatable, Sendable {
  /// Diagnostics in deterministic order.
  public let diagnostics: [AudioGraphDiagnostic]

  /// Whether the graph can be prepared safely.
  public var isValid: Bool { diagnostics.isEmpty }

  /// Creates a validation report.
  public init(diagnostics: [AudioGraphDiagnostic]) {
    self.diagnostics = diagnostics
  }
}

enum AudioGraphValidator {
  static func validate(
    nodes: [AudioGraphNodeInstance],
    connections: [AudioGraphConnection],
    configuration: AudioGraphConfiguration
  ) -> AudioGraphValidationReport {
    let cycleComponents = stronglyConnectedCycleComponents(
      nodes: nodes,
      connections: connections
    )
    let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    var diagnostics = cycleComponents.map { component in
      let componentNodeIDs = Set(component)
      let connectionIDs = connections.compactMap { connection -> AudioGraphConnectionID? in
        guard connection.isEnabled,
          componentNodeIDs.contains(connection.source.nodeID),
          componentNodeIDs.contains(connection.target.nodeID),
          nodesByID[connection.source.nodeID]?.descriptor.cycleBehavior != .breaksCycle
        else { return nil }
        return connection.id
      }.sorted(by: audioGraphConnectionIDLessThan)
      return AudioGraphDiagnostic(
        code: .cycle,
        nodeIDs: component,
        connectionIDs: connectionIDs,
        message:
          "The graph contains a same-render dependency cycle. Insert an explicit state-breaking node such as a delay."
      )
    }
    let maximumCount = configuration.limits.maximumDiagnosticCount
    if diagnostics.count > maximumCount {
      diagnostics = Array(diagnostics.prefix(maximumCount - 1))
      diagnostics.append(
        AudioGraphDiagnostic(
          code: .diagnosticsTruncated,
          message: "Additional graph diagnostics were discarded at the configured report bound."
        )
      )
    }
    return AudioGraphValidationReport(diagnostics: diagnostics)
  }

  private static func stronglyConnectedCycleComponents(
    nodes: [AudioGraphNodeInstance],
    connections: [AudioGraphConnection]
  ) -> [[AudioGraphNodeID]] {
    let nodeByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    let sortedNodeIDs = nodes.map(\.id).sorted(by: lessThan)
    var adjacency = Dictionary(
      uniqueKeysWithValues: sortedNodeIDs.map { ($0, [AudioGraphNodeID]()) }
    )
    var reverseAdjacency = adjacency
    var selfLoops = Set<AudioGraphNodeID>()

    for connection in connections where connection.isEnabled {
      guard let sourceNode = nodeByID[connection.source.nodeID],
        nodeByID[connection.target.nodeID] != nil,
        sourceNode.descriptor.cycleBehavior != .breaksCycle
      else {
        continue
      }
      adjacency[connection.source.nodeID, default: []].append(connection.target.nodeID)
      reverseAdjacency[connection.target.nodeID, default: []].append(connection.source.nodeID)
      if connection.source.nodeID == connection.target.nodeID {
        selfLoops.insert(connection.source.nodeID)
      }
    }
    for nodeID in sortedNodeIDs {
      adjacency[nodeID]?.sort(by: lessThan)
      reverseAdjacency[nodeID]?.sort(by: lessThan)
    }

    let finishOrder = iterativeFinishOrder(nodes: sortedNodeIDs, adjacency: adjacency)
    var assigned = Set<AudioGraphNodeID>()
    var cycleComponents: [[AudioGraphNodeID]] = []
    for root in finishOrder.reversed() where !assigned.contains(root) {
      var component: [AudioGraphNodeID] = []
      var stack = [root]
      assigned.insert(root)
      while let nodeID = stack.popLast() {
        component.append(nodeID)
        for neighbor in reverseAdjacency[nodeID, default: []].reversed()
        where !assigned.contains(neighbor) {
          assigned.insert(neighbor)
          stack.append(neighbor)
        }
      }
      component.sort(by: lessThan)
      if component.count > 1 || component.first.map(selfLoops.contains) == true {
        cycleComponents.append(component)
      }
    }
    cycleComponents.sort {
      guard let left = $0.first, let right = $1.first else { return $0.count < $1.count }
      return lessThan(left, right)
    }
    return cycleComponents
  }

  private struct VisitFrame {
    let nodeID: AudioGraphNodeID
    var nextNeighborIndex: Int
  }

  private static func iterativeFinishOrder(
    nodes: [AudioGraphNodeID],
    adjacency: [AudioGraphNodeID: [AudioGraphNodeID]]
  ) -> [AudioGraphNodeID] {
    var visited = Set<AudioGraphNodeID>()
    var finishOrder: [AudioGraphNodeID] = []
    finishOrder.reserveCapacity(nodes.count)

    for root in nodes where !visited.contains(root) {
      visited.insert(root)
      var stack = [VisitFrame(nodeID: root, nextNeighborIndex: 0)]
      while var frame = stack.popLast() {
        let neighbors = adjacency[frame.nodeID, default: []]
        if frame.nextNeighborIndex < neighbors.count {
          let neighbor = neighbors[frame.nextNeighborIndex]
          frame.nextNeighborIndex += 1
          stack.append(frame)
          if visited.insert(neighbor).inserted {
            stack.append(VisitFrame(nodeID: neighbor, nextNeighborIndex: 0))
          }
        } else {
          finishOrder.append(frame.nodeID)
        }
      }
    }
    return finishOrder
  }

  private static func lessThan(_ left: AudioGraphNodeID, _ right: AudioGraphNodeID) -> Bool {
    audioGraphNodeIDLessThan(left, right)
  }
}
