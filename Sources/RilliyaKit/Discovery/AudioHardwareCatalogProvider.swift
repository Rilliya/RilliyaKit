// SPDX-License-Identifier: Apache-2.0

typealias HardwareObjectID = UInt32

protocol AudioHardwareCatalogProvider: Sendable {
  var currentProcessIdentifier: Int32 { get }

  func deviceObjectIDs() throws(AudioCatalogError) -> [HardwareObjectID]

  func processObjectIDs() throws(AudioCatalogError) -> [HardwareObjectID]

  func defaultDeviceObjectID(
    for direction: AudioDirection
  ) throws(AudioCatalogError) -> HardwareObjectID?

  func device(
    for objectID: HardwareObjectID
  ) throws(AudioCatalogError) -> HardwareDeviceDescription

  func process(
    for objectID: HardwareObjectID
  ) throws(AudioCatalogError) -> HardwareProcessDescription
}

struct HardwareProcessDescription: Hashable, Sendable {
  let processIdentifier: Int32
  let bundleIdentifier: String?
  let isRunning: Bool
  let isRunningInput: Bool
  let isRunningOutput: Bool
  let inputDeviceObjectIDs: [HardwareObjectID]
  let outputDeviceObjectIDs: [HardwareObjectID]
}

struct HardwareDeviceDescription: Hashable, Sendable {
  let uid: String
  let name: String
  let transportType: UInt32
  let nominalSampleRate: Double
  let isAlive: Bool
  let isRunning: Bool
  let input: HardwareDeviceEndpointDescription?
  let output: HardwareDeviceEndpointDescription?
}

struct HardwareDeviceEndpointDescription: Hashable, Sendable {
  let channelCount: Int
  let streams: [HardwareStreamDescription]
}

struct HardwareStreamDescription: Hashable, Sendable {
  let isActive: Bool
  let startingChannel: Int?
  let virtualFormat: AudioStreamFormat?
  let physicalFormat: AudioStreamFormat?

  var channelCount: Int {
    Int(virtualFormat?.channelsPerFrame ?? physicalFormat?.channelsPerFrame ?? 0)
  }
}
