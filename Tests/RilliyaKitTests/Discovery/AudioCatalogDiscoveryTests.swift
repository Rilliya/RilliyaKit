// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RilliyaKit

@Suite("AudioCatalogDiscovery")
struct AudioCatalogDiscoveryTests {
  @Test("Filters invalid entries and sorts devices and processes")
  func filtersAndSortsCatalog() throws {
    let brokenDeviceError = hardwareError(property: .deviceIdentifier)
    let provider = FakeAudioHardwareProvider(
      currentProcessIdentifier: 999,
      deviceObjectIDsResult: .value([30, 20, 10, 40]),
      processObjectIDsResult: .value([5, 4, 3, 2, 1]),
      defaultDevices: [.input: .value(10), .output: .value(20)],
      devices: [
        10: .value(
          device(
            uid: "duplex",
            name: "Beta Interface",
            inputChannels: 2,
            outputChannels: 2
          )
        ),
        20: .value(device(uid: "speaker", name: "Alpha Speaker", outputChannels: 2)),
        30: .value(device(uid: "clock", name: "Clock Only")),
        40: .failure(brokenDeviceError),
      ],
      processes: [
        1: .value(process(pid: 100, bundleID: nil)),
        2: .value(process(pid: 200, bundleID: "b.input", input: true, inputDevices: [10])),
        3: .value(
          process(pid: 300, bundleID: "z.output", output: true, outputDevices: [20, 20, 99])
        ),
        4: .value(process(pid: 0, bundleID: "invalid")),
        5: .value(process(pid: 999, bundleID: "self", output: true)),
      ]
    )
    let snapshot = try AudioCatalogDiscovery(provider: provider).snapshot()

    #expect(snapshot.devices.map(\.id.rawValue) == ["speaker", "duplex"])
    #expect(snapshot.inputDevices.map(\.id.rawValue) == ["duplex"])
    #expect(snapshot.outputDevices.map(\.id.rawValue) == ["speaker", "duplex"])
    #expect(snapshot.processes.map(\.id.rawValue) == [300, 200, 100])
    #expect(snapshot.processes[0].outputDeviceIDs.map(\.rawValue) == ["speaker"])
    #expect(snapshot.processes[1].inputDeviceIDs.map(\.rawValue) == ["duplex"])
    #expect(snapshot.processes[2].bundleIdentifier == nil)
    #expect(snapshot.issues == [AudioCatalogIssue(error: brokenDeviceError)])
  }

