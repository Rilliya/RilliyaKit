// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaCore
import RilliyaRealtime

/// Configuration for bounded native audio capture delivery.
public struct AudioCaptureConfiguration: Hashable, Sendable {
  /// The largest waveform array accepted by the capture implementation.
  public static let maximumWaveformSampleCount = 512

  /// The largest number of additional frame subscribers accepted by one capture.
  public static let maximumAdditionalFrameSubscriberCountLimit = 63

  /// The requested maximum number of snapshots delivered each second.
  public let updatesPerSecond: Int

  /// The maximum number of waveform samples published for each channel.
  public let waveformSampleCount: Int

  /// The decibel value reported for silence and values below the display floor.
  public let minimumDecibels: Float

  /// Whether capture computes and publishes meter and waveform snapshots.
  public let publishesMeterSnapshots: Bool

  /// The additional independently paced frame subscribers prepared before capture begins.
  ///
  /// Every capture also reserves one queue for its compatibility `frameBuffer` view.
  public let maximumAdditionalFrameSubscriberCount: Int

  /// Creates a bounded meter capture configuration.
  ///
  /// Values are clamped to safe ranges: 1...60 updates per second, 1...512 waveform samples,
  /// -200...-1 dB for the display floor, and 0...63 additional frame subscribers.
  public init(
    updatesPerSecond: Int = 30,
    waveformSampleCount: Int = 128,
    minimumDecibels: Float = -120,
    publishesMeterSnapshots: Bool = true,
    maximumAdditionalFrameSubscriberCount: Int = 3
  ) {
    let finiteMinimumDecibels = minimumDecibels.isFinite ? minimumDecibels : -120
    self.updatesPerSecond = min(max(updatesPerSecond, 1), 60)
    self.waveformSampleCount = min(
      max(waveformSampleCount, 1),
      Self.maximumWaveformSampleCount
    )
    self.minimumDecibels = min(max(finiteMinimumDecibels, -200), -1)
    self.publishesMeterSnapshots = publishesMeterSnapshots
    self.maximumAdditionalFrameSubscriberCount = min(
      max(maximumAdditionalFrameSubscriberCount, 0),
      Self.maximumAdditionalFrameSubscriberCountLimit
    )
  }
}

/// A source-compatible spelling for the unified native capture configuration.
public typealias AudioMeterCaptureConfiguration = AudioCaptureConfiguration

/// The meter configuration accepted by process-output capture.
public typealias ProcessOutputCaptureConfiguration = AudioCaptureConfiguration

/// How the tapped process reaches its ordinary hardware destination while capture is active.
public enum ProcessOutputCaptureMuteBehavior: Hashable, Sendable {
  /// Capture audio while leaving the process's ordinary hardware playback unchanged.
  case unmuted

  /// Prevent the process from reaching its ordinary hardware destination for the entire tap life.
  case muted

  /// Leave ordinary playback unchanged until another audio client actively reads the tap.
  case mutedWhileTapped
}

/// The runtime format published by a process-output capture.
public struct ProcessOutputCaptureFormat: Hashable, Sendable {
  /// The process whose output is captured.
  public let processID: AudioProcessID

  /// The number of sample frames per second in the native tap stream.
  public let sampleRate: Double

  /// The stable channel identities in native tap order.
  public let channelIDs: [AudioChannelID]

  /// Creates a process-output capture format.
  public init(
    processID: AudioProcessID,
    sampleRate: Double,
    channelIDs: [AudioChannelID]
  ) {
    self.processID = processID
    self.sampleRate = sampleRate
    self.channelIDs = channelIDs
  }
}

/// A bounded value snapshot produced by a process-output capture.
public struct ProcessOutputMeterSnapshot: Equatable, Sendable {
  /// The runtime format shared by every channel in the snapshot.
  public let format: ProcessOutputCaptureFormat

  /// A monotonically increasing sequence number within this capture session.
  public let sequence: UInt64

  /// The number of native frames analyzed for this snapshot.
  public let frameCount: Int

  /// Per-channel meter values in native tap order.
  public let channels: [AudioChannelMeterSnapshot]

