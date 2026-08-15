// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import Foundation
import Testing

@testable import RilliyaKit

private typealias StableAudioDeviceID = RilliyaKit.AudioDeviceID

@Suite("Device output playback lifecycle")
struct DeviceOutputPlaybackTests {
  @Test("Publishes stable destination format and one-shot lifecycle")
  func publishesFormatAndLifecycle() throws {
    let deviceID = try #require(StableAudioDeviceID(rawValue: "test-output-device"))
    let resource = StubDeviceOutputPlaybackResource(format: playbackFormat(deviceID: deviceID))
    let playback = try DeviceOutputPlayback(
      deviceID: deviceID,
      backend: StubDeviceOutputPlaybackBackend(resource: resource),
      rendererFactory: { preparation in StubPreparedAudioSource(preparation: preparation) },
      failureHandler: { _ in }
    )

    #expect(playback.deviceID == deviceID)
    #expect(playback.format.sampleRate == 48_000)
    #expect(playback.format.channelIDs.count == 2)
    #expect(!playback.isRunning)

    try playback.start()
    try playback.start()
    #expect(playback.isRunning)
    #expect(resource.startCallCount == 1)

    try playback.stop()
    #expect(!playback.isRunning)
    #expect(resource.stopCallCount == 1)
    #expect(throws: DeviceOutputPlaybackError.alreadyStopped) {
      try playback.start()
    }
  }

  @Test("Start failure performs terminal resource cleanup")
  func cleansUpAfterStartFailure() throws {
    let deviceID = try #require(StableAudioDeviceID(rawValue: "test-output-device"))
    let failure = DeviceOutputPlaybackError.hardware(
      operation: .startAudioUnit,
      status: AudioHardwareStatus(rawValue: -50)
    )
    let resource = StubDeviceOutputPlaybackResource(
      format: playbackFormat(deviceID: deviceID),
      startError: failure
    )
    let playback = try DeviceOutputPlayback(
      deviceID: deviceID,
      backend: StubDeviceOutputPlaybackBackend(resource: resource),
      rendererFactory: { preparation in StubPreparedAudioSource(preparation: preparation) },
      failureHandler: { _ in }
    )

    #expect(throws: failure) {
      try playback.start()
    }
    #expect(resource.stopCallCount == 1)
    #expect(throws: DeviceOutputPlaybackError.alreadyStopped) {
      try playback.start()
    }
  }

  @Test("AUHAL output client format is planar native Float32")
  func buildsOutputClientFormat() {
    let format = CoreAudioDeviceOutputClientFormat.make(
      sampleRate: 96_000,
      channelCount: 8
    )

    #expect(format.mSampleRate == 96_000)
    #expect(format.mFormatID == kAudioFormatLinearPCM)
    #expect(format.mFramesPerPacket == 1)
    #expect(format.mBytesPerPacket == UInt32(MemoryLayout<Float>.stride))
    #expect(format.mBytesPerFrame == UInt32(MemoryLayout<Float>.stride))
    #expect(format.mChannelsPerFrame == 8)
    #expect(format.mBitsPerChannel == 32)
    #expect(format.mFormatFlags & kAudioFormatFlagIsFloat != 0)
    #expect(format.mFormatFlags & kAudioFormatFlagIsPacked != 0)
    #expect(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0)
  }

  private func playbackFormat(deviceID: StableAudioDeviceID) -> DeviceOutputPlaybackFormat {
    let channelIDs = (0..<2).compactMap { index in
      AudioChannelIndex(rawValue: index).map {
        AudioChannelID(ownerID: .destination(.deviceOutput(deviceID)), index: $0)
      }
    }
    return DeviceOutputPlaybackFormat(
      deviceID: deviceID,
      sampleRate: 48_000,
      channelIDs: channelIDs,
      maximumFrameCount: 512
    )
  }
}

private struct StubDeviceOutputPlaybackBackend: DeviceOutputPlaybackBackend {
  let resource: StubDeviceOutputPlaybackResource

  func makeResource(
    deviceID: StableAudioDeviceID,
    rendererFactory: @escaping DeviceOutputPlayback.RendererFactory,
    failureHandler: @escaping DeviceOutputPlayback.FailureHandler
  ) throws -> any DeviceOutputPlaybackResource {
    resource
  }
}

private final class StubDeviceOutputPlaybackResource:
  DeviceOutputPlaybackResource, @unchecked Sendable
{
  let format: DeviceOutputPlaybackFormat

  private let lock = NSLock()
  private let startError: DeviceOutputPlaybackError?
  private var storedStartCallCount = 0
  private var storedStopCallCount = 0

  init(
    format: DeviceOutputPlaybackFormat,
    startError: DeviceOutputPlaybackError? = nil
  ) {
    self.format = format
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

private final class StubPreparedAudioSource: PreparedAudioSource, @unchecked Sendable {
  let preparation: AudioRenderPreparation
  let timing = AudioNodeTiming.transparent

  init(preparation: AudioRenderPreparation) {
    self.preparation = preparation
  }

  func render(
    outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRenderResult {
    .rendered
  }
}
