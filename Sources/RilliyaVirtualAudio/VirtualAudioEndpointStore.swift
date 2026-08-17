// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import Foundation

/// The Rilliya Audio Server Plug-in's availability to the current Core Audio process.
public enum VirtualAudioDriverAvailability: Equatable, Sendable {
  /// Core Audio currently publishes the Rilliya plug-in.
  case available

  /// The plug-in is not installed or Core Audio has not loaded it yet.
  case notInstalled
}

/// A bounded operation performed by ``VirtualAudioEndpointStore``.
public enum VirtualAudioEndpointStoreOperation: String, Equatable, Sendable {
  /// Resolve the plug-in from its stable bundle identifier.
  case resolveDriver

  /// Read the current catalog from the plug-in.
  case readCatalog

  /// Publish a new catalog to the plug-in.
  case writeCatalog
}

/// A virtual-endpoint management failure suitable for application diagnostics.
public enum VirtualAudioEndpointStoreError: Error, Equatable, LocalizedError, Sendable {
  /// Core Audio does not currently publish the Rilliya Audio Server Plug-in.
  case driverNotInstalled

  /// The installed plug-in does not expose the expected catalog property.
  case catalogPropertyUnavailable

  /// The plug-in returned a catalog that does not match the public schema.
  case invalidDriverCatalog(String)

  /// The configured endpoint count exceeds the driver's fixed safety bound.
  case endpointLimitExceeded(maximum: Int)

  /// Core Audio rejected or failed an operation.
  case hardware(operation: VirtualAudioEndpointStoreOperation, status: Int32)

  /// A human-readable explanation suitable for application diagnostics.
  public var errorDescription: String? {
    switch self {
    case .driverNotInstalled:
      "The Rilliya virtual audio driver is not installed or has not been loaded by Core Audio."
    case .catalogPropertyUnavailable:
      "The installed Rilliya virtual audio driver does not expose endpoint management."
    case .invalidDriverCatalog(let reason):
      "The Rilliya virtual audio driver returned an invalid endpoint catalog: \(reason)"
    case .endpointLimitExceeded(let maximum):
      "The Rilliya virtual audio driver supports at most \(maximum) endpoints."
    case .hardware(let operation, let status):
      "Core Audio failed to \(operation.description) (OSStatus \(status))."
    }
  }
}

extension VirtualAudioEndpointStoreOperation {
  fileprivate var description: String {
    switch self {
    case .resolveDriver:
      "resolve the virtual audio driver"
    case .readCatalog:
      "read the virtual audio endpoint catalog"
    case .writeCatalog:
      "update the virtual audio endpoint catalog"
    }
  }
}

