// SPDX-License-Identifier: Apache-2.0

import Foundation

struct AudioCatalogBuilder: Sendable {
  let provider: any AudioHardwareCatalogProvider

  func snapshot() throws(AudioCatalogError) -> AudioCatalogSnapshot {
    var issues: [AudioCatalogIssue] = []
    let defaultInput = readDefaultDevice(for: .input, issues: &issues)
    let defaultOutput = readDefaultDevice(for: .output, issues: &issues)
    let deviceObjectIDs = try provider.deviceObjectIDs()
    var deviceIDByObjectID: [HardwareObjectID: AudioDeviceID] = [:]
    var devicesByID: [AudioDeviceID: AudioDevice] = [:]

    for objectID in deviceObjectIDs {
      do {
        let (deviceID, device) = try loadDevice(
          for: objectID,
          defaultInput: defaultInput,
          defaultOutput: defaultOutput
        )
        if let retainedDevice = devicesByID[deviceID] {
          deviceIDByObjectID[objectID] = deviceID
          devicesByID[deviceID] = mergingDefaultFlags(
            of: retainedDevice,
            with: device
          )
          continue
        }
        guard device.input != nil || device.output != nil else { continue }
        deviceIDByObjectID[objectID] = deviceID
        devicesByID[deviceID] = device
      } catch {
        issues.append(AudioCatalogIssue(error: error))
      }
    }

    let processes = try makeProcesses(
      deviceIDByObjectID: deviceIDByObjectID,
      issues: &issues
    )
    let devices = devicesByID.values.sorted(by: compareDevices)
    return AudioCatalogSnapshot(processes: processes, devices: devices, issues: issues)
  }

  private func readDefaultDevice(
    for direction: AudioDirection,
    issues: inout [AudioCatalogIssue]
  ) -> HardwareObjectID? {
    do {
      return try provider.defaultDeviceObjectID(for: direction)
    } catch {
      issues.append(AudioCatalogIssue(error: error))
      return nil
    }
  }

  private func makeProcesses(
    deviceIDByObjectID: [HardwareObjectID: AudioDeviceID],
    issues: inout [AudioCatalogIssue]
  ) throws(AudioCatalogError) -> [AudioProcess] {
    let processObjectIDs = try provider.processObjectIDs()
    var processesByID: [AudioProcessID: AudioProcess] = [:]

    for objectID in processObjectIDs {
      do {
        let hardwareProcess = try provider.process(for: objectID)
        guard
          hardwareProcess.processIdentifier != provider.currentProcessIdentifier,
          let processID = AudioProcessID(rawValue: hardwareProcess.processIdentifier),
          processesByID[processID] == nil
        else { continue }

        let inputDeviceIDs = identities(
          for: hardwareProcess.inputDeviceObjectIDs,
          using: deviceIDByObjectID
        )
        let outputDeviceIDs = identities(
          for: hardwareProcess.outputDeviceObjectIDs,
          using: deviceIDByObjectID
        )
        let bundleIdentifier = hardwareProcess.bundleIdentifier.flatMap {
          $0.isEmpty ? nil : $0
        }
        processesByID[processID] = AudioProcess(
          id: processID,
          bundleIdentifier: bundleIdentifier,
          isRunning: hardwareProcess.isRunning,
          isRunningInput: hardwareProcess.isRunningInput,
          isRunningOutput: hardwareProcess.isRunningOutput,
          inputDeviceIDs: inputDeviceIDs,
          outputDeviceIDs: outputDeviceIDs
        )
      } catch {
        issues.append(AudioCatalogIssue(error: error))
      }
    }

    return processesByID.values.sorted(by: compareProcesses)
  }

  private func loadDevice(
    for objectID: HardwareObjectID,
    defaultInput: HardwareObjectID?,
    defaultOutput: HardwareObjectID?
  ) throws(AudioCatalogError) -> (AudioDeviceID, AudioDevice) {
    let hardwareDevice = try provider.device(for: objectID)
    guard let deviceID = AudioDeviceID(rawValue: hardwareDevice.uid) else {
      throw .invalidData(
        AudioHardwareDataError(
          objectKind: .device,
          property: .deviceIdentifier,
          reason: "the device UID is empty"
        )
      )
    }
    return (
      deviceID,
      makeDevice(
        hardwareDevice,
        id: deviceID,
        isDefaultInput: objectID == defaultInput,
        isDefaultOutput: objectID == defaultOutput
      )
    )
  }

  private func identities(
    for objectIDs: [HardwareObjectID],
    using deviceIDByObjectID: [HardwareObjectID: AudioDeviceID]
  ) -> [AudioDeviceID] {
    var seen: Set<AudioDeviceID> = []
    return objectIDs.compactMap { objectID in
      guard let id = deviceIDByObjectID[objectID], seen.insert(id).inserted else { return nil }
      return id
    }
  }

