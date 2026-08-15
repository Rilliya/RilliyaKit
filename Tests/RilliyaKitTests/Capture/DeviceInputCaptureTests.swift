// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import Foundation
import Testing

@testable import RilliyaKit

private typealias StableAudioDeviceID = RilliyaKit.AudioDeviceID

@Suite("Device input capture lifecycle")
struct DeviceInputCaptureTests {
  @Test("Publishes a stable device and channel format")
  func publishesStableRuntimeFormat() throws {
    let deviceID = try #require(StableAudioDeviceID(rawValue: "test-input-device"))
    let resource = try StubDeviceInputCaptureResource(
      format: captureFormat(deviceID: deviceID)
    )
    let capture = try DeviceInputCapture(
      deviceID: deviceID,
      configuration: AudioMeterCaptureConfiguration(),
      backend: StubDeviceInputCaptureBackend(resource: resource),
      snapshotHandler: { _ in },
      failureHandler: { _ in }
    )

    #expect(capture.deviceID == deviceID)
    #expect(capture.format.deviceID == deviceID)
    #expect(capture.format.sampleRate == 48_000)
    #expect(capture.format.channelIDs.count == 2)
    #expect(capture.frameBuffer.format.channelCount == 2)
    for (index, channelID) in capture.format.channelIDs.enumerated() {
      #expect(channelID.ownerID == .source(.deviceInput(deviceID)))
      #expect(channelID.index.rawValue == index)
    }
    #expect(!capture.isRunning)
  }

  @Test("Start is idempotent while running and stop is terminal")
  func enforcesOneShotLifecycle() throws {
    let deviceID = try #require(StableAudioDeviceID(rawValue: "test-input-device"))
    let resource = try StubDeviceInputCaptureResource(
      format: captureFormat(deviceID: deviceID)
    )
    let capture = try DeviceInputCapture(
      deviceID: deviceID,
      configuration: AudioMeterCaptureConfiguration(),
      backend: StubDeviceInputCaptureBackend(resource: resource),
      snapshotHandler: { _ in },
      failureHandler: { _ in }
    )

    try capture.start()
    try capture.start()
    #expect(capture.isRunning)
    #expect(resource.startCallCount == 1)

    try capture.stop()
    #expect(!capture.isRunning)
    #expect(resource.stopCallCount == 1)
    #expect(throws: DeviceInputCaptureError.alreadyStopped) {
      try capture.start()
    }
  }

  @Test("Start failure performs terminal resource cleanup")
  func cleansUpAfterStartFailure() throws {
    let deviceID = try #require(StableAudioDeviceID(rawValue: "test-input-device"))
    let failure = DeviceInputCaptureError.hardware(
      operation: .startAudioUnit,
      status: AudioHardwareStatus(rawValue: -50)
    )
    let resource = try StubDeviceInputCaptureResource(
      format: captureFormat(deviceID: deviceID),
      startError: failure
    )
    let capture = try DeviceInputCapture(
      deviceID: deviceID,
      configuration: AudioMeterCaptureConfiguration(),
      backend: StubDeviceInputCaptureBackend(resource: resource),
      snapshotHandler: { _ in },
      failureHandler: { _ in }
    )

    #expect(throws: failure) {
      try capture.start()
    }
    #expect(!capture.isRunning)
    #expect(resource.stopCallCount == 1)
    #expect(throws: DeviceInputCaptureError.alreadyStopped) {
      try capture.start()
    }
  }

  @Test("Backend setup failures retain typed context")
  func propagatesBackendFailure() throws {
    let deviceID = try #require(StableAudioDeviceID(rawValue: "missing-input-device"))
    let failure = DeviceInputCaptureError.deviceNotFound(deviceID)

    #expect(throws: failure) {
      _ = try DeviceInputCapture(
        deviceID: deviceID,
        configuration: AudioMeterCaptureConfiguration(),
        backend: StubDeviceInputCaptureBackend(error: failure),
        snapshotHandler: { _ in },
        failureHandler: { _ in }
      )
    }
  }

  @Test("Stop failures leave the public lifecycle terminal")
  func retainsTerminalStateAfterStopFailure() throws {
    let deviceID = try #require(StableAudioDeviceID(rawValue: "test-input-device"))
    let failure = DeviceInputCaptureError.hardware(
      operation: .disposeAudioUnit,
      status: AudioHardwareStatus(rawValue: -50)
    )
    let resource = try StubDeviceInputCaptureResource(
      format: captureFormat(deviceID: deviceID),
      stopError: failure
    )
    let capture = try DeviceInputCapture(
      deviceID: deviceID,
      configuration: AudioMeterCaptureConfiguration(),
      backend: StubDeviceInputCaptureBackend(resource: resource),
      snapshotHandler: { _ in },
      failureHandler: { _ in }
    )

    try capture.start()
    #expect(throws: failure) {
      try capture.stop()
    }
    #expect(!capture.isRunning)
    #expect(throws: DeviceInputCaptureError.alreadyStopped) {
      try capture.start()
    }
  }

  @Test("AUHAL client format is planar native Float32")
  func buildsBoundedClientFormat() {
    let format = CoreAudioDeviceInputClientFormat.make(
      sampleRate: 96_000,
      channelCount: 6
    )

    #expect(format.mSampleRate == 96_000)
    #expect(format.mFormatID == kAudioFormatLinearPCM)
    #expect(format.mFramesPerPacket == 1)
    #expect(format.mBytesPerPacket == UInt32(MemoryLayout<Float32>.stride))
    #expect(format.mBytesPerFrame == UInt32(MemoryLayout<Float32>.stride))
    #expect(format.mChannelsPerFrame == 6)
    #expect(format.mBitsPerChannel == 32)
    #expect(format.mFormatFlags & kAudioFormatFlagIsFloat != 0)
    #expect(
      format.mFormatFlags & kAudioFormatFlagIsBigEndian == kAudioFormatFlagsNativeEndian
    )
    #expect(format.mFormatFlags & kAudioFormatFlagIsPacked != 0)
    #expect(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0)
  }

  private func captureFormat(deviceID: StableAudioDeviceID) -> DeviceInputCaptureFormat {
    let channelIDs = (0..<2).compactMap { rawIndex in
      AudioChannelIndex(rawValue: rawIndex).map {
        AudioChannelID(ownerID: .source(.deviceInput(deviceID)), index: $0)
      }
    }
    return DeviceInputCaptureFormat(
      deviceID: deviceID,
      sampleRate: 48_000,
      channelIDs: channelIDs
    )
  }
}