/// A serialized, transactional interface to the Rilliya Audio Server Plug-in catalog.
///
/// Every mutation first reads the driver's latest revision, applies one validated model mutation,
/// and then publishes the next revision. The driver rejects stale revisions and changes while a
/// published endpoint is running, so concurrent or unsafe updates fail instead of silently
/// replacing live device state.
public actor VirtualAudioEndpointStore {
  /// The bundle identifier of the clean-room driver this package is written against.
  ///
  /// A build of that driver published under a different identifier is reached by passing it to
  /// ``init(driverBundleIdentifier:)``.
  public static let driverBundleIdentifier =
    "moe.uwucocoa.rilliya.virtual-audio-driver"

  /// The maximum number of user-visible endpoints published by one driver instance.
  public static let maximumEndpointCount = 32

  private let driverBundleIdentifier: String
  private let propertyAccess: any VirtualAudioEndpointDriverPropertyAccess

  /// Creates a store for the virtual audio driver Core Audio publishes under
  /// `driverBundleIdentifier`.
  ///
  /// - Parameter driverBundleIdentifier: The driver to manage, defaulting to the identifier this
  ///   package is written against.
  public init(driverBundleIdentifier: String = VirtualAudioEndpointStore.driverBundleIdentifier) {
    self.driverBundleIdentifier = driverBundleIdentifier
    propertyAccess = SystemVirtualAudioEndpointDriverPropertyAccess()
  }

  init(
    driverBundleIdentifier: String = VirtualAudioEndpointStore.driverBundleIdentifier,
    propertyAccess: any VirtualAudioEndpointDriverPropertyAccess
  ) {
    self.driverBundleIdentifier = driverBundleIdentifier
    self.propertyAccess = propertyAccess
  }

  /// Reports whether Core Audio currently publishes the driver.
  public func availability() throws -> VirtualAudioDriverAvailability {
    try propertyAccess.resolvePlugIn(bundleIdentifier: driverBundleIdentifier) == nil
      ? .notInstalled : .available
  }

  /// Reads and validates the latest catalog from the driver.
  public func catalog() throws -> VirtualAudioEndpointCatalog {
    let plugInObjectID = try requirePlugIn()
    let data = try propertyAccess.readCatalog(plugInObjectID: plugInObjectID)
    return try VirtualAudioEndpointCatalogPropertyList.decode(data)
  }

  /// Creates and publishes one endpoint.
  @discardableResult
  public func create(
    _ configuration: VirtualAudioEndpointConfiguration,
    id: VirtualAudioEndpointID = VirtualAudioEndpointID()
  ) throws -> VirtualAudioEndpoint {
    var current = try catalog()
    guard current.endpoints.count < Self.maximumEndpointCount else {
      throw VirtualAudioEndpointStoreError.endpointLimitExceeded(
        maximum: Self.maximumEndpointCount
      )
    }
    let endpoint = try current.create(configuration, id: id)
    try publish(current)
    return endpoint
  }

  /// Updates and publishes one endpoint while preserving its stable identity.
  @discardableResult
  public func update(
    id: VirtualAudioEndpointID,
    configuration: VirtualAudioEndpointConfiguration
  ) throws -> VirtualAudioEndpoint {
    var current = try catalog()
    let endpoint = try current.update(id: id, configuration: configuration)
    try publish(current)
    return endpoint
  }

  /// Removes and returns one endpoint.
  @discardableResult
  public func remove(id: VirtualAudioEndpointID) throws -> VirtualAudioEndpoint {
    var current = try catalog()
    let endpoint = try current.remove(id: id)
    try publish(current)
    return endpoint
  }

  private func requirePlugIn() throws -> AudioObjectID {
    guard let objectID = try propertyAccess.resolvePlugIn(bundleIdentifier: driverBundleIdentifier)
    else {
      throw VirtualAudioEndpointStoreError.driverNotInstalled
    }
    return objectID
  }

  private func publish(_ catalog: VirtualAudioEndpointCatalog) throws {
    guard catalog.endpoints.count <= Self.maximumEndpointCount else {
      throw VirtualAudioEndpointStoreError.endpointLimitExceeded(
        maximum: Self.maximumEndpointCount
      )
    }
    let plugInObjectID = try requirePlugIn()
    let data = try VirtualAudioEndpointCatalogPropertyList.encode(catalog)
    try propertyAccess.writeCatalog(data, plugInObjectID: plugInObjectID)
  }
}

protocol VirtualAudioEndpointDriverPropertyAccess: Sendable {
  func resolvePlugIn(bundleIdentifier: String) throws -> AudioObjectID?
  func readCatalog(plugInObjectID: AudioObjectID) throws -> Data
  func writeCatalog(_ data: Data, plugInObjectID: AudioObjectID) throws
}

private struct SystemVirtualAudioEndpointDriverPropertyAccess:
  VirtualAudioEndpointDriverPropertyAccess
{
  private static let endpointCatalogSelector = AudioObjectPropertySelector(0x726C_6374)

  func resolvePlugIn(bundleIdentifier: String) throws -> AudioObjectID? {
    var address = propertyAddress(kAudioHardwarePropertyTranslateBundleIDToPlugIn)
    var qualifier = bundleIdentifier as CFString
    var objectID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.stride)
    let status = withUnsafePointer(to: &qualifier) { pointer in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        UInt32(MemoryLayout<CFString>.stride),
        pointer,
        &size,
        &objectID
      )
    }
    try check(status, operation: .resolveDriver)
    guard size == MemoryLayout<AudioObjectID>.stride else {
      throw VirtualAudioEndpointStoreError.invalidDriverCatalog(
        "Core Audio returned an invalid plug-in identifier size"
      )
    }
    return objectID == kAudioObjectUnknown ? nil : objectID
  }

  func readCatalog(plugInObjectID: AudioObjectID) throws -> Data {
    var address = propertyAddress(Self.endpointCatalogSelector)
    guard AudioObjectHasProperty(plugInObjectID, &address) else {
      throw VirtualAudioEndpointStoreError.catalogPropertyUnavailable
    }
    var size: UInt32 = 0
    try check(
      AudioObjectGetPropertyDataSize(plugInObjectID, &address, 0, nil, &size),
      operation: .readCatalog
    )
    guard size == MemoryLayout<CFPropertyList?>.stride else {
      throw VirtualAudioEndpointStoreError.invalidDriverCatalog(
        "the catalog property has an invalid byte count"
      )
    }
    var propertyList: CFPropertyList?
    let status = withUnsafeMutablePointer(to: &propertyList) { pointer in
      AudioObjectGetPropertyData(plugInObjectID, &address, 0, nil, &size, pointer)
    }
    try check(status, operation: .readCatalog)
    guard size == MemoryLayout<CFPropertyList?>.stride, let propertyList else {
      throw VirtualAudioEndpointStoreError.invalidDriverCatalog(
        "the catalog property is empty"
      )
    }
    do {
      return try PropertyListSerialization.data(
        fromPropertyList: propertyList,
        format: .binary,
        options: 0
      )
    } catch {
      throw VirtualAudioEndpointStoreError.invalidDriverCatalog(
        "the catalog property is not serializable"
      )
    }
  }

  func writeCatalog(_ data: Data, plugInObjectID: AudioObjectID) throws {
    var address = propertyAddress(Self.endpointCatalogSelector)
    guard AudioObjectHasProperty(plugInObjectID, &address) else {
      throw VirtualAudioEndpointStoreError.catalogPropertyUnavailable
    }
    let propertyList: Any
    do {
      propertyList = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      )
    } catch {
      throw VirtualAudioEndpointStoreError.invalidDriverCatalog(
        "the encoded catalog cannot be deserialized"
      )
    }
    var value: CFPropertyList? = propertyList as CFPropertyList
    let status = withUnsafePointer(to: &value) { pointer in
      AudioObjectSetPropertyData(
        plugInObjectID,
        &address,
        0,
        nil,
        UInt32(MemoryLayout<CFPropertyList?>.stride),
        pointer
      )
    }
    try check(status, operation: .writeCatalog)
  }

  private func check(
    _ status: OSStatus,
    operation: VirtualAudioEndpointStoreOperation
  ) throws {
    guard status == noErr else {
      throw VirtualAudioEndpointStoreError.hardware(operation: operation, status: status)
    }
  }

  private func propertyAddress(
    _ selector: AudioObjectPropertySelector
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
  }
}

