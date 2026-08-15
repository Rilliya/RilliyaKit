// SPDX-License-Identifier: Apache-2.0

import RilliyaCore
import Testing

@Suite("Audio identities")
struct AudioIdentityTests {
  @Test("Process identities require positive identifiers", arguments: [-1, 0])
  func rejectsInvalidProcessIdentifiers(rawValue: Int32) {
    #expect(AudioProcessID(rawValue: rawValue) == nil)
  }

  @Test("Device identities preserve opaque Core Audio UIDs")
  func preservesDeviceIdentifiers() throws {
    let id = try #require(AudioDeviceID(rawValue: "device:BuiltIn/0"))

    #expect(id.rawValue == "device:BuiltIn/0")
    #expect(AudioDeviceID(rawValue: "") == nil)
  }

  @Test("Stream indices reject negative values")
  func validatesStreamIndices() {
    #expect(AudioStreamIndex(rawValue: -1) == nil)
    #expect(AudioStreamIndex(rawValue: 0)?.rawValue == 0)
  }

  @Test("Channel identity includes its routing endpoint")
  func channelIdentityIncludesOwner() throws {
    let deviceID = try #require(AudioDeviceID(rawValue: "input-device"))
    let index = try #require(AudioChannelIndex(rawValue: 0))
    let sourceChannel = AudioChannelID(
      ownerID: .source(.deviceInput(deviceID)),
      index: index
    )
    let destinationChannel = AudioChannelID(
      ownerID: .destination(.deviceOutput(deviceID)),
      index: index
    )

    #expect(sourceChannel != destinationChannel)
  }
}
