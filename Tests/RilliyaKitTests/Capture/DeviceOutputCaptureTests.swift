// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import Foundation
import RilliyaCore
import RilliyaRealtime
import Testing

@testable import RilliyaCapture

private typealias StableAudioDeviceID = RilliyaCore.AudioDeviceID

@Suite("Output device capture lifecycle")
struct DeviceOutputCaptureTests {
  @Test("Process exclusions are deduplicated and ordered")
  func normalizesProcessExclusions() throws {
    let first = try #require(AudioProcessID(rawValue: 7))
    let second = try #require(AudioProcessID(rawValue: 42))

    let exclusion = DeviceOutputCaptureProcessExclusion(
      processIDs: [second, first, second],
      excludesCurrentProcess: false
    )

    #expect(exclusion.processIDs == [first, second])
    #expect(!exclusion.excludesCurrentProcess)
    #expect(DeviceOutputCaptureProcessExclusion.none.processIDs.isEmpty)
  }

  @Test("HAL exclusion resolution includes the host and rejects missing explicit processes")
  func resolvesProcessObjectExclusions() throws {
    let host = try #require(AudioProcessID(rawValue: 7))
    let explicit = try #require(AudioProcessID(rawValue: 42))
    let missing = try #require(AudioProcessID(rawValue: 99))
    let processObjects: [AudioProcessID: AudioObjectID] = [
      host: 300,
      explicit: 200,
    ]

    let resolved = try CoreAudioDeviceOutputTapSupport.resolvedExcludedProcessObjectIDs(
      for: DeviceOutputCaptureProcessExclusion(processIDs: [explicit]),
      processObjects: processObjects,
      currentProcessID: host
    )
    #expect(resolved == [200, 300])

    let hostNotPublished = try CoreAudioDeviceOutputTapSupport.resolvedExcludedProcessObjectIDs(
      for: DeviceOutputCaptureProcessExclusion(),
      processObjects: [explicit: 200],
      currentProcessID: host
    )
    #expect(hostNotPublished.isEmpty)

    #expect(throws: DeviceOutputCaptureError.processNotFound(missing)) {
      try CoreAudioDeviceOutputTapSupport.resolvedExcludedProcessObjectIDs(
        for: DeviceOutputCaptureProcessExclusion(processIDs: [missing]),
        processObjects: processObjects,
        currentProcessID: host
      )
    }
  }

  @Test("Publishes the requested target and resolved device format")
  func publishesResolvedRuntimeFormat() throws {
    let requestedID = try #require(StableAudioDeviceID(rawValue: "requested-output"))
    let resolvedID = try #require(StableAudioDeviceID(rawValue: "resolved-output"))
    let resource = try StubDeviceOutputCaptureResource(
      format: captureFormat(deviceID: resolvedID)
    )
    let backend = StubDeviceOutputCaptureBackend(resource: resource)
    let capture = try DeviceOutputCapture(
      target: .device(requestedID),
      processExclusion: DeviceOutputCaptureProcessExclusion(),
      configuration: AudioMeterCaptureConfiguration(),
      backend: backend,
      snapshotHandler: { _ in }
    )

    #expect(capture.target == .device(requestedID))
    #expect(capture.processExclusion.excludesCurrentProcess)
    #expect(capture.deviceID == resolvedID)
    #expect(capture.format.deviceID == resolvedID)
    #expect(capture.format.streamIndex.rawValue == 0)
    #expect(capture.format.sampleRate == 48_000)
    #expect(capture.frameBuffer.format.channelCount == 2)
    for (index, channelID) in capture.format.channelIDs.enumerated() {
      #expect(channelID.ownerID == .source(.deviceOutput(resolvedID)))
      #expect(channelID.index.rawValue == index)
    }
    #expect(!capture.isRunning)
  }

  @Test("System default remains an explicit preparation target")
  func preservesDefaultTarget() throws {
    let resolvedID = try #require(StableAudioDeviceID(rawValue: "default-output"))
    let resource = try StubDeviceOutputCaptureResource(
      format: captureFormat(deviceID: resolvedID)
    )
    let backend = StubDeviceOutputCaptureBackend(resource: resource)
    let capture = try DeviceOutputCapture(
      target: .systemDefault,
      processExclusion: .none,
      configuration: AudioMeterCaptureConfiguration(),
      backend: backend,
      snapshotHandler: { _ in }
    )

    #expect(capture.target == .systemDefault)
    #expect(capture.processExclusion == .none)
    #expect(capture.deviceID == resolvedID)
    #expect(
      backend.requestedRequests() == [
        .init(target: .systemDefault, exclusion: .none)
      ]
    )
  }

  @Test("Start is idempotent while running and stop is terminal")
  func enforcesOneShotLifecycle() throws {
    let deviceID = try #require(StableAudioDeviceID(rawValue: "test-output"))
    let resource = try StubDeviceOutputCaptureResource(
      format: captureFormat(deviceID: deviceID)
    )
    let capture = try makeCapture(deviceID: deviceID, resource: resource)

    try capture.start()
    try capture.start()
    #expect(capture.isRunning)
    #expect(resource.startCallCount == 1)

    try capture.stop()
    #expect(!capture.isRunning)
    #expect(resource.stopCallCount == 1)
    #expect(throws: DeviceOutputCaptureError.alreadyStopped) {
      try capture.start()
    }
  }

  @Test("Start failure performs terminal resource cleanup")
  func cleansUpAfterStartFailure() throws {
    let deviceID = try #require(StableAudioDeviceID(rawValue: "test-output"))
    let failure = DeviceOutputCaptureError.hardware(
      operation: .startDevice,
      status: AudioHardwareStatus(rawValue: -50)
    )
    let resource = try StubDeviceOutputCaptureResource(
      format: captureFormat(deviceID: deviceID),
      startError: failure
    )
    let capture = try makeCapture(deviceID: deviceID, resource: resource)

    #expect(throws: failure) {
      try capture.start()
    }
    #expect(!capture.isRunning)
    #expect(resource.stopCallCount == 1)
    #expect(throws: DeviceOutputCaptureError.alreadyStopped) {
      try capture.start()
    }
  }

  @Test("Backend setup failures retain typed context")
  func propagatesBackendFailure() throws {
    let deviceID = try #require(StableAudioDeviceID(rawValue: "missing-output"))
    let failure = DeviceOutputCaptureError.deviceNotFound(deviceID)

    #expect(throws: failure) {
      _ = try DeviceOutputCapture(
        target: .device(deviceID),
        processExclusion: DeviceOutputCaptureProcessExclusion(),
        configuration: AudioMeterCaptureConfiguration(),
        backend: StubDeviceOutputCaptureBackend(error: failure),
        snapshotHandler: { _ in }
      )
    }
  }

  @Test("Stop failures leave the public lifecycle terminal")
  func retainsTerminalStateAfterStopFailure() throws {
    let deviceID = try #require(StableAudioDeviceID(rawValue: "test-output"))
    let failure = DeviceOutputCaptureError.hardware(
      operation: .destroyTap,
      status: AudioHardwareStatus(rawValue: -50)
    )
    let resource = try StubDeviceOutputCaptureResource(
      format: captureFormat(deviceID: deviceID),
      stopError: failure
    )
    let capture = try makeCapture(deviceID: deviceID, resource: resource)

    try capture.start()
    #expect(throws: failure) {
      try capture.stop()
    }
    #expect(!capture.isRunning)
    #expect(throws: DeviceOutputCaptureError.alreadyStopped) {
      try capture.start()
    }
  }

  private func makeCapture(
    deviceID: StableAudioDeviceID,
    resource: StubDeviceOutputCaptureResource
  ) throws -> DeviceOutputCapture {
    try DeviceOutputCapture(
      target: .device(deviceID),
      processExclusion: DeviceOutputCaptureProcessExclusion(),
      configuration: AudioMeterCaptureConfiguration(),
      backend: StubDeviceOutputCaptureBackend(resource: resource),
      snapshotHandler: { _ in }
    )
  }

  private func captureFormat(deviceID: StableAudioDeviceID) throws -> DeviceOutputCaptureFormat {
    let channelIDs = (0..<2).compactMap { rawIndex in
      AudioChannelIndex(rawValue: rawIndex).map {
        AudioChannelID(ownerID: .source(.deviceOutput(deviceID)), index: $0)
      }
    }
    return DeviceOutputCaptureFormat(
      deviceID: deviceID,
      streamIndex: try #require(AudioStreamIndex(rawValue: 0)),
      sampleRate: 48_000,
      channelIDs: channelIDs
    )
  }
}