private enum VirtualAudioEndpointCatalogPropertyList {
  static let schemaVersion = 1

  static func encode(_ catalog: VirtualAudioEndpointCatalog) throws -> Data {
    guard catalog.revision <= VirtualAudioEndpointCatalog.maximumRevision else {
      throw VirtualAudioEndpointCatalogError.revisionOutOfRange(catalog.revision)
    }
    let value = Catalog(
      schemaVersion: schemaVersion,
      revision: Int64(catalog.revision),
      endpoints: catalog.endpoints.map(Endpoint.init)
    )
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    return try encoder.encode(value)
  }

  static func decode(_ data: Data) throws -> VirtualAudioEndpointCatalog {
    let value: Catalog
    do {
      value = try PropertyListDecoder().decode(Catalog.self, from: data)
    } catch {
      throw VirtualAudioEndpointStoreError.invalidDriverCatalog("the schema cannot be decoded")
    }
    guard value.schemaVersion == schemaVersion else {
      throw VirtualAudioEndpointStoreError.invalidDriverCatalog(
        "schema version \(value.schemaVersion) is unsupported"
      )
    }
    guard value.revision >= 0 else {
      throw VirtualAudioEndpointStoreError.invalidDriverCatalog("the revision is negative")
    }
    do {
      return try VirtualAudioEndpointCatalog(
        revision: UInt64(value.revision),
        endpoints: try value.endpoints.map { try $0.endpoint() }
      )
    } catch {
      throw VirtualAudioEndpointStoreError.invalidDriverCatalog(String(describing: error))
    }
  }

  private struct Catalog: Codable {
    let schemaVersion: Int
    let revision: Int64
    let endpoints: [Endpoint]
  }

  private struct Endpoint: Codable {
    let id: String
    let name: String
    let direction: String
    let sampleRate: Double
    let channelCount: Int

    init(_ endpoint: VirtualAudioEndpoint) {
      id = endpoint.id.rawValue.uuidString
      name = endpoint.configuration.name
      direction = endpoint.configuration.direction.rawValue
      sampleRate = endpoint.configuration.format.sampleRate
      channelCount = endpoint.configuration.format.channelCount
    }

    func endpoint() throws -> VirtualAudioEndpoint {
      guard let identifier = UUID(uuidString: id) else {
        throw VirtualAudioEndpointStoreError.invalidDriverCatalog(
          "endpoint identifier \(id) is not a UUID"
        )
      }
      guard let direction = VirtualAudioEndpointDirection(rawValue: direction) else {
        throw VirtualAudioEndpointStoreError.invalidDriverCatalog(
          "endpoint direction \(direction) is unsupported"
        )
      }
      return VirtualAudioEndpoint(
        id: VirtualAudioEndpointID(rawValue: identifier),
        configuration: try VirtualAudioEndpointConfiguration(
          name: name,
          direction: direction,
          format: VirtualAudioEndpointFormat(
            sampleRate: sampleRate,
            channelCount: channelCount
          )
        )
      )
    }
  }
}