  @Test("Builds explicit stream and channel identities")
  func buildsStreamAndChannelIdentities() throws {
    let stereoFormat = format(channels: 2, sampleRate: 48_000)
    let monoFormat = format(channels: 1, sampleRate: 48_000)
    let endpoint = HardwareDeviceEndpointDescription(
      channelCount: 3,
      streams: [
        HardwareStreamDescription(
          isActive: true,
          startingChannel: 1,
          virtualFormat: stereoFormat,
          physicalFormat: stereoFormat
        ),
        HardwareStreamDescription(
          isActive: false,
          startingChannel: 3,
          virtualFormat: monoFormat,
          physicalFormat: nil
        ),
      ]
    )
    let provider = FakeAudioHardwareProvider(
      currentProcessIdentifier: 999,
      deviceObjectIDsResult: .value([10]),
      processObjectIDsResult: .value([]),
      defaultDevices: [.input: .value(10), .output: .value(nil)],
      devices: [
        10: .value(
          HardwareDeviceDescription(
            uid: "three-channel-input",
            name: "Three Channel Input",
            transportType: 7,
            nominalSampleRate: 48_000,
            isAlive: true,
            isRunning: true,
            input: endpoint,
            output: nil
          )
        )
      ],
      processes: [:]
    )
    let snapshot = try AudioCatalogDiscovery(provider: provider).snapshot()
    let device = try #require(snapshot.devices.first)
    let input = try #require(device.input)

    #expect(device.nominalSampleRate == 48_000)
    #expect(device.isRunning)
    #expect(input.isDefault)
    #expect(input.channelCount == 3)
    #expect(input.streams.map(\.isActive) == [true, false])
    #expect(input.streams.map(\.virtualFormat?.channelsPerFrame) == [2, 1])
    #expect(input.channels.map(\.id.index.rawValue) == [0, 1, 2])
    #expect(input.channels.map(\.streamID?.index.rawValue) == [0, 0, 1])
    #expect(input.channels.map(\.streamChannelIndex?.rawValue) == [0, 1, 0])
    #expect(
      input.channels.allSatisfy { channel in
        channel.id.ownerID == .source(.deviceInput(device.id))
      })
  }

  @Test("Uses persistent device identity for duplicate HAL objects")
  func deduplicatesDeviceIdentity() throws {
    let provider = FakeAudioHardwareProvider(
      currentProcessIdentifier: 999,
      deviceObjectIDsResult: .value([10, 11]),
      processObjectIDsResult: .value([1]),
      defaultDevices: [.input: .value(nil), .output: .value(11)],
      devices: [
        10: .value(device(uid: "shared", name: "First Metadata", outputChannels: 2)),
        11: .value(device(uid: "shared", name: "Later Metadata", outputChannels: 2)),
      ],
      processes: [
        1: .value(process(pid: 100, bundleID: "example", outputDevices: [11]))
      ]
    )
    let snapshot = try AudioCatalogDiscovery(provider: provider).snapshot()

    #expect(snapshot.devices.count == 1)
    #expect(snapshot.devices.first?.name == "First Metadata")
    #expect(snapshot.outputDevices.first?.output?.isDefault == true)
    #expect(snapshot.processes.first?.outputDeviceIDs.map(\.rawValue) == ["shared"])
  }

  @Test("Reports a default-device failure without discarding the catalog")
  func reportsDefaultDeviceFailure() throws {
    let defaultError = hardwareError(property: .defaultInputDevice)
    let provider = FakeAudioHardwareProvider(
      currentProcessIdentifier: 999,
      deviceObjectIDsResult: .value([10]),
      processObjectIDsResult: .value([]),
      defaultDevices: [.input: .failure(defaultError), .output: .value(nil)],
      devices: [10: .value(device(uid: "input", name: "Input", inputChannels: 1))],
      processes: [:]
    )
    let snapshot = try AudioCatalogDiscovery(provider: provider).snapshot()

    #expect(snapshot.inputDevices.count == 1)
    #expect(snapshot.inputDevices.first?.input?.isDefault == false)
    #expect(snapshot.issues == [AudioCatalogIssue(error: defaultError)])
  }

  @Test("Throws a typed error when the root device list fails")
  func throwsRootListFailure() {
    let rootError = hardwareError(property: .devices)
    let provider = FakeAudioHardwareProvider(
      currentProcessIdentifier: 999,
      deviceObjectIDsResult: .failure(rootError),
      processObjectIDsResult: .value([]),
      defaultDevices: [.input: .value(nil), .output: .value(nil)],
      devices: [:],
      processes: [:]
    )

    #expect(throws: rootError) {
      try AudioCatalogDiscovery(provider: provider).snapshot()
    }
  }

  @Test("Publishes an initial catalog snapshot")
  func publishesInitialSnapshot() async throws {
    let provider = FakeAudioHardwareProvider(
      currentProcessIdentifier: 999,
      deviceObjectIDsResult: .value([10]),
      processObjectIDsResult: .value([]),
      defaultDevices: [.input: .value(10), .output: .value(nil)],
      devices: [10: .value(device(uid: "input", name: "Input", inputChannels: 1))],
      processes: [:]
    )
    let updates = AudioCatalogDiscovery(provider: provider).updates(pollingEvery: .seconds(60))
    var iterator = updates.makeAsyncIterator()

    let snapshot = try await iterator.next()

    #expect(snapshot?.inputDevices.map(\.id.rawValue) == ["input"])
  }

  @Test("Publishes event-driven changes and suppresses equal snapshots")
  func publishesEventDrivenChanges() async throws {
    let provider = MutableAudioHardwareProvider(deviceName: "Initial")
    let changeSource = ManualAudioCatalogChangeSource()
    let updates = AudioCatalogDiscovery(
      provider: provider,
      changeSource: changeSource
    ).updates()
    var iterator = updates.makeAsyncIterator()

    let initial = try await iterator.next()
    provider.setDeviceName("Updated")
    changeSource.send()
    let updated = try await iterator.next()
    changeSource.send()
    changeSource.finish()
    let duplicate = try await iterator.next()

    #expect(initial?.devices.first?.name == "Initial")
    #expect(updated?.devices.first?.name == "Updated")
    #expect(duplicate == nil)
  }
}

private final class ManualAudioCatalogChangeSource: AudioCatalogChangeSource, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncStream<Void>.Continuation?

  func changes() -> AsyncStream<Void> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      lock.withLock {
        self.continuation = continuation
      }
      continuation.onTermination = { [weak self] _ in
        self?.lock.withLock {
          self?.continuation = nil
        }
      }
    }
  }

  func send() {
    lock.withLock { continuation }?.yield(())
  }

  func finish() {
    let continuation = lock.withLock { () -> AsyncStream<Void>.Continuation? in
      defer { self.continuation = nil }
      return self.continuation
    }
    continuation?.finish()
  }
}

private final class MutableAudioHardwareProvider: AudioHardwareCatalogProvider, @unchecked Sendable
{
  let currentProcessIdentifier: Int32 = 999

  private let lock = NSLock()
  private var deviceName: String

  init(deviceName: String) {
    self.deviceName = deviceName
  }

  func setDeviceName(_ name: String) {
    lock.withLock {
      deviceName = name
    }
  }

  func deviceObjectIDs() throws(AudioCatalogError) -> [HardwareObjectID] {
    [10]
  }

  func processObjectIDs() throws(AudioCatalogError) -> [HardwareObjectID] {
    []
  }

  func defaultDeviceObjectID(
    for direction: AudioDirection
  ) throws(AudioCatalogError) -> HardwareObjectID? {
    direction == .input ? 10 : nil
  }

