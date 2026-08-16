// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaCapture
import RilliyaCore
import RilliyaEngine
import RilliyaGraph
import RilliyaRealtime

/// Captures the native output of one running macOS application process.
@available(macOS 14.2, *)
public struct ApplicationAudioInput: AudioGraphExecutableNode {
  /// Named ports exposed by an application-audio node handle.
  public struct Ports: AudioGraphNodePorts {
    /// The process's native output bus.
    public let audio = AudioGraphPortID(rawValue: "audio")

    /// Creates the stable application-audio port set.
    public init() {}
  }

  /// The stable public node identity.
  public static let typeID = AudioGraphNodeTypeID(
    rawValue: "moe.uwucocoa.rilliyakit.capture.application-audio-input"
  )

  /// Stable named ports for typed graph handles.
  public static let ports = Ports()

  /// The running process selected for capture.
  public let processID: AudioProcessID

  /// Whether ordinary hardware playback continues while the graph reads the process tap.
  public let muteBehavior: ProcessOutputCaptureMuteBehavior

  /// Creates an unmuted application-audio source by default.
  public init(
    processID: AudioProcessID,
    muteBehavior: ProcessOutputCaptureMuteBehavior = .unmuted
  ) {
    self.processID = processID
    self.muteBehavior = muteBehavior
  }

  /// Describes one runtime-resolved native audio output.
  public func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        .output(
          Self.ports.audio,
          signal: .audio(AudioGraphAudioSignalType())
        )
      ]
    )
  }

  /// Creates the process tap away from the graph render path and disables unused meter work.
  public func prepare(
    context: AudioGraphNodePreparationContext
  ) async throws -> any PreparedAudioGraphNode {
    let processID = processID
    let muteBehavior = muteBehavior
    let capture = try await Task.detached(priority: .userInitiated) {
      try ProcessOutputCapture(
        processID: processID,
        configuration: AudioMeterCaptureConfiguration(publishesMeterSnapshots: false),
        muteBehavior: muteBehavior,
        snapshotHandler: { _ in }
      )
    }.value
    return try PreparedCapturedAudioSourceNode(
      session: capture,
      outputPortID: Self.ports.audio,
      maximumFrameCount: context.maximumFrameCount
    )
  }
}

/// Captures native audio entering through one physical or virtual Core Audio input device.
@available(macOS 14.2, *)
public struct DeviceAudioInput: AudioGraphExecutableNode {
  /// Named ports exposed by a device-audio node handle.
  public struct Ports: AudioGraphNodePorts {
    /// The input device's native channel bus.
    public let audio = AudioGraphPortID(rawValue: "audio")

    /// Creates the stable device-audio port set.
    public init() {}
  }

  /// Receives an asynchronous AUHAL render failure away from the device callback.
  public typealias FailureHandler = DeviceInputCapture.FailureHandler

  /// The stable public node identity.
  public static let typeID = AudioGraphNodeTypeID(
    rawValue: "moe.uwucocoa.rilliyakit.capture.device-audio-input"
  )

  /// Stable named ports for typed graph handles.
  public static let ports = Ports()

  /// The persistent input-device identity selected for capture.
  public let deviceID: AudioDeviceID

  private let failureHandler: FailureHandler

  /// Creates a physical or virtual input-device source.
  ///
  /// The host remains responsible for requesting microphone permission before engine preparation.
  public init(
    deviceID: AudioDeviceID,
    failureHandler: @escaping FailureHandler = { _ in }
  ) {
    self.deviceID = deviceID
    self.failureHandler = failureHandler
  }

  /// Describes one runtime-resolved native audio output.
  public func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        .output(
          Self.ports.audio,
          signal: .audio(AudioGraphAudioSignalType())
        )
      ]
    )
  }

  /// Creates AUHAL input capture away from the graph render path and disables unused meter work.
  public func prepare(
    context: AudioGraphNodePreparationContext
  ) async throws -> any PreparedAudioGraphNode {
    let deviceID = deviceID
    let failureHandler = failureHandler
    let capture = try await Task.detached(priority: .userInitiated) {
      try DeviceInputCapture(
        deviceID: deviceID,
        configuration: AudioMeterCaptureConfiguration(publishesMeterSnapshots: false),
        snapshotHandler: { _ in },
        failureHandler: failureHandler
      )
    }.value
    return try PreparedCapturedAudioSourceNode(
      session: capture,
      outputPortID: Self.ports.audio,
      maximumFrameCount: context.maximumFrameCount
    )
  }
}

protocol AudioGraphCaptureSession: AnyObject, Sendable {
  var frameBuffer: AudioRealtimeFrameBuffer { get }

  func start() throws

  func stop() throws
}

@available(macOS 14.2, *)
extension ProcessOutputCapture: AudioGraphCaptureSession {}

@available(macOS 14.2, *)
extension DeviceInputCapture: AudioGraphCaptureSession {}

final class PreparedCapturedAudioSourceNode: PreparedAudioGraphNode, @unchecked Sendable {
  let outputFormats: [AudioGraphPortID: AudioProcessingFormat]
  let timing = AudioNodeTiming.transparent

  private let session: any AudioGraphCaptureSession
  private let source: PreparedAudioFrameBufferSource
  private let outputPortID: AudioGraphPortID

  init(
    session: any AudioGraphCaptureSession,
    outputPortID: AudioGraphPortID,
    maximumFrameCount: Int
  ) throws {
    self.session = session
    self.outputPortID = outputPortID
    source = try PreparedAudioFrameBufferSource(
      frameBuffer: session.frameBuffer,
      maximumFrameCount: maximumFrameCount
    )
    outputFormats = [outputPortID: session.frameBuffer.format]
  }

  func start() async throws {
    let session = session
    try await Task.detached(priority: .userInitiated) {
      try session.start()
    }.value
  }

  func render(context: AudioGraphRenderContext) -> AudioRenderResult {
    guard let output = context.output(outputPortID) else {
      return .insufficientChannels
    }
    return source.render(
      outputChannels: output.bus.channels,
      frameCount: context.frameCount
    )
  }

  func stop() async throws {
    let session = session
    try await Task.detached(priority: .userInitiated) {
      try session.stop()
    }.value
  }
}
