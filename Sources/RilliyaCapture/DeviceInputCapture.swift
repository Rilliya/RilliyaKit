// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaCore
import RilliyaRealtime

/// The runtime format published by an input-device capture.
public struct DeviceInputCaptureFormat: Hashable, Sendable {
  /// The persistent identity of the captured device.
  public let deviceID: AudioDeviceID

  /// The number of sample frames per second delivered by the capture.
  public let sampleRate: Double

  /// The stable input-channel identities in capture order.
  public let channelIDs: [AudioChannelID]

  /// Creates an input-device capture format.
  public init(
    deviceID: AudioDeviceID,
    sampleRate: Double,
    channelIDs: [AudioChannelID]
  ) {
    self.deviceID = deviceID
    self.sampleRate = sampleRate
    self.channelIDs = channelIDs
  }
}

/// A bounded value snapshot produced by an input-device capture.
public struct DeviceInputMeterSnapshot: Equatable, Sendable {
  /// The runtime format shared by every channel in the snapshot.
  public let format: DeviceInputCaptureFormat

  /// A monotonically increasing sequence number within this capture session.
  public let sequence: UInt64

  /// The number of native frames analyzed for this snapshot.
  public let frameCount: Int

  /// Per-channel meter values in input-device order.
  public let channels: [AudioChannelMeterSnapshot]

