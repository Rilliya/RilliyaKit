// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import CoreAudio
import Dispatch
import Foundation
import os.lock

/// The runtime format prepared for one physical or virtual Core Audio output device.
public struct DeviceOutputPlaybackFormat: Hashable, Sendable {
  /// The persistent identity of the destination device.
  public let deviceID: AudioDeviceID

  /// The number of sample frames rendered each second.
  public let sampleRate: Double

  /// The stable output-channel identities in client render order.
  public let channelIDs: [AudioChannelID]

  /// The largest frame count accepted by one device render callback.
  public let maximumFrameCount: Int

  /// Creates a prepared output-device format.
  public init(
    deviceID: AudioDeviceID,
    sampleRate: Double,
    channelIDs: [AudioChannelID],
    maximumFrameCount: Int
  ) {
    self.deviceID = deviceID
    self.sampleRate = sampleRate
    self.channelIDs = channelIDs
    self.maximumFrameCount = maximumFrameCount
  }
}

/// A stage of the native output-device playback lifecycle.
public enum DeviceOutputPlaybackOperation: String, Hashable, Sendable {
  /// Translating a persistent device UID to its current Core Audio object.
  case resolveDevice

  /// Reading whether the selected device is available for IO.
  case readDeviceAvailability

  /// Creating the HAL output audio unit.
  case createAudioUnit

  /// Disabling the unused input bus.
  case disableInput

  /// Selecting the requested Core Audio device.
  case selectDevice

  /// Reading whether the device publishes an output bus.
  case readOutputAvailability

  /// Reading the device output format.
  case readDeviceFormat

  /// Setting the planar Float32 client format.
  case setClientFormat

  /// Reading the largest output render quantum.
  case readMaximumFrames

  /// Installing the output render callback.
  case setRenderCallback

  /// Initializing the HAL output audio unit.
  case initializeAudioUnit

  /// Starting output-device IO.
  case startAudioUnit

  /// Rendering output frames.
  case renderOutput

  /// Stopping output-device IO.
  case stopAudioUnit

  /// Uninitializing the HAL output audio unit.
  case uninitializeAudioUnit

  /// Disposing the HAL output audio unit.
  case disposeAudioUnit
}

/// A typed failure from output-device setup, rendering, or lifecycle management.
public enum DeviceOutputPlaybackError: Error, Equatable, LocalizedError, Sendable {
  /// Core Audio does not currently publish a device with the requested UID.
  case deviceNotFound(AudioDeviceID)

  /// The requested device is present but unavailable for IO.
  case deviceUnavailable(AudioDeviceID)

  /// The requested device publishes no output channels.
  case noOutputChannels(AudioDeviceID)

  /// The device format cannot be represented by this bounded playback path.
  case unsupportedFormat(AudioDeviceID)

  /// The prepared renderer does not match the device format or maximum quantum.
  case incompatibleRenderer

  /// A stopped playback session cannot be started again.
  case alreadyStopped

  /// Core Audio returned a nonzero status during a lifecycle operation.
  case hardware(operation: DeviceOutputPlaybackOperation, status: AudioHardwareStatus)

  /// The prepared renderer rejected a realtime output quantum.
  case renderer(AudioRenderResult)

  /// A human-readable description that retains native failure context.
  public var errorDescription: String? {
    switch self {
    case .deviceNotFound(let deviceID):
      return "Core Audio does not publish output device \(deviceID.rawValue)."
    case .deviceUnavailable(let deviceID):
      return "Output device \(deviceID.rawValue) is not currently available."
    case .noOutputChannels(let deviceID):
      return "Output device \(deviceID.rawValue) does not publish any output channels."
    case .unsupportedFormat(let deviceID):
      return "Output device \(deviceID.rawValue) does not publish a supported runtime format."
    case .incompatibleRenderer:
      return "The prepared audio renderer does not match the output-device render contract."
    case .alreadyStopped:
      return "A stopped output-device playback session cannot be restarted."
    case .hardware(let operation, let status):
      let code =
        status.fourCharacterCode.map { "\(status.rawValue) ('\($0)')" }
        ?? String(status.rawValue)
      return "Core Audio failed to \(operation.description): OSStatus \(code)."
    case .renderer(let result):
      return "The prepared audio renderer rejected an output quantum: \(result)."
    }
  }
}

