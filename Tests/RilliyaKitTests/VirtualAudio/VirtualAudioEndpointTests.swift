import Foundation
import Testing

@testable import RilliyaVirtualAudio

struct VirtualAudioEndpointTests {
  @Test
  func configurationNormalizesAndValidatesNames() throws {
    let configuration = try VirtualAudioEndpointConfiguration(
      name: "  Remote Microphone  ",
      direction: .input
    )

    #expect(configuration.name == "Remote Microphone")
    #expect(configuration.format == .stereo48kHz)
    #expect(throws: VirtualAudioEndpointValidationError.emptyName) {
      try VirtualAudioEndpointConfiguration(name: " \n ", direction: .input)
    }
    #expect(throws: VirtualAudioEndpointValidationError.nameContainsControlCharacter) {
      try VirtualAudioEndpointConfiguration(name: "Remote\u{0000}Mic", direction: .input)
    }
  }

  @Test
  func formatDecoderCannotBypassValidation() throws {
    let data = Data(#"{"sampleRate":0,"channelCount":2}"#.utf8)

    #expect(throws: VirtualAudioEndpointValidationError.invalidSampleRate(0)) {
      try JSONDecoder().decode(VirtualAudioEndpointFormat.self, from: data)
    }
  }

  @Test
  func catalogMutationsAdvanceRevisionAndPreserveIdentity() throws {
    var catalog = VirtualAudioEndpointCatalog.empty
    let id = VirtualAudioEndpointID(
      rawValue: try #require(UUID(uuidString: "78F06182-D964-4933-901E-B8D75F6067DB"))
    )
    let created = try catalog.create(
      VirtualAudioEndpointConfiguration(name: "Remote Microphone", direction: .input),
      id: id
    )

    #expect(catalog.revision == 1)
    #expect(created.id == id)
    let updated = try catalog.update(
      id: id,
      configuration: VirtualAudioEndpointConfiguration(
        name: "Studio Microphone",
        direction: .input,
        format: VirtualAudioEndpointFormat(sampleRate: 48_000, channelCount: 1)
      )
    )
    #expect(catalog.revision == 2)
    #expect(updated.id == id)
    #expect(updated.configuration.name == "Studio Microphone")
    #expect(try catalog.remove(id: id) == updated)
    #expect(catalog.revision == 3)
    #expect(catalog.endpoints.isEmpty)
  }

  @Test
  func catalogRejectsAmbiguousNamesAndDuplicateIdentities() throws {
    var catalog = VirtualAudioEndpointCatalog.empty
    let firstID = VirtualAudioEndpointID()
    let firstConfiguration = try VirtualAudioEndpointConfiguration(
      name: "Café Input",
      direction: .input
    )
    _ = try catalog.create(firstConfiguration, id: firstID)

    #expect(throws: VirtualAudioEndpointCatalogError.duplicateName("Cafe\u{301} Input")) {
      try catalog.create(
        VirtualAudioEndpointConfiguration(name: "Cafe\u{301} Input", direction: .output)
      )
    }
    #expect(throws: VirtualAudioEndpointCatalogError.duplicateIdentity(firstID)) {
      try catalog.create(
        VirtualAudioEndpointConfiguration(name: "Different Name", direction: .output),
        id: firstID
      )
    }
  }

  @Test
  func catalogDecoderRejectsDuplicateNames() throws {
    let firstID = VirtualAudioEndpointID()
    let secondID = VirtualAudioEndpointID()
    let data = Data(
      """
      {
        "revision": 7,
        "endpoints": [
          {
            "id": { "rawValue": "\(firstID.rawValue.uuidString)" },
            "configuration": {
              "name": "Shared Output",
              "direction": "output",
              "format": { "sampleRate": 48000, "channelCount": 2 }
            }
          },
          {
            "id": { "rawValue": "\(secondID.rawValue.uuidString)" },
            "configuration": {
              "name": "shared output",
              "direction": "input",
              "format": { "sampleRate": 48000, "channelCount": 2 }
            }
          }
        ]
      }
      """.utf8
    )

    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(VirtualAudioEndpointCatalog.self, from: data)
    }
  }

  @Test
  func exhaustedRevisionLeavesCatalogUnchanged() throws {
    let endpoint = VirtualAudioEndpoint(
      configuration: try VirtualAudioEndpointConfiguration(
        name: "Stable Input",
        direction: .input
      )
    )
    var catalog = try VirtualAudioEndpointCatalog(
      revision: .max,
      endpoints: [endpoint]
    )

    #expect(throws: VirtualAudioEndpointCatalogError.revisionExhausted) {
      try catalog.update(
        id: endpoint.id,
        configuration: VirtualAudioEndpointConfiguration(
          name: "Changed Input",
          direction: .input
        )
      )
    }
    #expect(catalog.revision == .max)
    #expect(catalog.endpoints == [endpoint])
  }

  @Test
  func catalogRoundTripsWithoutChangingStableReferences() throws {
    var catalog = VirtualAudioEndpointCatalog.empty
    let endpoint = try catalog.create(
      VirtualAudioEndpointConfiguration(name: "Broadcast Feed", direction: .output)
    )

    let encoded = try JSONEncoder().encode(catalog)
    let decoded = try JSONDecoder().decode(VirtualAudioEndpointCatalog.self, from: encoded)

    #expect(decoded == catalog)
    #expect(decoded.endpoint(id: endpoint.id) == endpoint)
  }
}