private final class StubDeviceOutputCaptureBackend: DeviceOutputCaptureBackend, @unchecked Sendable
{
  struct Request: Equatable {
    let target: DeviceOutputCaptureTarget
    let exclusion: DeviceOutputCaptureProcessExclusion
  }

  private let lock = NSLock()
  private let result: Result<StubDeviceOutputCaptureResource, DeviceOutputCaptureError>
  private var requests: [Request] = []

  init(resource: StubDeviceOutputCaptureResource) {
    result = .success(resource)
  }

  init(error: DeviceOutputCaptureError) {
    result = .failure(error)
  }

  func makeResource(
    target: DeviceOutputCaptureTarget,
    processExclusion: DeviceOutputCaptureProcessExclusion,
    configuration: AudioMeterCaptureConfiguration,
    snapshotHandler: @escaping DeviceOutputCapture.SnapshotHandler
  ) throws -> any DeviceOutputCaptureResource {
    lock.withLock {
      requests.append(Request(target: target, exclusion: processExclusion))
    }
    return try result.get()
  }

  func requestedRequests() -> [Request] {
    lock.withLock { requests }
  }
}

private final class StubDeviceOutputCaptureResource:
  DeviceOutputCaptureResource, @unchecked Sendable
{
  let format: DeviceOutputCaptureFormat
  let frameBuffer: AudioRealtimeFrameBuffer

  private let lock = NSLock()
  private let startError: DeviceOutputCaptureError?
  private let stopError: DeviceOutputCaptureError?
  private var storedStartCallCount = 0
  private var storedStopCallCount = 0

  init(
    format: DeviceOutputCaptureFormat,
    startError: DeviceOutputCaptureError? = nil,
    stopError: DeviceOutputCaptureError? = nil
  ) throws {
    self.format = format
    frameBuffer = try AudioRealtimeFrameBuffer(
      format: try AudioProcessingFormat(
        sampleRate: format.sampleRate,
        channelCount: format.channelIDs.count
      )
    )
    self.startError = startError
    self.stopError = stopError
  }

  var startCallCount: Int {
    lock.withLock { storedStartCallCount }
  }

  var stopCallCount: Int {
    lock.withLock { storedStopCallCount }
  }

  func start() throws {
    try lock.withLock {
      storedStartCallCount += 1
      if let startError {
        throw startError
      }
    }
  }

  func stop() throws {
    try lock.withLock {
      storedStopCallCount += 1
      if let stopError {
        throw stopError
      }
    }
  }
}
