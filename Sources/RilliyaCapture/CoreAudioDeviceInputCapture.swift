// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import AudioUnit
import CoreAudio
import Dispatch
import Foundation
import RilliyaCore
import RilliyaRealtime
import os.lock

@available(macOS 14.2, *)
struct CoreAudioDeviceInputCaptureBackend: DeviceInputCaptureBackend {
  func makeResource(
    deviceID: RilliyaCore.AudioDeviceID,
    configuration: AudioMeterCaptureConfiguration,
    snapshotHandler: @escaping DeviceInputCapture.SnapshotHandler,
    failureHandler: @escaping DeviceInputCapture.FailureHandler
  ) throws -> any DeviceInputCaptureResource {
    try CoreAudioDeviceInputCaptureResource(
      deviceID: deviceID,
      configuration: configuration,
      snapshotHandler: snapshotHandler,
      failureHandler: failureHandler
    )
  }
}

enum CoreAudioDeviceInputClientFormat {
  static func make(
    sampleRate: Double,
    channelCount: UInt32
  ) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
      mBytesPerPacket: UInt32(MemoryLayout<Float32>.stride),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(MemoryLayout<Float32>.stride),
      mChannelsPerFrame: channelCount,
      mBitsPerChannel: 32,
      mReserved: 0
    )
  }
}

private enum CoreAudioDeviceInputLimits {
  static let maximumChannelCount: UInt32 = 256
  static let maximumFramesPerSlice: UInt32 = 65_536
}