  func device(
    for objectID: HardwareObjectID
  ) throws(AudioCatalogError) -> HardwareDeviceDescription {
    guard objectID == 10 else {
      throw missingDataError(objectKind: .device, property: .deviceIdentifier)
    }
    return lock.withLock {
      HardwareDeviceDescription(
        uid: "mutable-input",
        name: deviceName,
        transportType: 0,
        nominalSampleRate: 48_000,
        isAlive: true,
        isRunning: false,
        input: endpoint(channelCount: 1),
        output: nil
      )
    }
  }

  func process(
    for objectID: HardwareObjectID
  ) throws(AudioCatalogError) -> HardwareProcessDescription {
    throw missingDataError(objectKind: .process, property: .processIdentifier)
  }
}

private enum FakeResult<Value: Sendable>: Sendable {
  case value(Value)
  case failure(AudioCatalogError)

  func get() throws(AudioCatalogError) -> Value {
    switch self {
    case .value(let value):
      return value
    case .failure(let error):
      throw error
    }
  }
}

private struct FakeAudioHardwareProvider: AudioHardwareCatalogProvider {
  let currentProcessIdentifier: Int32
  let deviceObjectIDsResult: FakeResult<[HardwareObjectID]>
  let processObjectIDsResult: FakeResult<[HardwareObjectID]>
  let defaultDevices: [AudioDirection: FakeResult<HardwareObjectID?>]
  let devices: [HardwareObjectID: FakeResult<HardwareDeviceDescription>]
  let processes: [HardwareObjectID: FakeResult<HardwareProcessDescription>]

  func deviceObjectIDs() throws(AudioCatalogError) -> [HardwareObjectID] {
    try deviceObjectIDsResult.get()
  }

  func processObjectIDs() throws(AudioCatalogError) -> [HardwareObjectID] {
    try processObjectIDsResult.get()
  }

  func defaultDeviceObjectID(
    for direction: AudioDirection
  ) throws(AudioCatalogError) -> HardwareObjectID? {
    try defaultDevices[direction, default: .value(nil)].get()
  }

  func device(
    for objectID: HardwareObjectID
  ) throws(AudioCatalogError) -> HardwareDeviceDescription {
    guard let result = devices[objectID] else {
      throw missingDataError(objectKind: .device, property: .deviceIdentifier)
    }
    return try result.get()
  }

  func process(
    for objectID: HardwareObjectID
  ) throws(AudioCatalogError) -> HardwareProcessDescription {
    guard let result = processes[objectID] else {
      throw missingDataError(objectKind: .process, property: .processIdentifier)
    }
    return try result.get()
  }
}

private func device(
  uid: String,
  name: String,
  inputChannels: Int = 0,
  outputChannels: Int = 0
) -> HardwareDeviceDescription {
  HardwareDeviceDescription(
    uid: uid,
    name: name,
    transportType: 0,
    nominalSampleRate: 48_000,
    isAlive: true,
    isRunning: false,
    input: endpoint(channelCount: inputChannels),
    output: endpoint(channelCount: outputChannels)
  )
}

private func endpoint(channelCount: Int) -> HardwareDeviceEndpointDescription? {
  guard channelCount > 0 else { return nil }
  return HardwareDeviceEndpointDescription(
    channelCount: channelCount,
    streams: [
      HardwareStreamDescription(
        isActive: false,
        startingChannel: 1,
        virtualFormat: format(channels: UInt32(channelCount), sampleRate: 48_000),
        physicalFormat: nil
      )
    ]
  )
}

private func process(
  pid: Int32,
  bundleID: String?,
  running: Bool = false,
  input: Bool = false,
  output: Bool = false,
  inputDevices: [HardwareObjectID] = [],
  outputDevices: [HardwareObjectID] = []
) -> HardwareProcessDescription {
  HardwareProcessDescription(
    processIdentifier: pid,
    bundleIdentifier: bundleID,
    isRunning: running || input || output,
    isRunningInput: input,
    isRunningOutput: output,
    inputDeviceObjectIDs: inputDevices,
    outputDeviceObjectIDs: outputDevices
  )
}

private func format(channels: UInt32, sampleRate: Double) -> AudioStreamFormat {
  AudioStreamFormat(
    sampleRate: sampleRate,
    formatID: 0x6C70_636D,
    formatFlags: 1,
    bytesPerPacket: 4 * channels,
    framesPerPacket: 1,
    bytesPerFrame: 4 * channels,
    channelsPerFrame: channels,
    bitsPerChannel: 32
  )
}

private func hardwareError(property: AudioHardwareProperty) -> AudioCatalogError {
  .hardware(
    AudioHardwareError(
      objectKind: property == .devices ? .system : .device,
      property: property,
      operation: .readProperty,
      status: AudioHardwareStatus(rawValue: -50)
    )
  )
}

private func missingDataError(
  objectKind: AudioHardwareObjectKind,
  property: AudioHardwareProperty
) -> AudioCatalogError {
  .invalidData(
    AudioHardwareDataError(
      objectKind: objectKind,
      property: property,
      reason: "the fake provider has no entry"
    )
  )
}