/// Pulls prepared Float32 PCM into one Core Audio output device.
///
/// Setup, renderer preparation, and all allocation occur before device IO starts. The HAL callback
/// only fills caller-owned buffers, reports a bounded failure, and substitutes silence after an
/// error. Host applications should create playback away from latency-sensitive actors and call
/// ``stop()`` when the destination is no longer needed.
@available(macOS 14.2, *)
public final class DeviceOutputPlayback: @unchecked Sendable {
  /// Creates a prepared source after the output device's exact render contract is known.
  public typealias RendererFactory =
    @Sendable (
      _ preparation: AudioRenderPreparation
    ) throws -> any PreparedAudioSource

  /// Receives the first asynchronous render failure away from the HAL thread.
  public typealias FailureHandler = @Sendable (DeviceOutputPlaybackError) -> Void

  /// The persistent destination identity selected during setup.
  public let deviceID: AudioDeviceID

  /// The runtime client format prepared for the selected device.
  public let format: DeviceOutputPlaybackFormat

  private enum State {
    case ready
    case running
    case stopped
  }

  private let lock = NSLock()
  private let resource: any DeviceOutputPlaybackResource
  private var state = State.ready

  /// Creates native output-device playback using the public AUHAL interface.
  public convenience init(
    deviceID: AudioDeviceID,
    rendererFactory: @escaping RendererFactory,
    failureHandler: @escaping FailureHandler = { _ in }
  ) throws {
    try self.init(
      deviceID: deviceID,
      backend: CoreAudioDeviceOutputPlaybackBackend(),
      rendererFactory: rendererFactory,
      failureHandler: failureHandler
    )
  }

  init(
    deviceID: AudioDeviceID,
    backend: any DeviceOutputPlaybackBackend,
    rendererFactory: @escaping RendererFactory,
    failureHandler: @escaping FailureHandler
  ) throws {
    let resource = try backend.makeResource(
      deviceID: deviceID,
      rendererFactory: rendererFactory,
      failureHandler: failureHandler
    )
    self.deviceID = deviceID
    format = resource.format
    self.resource = resource
  }

  deinit {
    try? resource.stop()
  }