@available(macOS 14.2, *)
private final class CoreAudioDeviceInputCaptureResource:
  DeviceInputCaptureResource, @unchecked Sendable
{
  let format: DeviceInputCaptureFormat
  let frameBuffer: AudioRealtimeFrameBuffer

  private let lock = NSLock()
  private let meterBridge: RealtimeMeterBridge
  private let failureBridge: DeviceInputFailureBridge
  private let renderStorage: DeviceInputRenderStorage
  private var audioUnit: AudioUnit?
  private var isInitialized = false
  private var isRunning = false

  init(
    deviceID: RilliyaCore.AudioDeviceID,
    configuration: AudioMeterCaptureConfiguration,
    snapshotHandler: @escaping DeviceInputCapture.SnapshotHandler,
    failureHandler: @escaping DeviceInputCapture.FailureHandler
  ) throws {
    let deviceObjectID = try Self.deviceObjectID(for: deviceID)
    guard try Self.deviceIsAlive(deviceObjectID) else {
      throw DeviceInputCaptureError.deviceUnavailable(deviceID)
    }
    let newAudioUnit = try Self.makeAudioUnit()
    var setupSucceeded = false
    defer {
      if !setupSucceeded {
        AudioUnitUninitialize(newAudioUnit)
        AudioComponentInstanceDispose(newAudioUnit)
      }
    }

    try Self.setEnabled(true, scope: kAudioUnitScope_Input, element: 1, on: newAudioUnit)
    try Self.setEnabled(false, scope: kAudioUnitScope_Output, element: 0, on: newAudioUnit)
    try Self.select(deviceObjectID, on: newAudioUnit)
    guard try Self.hasInput(on: newAudioUnit) else {
      throw DeviceInputCaptureError.noInputChannels(deviceID)
    }

    let deviceFormat = try Self.streamFormat(
      scope: kAudioUnitScope_Input,
      element: 1,
      operation: .readDeviceFormat,
      on: newAudioUnit
    )
    guard deviceFormat.mChannelsPerFrame > 0 else {
      throw DeviceInputCaptureError.noInputChannels(deviceID)
    }
    guard
      deviceFormat.mSampleRate.isFinite,
      deviceFormat.mSampleRate > 0,
      deviceFormat.mChannelsPerFrame <= CoreAudioDeviceInputLimits.maximumChannelCount
    else {
      throw DeviceInputCaptureError.unsupportedFormat(deviceID)
    }

    let clientFormat = CoreAudioDeviceInputClientFormat.make(
      sampleRate: deviceFormat.mSampleRate,
      channelCount: deviceFormat.mChannelsPerFrame
    )
    try Self.setStreamFormat(clientFormat, on: newAudioUnit)
    let maximumFrames = try Self.maximumFramesPerSlice(on: newAudioUnit)
    guard
      maximumFrames > 0,
      maximumFrames <= CoreAudioDeviceInputLimits.maximumFramesPerSlice
    else {
      throw DeviceInputCaptureError.unsupportedFormat(deviceID)
    }

    let channelIDs = (0..<Int(clientFormat.mChannelsPerFrame)).compactMap { index in
      AudioChannelIndex(rawValue: index).map {
        AudioChannelID(ownerID: .source(.deviceInput(deviceID)), index: $0)
      }
    }
    guard channelIDs.count == Int(clientFormat.mChannelsPerFrame) else {
      throw DeviceInputCaptureError.unsupportedFormat(deviceID)
    }
    let captureFormat = DeviceInputCaptureFormat(
      deviceID: deviceID,
      sampleRate: clientFormat.mSampleRate,
      channelIDs: channelIDs
    )
    let processingFormat = try AudioProcessingFormat(
      sampleRate: captureFormat.sampleRate,
      channelCount: captureFormat.channelIDs.count
    )
    let frameBuffer = try AudioRealtimeFrameBuffer(format: processingFormat)
    let storage = DeviceInputRenderStorage(
      channelCount: channelIDs.count,
      maximumFrames: Int(maximumFrames)
    )
    let meterBridge = RealtimeMeterBridge(
      sampleRate: captureFormat.sampleRate,
      channelIDs: captureFormat.channelIDs,
      configuration: configuration,
      snapshotHandler: { sequence, frameCount, channels in
        snapshotHandler(
          DeviceInputMeterSnapshot(
            format: captureFormat,
            sequence: sequence,
            frameCount: frameCount,
            channels: channels
          )
        )
      }
    )
    let failureBridge = DeviceInputFailureBridge(handler: failureHandler)

    format = captureFormat
    self.frameBuffer = frameBuffer
    renderStorage = storage
    self.meterBridge = meterBridge
    self.failureBridge = failureBridge
    audioUnit = newAudioUnit

    var callback = AURenderCallbackStruct(
      inputProc: { reference, flags, timestamp, _, frameCount, _ in
        return Unmanaged<CoreAudioDeviceInputCaptureResource>
          .fromOpaque(reference)
          .takeUnretainedValue()
          .render(flags: flags, timestamp: timestamp, frameCount: frameCount)
      },
      inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
    )
    try Self.check(
      AudioUnitSetProperty(
        newAudioUnit,
        kAudioOutputUnitProperty_SetInputCallback,
        kAudioUnitScope_Global,
        0,
        &callback,
        UInt32(MemoryLayout<AURenderCallbackStruct>.size)
      ),
      operation: .setInputCallback
    )
    try Self.check(AudioUnitInitialize(newAudioUnit), operation: .initializeAudioUnit)
    isInitialized = true
    setupSucceeded = true
  }

  deinit {
    try? stop()
  }

  func start() throws {
    lock.lock()
    defer { lock.unlock() }
    guard let audioUnit, isInitialized else {
      throw DeviceInputCaptureError.alreadyStopped
    }
    guard !isRunning else { return }
    try Self.check(AudioOutputUnitStart(audioUnit), operation: .startAudioUnit)
    isRunning = true
  }

  func stop() throws {
    lock.lock()
    defer { lock.unlock() }
    meterBridge.stopPublishing()
    failureBridge.stopPublishing()

    guard let retainedAudioUnit = audioUnit else { return }
    var firstError: DeviceInputCaptureError?
    if isRunning {
      firstError = Self.cleanupError(
        AudioOutputUnitStop(retainedAudioUnit),
        operation: .stopAudioUnit,
        retaining: firstError
      )
    }
    isRunning = false
    if isInitialized {
      firstError = Self.cleanupError(
        AudioUnitUninitialize(retainedAudioUnit),
        operation: .uninitializeAudioUnit,
        retaining: firstError
      )
    }
    isInitialized = false
    let disposeStatus = AudioComponentInstanceDispose(retainedAudioUnit)
    firstError = Self.cleanupError(
      disposeStatus,
      operation: .disposeAudioUnit,
      retaining: firstError
    )
    if disposeStatus == noErr {
      audioUnit = nil
    }
    if let firstError {
      throw firstError
    }
  }

  private func render(
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timestamp: UnsafePointer<AudioTimeStamp>,
    frameCount: UInt32
  ) -> OSStatus {
    guard let audioUnit,
      let buffers = renderStorage.prepare(frameCount: frameCount)
    else {
      failureBridge.report(status: kAudio_ParamError)
      return kAudio_ParamError
    }
    let status = AudioUnitRender(
      audioUnit,
      flags,
      timestamp,
      1,
      frameCount,
      buffers
    )
    guard status == noErr else {
      failureBridge.report(status: status)
      return status
    }
    frameBuffer.write(UnsafePointer(buffers))
    meterBridge.consume(UnsafePointer(buffers))
    return noErr
  }

  private static func deviceObjectID(
    for deviceID: RilliyaCore.AudioDeviceID
  ) throws -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var uid = deviceID.rawValue as CFString
    var objectID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = withUnsafePointer(to: &uid) { qualifier in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        UInt32(MemoryLayout<CFString>.size),
        qualifier,
        &size,
        &objectID
      )
    }
    try check(status, operation: .resolveDevice)
    guard size == UInt32(MemoryLayout<AudioObjectID>.size) else {
      throw DeviceInputCaptureError.invalidPropertyData(operation: .resolveDevice)
    }
    guard objectID != kAudioObjectUnknown else {
      throw DeviceInputCaptureError.deviceNotFound(deviceID)
    }
    return objectID
  }

  private static func deviceIsAlive(_ deviceObjectID: AudioObjectID) throws -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsAlive,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(
      deviceObjectID,
      &address,
      0,
      nil,
      &size,
      &value
    )
    try check(status, operation: .readDeviceAvailability)
    guard size == UInt32(MemoryLayout<UInt32>.size) else {
      throw DeviceInputCaptureError.invalidPropertyData(operation: .readDeviceAvailability)
    }
    return value != 0
  }

  private static func makeAudioUnit() throws -> AudioUnit {
    var description = AudioComponentDescription(
      componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_HALOutput,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0,
      componentFlagsMask: 0
    )
    guard let component = AudioComponentFindNext(nil, &description) else {
      throw DeviceInputCaptureError.hardware(
        operation: .createAudioUnit,
        status: AudioHardwareStatus(rawValue: kAudio_ParamError)
      )
    }
    var instance: AudioUnit?
    try check(AudioComponentInstanceNew(component, &instance), operation: .createAudioUnit)
    guard let instance else {
      throw DeviceInputCaptureError.hardware(
        operation: .createAudioUnit,
        status: AudioHardwareStatus(rawValue: kAudio_ParamError)
      )
    }
    return instance
  }

  private static func setEnabled(
    _ enabled: Bool,
    scope: AudioUnitScope,
    element: AudioUnitElement,
    on audioUnit: AudioUnit
  ) throws {
    var value: UInt32 = enabled ? 1 : 0
    try check(
      AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_EnableIO,
        scope,
        element,
        &value,
        UInt32(MemoryLayout<UInt32>.size)
      ),
      operation: enabled ? .enableInput : .disableOutput
    )
  }

  private static func select(_ deviceObjectID: AudioObjectID, on audioUnit: AudioUnit) throws {
    var objectID = deviceObjectID
    try check(
      AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &objectID,
        UInt32(MemoryLayout<AudioObjectID>.size)
      ),
      operation: .selectDevice
    )
  }

  private static func hasInput(on audioUnit: AudioUnit) throws -> Bool {
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    try check(
      AudioUnitGetProperty(
        audioUnit,
        kAudioOutputUnitProperty_HasIO,
        kAudioUnitScope_Input,
        1,
        &value,
        &size
      ),
      operation: .readInputAvailability
    )
    guard size == UInt32(MemoryLayout<UInt32>.size) else {
      throw DeviceInputCaptureError.invalidPropertyData(operation: .readInputAvailability)
    }
    return value != 0
  }

  private static func streamFormat(
    scope: AudioUnitScope,
    element: AudioUnitElement,
    operation: DeviceInputCaptureOperation,
    on audioUnit: AudioUnit
  ) throws -> AudioStreamBasicDescription {
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try check(
      AudioUnitGetProperty(
        audioUnit,
        kAudioUnitProperty_StreamFormat,
        scope,
        element,
        &format,
        &size
      ),
      operation: operation
    )
    guard size == UInt32(MemoryLayout<AudioStreamBasicDescription>.size) else {
      throw DeviceInputCaptureError.invalidPropertyData(operation: operation)
    }
    return format
  }

  private static func setStreamFormat(
    _ clientFormat: AudioStreamBasicDescription,
    on audioUnit: AudioUnit
  ) throws {
    var format = clientFormat
    try check(
      AudioUnitSetProperty(
        audioUnit,
        kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Output,
        1,
        &format,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      ),
      operation: .setClientFormat
    )
  }

  private static func maximumFramesPerSlice(on audioUnit: AudioUnit) throws -> UInt32 {
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    try check(
      AudioUnitGetProperty(
        audioUnit,
        kAudioUnitProperty_MaximumFramesPerSlice,
        kAudioUnitScope_Global,
        0,
        &value,
        &size
      ),
      operation: .readMaximumFrames
    )
    guard size == UInt32(MemoryLayout<UInt32>.size) else {
      throw DeviceInputCaptureError.invalidPropertyData(operation: .readMaximumFrames)
    }
    return value
  }

  private static func check(
    _ status: OSStatus,
    operation: DeviceInputCaptureOperation
  ) throws {
    guard status != noErr else { return }
    throw deviceInputCaptureError(status: status, operation: operation)
  }

  private static func cleanupError(
    _ status: OSStatus,
    operation: DeviceInputCaptureOperation,
    retaining firstError: DeviceInputCaptureError?
  ) -> DeviceInputCaptureError? {
    guard status != noErr else { return firstError }
    return firstError
      ?? .hardware(operation: operation, status: AudioHardwareStatus(rawValue: status))
  }
}