  /// Creates an input-device meter snapshot.
  public init(
    format: DeviceInputCaptureFormat,
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

/// A stage of the native input-device capture lifecycle.
public enum DeviceInputCaptureOperation: String, Hashable, Sendable {
  /// Translating a persistent device UID to its current Core Audio object.
  case resolveDevice

  /// Reading whether the selected device is available for IO.
  case readDeviceAvailability

  /// Reading whether the selected device publishes an input bus.
  case readInputAvailability

  /// Creating the HAL output audio unit used for input.
  case createAudioUnit

  /// Enabling the audio unit's input bus.
  case enableInput

  /// Disabling the audio unit's unused output bus.
  case disableOutput

  /// Selecting the requested Core Audio device.
  case selectDevice

  /// Reading the input device's runtime format.
  case readDeviceFormat

  /// Setting the Float32 format delivered to the client.
  case setClientFormat

  /// Reading the maximum number of frames in one render operation.
  case readMaximumFrames

  /// Installing the input render callback.
  case setInputCallback

  /// Initializing the HAL audio unit.
  case initializeAudioUnit

  /// Starting input-device IO.
  case startAudioUnit

  /// Rendering input frames from the HAL audio unit.
  case renderInput

  /// Stopping input-device IO.
  case stopAudioUnit

  /// Uninitializing the HAL audio unit.
  case uninitializeAudioUnit

  /// Disposing the HAL audio unit.
  case disposeAudioUnit
}

/// A typed failure from input-device capture setup or lifecycle management.
public enum DeviceInputCaptureError: Error, Hashable, LocalizedError, Sendable {
  /// Core Audio does not currently publish a device with the requested UID.
  case deviceNotFound(AudioDeviceID)

  /// The requested device is present but unavailable for IO.
  case deviceUnavailable(AudioDeviceID)

  /// The requested device publishes no input channels.
  case noInputChannels(AudioDeviceID)

  /// The device format cannot be represented by this bounded capture.
  case unsupportedFormat(AudioDeviceID)

  /// The host application does not have permission to capture audio input.
  case permissionDenied

  /// A stopped capture cannot be started again.
  case alreadyStopped

  /// Core Audio returned a nonzero status during a lifecycle operation.
  case hardware(operation: DeviceInputCaptureOperation, status: AudioHardwareStatus)

  /// Core Audio returned property data whose size does not match its declared type.
  case invalidPropertyData(operation: DeviceInputCaptureOperation)

  /// A human-readable description that retains native failure context.
  public var errorDescription: String? {
    switch self {
    case .deviceNotFound(let deviceID):
      return "Core Audio does not publish input device \(deviceID.rawValue)."
    case .deviceUnavailable(let deviceID):
      return "Input device \(deviceID.rawValue) is not currently available."
    case .noInputChannels(let deviceID):
      return "Input device \(deviceID.rawValue) does not publish any input channels."
    case .unsupportedFormat(let deviceID):
      return "Input device \(deviceID.rawValue) does not publish a supported runtime format."
    case .permissionDenied:
      return "Microphone access is required to capture an input device."
    case .alreadyStopped:
      return "A stopped input-device capture cannot be restarted."
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

/// Captures the native channels entering through one Core Audio input device.
///
/// The device is selected by its persistent UID, so callers never handle transient Core Audio
/// object identifiers. Snapshot callbacks run on a private serial delivery queue, never on the
/// audio render thread. Host applications remain responsible for requesting microphone permission
/// before constructing a capture. Call ``stop()`` when capture is no longer needed; stopped
/// sessions are intentionally one-shot and cannot be restarted.
@available(macOS 14.2, *)
public final class DeviceInputCapture: @unchecked Sendable {
  /// A callback that receives bounded meter snapshots.
  public typealias SnapshotHandler = @Sendable (DeviceInputMeterSnapshot) -> Void

  /// A callback that receives asynchronous render failures away from the audio thread.
  public typealias FailureHandler = @Sendable (DeviceInputCaptureError) -> Void

  /// The persistent identity selected when this capture was created.
  public let deviceID: AudioDeviceID

  /// The runtime client format resolved while the audio unit was created.
  public let format: DeviceInputCaptureFormat

  /// Bounded native PCM frames produced by this capture.
  ///
  /// One serialized render consumer may read this buffer while device IO is running. The buffer
  /// never allocates or invokes application code from the Core Audio render callback.
  public let frameBuffer: AudioRealtimeFrameBuffer

  private enum State {
    case ready
    case running
    case stopped
  }

  private let lock = NSLock()
  private let resource: any DeviceInputCaptureResource
  private var state = State.ready

  /// Creates a native input-device capture.
  ///
  /// Setup resolves the current Core Audio object for `deviceID` and prepares an AUHAL input unit.
  /// Applications should construct captures away from latency-sensitive actors.
  ///
  /// - Parameters:
  ///   - deviceID: The persistent RilliyaKit identity of the device to capture.
  ///   - configuration: Bounds for meter delivery and waveform storage.
  ///   - snapshotHandler: Called serially on a private non-render queue.
  ///   - failureHandler: Called once when input rendering fails asynchronously.
  /// - Throws: ``DeviceInputCaptureError`` when Core Audio cannot prepare the device.
  public convenience init(
    deviceID: AudioDeviceID,
    configuration: AudioMeterCaptureConfiguration = AudioMeterCaptureConfiguration(),
    snapshotHandler: @escaping SnapshotHandler,
    failureHandler: @escaping FailureHandler = { _ in }
  ) throws {
    try self.init(
      deviceID: deviceID,
      configuration: configuration,
      backend: CoreAudioDeviceInputCaptureBackend(),
      snapshotHandler: snapshotHandler,
      failureHandler: failureHandler
    )
  }

  init(
    deviceID: AudioDeviceID,
    configuration: AudioMeterCaptureConfiguration,
    backend: any DeviceInputCaptureBackend,
    snapshotHandler: @escaping SnapshotHandler,
    failureHandler: @escaping FailureHandler
  ) throws {
    let resource = try backend.makeResource(
      deviceID: deviceID,
      configuration: configuration,
      snapshotHandler: snapshotHandler,
      failureHandler: failureHandler
    )
    self.deviceID = deviceID
    format = resource.format
    frameBuffer = resource.frameBuffer
    self.resource = resource
  }

  deinit {
    try? resource.stop()
  }

  /// Whether input-device IO is currently running.
  public var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return state == .running
  }

  /// Starts delivering input-device meter snapshots.
  public func start() throws {
    lock.lock()
    defer { lock.unlock() }
    switch state {
    case .running:
      return
    case .stopped:
      throw DeviceInputCaptureError.alreadyStopped
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

  /// Stops IO and releases every Core Audio resource owned by the capture.
  ///
  /// Cleanup attempts every owned operation even when one native operation fails. The first failure
  /// is thrown after the remaining cleanup operations have been attempted.
  public func stop() throws {
    lock.lock()
    defer { lock.unlock() }
    state = .stopped
    try resource.stop()
  }
}

protocol DeviceInputCaptureBackend: Sendable {
  func makeResource(
    deviceID: AudioDeviceID,
    configuration: AudioMeterCaptureConfiguration,
    snapshotHandler: @escaping DeviceInputCapture.SnapshotHandler,
    failureHandler: @escaping DeviceInputCapture.FailureHandler
  ) throws -> any DeviceInputCaptureResource
}

protocol DeviceInputCaptureResource: AnyObject, Sendable {
  var format: DeviceInputCaptureFormat { get }
  var frameBuffer: AudioRealtimeFrameBuffer { get }

  func start() throws

  func stop() throws
}

extension DeviceInputCaptureOperation {
  fileprivate var description: String {
    switch self {
    case .resolveDevice:
      "resolve the input device UID"
    case .readDeviceAvailability:
      "read input-device availability"
    case .readInputAvailability:
      "read whether the device publishes input channels"
    case .createAudioUnit:
      "create the HAL input audio unit"
    case .enableInput:
      "enable input-device IO"
    case .disableOutput:
      "disable unused output-device IO"
    case .selectDevice:
      "select the input device"
    case .readDeviceFormat:
      "read the input-device format"
    case .setClientFormat:
      "set the Float32 input format"
    case .readMaximumFrames:
      "read the maximum input frame count"
    case .setInputCallback:
      "install the input render callback"
    case .initializeAudioUnit:
      "initialize the HAL input audio unit"
    case .startAudioUnit:
      "start input-device IO"
    case .renderInput:
      "render input-device audio"
    case .stopAudioUnit:
      "stop input-device IO"
    case .uninitializeAudioUnit:
      "uninitialize the HAL input audio unit"
    case .disposeAudioUnit:
      "dispose the HAL input audio unit"
    }
  }
}
