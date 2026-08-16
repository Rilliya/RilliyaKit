// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A revisioned, persistent collection of globally managed virtual audio endpoints.
///
/// The value contains no HAL object identifiers and can be encoded directly into application
/// state. Mutations preserve deterministic ordering and reject ambiguous names before a driver is
/// asked to change its published device list.
public struct VirtualAudioEndpointCatalog: Codable, Equatable, Sendable {
  /// An empty initial catalog.
  public static let empty = VirtualAudioEndpointCatalog()

  /// The monotonically increasing catalog revision.
  public private(set) var revision: UInt64

  /// Endpoints in stable creation order.
  public private(set) var endpoints: [VirtualAudioEndpoint]

  /// Creates a catalog after validating every identity and name.
  public init(
    revision: UInt64 = 0,
    endpoints: [VirtualAudioEndpoint] = []
  ) throws {
    try Self.validate(endpoints)
    self.revision = revision
    self.endpoints = endpoints
  }

  private init() {
    revision = 0
    endpoints = []
  }

  /// Looks up one endpoint by its persistent identity.
  public func endpoint(id: VirtualAudioEndpointID) -> VirtualAudioEndpoint? {
    endpoints.first { $0.id == id }
  }

  /// Adds a newly configured endpoint and advances the revision.
  @discardableResult
  public mutating func create(
    _ configuration: VirtualAudioEndpointConfiguration,
    id: VirtualAudioEndpointID = VirtualAudioEndpointID()
  ) throws -> VirtualAudioEndpoint {
    guard endpoint(id: id) == nil else {
      throw VirtualAudioEndpointCatalogError.duplicateIdentity(id)
    }
    try ensureUniqueName(configuration.name, excluding: nil)
    let nextRevision = try nextRevision()
    let endpoint = VirtualAudioEndpoint(id: id, configuration: configuration)
    endpoints.append(endpoint)
    revision = nextRevision
    return endpoint
  }

  /// Replaces an endpoint's user-controlled configuration and advances the revision.
  @discardableResult
  public mutating func update(
    id: VirtualAudioEndpointID,
    configuration: VirtualAudioEndpointConfiguration
  ) throws -> VirtualAudioEndpoint {
    guard let index = endpoints.firstIndex(where: { $0.id == id }) else {
      throw VirtualAudioEndpointCatalogError.endpointNotFound(id)
    }
    try ensureUniqueName(configuration.name, excluding: id)
    let nextRevision = try nextRevision()
    let endpoint = VirtualAudioEndpoint(id: id, configuration: configuration)
    endpoints[index] = endpoint
    revision = nextRevision
    return endpoint
  }

  /// Removes one endpoint and advances the revision.
  ///
  /// Applications should check workflow references before calling this operation. The catalog does
  /// not know about any host application's workflow model.
  @discardableResult
  public mutating func remove(id: VirtualAudioEndpointID) throws -> VirtualAudioEndpoint {
    guard let index = endpoints.firstIndex(where: { $0.id == id }) else {
      throw VirtualAudioEndpointCatalogError.endpointNotFound(id)
    }
    let nextRevision = try nextRevision()
    let removed = endpoints.remove(at: index)
    revision = nextRevision
    return removed
  }

  private func nextRevision() throws -> UInt64 {
    let result = revision.addingReportingOverflow(1)
    guard !result.overflow else {
      throw VirtualAudioEndpointCatalogError.revisionExhausted
    }
    return result.partialValue
  }

  private func ensureUniqueName(
    _ name: String,
    excluding excludedID: VirtualAudioEndpointID?
  ) throws {
    let key = Self.nameKey(name)
    guard
      !endpoints.contains(where: { endpoint in
        endpoint.id != excludedID && Self.nameKey(endpoint.configuration.name) == key
      })
    else {
      throw VirtualAudioEndpointCatalogError.duplicateName(name)
    }
  }

  private static func validate(_ endpoints: [VirtualAudioEndpoint]) throws {
    var identities = Set<VirtualAudioEndpointID>()
    var names = Set<String>()
    for endpoint in endpoints {
      guard identities.insert(endpoint.id).inserted else {
        throw VirtualAudioEndpointCatalogError.duplicateIdentity(endpoint.id)
      }
      guard names.insert(nameKey(endpoint.configuration.name)).inserted else {
        throw VirtualAudioEndpointCatalogError.duplicateName(endpoint.configuration.name)
      }
    }
  }

  private static func nameKey(_ name: String) -> String {
    name.precomposedStringWithCanonicalMapping.lowercased()
  }

  private enum CodingKeys: String, CodingKey {
    case revision
    case endpoints
  }

  /// Decodes a persisted catalog and rejects duplicate identities or names.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      revision: container.decode(UInt64.self, forKey: .revision),
      endpoints: container.decode([VirtualAudioEndpoint].self, forKey: .endpoints)
    )
  }
}

/// A deterministic global-catalog mutation failure.
public enum VirtualAudioEndpointCatalogError: Error, Equatable, LocalizedError, Sendable {
  /// The catalog already contains the stable identity.
  case duplicateIdentity(VirtualAudioEndpointID)

  /// The catalog already contains the case-insensitive, canonically equivalent name.
  case duplicateName(String)

  /// No endpoint has the requested stable identity.
  case endpointNotFound(VirtualAudioEndpointID)

  /// The monotonic revision cannot be advanced safely.
  case revisionExhausted

  /// A human-readable explanation suitable for application diagnostics.
  public var errorDescription: String? {
    switch self {
    case .duplicateIdentity(let id):
      "Virtual audio endpoint \(id.rawValue.uuidString) already exists."
    case .duplicateName(let name):
      "A virtual audio endpoint named “\(name)” already exists."
    case .endpointNotFound(let id):
      "Virtual audio endpoint \(id.rawValue.uuidString) does not exist."
    case .revisionExhausted:
      "The virtual audio endpoint catalog revision cannot be advanced."
    }
  }
}