@available(macOS 14.2, *)
private final class DeviceInputRenderStorage: @unchecked Sendable {
  private let maximumFrames: UInt32
  private let bufferList: UnsafeMutableAudioBufferListPointer
  private let channelStorage: [UnsafeMutableRawPointer]

  init(channelCount: Int, maximumFrames: Int) {
    self.maximumFrames = UInt32(maximumFrames)
    bufferList = AudioBufferList.allocate(maximumBuffers: channelCount)
    let byteCount = maximumFrames * MemoryLayout<Float32>.stride
    channelStorage = (0..<channelCount).map { _ in
      UnsafeMutableRawPointer.allocate(
        byteCount: byteCount,
        alignment: MemoryLayout<Float32>.alignment
      )
    }
    bufferList.count = channelCount
    for index in 0..<channelCount {
      bufferList[index] = AudioBuffer(
        mNumberChannels: 1,
        mDataByteSize: UInt32(byteCount),
        mData: channelStorage[index]
      )
    }
  }

  deinit {
    for storage in channelStorage {
      storage.deallocate()
    }
    bufferList.unsafeMutablePointer.deallocate()
  }

  func prepare(frameCount: UInt32) -> UnsafeMutablePointer<AudioBufferList>? {
    guard frameCount <= maximumFrames else { return nil }
    let byteCount = frameCount * UInt32(MemoryLayout<Float32>.stride)
    for index in bufferList.indices {
      bufferList[index].mDataByteSize = byteCount
    }
    return bufferList.unsafeMutablePointer
  }
}