  /// Whether the output audio unit is currently running.
  public var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return state == .running
  }

  /// Starts pulling prepared PCM into the selected output device.
  public func start() throws {
    lock.lock()
    defer { lock.unlock() }
    switch state {
    case .running:
      return
    case .stopped:
      throw DeviceOutputPlaybackError.alreadyStopped
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

  /// Stops IO and releases every Core Audio resource owned by this playback session.
  public func stop() throws {
    lock.lock()
    defer { lock.unlock() }
    state = .stopped
    try resource.stop()
  }
}

protocol DeviceOutputPlaybackBackend: Sendable {
  func makeResource(
    deviceID: AudioDeviceID,
    rendererFactory: @escaping DeviceOutputPlayback.RendererFactory,
    failureHandler: @escaping DeviceOutputPlayback.FailureHandler
  ) throws -> any DeviceOutputPlaybackResource
}

protocol DeviceOutputPlaybackResource: AnyObject, Sendable {
  var format: DeviceOutputPlaybackFormat { get }

  func start() throws

  func stop() throws
}

@available(macOS 14.2, *)
private struct CoreAudioDeviceOutputPlaybackBackend: DeviceOutputPlaybackBackend {
  func makeResource(
    deviceID: AudioDeviceID,
    rendererFactory: @escaping DeviceOutputPlayback.RendererFactory,
    failureHandler: @escaping DeviceOutputPlayback.FailureHandler
  ) throws -> any DeviceOutputPlaybackResource {
    try CoreAudioDeviceOutputPlaybackResource(
      deviceID: deviceID,
      rendererFactory: rendererFactory,
      failureHandler: failureHandler
    )
  }
}

@available(macOS 14.2, *)
private final class CoreAudioDeviceOutputPlaybackResource:
  DeviceOutputPlaybackResource, @unchecked Sendable
{
  let format: DeviceOutputPlaybackFormat

  private let lock = NSLock()
  private let renderer: any PreparedAudioSource
  private let failureBridge: DeviceOutputFailureBridge
  private let pointerStorage: DeviceOutputChannelPointerStorage
  private var audioUnit: AudioUnit?
  private var isInitialized = false
  private var isRunning = false

  init(
    deviceID: AudioDeviceID,
    rendererFactory: @escaping DeviceOutputPlayback.RendererFactory,
    failureHandler: @escaping DeviceOutputPlayback.FailureHandler
  ) throws {
    let deviceObjectID = try Self.deviceObjectID(for: deviceID)
    guard try Self.deviceIsAlive(deviceObjectID) else {
      throw DeviceOutputPlaybackError.deviceUnavailable(deviceID)
    }
    let newAudioUnit = try Self.makeAudioUnit()
    var setupSucceeded = false
    defer {
      if !setupSucceeded {
        AudioUnitUninitialize(newAudioUnit)
        AudioComponentInstanceDispose(newAudioUnit)
      }
    }

    try Self.setEnabled(false, scope: kAudioUnitScope_Input, element: 1, on: newAudioUnit)
    try Self.select(deviceObjectID, on: newAudioUnit)
    guard try Self.hasOutput(on: newAudioUnit) else {
      throw DeviceOutputPlaybackError.noOutputChannels(deviceID)
    }
    let deviceFormat = try Self.streamFormat(
      scope: kAudioUnitScope_Output,
      element: 0,
      operation: .readDeviceFormat,
      on: newAudioUnit
    )
    guard deviceFormat.mChannelsPerFrame > 0 else {
      throw DeviceOutputPlaybackError.noOutputChannels(deviceID)
    }
    guard deviceFormat.mSampleRate.isFinite,
      deviceFormat.mSampleRate > 0,
      deviceFormat.mChannelsPerFrame <= AudioProcessingFormat.maximumChannelCount
    else {
      throw DeviceOutputPlaybackError.unsupportedFormat(deviceID)
    }
    let clientFormat = CoreAudioDeviceOutputClientFormat.make(
      sampleRate: deviceFormat.mSampleRate,
      channelCount: deviceFormat.mChannelsPerFrame
    )
    try Self.setStreamFormat(clientFormat, on: newAudioUnit)
    let maximumFrames = try Self.maximumFramesPerSlice(on: newAudioUnit)
    guard maximumFrames > 0,
      maximumFrames <= AudioRenderPreparation.maximumSupportedFrameCount
    else {
      throw DeviceOutputPlaybackError.unsupportedFormat(deviceID)
    }
    let channelIDs = (0..<Int(clientFormat.mChannelsPerFrame)).compactMap { index in
      AudioChannelIndex(rawValue: index).map {
        AudioChannelID(ownerID: .destination(.deviceOutput(deviceID)), index: $0)
      }
    }
    guard channelIDs.count == Int(clientFormat.mChannelsPerFrame) else {
      throw DeviceOutputPlaybackError.unsupportedFormat(deviceID)
    }
    let playbackFormat = DeviceOutputPlaybackFormat(
      deviceID: deviceID,
      sampleRate: clientFormat.mSampleRate,
      channelIDs: channelIDs,
      maximumFrameCount: maximumFrames
    )
    let preparation = try AudioRenderPreparation(
      format: AudioProcessingFormat(
        sampleRate: playbackFormat.sampleRate,
        channelCount: playbackFormat.channelIDs.count
      ),
      maximumFrameCount: maximumFrames
    )
    let renderer = try rendererFactory(preparation)
    guard renderer.preparation.format == preparation.format,
      renderer.preparation.maximumFrameCount >= preparation.maximumFrameCount
    else {
      throw DeviceOutputPlaybackError.incompatibleRenderer
    }
    let pointerStorage = DeviceOutputChannelPointerStorage(
      channelCount: playbackFormat.channelIDs.count
    )

    format = playbackFormat
    self.renderer = renderer
    failureBridge = DeviceOutputFailureBridge(handler: failureHandler)
    self.pointerStorage = pointerStorage
    audioUnit = newAudioUnit

    var callback = AURenderCallbackStruct(
      inputProc: { reference, _, _, _, frameCount, outputData in
        Unmanaged<CoreAudioDeviceOutputPlaybackResource>
          .fromOpaque(reference)
          .takeUnretainedValue()
          .render(frameCount: frameCount, outputData: outputData)
      },
      inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
    )
    try Self.check(
      AudioUnitSetProperty(
        newAudioUnit,
        kAudioUnitProperty_SetRenderCallback,
        kAudioUnitScope_Input,
        0,
        &callback,
        UInt32(MemoryLayout<AURenderCallbackStruct>.size)
      ),
      operation: .setRenderCallback
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
      throw DeviceOutputPlaybackError.alreadyStopped
    }
    guard !isRunning else { return }
    try Self.check(AudioOutputUnitStart(audioUnit), operation: .startAudioUnit)
    isRunning = true
  }

  func stop() throws {
    lock.lock()
    defer { lock.unlock() }
    failureBridge.stopPublishing()
    guard let retainedAudioUnit = audioUnit else { return }
    var firstError: DeviceOutputPlaybackError?
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
    frameCount: UInt32,
    outputData: UnsafeMutablePointer<AudioBufferList>?
  ) -> OSStatus {
    guard let outputData else {
      failureBridge.report(status: kAudio_ParamError)
      return kAudio_ParamError
    }
    let buffers = UnsafeMutableAudioBufferListPointer(outputData)
    guard Int(frameCount) <= format.maximumFrameCount else {
      silence(buffers: buffers, frameCount: Int(frameCount))
      failureBridge.report(result: .invalidFrameCount)
      return noErr
    }
    guard buffers.count >= format.channelIDs.count else {
      silence(buffers: buffers, frameCount: Int(frameCount))
      failureBridge.report(result: .insufficientChannels)
      return noErr
    }
    let byteCount = Int(frameCount) * MemoryLayout<Float>.stride
    for channel in format.channelIDs.indices {
      guard buffers[channel].mNumberChannels == 1,
        Int(buffers[channel].mDataByteSize) >= byteCount,
        let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self)
      else {
        silence(buffers: buffers, frameCount: Int(frameCount))
        failureBridge.report(status: kAudio_ParamError)
        return noErr
      }
      pointerStorage.pointers[channel] = data
      buffers[channel].mDataByteSize = UInt32(byteCount)
    }
    let pointers = UnsafeBufferPointer(
      start: pointerStorage.pointers,
      count: format.channelIDs.count
    )
    let result = renderer.render(outputChannels: pointers, frameCount: Int(frameCount))
    guard result == .rendered else {
      silence(buffers: buffers, frameCount: Int(frameCount))
      failureBridge.report(result: result)
      return noErr
    }
    return noErr
  }

  private func silence(
    buffers: UnsafeMutableAudioBufferListPointer,
    frameCount: Int
  ) {
    let byteCount = frameCount * MemoryLayout<Float>.stride
    for index in buffers.indices {
      guard let data = buffers[index].mData else { continue }
      data.initializeMemory(
        as: UInt8.self, repeating: 0,
        count: min(
          byteCount * max(Int(buffers[index].mNumberChannels), 1),
          Int(buffers[index].mDataByteSize)
        ))
    }
  }

  private static func deviceObjectID(for deviceID: AudioDeviceID) throws -> AudioObjectID {
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
    guard size == MemoryLayout<AudioObjectID>.size else {
      throw DeviceOutputPlaybackError.hardware(
        operation: .resolveDevice,
        status: AudioHardwareStatus(rawValue: kAudioHardwareUnspecifiedError)
      )
    }
    guard objectID != kAudioObjectUnknown else {
      throw DeviceOutputPlaybackError.deviceNotFound(deviceID)
    }
    return objectID
  }

  private static func deviceIsAlive(_ deviceID: AudioObjectID) throws -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsAlive,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var alive: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    try check(
      AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive),
      operation: .readDeviceAvailability
    )
    return size == MemoryLayout<UInt32>.size && alive != 0
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
      throw DeviceOutputPlaybackError.hardware(
        operation: .createAudioUnit,
        status: AudioHardwareStatus(rawValue: kAudioHardwareUnspecifiedError)
      )
    }
    var audioUnit: AudioUnit?
    try check(AudioComponentInstanceNew(component, &audioUnit), operation: .createAudioUnit)
    guard let audioUnit else {
      throw DeviceOutputPlaybackError.hardware(
        operation: .createAudioUnit,
        status: AudioHardwareStatus(rawValue: kAudioHardwareUnspecifiedError)
      )
    }
    return audioUnit
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
      operation: .disableInput
    )
  }

  private static func select(_ deviceID: AudioObjectID, on audioUnit: AudioUnit) throws {
    var deviceID = deviceID
    try check(
      AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &deviceID,
        UInt32(MemoryLayout<AudioObjectID>.size)
      ),
      operation: .selectDevice
    )
  }

  private static func hasOutput(on audioUnit: AudioUnit) throws -> Bool {
    var hasOutput: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    try check(
      AudioUnitGetProperty(
        audioUnit,
        kAudioOutputUnitProperty_HasIO,
        kAudioUnitScope_Output,
        0,
        &hasOutput,
        &size
      ),
      operation: .readOutputAvailability
    )
    return size == MemoryLayout<UInt32>.size && hasOutput != 0
  }

  private static func streamFormat(
    scope: AudioUnitScope,
    element: AudioUnitElement,
    operation: DeviceOutputPlaybackOperation,
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
    guard size == MemoryLayout<AudioStreamBasicDescription>.size else {
      throw DeviceOutputPlaybackError.hardware(
        operation: operation,
        status: AudioHardwareStatus(rawValue: kAudioHardwareUnspecifiedError)
      )
    }
    return format
  }

  private static func setStreamFormat(
    _ format: AudioStreamBasicDescription,
    on audioUnit: AudioUnit
  ) throws {
    var format = format
    try check(
      AudioUnitSetProperty(
        audioUnit,
        kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Input,
        0,
        &format,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      ),
      operation: .setClientFormat
    )
  }

  private static func maximumFramesPerSlice(on audioUnit: AudioUnit) throws -> Int {
    var maximumFrames: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    try check(
      AudioUnitGetProperty(
        audioUnit,
        kAudioUnitProperty_MaximumFramesPerSlice,
        kAudioUnitScope_Global,
        0,
        &maximumFrames,
        &size
      ),
      operation: .readMaximumFrames
    )
    guard size == MemoryLayout<UInt32>.size else {
      throw DeviceOutputPlaybackError.hardware(
        operation: .readMaximumFrames,
        status: AudioHardwareStatus(rawValue: kAudioHardwareUnspecifiedError)
      )
    }
    return Int(maximumFrames)
  }

  private static func check(
    _ status: OSStatus,
    operation: DeviceOutputPlaybackOperation
  ) throws {
    guard status == noErr else {
      throw DeviceOutputPlaybackError.hardware(
        operation: operation,
        status: AudioHardwareStatus(rawValue: status)
      )
    }
  }

  private static func cleanupError(
    _ status: OSStatus,
    operation: DeviceOutputPlaybackOperation,
    retaining error: DeviceOutputPlaybackError?
  ) -> DeviceOutputPlaybackError? {
    guard error == nil, status != noErr else { return error }
    return .hardware(operation: operation, status: AudioHardwareStatus(rawValue: status))
  }
}

