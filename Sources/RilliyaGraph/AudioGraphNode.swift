// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The direction in which a graph port carries a signal.
public enum AudioGraphPortDirection: String, Hashable, Codable, Sendable {
  /// A signal enters the node through this port.
  case input

  /// A signal leaves the node through this port.
  case output
}

/// The connection behavior supported by one graph port.
public enum AudioGraphPortConnectionPolicy: String, Hashable, Codable, Sendable {
  /// One output may feed multiple downstream inputs.
  case fanOut

  /// One input accepts at most one enabled upstream connection.
  case singleInput

  /// One input accepts multiple enabled upstream connections that the node combines explicitly.
  case mixingInput
}

/// The same-render dependency behavior used while validating graph cycles.
public enum AudioGraphCycleBehavior: String, Hashable, Codable, Sendable {
  /// Current output depends on current input, so the node participates in cycle detection.
  case combinational

  /// Current output comes from stored state, so outgoing edges break same-render dependency cycles.
  case breaksCycle
}

/// The semantic definition of one graph port.
public struct AudioGraphPortDescriptor: Hashable, Codable, Sendable {
  /// The stable node-local identity of the port.
  public let id: AudioGraphPortID

  /// Whether the signal enters or leaves the node.
  public let direction: AudioGraphPortDirection

  /// The value carried by the port.
  public let signalType: AudioGraphSignalType

  /// The number and meaning of connections accepted by the port.
  public let connectionPolicy: AudioGraphPortConnectionPolicy

  /// Creates a semantic port descriptor.
  public init(
    id: AudioGraphPortID,
    direction: AudioGraphPortDirection,
    signalType: AudioGraphSignalType,
    connectionPolicy: AudioGraphPortConnectionPolicy
  ) {
    self.id = id
    self.direction = direction
    self.signalType = signalType
    self.connectionPolicy = connectionPolicy
  }

  /// Creates an input port with single-source or explicit mixing behavior.
  public static func input(
    _ id: AudioGraphPortID,
    signal: AudioGraphSignalType,
    connectionPolicy: AudioGraphPortConnectionPolicy = .singleInput
  ) -> AudioGraphPortDescriptor {
    AudioGraphPortDescriptor(
      id: id,
      direction: .input,
      signalType: signal,
      connectionPolicy: connectionPolicy
    )
  }

  /// Creates a fan-out output port.
  public static func output(
    _ id: AudioGraphPortID,
    signal: AudioGraphSignalType
  ) -> AudioGraphPortDescriptor {
    AudioGraphPortDescriptor(
      id: id,
      direction: .output,
      signalType: signal,
      connectionPolicy: .fanOut
    )
  }
}

/// The resolved semantic shape of one node instance.
public struct AudioGraphNodeDescriptor: Hashable, Codable, Sendable {
  /// Ports in the node author's stable semantic order.
  public let ports: [AudioGraphPortDescriptor]

  /// Whether this node breaks a same-render dependency cycle.
  public let cycleBehavior: AudioGraphCycleBehavior

  /// Creates a node descriptor.
  public init(
    ports: [AudioGraphPortDescriptor],
    cycleBehavior: AudioGraphCycleBehavior = .combinational
  ) {
    self.ports = ports
    self.cycleBehavior = cycleBehavior
  }
}

/// A node-specific collection of named ports exposed through a typed node handle.
///
/// A node package normally defines a small value with one `AudioGraphPortID` property per named
/// port. The handle returned by `AudioGraph.add(_:)` forwards those names, so a consumer can write
/// `source.audio` or `analyzer.input`. Dynamic ports can still use `handle.port(_:)` directly.
public protocol AudioGraphNodePorts: Sendable {}

/// An empty named-port collection for nodes that expose only dynamic ports or no ports.
public struct EmptyAudioGraphNodePorts: AudioGraphNodePorts, Hashable, Codable, Sendable {
  /// Creates an empty named-port collection.
  public init() {}
}

/// A trusted node value supplied by RilliyaKit or a package consumer.
///
/// Configuration belongs in the conforming value, with ordinary Swift defaults and validation.
/// The graph retains that value for a later preparation phase. Node implementations are trusted
/// compile-time code; this protocol is not an untrusted binary plug-in boundary.
public protocol AudioGraphNode: Sendable {
  /// The named ports made available on the handle returned from `AudioGraph.add(_:)`.
  associatedtype Ports: AudioGraphNodePorts = EmptyAudioGraphNodePorts

  /// A globally namespaced identity that remains stable across compatible releases.
  static var typeID: AudioGraphNodeTypeID { get }

  /// Stable named port identities for this node type.
  static var ports: Ports { get }

  /// Resolves ports and same-render cycle behavior for this configured node value.
  func makeDescriptor() throws -> AudioGraphNodeDescriptor
}

extension AudioGraphNode where Ports == EmptyAudioGraphNodePorts {
  /// The default empty named-port collection.
  public static var ports: EmptyAudioGraphNodePorts { EmptyAudioGraphNodePorts() }
}

/// One resolved node instance stored in a graph snapshot.
public struct AudioGraphNodeInstance: Identifiable, Sendable {
  /// The stable identity of this node instance.
  public let id: AudioGraphNodeID

  /// The stable identity of the node definition.
  public let typeID: AudioGraphNodeTypeID

  /// The resolved ports and cycle behavior.
  public let descriptor: AudioGraphNodeDescriptor

  /// The configured node value retained for runtime preparation or inspection.
  public let value: any AudioGraphNode

  private let portsByID: [AudioGraphPortID: AudioGraphPortDescriptor]

  init(
    id: AudioGraphNodeID,
    typeID: AudioGraphNodeTypeID,
    descriptor: AudioGraphNodeDescriptor,
    value: any AudioGraphNode
  ) {
    self.id = id
    self.typeID = typeID
    self.descriptor = descriptor
    self.value = value
    portsByID = Dictionary(uniqueKeysWithValues: descriptor.ports.map { ($0.id, $0) })
  }

  /// Returns the configured node value when the requested type matches this instance.
  public func value<Node: AudioGraphNode>(
    as type: Node.Type = Node.self
  ) -> Node? {
    value as? Node
  }

  /// Returns the descriptor for one semantic port identity.
  public func port(_ portID: AudioGraphPortID) -> AudioGraphPortDescriptor? {
    portsByID[portID]
  }
}
