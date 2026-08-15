// SPDX-License-Identifier: Apache-2.0

/// The direction in which audio moves through a device.
public enum AudioDirection: String, CaseIterable, Hashable, Sendable {
  /// Audio entering the system from a device.
  case input

  /// Audio leaving the system through a device.
  case output
}

/// The runtime identity of a process connected to the Core Audio HAL.
public struct AudioProcessID: Hashable, RawRepresentable, Sendable {
  /// The POSIX process identifier represented by this value.
  public let rawValue: Int32

  /// Creates an identity for a positive POSIX process identifier.
  ///
  /// - Parameter rawValue: The process identifier.
  public init?(rawValue: Int32) {
    guard rawValue > 0 else { return nil }
    self.rawValue = rawValue
  }
}

/// The persistent identity of a Core Audio device.
public struct AudioDeviceID: Hashable, RawRepresentable, Sendable {
  /// The opaque Core Audio device UID represented by this value.
  public let rawValue: String

  /// Creates an identity from a nonempty Core Audio device UID.
  ///
  /// - Parameter rawValue: The device UID exactly as supplied by Core Audio.
  public init?(rawValue: String) {
    guard !rawValue.isEmpty else { return nil }
    self.rawValue = rawValue
  }
}

/// A validated zero-based index into the streams of a device endpoint.
public struct AudioStreamIndex: Hashable, Comparable, RawRepresentable, Sendable {
  /// The zero-based integer represented by this index.
  public let rawValue: Int

  /// Creates an index when `rawValue` is nonnegative.
  ///
  /// - Parameter rawValue: The zero-based stream position.
  public init?(rawValue: Int) {
    guard rawValue >= 0 else { return nil }
    self.rawValue = rawValue
  }

  /// Orders stream indices by their zero-based positions.
  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

/// The identity of a stream within one direction of a device.
public struct AudioStreamID: Hashable, Sendable {
  /// The device that owns the stream.
  public let deviceID: AudioDeviceID

  /// The direction of the stream.
  public let direction: AudioDirection

  /// The zero-based position of the stream in its endpoint.
  public let index: AudioStreamIndex

  /// Creates a device stream identity.
  ///
  /// - Parameters:
  ///   - deviceID: The persistent identity of the owning device.
  ///   - direction: The direction of the stream.
  ///   - index: The zero-based position of the stream.
  public init(deviceID: AudioDeviceID, direction: AudioDirection, index: AudioStreamIndex) {
    self.deviceID = deviceID
    self.direction = direction
    self.index = index
  }
}

/// The identity of an audio source that can feed a future routing graph.
public enum AudioSourceID: Hashable, Sendable {
  /// The output produced by a process.
  case processOutput(AudioProcessID)

  /// Audio entering through an input device.
  case deviceInput(AudioDeviceID)
}

/// The identity of an audio destination that can receive routed audio.
public enum AudioDestinationID: Hashable, Sendable {
  /// Audio leaving through an output device.
  case deviceOutput(AudioDeviceID)
}

/// The endpoint that owns a channel.
public enum AudioChannelOwnerID: Hashable, Sendable {
  /// A channel owned by an audio source.
  case source(AudioSourceID)

  /// A channel owned by an audio destination.
  case destination(AudioDestinationID)
}

/// The stable identity of a channel within an audio endpoint.
public struct AudioChannelID: Hashable, Sendable {
  /// The endpoint that owns the channel.
  public let ownerID: AudioChannelOwnerID

  /// The zero-based position of the channel in the endpoint.
  public let index: AudioChannelIndex

  /// Creates an audio channel identity.
  ///
  /// - Parameters:
  ///   - ownerID: The endpoint that owns the channel.
  ///   - index: The zero-based position of the channel.
  public init(ownerID: AudioChannelOwnerID, index: AudioChannelIndex) {
    self.ownerID = ownerID
    self.index = index
  }
}