@available(macOS 14.2, *)
private final class DeviceInputFailureBridge: @unchecked Sendable {
  private let handler: DeviceInputCapture.FailureHandler
  private let deliverySource: DispatchSourceUserDataAdd
  private var lock = os_unfair_lock_s()
  private var retainedStatus: OSStatus?
  private var isPublishing = true
  private var hasPublished = false

  init(handler: @escaping DeviceInputCapture.FailureHandler) {
    self.handler = handler
    let queue = DispatchQueue(
      label: "moe.uwucocoa.rilliyakit.device-input.failure",
      qos: .userInitiated
    )
    deliverySource = DispatchSource.makeUserDataAddSource(queue: queue)
    deliverySource.setEventHandler { [weak self] in
      self?.publishFailure()
    }
    deliverySource.resume()
  }

  deinit {
    deliverySource.setEventHandler {}
    deliverySource.cancel()
  }

  func report(status: OSStatus) {
    guard os_unfair_lock_trylock(&lock) else { return }
    guard isPublishing, retainedStatus == nil else {
      os_unfair_lock_unlock(&lock)
      return
    }
    retainedStatus = status
    os_unfair_lock_unlock(&lock)
    deliverySource.add(data: 1)
  }

  func stopPublishing() {
    os_unfair_lock_lock(&lock)
    isPublishing = false
    os_unfair_lock_unlock(&lock)
  }

  private func publishFailure() {
    os_unfair_lock_lock(&lock)
    guard isPublishing, !hasPublished, let status = retainedStatus else {
      os_unfair_lock_unlock(&lock)
      return
    }
    hasPublished = true
    os_unfair_lock_unlock(&lock)
    handler(
      deviceInputCaptureError(status: status, operation: .renderInput)
    )
  }
}

private func deviceInputCaptureError(
  status: OSStatus,
  operation: DeviceInputCaptureOperation
) -> DeviceInputCaptureError {
  if status == kAudioUnitErr_Unauthorized || status == kAudioComponentErr_NotPermitted {
    return .permissionDenied
  }
  return .hardware(
    operation: operation,
    status: AudioHardwareStatus(rawValue: status)
  )
}
