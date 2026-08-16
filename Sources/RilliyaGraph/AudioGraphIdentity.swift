// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A stable identity for one node instance in an audio graph.
public struct AudioGraphNodeID: Hashable, RawRepresentable, Codable, Sendable {
  /// The UUID stored by this identity.
  public let rawValue: UUID

  /// Creates an identity from a persisted UUID.
  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }

  /// Creates a fresh node identity.
  public init() {
    rawValue = UUID()
  }
}

/// A stable identity for one connection instance in an audio graph.
public struct AudioGraphConnectionID: Hashable, RawRepresentable, Codable, Sendable {
  /// The UUID stored by this identity.
  public let rawValue: UUID

  /// Creates an identity from a persisted UUID.
  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }

  /// Creates a fresh connection identity.
  public init() {
    rawValue = UUID()
  }
}

/// A stable, developer-defined identity for one kind of node.
public struct AudioGraphNodeTypeID: Hashable, RawRepresentable, Codable, Sendable {
  /// The reverse-DNS or similarly namespaced identifier supplied by a node author.
  public let rawValue: String

  /// Creates a node-type identity.
  ///
  /// Empty identities are rejected when a node is inserted into a graph.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// A stable, node-local identity for one input or output port.
public struct AudioGraphPortID: Hashable, RawRepresentable, Codable, Sendable {
  /// The semantic identifier supplied by the node author.
  public let rawValue: String

  /// Creates a port identity.
  ///
  /// Empty identities are rejected when a node is inserted into a graph.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// A stable identity for a category signal's vocabulary.
public struct AudioGraphCategoryDomainID: Hashable, RawRepresentable, Codable, Sendable {
  /// The namespaced domain identifier.
  public let rawValue: String

  /// Creates a category-domain identity.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// A stable identity for a nominal structured signal schema.
public struct AudioGraphStructureID: Hashable, RawRepresentable, Codable, Sendable {
  /// The namespaced schema identifier.
  public let rawValue: String

  /// Creates a structure identity.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// A stable identity for one field in a structured signal.
public struct AudioGraphFieldID: Hashable, RawRepresentable, Codable, Sendable {
  /// The schema-local field identifier.
  public let rawValue: String

  /// Creates a field identity.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// A stable path to a nested field in a structured signal.
public struct AudioGraphFieldPath: Hashable, Codable, Sendable {
  /// Field identities ordered from the outer structure to the selected field.
  public let components: [AudioGraphFieldID]

  /// Creates a field path.
  ///
  /// Empty components are permitted for the structure root. Empty field identifiers are rejected
  /// when the path is used by a node definition.
  public init(_ components: [AudioGraphFieldID]) {
    self.components = components
  }
}

/// The stable address of one port on one node.
public struct AudioGraphPortAddress: Hashable, Codable, Sendable {
  /// The node that owns the port.
  public let nodeID: AudioGraphNodeID

  /// The node-local port identity.
  public let portID: AudioGraphPortID

  /// Creates a port address.
  public init(nodeID: AudioGraphNodeID, portID: AudioGraphPortID) {
    self.nodeID = nodeID
    self.portID = portID
  }
}

/// A lightweight typed reference returned when a node is inserted into a graph.
@dynamicMemberLookup
public struct AudioGraphNodeHandle<Node: AudioGraphNode>: Hashable, Sendable {
  /// The stable identity of the inserted node.
  public let id: AudioGraphNodeID

  /// Returns a stable address for one named port declared by the node type.
  public subscript(
    dynamicMember keyPath: KeyPath<Node.Ports, AudioGraphPortID>
  ) -> AudioGraphPortAddress {
    port(Node.ports[keyPath: keyPath])
  }

  /// Returns a stable address for one of this node's semantic ports.
  public func port(_ portID: AudioGraphPortID) -> AudioGraphPortAddress {
    AudioGraphPortAddress(nodeID: id, portID: portID)
  }
}
