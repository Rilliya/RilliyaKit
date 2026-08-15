// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import Foundation

/// The kind of Core Audio object involved in a hardware operation.
public enum AudioHardwareObjectKind: String, Hashable, Sendable {
  /// The singleton Core Audio system object.
  case system

  /// A Core Audio process object.
  case process

  /// A Core Audio device object.
  case device

  /// A Core Audio stream object.
  case stream
}

/// A property read while discovering audio processes and devices.
public enum AudioHardwareProperty: String, Hashable, Sendable {
  /// The list of devices published by Core Audio.
  case devices

  /// The current default input device.
  case defaultInputDevice

  /// The current default output device.
  case defaultOutputDevice

  /// The list of processes connected to Core Audio.
  case processes

  /// The POSIX process identifier.
  case processIdentifier

  /// The process bundle identifier.
  case processBundleIdentifier

  /// The devices associated with a process.
  case processDevices

  /// Whether a process is performing any audio IO.
  case processIsRunning

  /// Whether a process has active input streams.
  case processIsRunningInput

  /// Whether a process has active output streams.
  case processIsRunningOutput

  /// The persistent device UID.
  case deviceIdentifier

  /// The device name.
  case deviceName

  /// The device transport type.
  case deviceTransportType

  /// The device nominal sample rate.
  case deviceNominalSampleRate

  /// Whether a device is ready for use.
  case deviceIsAlive

  /// Whether a device is performing IO.
  case deviceIsRunning

  /// The native device stream configuration.
  case deviceStreamConfiguration

  /// The list of streams exposed by a device.
  case deviceStreams

  /// Whether a stream is enabled and performing IO.
  case streamIsActive

  /// The first device channel represented by a stream.
  case streamStartingChannel

  /// The stream format used by client IO procedures.
  case streamVirtualFormat

  /// The stream format used by the underlying hardware.
  case streamPhysicalFormat
}

/// The stage of a Core Audio property operation that failed.
public enum AudioHardwareOperation: String, Hashable, Sendable {
  /// Reading the byte count of variable-length property data.
  case readPropertySize

  /// Reading property data.
  case readProperty
}

/// A typed Core Audio status code.
public struct AudioHardwareStatus: Hashable, RawRepresentable, Sendable {
  /// The signed Core Audio status code.
  public let rawValue: Int32

  /// Creates a status value from an `OSStatus` representation.
  ///
  /// - Parameter rawValue: The signed status code.
  public init(rawValue: Int32) {
    self.rawValue = rawValue
  }

  /// The printable four-character representation, when the status contains one.
  public var fourCharacterCode: String? {
    let bits = UInt32(bitPattern: rawValue)
    let bytes = [
      UInt8((bits >> 24) & 0xff),
      UInt8((bits >> 16) & 0xff),
      UInt8((bits >> 8) & 0xff),
      UInt8(bits & 0xff),
    ]
    guard bytes.allSatisfy({ (32...126).contains($0) }) else { return nil }
    return String(bytes: bytes, encoding: .ascii)
  }
}

/// A failure returned by a Core Audio hardware property operation.
public struct AudioHardwareError: Error, Hashable, LocalizedError, Sendable {
  /// The kind of object involved in the operation.
  public let objectKind: AudioHardwareObjectKind

  /// The property involved in the operation.
  public let property: AudioHardwareProperty

  /// The stage of the property operation that failed.
  public let operation: AudioHardwareOperation

  /// The status returned by Core Audio.
  public let status: AudioHardwareStatus

  /// Creates a typed Core Audio hardware failure.
  public init(
    objectKind: AudioHardwareObjectKind,
    property: AudioHardwareProperty,
    operation: AudioHardwareOperation,
    status: AudioHardwareStatus
  ) {
    self.objectKind = objectKind
    self.property = property
    self.operation = operation
    self.status = status
  }

  /// A human-readable description that retains the native status code.
  public var errorDescription: String? {
    let code =
      status.fourCharacterCode.map { "\(status.rawValue) ('\($0)')" }
      ?? String(status.rawValue)
    return
      "Core Audio could not \(operation.description) \(property.rawValue) on a "
      + "\(objectKind.rawValue) object: OSStatus \(code)"
  }
}

/// A failure to interpret otherwise successful Core Audio property data.
public struct AudioHardwareDataError: Error, Hashable, LocalizedError, Sendable {
  /// The kind of object that supplied the data.
  public let objectKind: AudioHardwareObjectKind

  /// The property whose data was invalid.
  public let property: AudioHardwareProperty

  /// A concise explanation of the invalid data.
  public let reason: String

  /// Creates an invalid hardware data failure.
  public init(
    objectKind: AudioHardwareObjectKind,
    property: AudioHardwareProperty,
    reason: String
  ) {
    self.objectKind = objectKind
    self.property = property
    self.reason = reason
  }

  /// A human-readable description of the invalid property data.
  public var errorDescription: String? {
    "Core Audio returned invalid \(property.rawValue) data for a \(objectKind.rawValue) "
      + "object: \(reason)"
  }
}

/// A typed failure produced while building an audio catalog.
public enum AudioCatalogError: Error, Hashable, LocalizedError, Sendable {
  /// Core Audio returned a nonzero status.
  case hardware(AudioHardwareError)

  /// Core Audio returned malformed or incomplete property data.
  case invalidData(AudioHardwareDataError)

  /// A human-readable description of the catalog failure.
  public var errorDescription: String? {
    switch self {
    case .hardware(let error):
      return error.errorDescription
    case .invalidData(let error):
      return error.errorDescription
    }
  }
}

/// A nonfatal failure encountered while building a catalog snapshot.
public struct AudioCatalogIssue: Hashable, Sendable {
  /// The catalog failure that caused this entry to be omitted.
  public let error: AudioCatalogError

  /// Creates a catalog issue.
  ///
  /// - Parameter error: The failure encountered during discovery.
  public init(error: AudioCatalogError) {
    self.error = error
  }
}

extension AudioHardwareOperation {
  fileprivate var description: String {
    switch self {
    case .readPropertySize:
      return "read the size of"
    case .readProperty:
      return "read"
    }
  }
}