  /// Creates a process-output meter snapshot.
  public init(
    format: ProcessOutputCaptureFormat,
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

/// A stage of the native process-tap lifecycle.
public enum ProcessOutputCaptureOperation: String, Hashable, Sendable {
  /// Reading the Core Audio process list.
  case readProcesses

  /// Reading a process identifier.
  case readProcessIdentifier

  /// Reading the output devices used by a process.
  case readProcessDevices

  /// Reading the default output device.
  case readDefaultOutputDevice

  /// Reading the output streams of a device.
  case readDeviceStreams

  /// Reading a Core Audio device UID.
  case readDeviceIdentifier

  /// Creating a native process tap.
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

  /// Destroying the native process tap.
  case destroyTap
}

/// A typed failure from process-output capture setup or lifecycle management.
public enum ProcessOutputCaptureError: Error, Hashable, LocalizedError, Sendable {
  /// Core Audio does not currently publish an object for the requested process.
  case processNotFound(AudioProcessID)

  /// No output device is available for the requested process.
  case noOutputDevice(AudioProcessID)

  /// The selected output device publishes no output streams.
  case noOutputStream(AudioProcessID)

  /// The tap did not publish an identifier or input stream before the setup deadline.
  case tapUnavailable

  /// The native tap format cannot be consumed as Float32 PCM.
  case unsupportedFormat

  /// A stopped capture cannot be started again.
  case alreadyStopped

  /// Core Audio returned a nonzero status during a lifecycle operation.
  case hardware(operation: ProcessOutputCaptureOperation, status: AudioHardwareStatus)

  /// Core Audio returned a property value whose size does not match its declared type.
  case invalidPropertyData(operation: ProcessOutputCaptureOperation)

  /// A human-readable description that retains native failure context.
  public var errorDescription: String? {
    switch self {
    case .processNotFound(let processID):
      return "Core Audio does not publish process \(processID.rawValue)."
    case .noOutputDevice(let processID):
      return "No output device is available for process \(processID.rawValue)."
    case .noOutputStream(let processID):
      return "The output device for process \(processID.rawValue) has no output streams."
    case .tapUnavailable:
      return "The process tap did not become available before the setup deadline."
    case .unsupportedFormat:
      return "The process tap did not publish packed native-endian Float32 PCM."
    case .alreadyStopped:
      return "A stopped process-output capture cannot be restarted."
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

/// Captures one process's native output channels with an explicit hardware-playback policy.
///
/// A capture owns one private process tap and one private aggregate device. Snapshot callbacks run
/// on a private serial delivery queue, never on the audio IO queue. Call ``stop()`` when capture is
/// no longer needed; stopped sessions are intentionally one-shot and cannot be restarted.
@available(macOS 14.2, *)
public final class ProcessOutputCapture: @unchecked Sendable {
  /// A callback that receives bounded meter snapshots.
  public typealias SnapshotHandler = @Sendable (ProcessOutputMeterSnapshot) -> Void

  /// The process selected when this capture was created.
  public let processID: AudioProcessID

  /// The hardware-playback policy selected when the native tap was prepared.
  public let muteBehavior: ProcessOutputCaptureMuteBehavior

  /// The native runtime format resolved while the tap was created.
  public let format: ProcessOutputCaptureFormat

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
  private let resource: any ProcessOutputCaptureResource
  private var state = State.ready

  /// Creates a native process-output capture.
  ///
  /// Setup may briefly wait for Core Audio to publish the private tap device. Applications should
  /// construct captures away from latency-sensitive actors.
  ///
  /// - Parameters:
  ///   - processID: The public RilliyaKit identity of the process to capture.
  ///   - configuration: Bounds for meter delivery and waveform storage.
  ///   - muteBehavior: Whether ordinary process playback continues while the tap is read.
  ///   - snapshotHandler: Called serially on a private non-IO queue.
  /// - Throws: ``ProcessOutputCaptureError`` when Core Audio cannot create or configure the tap.
  public convenience init(
    processID: AudioProcessID,
    configuration: ProcessOutputCaptureConfiguration = ProcessOutputCaptureConfiguration(),
    muteBehavior: ProcessOutputCaptureMuteBehavior = .unmuted,
    snapshotHandler: @escaping SnapshotHandler
  ) throws {
    try self.init(
      processID: processID,
      configuration: configuration,
      muteBehavior: muteBehavior,
      backend: CoreAudioProcessOutputCaptureBackend(),
      snapshotHandler: snapshotHandler
    )
  }

  init(
    processID: AudioProcessID,
    configuration: ProcessOutputCaptureConfiguration,
    muteBehavior: ProcessOutputCaptureMuteBehavior = .unmuted,
    backend: any ProcessOutputCaptureBackend,
    snapshotHandler: @escaping SnapshotHandler
  ) throws {
    let resource = try backend.makeResource(
      processID: processID,
      configuration: configuration,
      muteBehavior: muteBehavior,
      snapshotHandler: snapshotHandler
    )
    self.processID = processID
    self.muteBehavior = muteBehavior
    format = resource.format
    frameBuffer = resource.frameBuffer
    self.resource = resource
  }

  deinit {
    try? resource.stop()
  }

  /// Whether aggregate device IO is currently running.
  public var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return state == .running
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

  /// Starts delivering process-output meter snapshots.
  public func start() throws {
    lock.lock()
    defer { lock.unlock() }
    switch state {
    case .running:
      return
    case .stopped:
      throw ProcessOutputCaptureError.alreadyStopped
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

  /// Stops IO and destroys the IO procedure, private aggregate device, and process tap.
  ///
  /// Cleanup attempts every owned resource even when one native operation fails. The first failure
  /// is thrown after the remaining cleanup operations have been attempted.
  public func stop() throws {
    lock.lock()
    defer { lock.unlock() }
    state = .stopped
    try resource.stop()
  }
}

protocol ProcessOutputCaptureBackend: Sendable {
  func makeResource(
    processID: AudioProcessID,
    configuration: ProcessOutputCaptureConfiguration,
    muteBehavior: ProcessOutputCaptureMuteBehavior,
    snapshotHandler: @escaping ProcessOutputCapture.SnapshotHandler
  ) throws -> any ProcessOutputCaptureResource
}

protocol ProcessOutputCaptureResource: AnyObject, Sendable {
  var format: ProcessOutputCaptureFormat { get }
  var frameDistributor: AudioRealtimeFrameDistributor { get }
  var frameBuffer: AudioRealtimeFrameBuffer { get }

  func start() throws

  func stop() throws
}

extension ProcessOutputCaptureOperation {
  fileprivate var description: String {
    switch self {
    case .readProcesses:
      "read the process list"
    case .readProcessIdentifier:
      "read a process identifier"
    case .readProcessDevices:
      "read process output devices"
    case .readDefaultOutputDevice:
      "read the default output device"
    case .readDeviceStreams:
      "read device output streams"
    case .readDeviceIdentifier:
      "read the output device identifier"
    case .createTap:
      "create the process tap"
    case .readTapIdentifier:
      "read the process tap identifier"
    case .createAggregateDevice:
      "create the private aggregate device"
    case .attachTap:
      "attach the process tap"
    case .readTapFormat:
      "read the process tap format"
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
      "destroy the process tap"
    }
  }
}
