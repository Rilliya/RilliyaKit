// SPDX-License-Identifier: Apache-2.0

/// A channel exposed by an input or output device endpoint.
public struct AudioChannel: Hashable, Identifiable, Sendable {
  /// The identity of the channel.
  public let id: AudioChannelID

  /// The stream that carries this channel, when Core Audio reports the mapping.
  public let streamID: AudioStreamID?

  /// The zero-based position of the channel within `streamID`, when known.
  public let streamChannelIndex: AudioChannelIndex?

  /// Creates a channel description.
  public init(
    id: AudioChannelID,
    streamID: AudioStreamID? = nil,
    streamChannelIndex: AudioChannelIndex? = nil
  ) {
    self.id = id
    self.streamID = streamID
    self.streamChannelIndex = streamChannelIndex
  }
}

/// A native stream exposed by a Core Audio device.
public struct AudioStream: Hashable, Identifiable, Sendable {
  /// The identity of the stream.
  public let id: AudioStreamID

  /// Whether Core Audio currently considers the stream active.
  public let isActive: Bool

  /// The format used by client IO procedures, when the device reports it.
  public let virtualFormat: AudioStreamFormat?

  /// The format used by the underlying hardware, when the device reports it.
  public let physicalFormat: AudioStreamFormat?

  /// Creates a native stream description.
  public init(
    id: AudioStreamID,
    isActive: Bool,
    virtualFormat: AudioStreamFormat?,
    physicalFormat: AudioStreamFormat?
  ) {
    self.id = id
    self.isActive = isActive
    self.virtualFormat = virtualFormat
    self.physicalFormat = physicalFormat
  }
}

/// One directional endpoint of a Core Audio device.
public struct AudioDeviceEndpoint: Hashable, Sendable {
  /// The direction in which audio moves through the endpoint.
  public let direction: AudioDirection

  /// Whether this is the current system default for its direction.
  public let isDefault: Bool

  /// The channels in the device's native stream configuration.
  public let channels: [AudioChannel]

  /// The native streams reported for this direction.
  public let streams: [AudioStream]

  /// The number of channels in the native stream configuration.
  public var channelCount: Int {
    channels.count
  }

  /// Creates a directional device endpoint.
  public init(
    direction: AudioDirection,
    isDefault: Bool,
    channels: [AudioChannel],
    streams: [AudioStream]
  ) {
    self.direction = direction
    self.isDefault = isDefault
    self.channels = channels
    self.streams = streams
  }
}

/// A physical, aggregate, or virtual device published by Core Audio.
public struct AudioDevice: Hashable, Identifiable, Sendable {
  /// The persistent Core Audio identity of the device.
  public let id: AudioDeviceID

  /// The device name reported by Core Audio.
  public let name: String

  /// The native Core Audio transport type.
  public let transportType: UInt32

  /// The nominal sample rate currently configured on the device.
  public let nominalSampleRate: Double

  /// Whether Core Audio reports that the device is ready for use.
  public let isAlive: Bool

  /// Whether Core Audio reports that the device is performing IO.
  public let isRunning: Bool

  /// The input endpoint, or `nil` when the device has no input channels.
  public let input: AudioDeviceEndpoint?

  /// The output endpoint, or `nil` when the device has no output channels.
  public let output: AudioDeviceEndpoint?

  /// Creates an audio device description.
  public init(
    id: AudioDeviceID,
    name: String,
    transportType: UInt32,
    nominalSampleRate: Double,
    isAlive: Bool,
    isRunning: Bool,
    input: AudioDeviceEndpoint?,
    output: AudioDeviceEndpoint?
  ) {
    self.id = id
    self.name = name
    self.transportType = transportType
    self.nominalSampleRate = nominalSampleRate
    self.isAlive = isAlive
    self.isRunning = isRunning
    self.input = input
    self.output = output
  }
}

/// A process currently connected to the Core Audio HAL.
public struct AudioProcess: Hashable, Identifiable, Sendable {
  /// The runtime process identity.
  public let id: AudioProcessID

  /// The bundle identifier reported by Core Audio, when present.
  public let bundleIdentifier: String?

  /// Whether any audio IO is currently in progress in the process.
  public let isRunning: Bool

  /// Whether the process currently has active input streams.
  public let isRunningInput: Bool

  /// Whether the process currently has active output streams.
  public let isRunningOutput: Bool

  /// Input devices currently used by the process.
  public let inputDeviceIDs: [AudioDeviceID]

  /// Output devices currently used by the process.
  public let outputDeviceIDs: [AudioDeviceID]

  /// The identity used when the process output becomes a routing source.
  public var outputSourceID: AudioSourceID {
    .processOutput(id)
  }

  /// Creates an audio process description.
  public init(
    id: AudioProcessID,
    bundleIdentifier: String?,
    isRunning: Bool,
    isRunningInput: Bool,
    isRunningOutput: Bool,
    inputDeviceIDs: [AudioDeviceID],
    outputDeviceIDs: [AudioDeviceID]
  ) {
    self.id = id
    self.bundleIdentifier = bundleIdentifier
    self.isRunning = isRunning
    self.isRunningInput = isRunningInput
    self.isRunningOutput = isRunningOutput
    self.inputDeviceIDs = inputDeviceIDs
    self.outputDeviceIDs = outputDeviceIDs
  }
}

/// A value snapshot of the processes and devices currently known to Core Audio.
public struct AudioCatalogSnapshot: Hashable, Sendable {
  /// The audio-capable processes, ordered by current activity and identity.
  public let processes: [AudioProcess]

  /// The audio-capable devices, ordered by name and persistent identity.
  public let devices: [AudioDevice]

  /// Nonfatal failures encountered while reading individual catalog entries.
  public let issues: [AudioCatalogIssue]

  /// Devices with input channels, with the default input first.
  public var inputDevices: [AudioDevice] {
    devices.filter { $0.input != nil }.sorted { $0.inputSortKey < $1.inputSortKey }
  }

  /// Devices with output channels, with the default output first.
  public var outputDevices: [AudioDevice] {
    devices.filter { $0.output != nil }.sorted { $0.outputSortKey < $1.outputSortKey }
  }

  /// Creates an audio catalog snapshot.
  public init(
    processes: [AudioProcess],
    devices: [AudioDevice],
    issues: [AudioCatalogIssue] = []
  ) {
    self.processes = processes
    self.devices = devices
    self.issues = issues
  }
}

extension AudioDevice {
  fileprivate var inputSortKey: DeviceSortKey {
    DeviceSortKey(isDefault: input?.isDefault == true, name: name, id: id.rawValue)
  }

  fileprivate var outputSortKey: DeviceSortKey {
    DeviceSortKey(isDefault: output?.isDefault == true, name: name, id: id.rawValue)
  }
}

private struct DeviceSortKey: Comparable {
  let isDefault: Bool
  let name: String
  let id: String

  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
    let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
    if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
    return lhs.id < rhs.id
  }
}