enum CoreAudioDeviceOutputClientFormat {
  static func make(sampleRate: Double, channelCount: UInt32) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
      mBytesPerPacket: UInt32(MemoryLayout<Float>.stride),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(MemoryLayout<Float>.stride),
      mChannelsPerFrame: channelCount,
      mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
      mReserved: 0
    )
  }
}

private final class DeviceOutputChannelPointerStorage {
  let pointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

  private let fallbackSample: UnsafeMutablePointer<Float>
  private let channelCount: Int

  init(channelCount: Int) {
    precondition(channelCount > 0)
    self.channelCount = channelCount
    fallbackSample = .allocate(capacity: 1)
    fallbackSample.initialize(to: 0)
    pointers = .allocate(capacity: channelCount)
    pointers.initialize(repeating: fallbackSample, count: channelCount)
  }

  deinit {
    pointers.deinitialize(count: channelCount)
    pointers.deallocate()
    fallbackSample.deinitialize(count: 1)
    fallbackSample.deallocate()
  }
}

@available(macOS 14.2, *)
private final class DeviceOutputFailureBridge: @unchecked Sendable {
  private enum Failure {
    case status(OSStatus)
    case renderer(AudioRenderResult)
  }

  private let handler: DeviceOutputPlayback.FailureHandler
  private let deliverySource: DispatchSourceUserDataAdd
  private var lock = os_unfair_lock_s()
  private var retainedFailure: Failure?
  private var isPublishing = true
  private var hasPublished = false

