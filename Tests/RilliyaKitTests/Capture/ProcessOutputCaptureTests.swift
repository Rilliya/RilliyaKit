// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RilliyaKit

@Suite("Process output capture lifecycle")
struct ProcessOutputCaptureTests {
  @Test("Publishes runtime format without exposing Core Audio object identifiers")
  func publishesRuntimeFormat() throws {
    let processID = try #require(AudioProcessID(rawValue: 42))
    let resource = try StubProcessOutputCaptureResource(
      format: captureFormat(processID: processID)
    )
    let capture = try ProcessOutputCapture(
      processID: processID,
      configuration: ProcessOutputCaptureConfiguration(),
      backend: StubProcessOutputCaptureBackend(resource: resource),
      snapshotHandler: { _ in }
    )

    #expect(capture.processID == processID)
    #expect(capture.format.sampleRate == 48_000)
    #expect(capture.format.channelIDs.count == 2)
    #expect(capture.frameBuffer.format.channelCount == 2)
    #expect(!capture.isRunning)
  }

  @Test("Start is idempotent while running and stop is terminal")
  func enforcesOneShotLifecycle() throws {
    let processID = try #require(AudioProcessID(rawValue: 42))
    let resource = try StubProcessOutputCaptureResource(
      format: captureFormat(processID: processID)
    )
    let capture = try ProcessOutputCapture(
      processID: processID,
      configuration: ProcessOutputCaptureConfiguration(),
      backend: StubProcessOutputCaptureBackend(resource: resource),
      snapshotHandler: { _ in }
    )

    try capture.start()
    try capture.start()
    #expect(capture.isRunning)
    #expect(resource.startCallCount == 1)

    try capture.stop()
    #expect(!capture.isRunning)
    #expect(resource.stopCallCount == 1)
    #expect(throws: ProcessOutputCaptureError.alreadyStopped) {
      try capture.start()
    }
  }

  @Test("Start failure triggers terminal resource cleanup")
  func cleansUpAfterStartFailure() throws {
    let processID = try #require(AudioProcessID(rawValue: 42))
    let failure = ProcessOutputCaptureError.hardware(
      operation: .startDevice,
      status: AudioHardwareStatus(rawValue: -50)
    )
    let resource = try StubProcessOutputCaptureResource(
      format: captureFormat(processID: processID),
      startError: failure
    )
    let capture = try ProcessOutputCapture(
      processID: processID,
      configuration: ProcessOutputCaptureConfiguration(),
      backend: StubProcessOutputCaptureBackend(resource: resource),
      snapshotHandler: { _ in }
    )

    #expect(throws: failure) {
      try capture.start()
    }
    #expect(!capture.isRunning)
    #expect(resource.stopCallCount == 1)
    #expect(throws: ProcessOutputCaptureError.alreadyStopped) {
      try capture.start()
    }
  }

  private func captureFormat(processID: AudioProcessID) -> ProcessOutputCaptureFormat {
    let channelIDs = (0..<2).compactMap { rawIndex in
      AudioChannelIndex(rawValue: rawIndex).map {
        AudioChannelID(ownerID: .source(.processOutput(processID)), index: $0)
      }
    }
    return ProcessOutputCaptureFormat(
      processID: processID,
      sampleRate: 48_000,
      channelIDs: channelIDs
    )
  }
}

private struct StubProcessOutputCaptureBackend: ProcessOutputCaptureBackend {
  let resource: StubProcessOutputCaptureResource

  func makeResource(
    processID: AudioProcessID,
    configuration: ProcessOutputCaptureConfiguration,
    snapshotHandler: @escaping ProcessOutputCapture.SnapshotHandler
  ) throws -> any ProcessOutputCaptureResource {
    resource
  }
}

private final class StubProcessOutputCaptureResource:
  ProcessOutputCaptureResource, @unchecked Sendable
{
  let format: ProcessOutputCaptureFormat
  let frameBuffer: AudioRealtimeFrameBuffer

  private let lock = NSLock()
  private let startError: ProcessOutputCaptureError?
  private var storedStartCallCount = 0
  private var storedStopCallCount = 0

  init(
    format: ProcessOutputCaptureFormat,
    startError: ProcessOutputCaptureError? = nil
  ) throws {
    self.format = format
    frameBuffer = try AudioRealtimeFrameBuffer(
      format: try AudioProcessingFormat(
        sampleRate: format.sampleRate,
        channelCount: format.channelIDs.count
      )
    )
    self.startError = startError
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
  }
}
