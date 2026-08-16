import CoreAudio
import Foundation
import Testing

@testable import RilliyaVirtualAudio

struct VirtualAudioEndpointStoreTests {
  @Test
  func reportsMissingDriverWithoutReadingProperties() async throws {
    let access = FakeVirtualAudioEndpointDriverPropertyAccess(
      plugInObjectID: nil,
      catalogData: try catalogData(revision: 0, endpoints: [])
    )
    let store = VirtualAudioEndpointStore(propertyAccess: access)

    #expect(try await store.availability() == .notInstalled)
    await #expect(throws: VirtualAudioEndpointStoreError.driverNotInstalled) {
      try await store.catalog()
    }
    #expect(access.readCount == 0)
  }

  @Test
  func mutationsReadLatestRevisionAndPublishValidatedCatalogs() async throws {
    let access = FakeVirtualAudioEndpointDriverPropertyAccess(
      catalogData: try catalogData(revision: 0, endpoints: [])
    )
    let store = VirtualAudioEndpointStore(propertyAccess: access)
    let identifier = VirtualAudioEndpointID(
      rawValue: try #require(UUID(uuidString: "C568307C-1C22-4F49-8E65-C70CC9C40948"))
    )

    let created = try await store.create(
      VirtualAudioEndpointConfiguration(name: "Remote Microphone", direction: .input),
      id: identifier
    )
    #expect(created.id == identifier)
    #expect(try await store.catalog().revision == 1)

    let updated = try await store.update(
      id: identifier,
      configuration: VirtualAudioEndpointConfiguration(
        name: "Remote Voice",
        direction: .input,
        format: VirtualAudioEndpointFormat(sampleRate: 96_000, channelCount: 1)
      )
    )
    #expect(updated.configuration.name == "Remote Voice")
    #expect(try await store.catalog().revision == 2)

    #expect(try await store.remove(id: identifier) == updated)
    let finalCatalog = try await store.catalog()
    #expect(finalCatalog.revision == 3)
    #expect(finalCatalog.endpoints.isEmpty)
    #expect(access.writeCount == 3)
  }

  @Test
  func rejectsCreationBeyondTheDriverBoundWithoutWriting() async throws {
    let endpoints = (0..<VirtualAudioEndpointStore.maximumEndpointCount).map { index in
      endpointDictionary(
        id: UUID(),
        name: "Endpoint \(index)",
        direction: index.isMultiple(of: 2) ? .input : .output
      )
    }
    let access = FakeVirtualAudioEndpointDriverPropertyAccess(
      catalogData: try catalogData(revision: 42, endpoints: endpoints)
    )
    let store = VirtualAudioEndpointStore(propertyAccess: access)

    await #expect(
      throws: VirtualAudioEndpointStoreError.endpointLimitExceeded(
        maximum: VirtualAudioEndpointStore.maximumEndpointCount
      )
    ) {
      try await store.create(
        VirtualAudioEndpointConfiguration(name: "One Too Many", direction: .input)
      )
    }
    #expect(access.writeCount == 0)
  }

  @Test
  func surfacesMalformedDriverCatalogs() async throws {
    let access = FakeVirtualAudioEndpointDriverPropertyAccess(
      catalogData: try catalogData(revision: 0, endpoints: [], schemaVersion: 99)
    )
    let store = VirtualAudioEndpointStore(propertyAccess: access)

    await #expect(throws: (any Error).self) {
      try await store.catalog()
    }
  }

  private func catalogData(
    revision: Int64,
    endpoints: [[String: Any]],
    schemaVersion: Int = 1
  ) throws -> Data {
    try PropertyListSerialization.data(
      fromPropertyList: [
        "schemaVersion": schemaVersion,
        "revision": revision,
        "endpoints": endpoints,
      ],
      format: .binary,
      options: 0
    )
  }

  private func endpointDictionary(
    id: UUID,
    name: String,
    direction: VirtualAudioEndpointDirection
  ) -> [String: Any] {
    [
      "id": id.uuidString,
      "name": name,
      "direction": direction.rawValue,
      "sampleRate": 48_000.0,
      "channelCount": 2,
    ]
  }
}

private final class FakeVirtualAudioEndpointDriverPropertyAccess:
  VirtualAudioEndpointDriverPropertyAccess, @unchecked Sendable
{
  private let lock = NSLock()
  private let plugInObjectID: AudioObjectID?
  private var storedCatalogData: Data
  private var storedReadCount = 0
  private var storedWriteCount = 0

  init(
    plugInObjectID: AudioObjectID? = 91,
    catalogData: Data
  ) {
    self.plugInObjectID = plugInObjectID
    storedCatalogData = catalogData
  }

  var readCount: Int { lock.withLock { storedReadCount } }
  var writeCount: Int { lock.withLock { storedWriteCount } }

  func resolvePlugIn(bundleIdentifier: String) throws -> AudioObjectID? {
    #expect(bundleIdentifier == VirtualAudioEndpointStore.driverBundleIdentifier)
    return plugInObjectID
  }

  func readCatalog(plugInObjectID: AudioObjectID) throws -> Data {
    #expect(plugInObjectID == self.plugInObjectID)
    return lock.withLock {
      storedReadCount += 1
      return storedCatalogData
    }
  }

  func writeCatalog(_ data: Data, plugInObjectID: AudioObjectID) throws {
    #expect(plugInObjectID == self.plugInObjectID)
    lock.withLock {
      storedWriteCount += 1
      storedCatalogData = data
    }
  }
}
