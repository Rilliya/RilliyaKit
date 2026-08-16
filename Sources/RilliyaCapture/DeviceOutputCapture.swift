// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaCore
import RilliyaRealtime

/// The meter configuration accepted by output-device capture.
public typealias DeviceOutputCaptureConfiguration = AudioCaptureConfiguration

/// The output device to resolve when preparing a capture.
public enum DeviceOutputCaptureTarget: Hashable, Sendable {
  /// Capture one output device identified by its persistent Core Audio UID.
  case device(AudioDeviceID)

  /// Resolve and capture the system default output device during preparation.
  ///
  /// The resolved device remains fixed for the lifetime of the capture. Prepare a new capture
  /// after the system default changes when the application needs to follow that change.
  case systemDefault
}

/// Processes omitted from an output-device mix.
public struct DeviceOutputCaptureProcessExclusion: Hashable, Sendable {
  /// Captures every process, including the host application.
  ///
  /// Routing such a capture back to the selected output device can create a feedback loop.
  public static let none = Self(processIDs: [], excludesCurrentProcess: false)

  /// Explicit process identities to omit, ordered by their POSIX identifiers.
  public let processIDs: [AudioProcessID]

  /// Whether to omit the host application when Core Audio currently publishes it.
  ///
  /// On macOS 14.2 through macOS 15, Core Audio can only exclude current HAL process objects. If
  /// the host has not opened audio IO during preparation, it has no process object to exclude.
  public let excludesCurrentProcess: Bool

  /// Creates a deterministic process-exclusion policy.
  ///
  /// Duplicate process identities are removed and the remaining values are ordered by PID.
  public init(
    processIDs: [AudioProcessID] = [],
    excludesCurrentProcess: Bool = true
  ) {
    self.processIDs = Array(Set(processIDs)).sorted { $0.rawValue < $1.rawValue }
    self.excludesCurrentProcess = excludesCurrentProcess
  }
}

/// The runtime format published by an output-device capture.
public struct DeviceOutputCaptureFormat: Hashable, Sendable {
  /// The persistent identity of the output device resolved during preparation.
  public let deviceID: AudioDeviceID

  /// The zero-based output stream captured from the device.
  public let streamIndex: AudioStreamIndex

  /// The number of sample frames per second in the native tap stream.
  public let sampleRate: Double

  /// The stable channel identities in native tap order.
  public let channelIDs: [AudioChannelID]

  /// Creates an output-device capture format.
  public init(
    deviceID: AudioDeviceID,
    streamIndex: AudioStreamIndex,
    sampleRate: Double,
    channelIDs: [AudioChannelID]
  ) {
    self.deviceID = deviceID
    self.streamIndex = streamIndex
    self.sampleRate = sampleRate
    self.channelIDs = channelIDs
  }
}

/// A bounded value snapshot produced by an output-device capture.
public struct DeviceOutputMeterSnapshot: Equatable, Sendable {
  /// The runtime format shared by every channel in the snapshot.
  public let format: DeviceOutputCaptureFormat

  /// A monotonically increasing sequence number within this capture session.
  public let sequence: UInt64

  /// The number of native frames analyzed for this snapshot.
  public let frameCount: Int

  /// Per-channel meter values in native tap order.
  public let channels: [AudioChannelMeterSnapshot]

  /// Creates an output-device meter snapshot.
  public init(
    format: DeviceOutputCaptureFormat,
    sequence: UInt64,
    frameCount: Int,
    channels: [AudioChannelMeterSnapshot]
  ) {
    self.format = format
    self.sequence = sequence
    self.frameCount = frameCount
    self.channels = channels
  }
}

/// A stage of the native output-device tap lifecycle.
public enum DeviceOutputCaptureOperation: String, Hashable, Sendable {
  /// Reading the Core Audio process list used for exclusions.
  case readProcesses

  /// Reading a process identifier used for exclusions.
  case readProcessIdentifier

  /// Reading the default output device.
  case readDefaultOutputDevice

  /// Resolving a persistent device UID to its current Core Audio object.
  case resolveDevice

  /// Reading whether the selected device is available for IO.
  case readDeviceAvailability

  /// Reading the output streams of the selected device.
  case readDeviceStreams

  /// Reading a Core Audio device UID.
  case readDeviceIdentifier

  /// Creating a native system-audio tap.
  case createTap

  /// Reading the native tap UID.
  case readTapIdentifier

  /// Creating the private aggregate device that hosts the tap.
  case createAggregateDevice

  /// Attaching the tap to its private aggregate device.
  case attachTap

  /// Reading the runtime format published by the tap device.
  case readTapFormat

  /// Creating the aggregate device IO procedure.
  case createIOProcedure

  /// Starting aggregate device IO.
  case startDevice

  /// Stopping aggregate device IO.
  case stopDevice

  /// Destroying the aggregate device IO procedure.
  case destroyIOProcedure

  /// Destroying the private aggregate device.
  case destroyAggregateDevice

  /// Destroying the native system-audio tap.
  case destroyTap
}

