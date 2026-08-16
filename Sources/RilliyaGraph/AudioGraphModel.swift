// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One directed connection between an output port and an input port.
public struct AudioGraphConnection: Identifiable, Sendable {
  /// The stable identity of this connection.
  public let id: AudioGraphConnectionID

  /// The upstream output port.
  public let source: AudioGraphPortAddress

  /// The downstream input port.
  public let target: AudioGraphPortAddress

  /// A lossless conversion selected while the connection was validated.
  public let implicitConversion: AudioGraphImplicitConversion?

  /// Whether the connection participates in rendering and input capacity.
  public let isEnabled: Bool

}

/// Safe resource bounds used while constructing and validating a graph.
public struct AudioGraphLimits: Hashable, Sendable {
  /// The standard limits used when a consumer does not supply custom bounds.
  public static let standard = AudioGraphLimits(
    validatedMaximumNodeCount: 2_048,
    maximumConnectionCount: 8_192,
    maximumPortCountPerNode: 256,
    maximumDiagnosticCount: 256
  )

  /// The maximum number of node instances.
  public let maximumNodeCount: Int

  /// The maximum number of connections, including disabled connections.
  public let maximumConnectionCount: Int

  /// The maximum number of semantic ports exposed by one node.
  public let maximumPortCountPerNode: Int

  /// The maximum number of diagnostics retained in one validation report.
  public let maximumDiagnosticCount: Int

  /// Creates checked graph resource limits.
  public init(
    maximumNodeCount: Int = 2_048,
    maximumConnectionCount: Int = 8_192,
    maximumPortCountPerNode: Int = 256,
    maximumDiagnosticCount: Int = 256
  ) throws {
    guard maximumNodeCount > 0 else {
      throw AudioGraphLimitConfigurationError.invalidMaximumNodeCount(maximumNodeCount)
    }
    guard maximumConnectionCount >= 0 else {
      throw AudioGraphLimitConfigurationError.invalidMaximumConnectionCount(
        maximumConnectionCount
      )
    }
    guard maximumPortCountPerNode >= 0 else {
      throw AudioGraphLimitConfigurationError.invalidMaximumPortCount(
        maximumPortCountPerNode
      )
    }
    guard maximumDiagnosticCount > 0 else {
      throw AudioGraphLimitConfigurationError.invalidMaximumDiagnosticCount(
        maximumDiagnosticCount
      )
    }
    self.init(
      validatedMaximumNodeCount: maximumNodeCount,
      maximumConnectionCount: maximumConnectionCount,
      maximumPortCountPerNode: maximumPortCountPerNode,
      maximumDiagnosticCount: maximumDiagnosticCount
    )
  }

  private init(
    validatedMaximumNodeCount maximumNodeCount: Int,
    maximumConnectionCount: Int,
    maximumPortCountPerNode: Int,
    maximumDiagnosticCount: Int
  ) {
    self.maximumNodeCount = maximumNodeCount
    self.maximumConnectionCount = maximumConnectionCount
    self.maximumPortCountPerNode = maximumPortCountPerNode
    self.maximumDiagnosticCount = maximumDiagnosticCount
  }
}

/// An invalid graph-limit configuration.
public enum AudioGraphLimitConfigurationError: Error, Equatable, LocalizedError, Sendable {
  /// The node bound must be positive.
  case invalidMaximumNodeCount(Int)

  /// The connection bound cannot be negative.
  case invalidMaximumConnectionCount(Int)

  /// The per-node port bound cannot be negative.
  case invalidMaximumPortCount(Int)

  /// The diagnostic bound must be positive.
  case invalidMaximumDiagnosticCount(Int)

  /// A localized explanation of the invalid limit.
  public var errorDescription: String? {
    switch self {
    case .invalidMaximumNodeCount(let value):
      return "The graph node limit must be positive; received \(value)."
    case .invalidMaximumConnectionCount(let value):
      return "The graph connection limit cannot be negative; received \(value)."
    case .invalidMaximumPortCount(let value):
      return "The per-node port limit cannot be negative; received \(value)."
    case .invalidMaximumDiagnosticCount(let value):
      return "The graph diagnostic limit must be positive; received \(value)."
    }
  }
}

/// Construction and validation policy for one graph.
public struct AudioGraphConfiguration: Hashable, Sendable {
  /// Resource limits enforced by this graph.
  public let limits: AudioGraphLimits

  /// Creates graph policy with safe standard limits.
  public init(limits: AudioGraphLimits = .standard) {
    self.limits = limits
  }
}

/// An immutable, validated graph ready for a preparation or compilation phase.
public struct AudioGraphSnapshot: Sendable {
  /// Nodes in stable insertion order.
  public let nodes: [AudioGraphNodeInstance]

  /// Connections in stable insertion order.
  public let connections: [AudioGraphConnection]

  /// The policy used to validate this snapshot.
  public let configuration: AudioGraphConfiguration

  private let nodesByID: [AudioGraphNodeID: AudioGraphNodeInstance]

  init(
    nodes: [AudioGraphNodeInstance],
    connections: [AudioGraphConnection],
    configuration: AudioGraphConfiguration
  ) {
    self.nodes = nodes
    self.connections = connections
    self.configuration = configuration
    nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
  }

  /// Returns one node by stable identity.
  public func node(id: AudioGraphNodeID) -> AudioGraphNodeInstance? {
    nodesByID[id]
  }
}
