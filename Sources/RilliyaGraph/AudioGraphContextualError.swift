// SPDX-License-Identifier: Apache-2.0

/// Structured graph context that a host can use for diagnostics, selection, and recovery UI.
///
/// Human-readable descriptions are useful for logs, but workflow editors should prefer these
/// stable identities when highlighting the part of a graph that needs attention. Concrete errors
/// may also retain a node package's original typed error through `underlyingError`.
public protocol AudioGraphContextualError: Error {
  /// Node instances directly implicated by the failure.
  var nodeIDs: [AudioGraphNodeID] { get }

  /// Connections directly implicated by the failure.
  var connectionIDs: [AudioGraphConnectionID] { get }

  /// Port addresses directly implicated by the failure.
  var portAddresses: [AudioGraphPortAddress] { get }

  /// The original node-package error when one exists.
  var underlyingError: (any Error)? { get }
}

extension AudioGraphContextualError {
  /// The default for failures that do not identify a connection.
  public var connectionIDs: [AudioGraphConnectionID] { [] }

  /// The default for failures that do not identify a port.
  public var portAddresses: [AudioGraphPortAddress] { [] }

  /// The default for failures that do not wrap another error.
  public var underlyingError: (any Error)? { nil }
}