/// A typed failure from output-device capture setup or lifecycle management.
public enum DeviceOutputCaptureError: Error, Hashable, LocalizedError, Sendable {
  /// Core Audio does not currently publish a default output device.
  case noDefaultOutputDevice

  /// Core Audio does not currently publish an object for an explicitly excluded process.
  case processNotFound(AudioProcessID)

  /// Core Audio does not currently publish a device with the requested UID.
  case deviceNotFound(AudioDeviceID)

  /// The requested device is present but unavailable for IO.
  case deviceUnavailable(AudioDeviceID)

  /// The selected device publishes no output streams.
  case noOutputStream(AudioDeviceID)

  /// The tap did not publish an identifier or input stream before the setup deadline.
  case tapUnavailable

  /// The native tap format cannot be consumed as Float32 PCM.
  case unsupportedFormat(AudioDeviceID)

  /// A stopped capture cannot be started again.
  case alreadyStopped

  /// Core Audio returned a nonzero status during a lifecycle operation.
  case hardware(operation: DeviceOutputCaptureOperation, status: AudioHardwareStatus)

  /// Core Audio returned property data whose size does not match its declared type.
  case invalidPropertyData(operation: DeviceOutputCaptureOperation)

  /// A human-readable description that retains native failure context.
  public var errorDescription: String? {
    switch self {
    case .noDefaultOutputDevice:
      return "Core Audio does not currently publish a default output device."
    case .processNotFound(let processID):
      return "Core Audio does not publish excluded process \(processID.rawValue)."
    case .deviceNotFound(let deviceID):
      return "Core Audio does not publish output device \(deviceID.rawValue)."
    case .deviceUnavailable(let deviceID):
      return "Output device \(deviceID.rawValue) is not currently available."
    case .noOutputStream(let deviceID):
      return "Output device \(deviceID.rawValue) does not publish any output streams."
    case .tapUnavailable:
      return "The output-device tap did not become available before the setup deadline."
    case .unsupportedFormat(let deviceID):
      return "Output device \(deviceID.rawValue) does not publish a supported tap format."
    case .alreadyStopped:
      return "A stopped output-device capture cannot be restarted."
    case .hardware(let operation, let status):
      let code =
        status.fourCharacterCode.map { "\(status.rawValue) ('\($0)')" }
        ?? String(status.rawValue)
      return "Core Audio failed to \(operation.description): OSStatus \(code)."
    case .invalidPropertyData(let operation):
      return "Core Audio returned invalid data while attempting to \(operation.description)."
    }
  }
}

/// Captures the mixed process audio destined for one Core Audio output-device stream.
///
/// The capture uses the public Core Audio tap API and leaves ordinary hardware playback unchanged.
/// Core Audio exposes device-specific taps one output stream at a time; this API captures stream
/// zero, which is the main stream for ordinary single-stream devices. Snapshot callbacks run on a
/// private serial delivery queue, never on the audio IO queue. The host application must include
/// `NSAudioCaptureUsageDescription` and the user must grant system-audio recording permission.
///
/// A ``DeviceOutputCaptureTarget/systemDefault`` target is resolved once during initialization.
/// Call ``stop()`` before releasing the capture. Stopped sessions are intentionally one-shot and
/// cannot be restarted.
@available(macOS 14.2, *)
public final class DeviceOutputCapture: @unchecked Sendable {
  /// A callback that receives bounded meter snapshots.
  public typealias SnapshotHandler = @Sendable (DeviceOutputMeterSnapshot) -> Void

  /// The target requested when this capture was created.
  public let target: DeviceOutputCaptureTarget

  /// The process-exclusion policy applied when the native tap was prepared.
  public let processExclusion: DeviceOutputCaptureProcessExclusion

  /// The output device resolved while the tap was created.
  public let deviceID: AudioDeviceID

  /// The native runtime format resolved while the tap was created.
  public let format: DeviceOutputCaptureFormat

  /// Bounded native PCM frames produced by this capture.
  ///
  /// This compatibility view supports exactly one serialized consumer. New code that may share a
  /// capture across workflows or output clocks should use ``subscribeToFrames()`` instead.
  public let frameBuffer: AudioRealtimeFrameBuffer

  private enum State {
    case ready
    case running
    case stopped
  }

  private let lock = NSLock()
  private let resource: any DeviceOutputCaptureResource
  private var state = State.ready

  /// Creates an output-device capture.
  ///
  /// Setup resolves the requested device and may briefly wait for Core Audio to publish the tap
  /// device. Applications should construct captures away from latency-sensitive actors.
  ///
  /// - Parameters:
  ///   - target: A persistent device identity or the system default resolved during setup.
  ///   - processExclusion: Processes omitted from the captured device mix. The host is excluded by
  ///     default when Core Audio currently publishes it.
  ///   - configuration: Bounds for meter delivery and waveform storage.
  ///   - snapshotHandler: Called serially on a private non-IO queue.
  /// - Throws: ``DeviceOutputCaptureError`` when Core Audio cannot prepare the device tap.
  public convenience init(
    target: DeviceOutputCaptureTarget,
    processExclusion: DeviceOutputCaptureProcessExclusion = DeviceOutputCaptureProcessExclusion(),
    configuration: DeviceOutputCaptureConfiguration = DeviceOutputCaptureConfiguration(),
    snapshotHandler: @escaping SnapshotHandler
  ) throws {
    try self.init(
      target: target,
      processExclusion: processExclusion,
      configuration: configuration,
      backend: CoreAudioDeviceOutputCaptureBackend(),
      snapshotHandler: snapshotHandler
    )
  }