  init(handler: @escaping DeviceOutputPlayback.FailureHandler) {
    self.handler = handler
    let queue = DispatchQueue(
      label: "moe.uwucocoa.rilliyakit.device-output.failure",
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
    report(.status(status))
  }

  func report(result: AudioRenderResult) {
    report(.renderer(result))
  }

  func stopPublishing() {
    os_unfair_lock_lock(&lock)
    isPublishing = false
    os_unfair_lock_unlock(&lock)
  }

  private func report(_ failure: Failure) {
    guard os_unfair_lock_trylock(&lock) else { return }
    guard isPublishing, retainedFailure == nil else {
      os_unfair_lock_unlock(&lock)
      return
    }
    retainedFailure = failure
    os_unfair_lock_unlock(&lock)
    deliverySource.add(data: 1)
  }

  private func publishFailure() {
    os_unfair_lock_lock(&lock)
    guard isPublishing, !hasPublished, let failure = retainedFailure else {
      os_unfair_lock_unlock(&lock)
      return
    }
    hasPublished = true
    os_unfair_lock_unlock(&lock)
    switch failure {
    case .status(let status):
      handler(
        .hardware(
          operation: .renderOutput,
          status: AudioHardwareStatus(rawValue: status)
        )
      )
    case .renderer(let result):
      handler(.renderer(result))
    }
  }
}

extension DeviceOutputPlaybackOperation {
  fileprivate var description: String {
    switch self {
    case .resolveDevice:
      "resolve the output device UID"
    case .readDeviceAvailability:
      "read output-device availability"
    case .createAudioUnit:
      "create the HAL output audio unit"
    case .disableInput:
      "disable unused input-device IO"
    case .selectDevice:
      "select the output device"
    case .readOutputAvailability:
      "read whether the device publishes output channels"
    case .readDeviceFormat:
      "read the output-device format"
    case .setClientFormat:
      "set the Float32 output format"
    case .readMaximumFrames:
      "read the maximum output frame count"
    case .setRenderCallback:
      "install the output render callback"
    case .initializeAudioUnit:
      "initialize the HAL output audio unit"
    case .startAudioUnit:
      "start output-device IO"
    case .renderOutput:
      "render output-device audio"
    case .stopAudioUnit:
      "stop output-device IO"
    case .uninitializeAudioUnit:
      "uninitialize the HAL output audio unit"
    case .disposeAudioUnit:
      "dispose the HAL output audio unit"
    }
  }
}