private struct StubDeviceInputCaptureBackend: DeviceInputCaptureBackend {
  private let result: Result<StubDeviceInputCaptureResource, DeviceInputCaptureError>

  init(resource: StubDeviceInputCaptureResource) {
    result = .success(resource)
  }

  init(error: DeviceInputCaptureError) {
    result = .failure(error)
  }

  func makeResource(
    deviceID: StableAudioDeviceID,
    configuration: AudioMeterCaptureConfiguration,
    snapshotHandler: @escaping DeviceInputCapture.SnapshotHandler,
    failureHandler: @escaping DeviceInputCapture.FailureHandler
  ) throws -> any DeviceInputCaptureResource {
    try result.get()
  }
}

private final class StubDeviceInputCaptureResource:
  DeviceInputCaptureResource, @unchecked Sendable
{
  let format: DeviceInputCaptureFormat
  let frameBuffer: AudioRealtimeFrameBuffer

  private let lock = NSLock()
  private let startError: DeviceInputCaptureError?
  private let stopError: DeviceInputCaptureError?
  private var storedStartCallCount = 0
  private var storedStopCallCount = 0

  init(
    format: DeviceInputCaptureFormat,
    startError: DeviceInputCaptureError? = nil,
    stopError: DeviceInputCaptureError? = nil
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
    lock.lock()
    defer { lock.unlock() }
    return storedStartCallCount
  }

  var stopCallCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedStopCallCount
  }

  func start() throws {
    lock.lock()
    defer { lock.unlock() }
    storedStartCallCount += 1
    if let startError {
      throw startError
    }
  }

  func stop() throws {
    lock.lock()
    defer { lock.unlock() }
    storedStopCallCount += 1
    if let stopError {
      throw stopError
    }
  }
}