  /// Creates a capture for one persistent output-device identity.
  public convenience init(
    deviceID: AudioDeviceID,
    processExclusion: DeviceOutputCaptureProcessExclusion = DeviceOutputCaptureProcessExclusion(),
    configuration: DeviceOutputCaptureConfiguration = DeviceOutputCaptureConfiguration(),
    snapshotHandler: @escaping SnapshotHandler
  ) throws {
    try self.init(
      target: .device(deviceID),
      processExclusion: processExclusion,
      configuration: configuration,
      snapshotHandler: snapshotHandler
    )
  }

  init(
    target: DeviceOutputCaptureTarget,
    processExclusion: DeviceOutputCaptureProcessExclusion,
    configuration: AudioMeterCaptureConfiguration,
    backend: any DeviceOutputCaptureBackend,
    snapshotHandler: @escaping SnapshotHandler
  ) throws {
    let resource = try backend.makeResource(
      target: target,
      processExclusion: processExclusion,
      configuration: configuration,
      snapshotHandler: snapshotHandler
    )
    self.target = target
    self.processExclusion = processExclusion
    deviceID = resource.format.deviceID
    format = resource.format
    frameBuffer = resource.frameBuffer
    self.resource = resource
  }

  deinit {
    try? resource.stop()
  }

  /// Whether aggregate device IO is currently running.
  public var isRunning: Bool {
    lock.withLock { state == .running }
  }

  /// Creates an independently paced, bounded PCM subscription.
  ///
  /// Subscription management may lock and must not run on an audio callback. Each returned
  /// subscription has its own queue and consumer cursor. The fixed limit comes from the capture
  /// configuration supplied during initialization.
  ///
  /// - Throws: ``AudioRealtimeFrameDistributorError/subscriberLimitReached(_:)`` when every
  ///   prepared subscription is active.
  public func subscribeToFrames() throws -> AudioRealtimeFrameSubscription {
    try resource.frameDistributor.subscribe()
  }

  /// Starts delivering output-device PCM and meter snapshots.
  public func start() throws {
    try lock.withLock {
      switch state {
      case .running:
        return
      case .stopped:
        throw DeviceOutputCaptureError.alreadyStopped
      case .ready:
        break
      }

      do {
        try resource.start()
        state = .running
      } catch {
        state = .stopped
        try? resource.stop()
        throw error
      }
    }
  }

  /// Stops IO and destroys the IO procedure, private aggregate device, and system-audio tap.
  ///
  /// Cleanup attempts every owned resource even when one native operation fails. The first failure
  /// is thrown after the remaining cleanup operations have been attempted.
  public func stop() throws {
    try lock.withLock {
      state = .stopped
      try resource.stop()
    }
  }
}

protocol DeviceOutputCaptureBackend: Sendable {
  func makeResource(
    target: DeviceOutputCaptureTarget,
    processExclusion: DeviceOutputCaptureProcessExclusion,
    configuration: AudioMeterCaptureConfiguration,
    snapshotHandler: @escaping DeviceOutputCapture.SnapshotHandler
  ) throws -> any DeviceOutputCaptureResource
}

protocol DeviceOutputCaptureResource: AnyObject, Sendable {
  var format: DeviceOutputCaptureFormat { get }
  var frameDistributor: AudioRealtimeFrameDistributor { get }
  var frameBuffer: AudioRealtimeFrameBuffer { get }

  func start() throws

  func stop() throws
}

extension DeviceOutputCaptureOperation {
  fileprivate var description: String {
    switch self {
    case .readProcesses:
      "read the process list"
    case .readProcessIdentifier:
      "read a process identifier"
    case .readDefaultOutputDevice:
      "read the default output device"
    case .resolveDevice:
      "resolve the output device"
    case .readDeviceAvailability:
      "read output-device availability"
    case .readDeviceStreams:
      "read output-device streams"
    case .readDeviceIdentifier:
      "read the output-device identifier"
    case .createTap:
      "create the output-device tap"
    case .readTapIdentifier:
      "read the output-device tap identifier"
    case .createAggregateDevice:
      "create the private aggregate device"
    case .attachTap:
      "attach the output-device tap"
    case .readTapFormat:
      "read the output-device tap format"
    case .createIOProcedure:
      "create the audio IO procedure"
    case .startDevice:
      "start aggregate device IO"
    case .stopDevice:
      "stop aggregate device IO"
    case .destroyIOProcedure:
      "destroy the audio IO procedure"
    case .destroyAggregateDevice:
      "destroy the private aggregate device"
    case .destroyTap:
      "destroy the output-device tap"
    }
  }
}