  private func makeDevice(
    _ hardwareDevice: HardwareDeviceDescription,
    id: AudioDeviceID,
    isDefaultInput: Bool,
    isDefaultOutput: Bool
  ) -> AudioDevice {
    AudioDevice(
      id: id,
      name: hardwareDevice.name,
      transportType: hardwareDevice.transportType,
      nominalSampleRate: hardwareDevice.nominalSampleRate,
      isAlive: hardwareDevice.isAlive,
      isRunning: hardwareDevice.isRunning,
      input: hardwareDevice.input.flatMap {
        makeEndpoint(
          $0,
          deviceID: id,
          direction: .input,
          isDefault: isDefaultInput
        )
      },
      output: hardwareDevice.output.flatMap {
        makeEndpoint(
          $0,
          deviceID: id,
          direction: .output,
          isDefault: isDefaultOutput
        )
      }
    )
  }

  private func mergingDefaultFlags(
    of retainedDevice: AudioDevice,
    with duplicateDevice: AudioDevice
  ) -> AudioDevice {
    AudioDevice(
      id: retainedDevice.id,
      name: retainedDevice.name,
      transportType: retainedDevice.transportType,
      nominalSampleRate: retainedDevice.nominalSampleRate,
      isAlive: retainedDevice.isAlive,
      isRunning: retainedDevice.isRunning,
      input: mergingDefaultFlag(
        of: retainedDevice.input,
        with: duplicateDevice.input
      ),
      output: mergingDefaultFlag(
        of: retainedDevice.output,
        with: duplicateDevice.output
      )
    )
  }

  private func mergingDefaultFlag(
    of retainedEndpoint: AudioDeviceEndpoint?,
    with duplicateEndpoint: AudioDeviceEndpoint?
  ) -> AudioDeviceEndpoint? {
    guard let retainedEndpoint else { return nil }
    return AudioDeviceEndpoint(
      direction: retainedEndpoint.direction,
      isDefault: retainedEndpoint.isDefault || duplicateEndpoint?.isDefault == true,
      channels: retainedEndpoint.channels,
      streams: retainedEndpoint.streams
    )
  }

  private func makeEndpoint(
    _ hardwareEndpoint: HardwareDeviceEndpointDescription,
    deviceID: AudioDeviceID,
    direction: AudioDirection,
    isDefault: Bool
  ) -> AudioDeviceEndpoint? {
    guard hardwareEndpoint.channelCount > 0 else { return nil }

    let streams: [AudioStream] = hardwareEndpoint.streams.enumerated().compactMap {
      position, hardwareStream in
      guard let index = AudioStreamIndex(rawValue: position) else { return nil }
      return AudioStream(
        id: AudioStreamID(deviceID: deviceID, direction: direction, index: index),
        isActive: hardwareStream.isActive,
        virtualFormat: hardwareStream.virtualFormat,
        physicalFormat: hardwareStream.physicalFormat
      )
    }
    let ownerID: AudioChannelOwnerID =
      switch direction {
      case .input:
        .source(.deviceInput(deviceID))
      case .output:
        .destination(.deviceOutput(deviceID))
      }
    let channels: [AudioChannel] = (0..<hardwareEndpoint.channelCount).compactMap { position in
      guard let index = AudioChannelIndex(rawValue: position) else { return nil }
      let mapping = streamMapping(
        for: position,
        streams: streams,
        descriptions: hardwareEndpoint.streams
      )
      return AudioChannel(
        id: AudioChannelID(ownerID: ownerID, index: index),
        streamID: mapping?.streamID,
        streamChannelIndex: mapping?.channelIndex
      )
    }
    return AudioDeviceEndpoint(
      direction: direction,
      isDefault: isDefault,
      channels: channels,
      streams: streams
    )
  }

  private func streamMapping(
    for channelPosition: Int,
    streams: [AudioStream],
    descriptions: [HardwareStreamDescription]
  ) -> (streamID: AudioStreamID, channelIndex: AudioChannelIndex)? {
    for (stream, description) in zip(streams, descriptions) {
      guard let startingChannel = description.startingChannel, startingChannel > 0 else { continue }
      let firstPosition = startingChannel - 1
      let streamPosition = channelPosition - firstPosition
      guard
        streamPosition >= 0,
        streamPosition < description.channelCount,
        let channelIndex = AudioChannelIndex(rawValue: streamPosition)
      else { continue }
      return (stream.id, channelIndex)
    }
    return nil
  }

  private func compareDevices(_ lhs: AudioDevice, _ rhs: AudioDevice) -> Bool {
    let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
    if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
    return lhs.id.rawValue < rhs.id.rawValue
  }

  private func compareProcesses(_ lhs: AudioProcess, _ rhs: AudioProcess) -> Bool {
    if lhs.isRunningOutput != rhs.isRunningOutput { return lhs.isRunningOutput }
    if lhs.isRunningInput != rhs.isRunningInput { return lhs.isRunningInput }
    if lhs.isRunning != rhs.isRunning { return lhs.isRunning }

    switch (lhs.bundleIdentifier, rhs.bundleIdentifier) {
    case (let left?, let right?):
      let order = left.localizedCaseInsensitiveCompare(right)
      if order != .orderedSame { return order == .orderedAscending }
    case (_?, nil):
      return true
    case (nil, _?):
      return false
    case (nil, nil):
      break
    }
    return lhs.id.rawValue < rhs.id.rawValue
  }
}
