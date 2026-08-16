// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import Darwin
import Dispatch
import Foundation
import RilliyaCore
import RilliyaRealtime

@available(macOS 14.2, *)
struct CoreAudioDeviceOutputCaptureBackend: DeviceOutputCaptureBackend {
  func makeResource(
    target: DeviceOutputCaptureTarget,
    processExclusion: DeviceOutputCaptureProcessExclusion,
    configuration: AudioMeterCaptureConfiguration,
    snapshotHandler: @escaping DeviceOutputCapture.SnapshotHandler
  ) throws -> any DeviceOutputCaptureResource {
    try CoreAudioDeviceOutputCaptureResource(
      target: target,
      processExclusion: processExclusion,
      configuration: configuration,
      snapshotHandler: snapshotHandler
    )
  }
}

@available(macOS 14.2, *)
private final class CoreAudioDeviceOutputCaptureResource:
  DeviceOutputCaptureResource, @unchecked Sendable
{
  let format: DeviceOutputCaptureFormat
  let frameDistributor: AudioRealtimeFrameDistributor
  let frameBuffer: AudioRealtimeFrameBuffer

  private let lock = NSLock()
  private let compatibilitySubscription: AudioRealtimeFrameSubscription
  private let ioQueue: DispatchQueue
  private let meterBridge: RealtimeMeterBridge?
  private var tapID: AudioObjectID
  private var aggregateID: AudioObjectID
  private var ioProcedureID: AudioDeviceIOProcID?
  private var isRunning = false

  init(
    target: DeviceOutputCaptureTarget,
    processExclusion: DeviceOutputCaptureProcessExclusion,
    configuration: AudioMeterCaptureConfiguration,
    snapshotHandler: @escaping DeviceOutputCapture.SnapshotHandler
  ) throws {
    var newTapID = AudioObjectID(kAudioObjectUnknown)
    var newAggregateID = AudioObjectID(kAudioObjectUnknown)

    do {
      let route = try CoreAudioDeviceOutputTapSupport.outputRoute(for: target)
      let excludedProcesses = try CoreAudioDeviceOutputTapSupport.excludedProcessObjectIDs(
        for: processExclusion
      )
      let description = CATapDescription(
        excludingProcesses: excludedProcesses,
        deviceUID: route.deviceID.rawValue,
        stream: route.streamIndex
      )
      description.name = "RilliyaKit Output Device"
      description.isExclusive = true
      description.isPrivate = true
      description.isMixdown = false
      description.isMono = false
      description.muteBehavior = .unmuted

      try CoreAudioDeviceOutputTapSupport.check(
        AudioHardwareCreateProcessTap(description, &newTapID),
        operation: .createTap
      )
      guard newTapID != kAudioObjectUnknown else {
        throw DeviceOutputCaptureError.tapUnavailable
      }
      let tapUID = try CoreAudioDeviceOutputTapSupport.waitForTapUID(newTapID)
      let aggregateDescription: [String: Any] = [
        kAudioAggregateDeviceNameKey: "RilliyaKit Output Device",
        kAudioAggregateDeviceUIDKey: "moe.uwucocoa.rilliyakit.output-capture.\(UUID().uuidString)",
        kAudioAggregateDeviceIsPrivateKey: true,
      ]
      try CoreAudioDeviceOutputTapSupport.check(
        AudioHardwareCreateAggregateDevice(
          aggregateDescription as CFDictionary,
          &newAggregateID
        ),
        operation: .createAggregateDevice
      )
      guard newAggregateID != kAudioObjectUnknown else {
        throw DeviceOutputCaptureError.tapUnavailable
      }
      try CoreAudioDeviceOutputTapSupport.setTapUID(tapUID, on: newAggregateID)
      let streamFormat = try CoreAudioDeviceOutputTapSupport.waitForFormat(on: newAggregateID)
      guard CoreAudioDeviceOutputTapSupport.supports(streamFormat) else {
        throw DeviceOutputCaptureError.unsupportedFormat(route.deviceID)
      }
      guard
        streamFormat.mSampleRate.isFinite,
        streamFormat.mSampleRate > 0,
        streamFormat.mChannelsPerFrame > 0,
        streamFormat.mChannelsPerFrame <= 256
      else {
        throw DeviceOutputCaptureError.unsupportedFormat(route.deviceID)
      }
      let channelIDs = (0..<Int(streamFormat.mChannelsPerFrame)).compactMap { index in
        AudioChannelIndex(rawValue: index).map {
          AudioChannelID(ownerID: .source(.deviceOutput(route.deviceID)), index: $0)
        }
      }
      guard channelIDs.count == Int(streamFormat.mChannelsPerFrame),
        let streamIndex = AudioStreamIndex(rawValue: Int(route.streamIndex))
      else {
        throw DeviceOutputCaptureError.unsupportedFormat(route.deviceID)
      }
      let format = DeviceOutputCaptureFormat(
        deviceID: route.deviceID,
        streamIndex: streamIndex,
        sampleRate: streamFormat.mSampleRate,
        channelIDs: channelIDs
      )
      let processingFormat = try AudioProcessingFormat(
        sampleRate: format.sampleRate,
        channelCount: format.channelIDs.count
      )
      let frameDistributor = try AudioRealtimeFrameDistributor(
        format: processingFormat,
        maximumSubscriberCount: configuration.maximumAdditionalFrameSubscriberCount + 1
      )
      let compatibilitySubscription = try frameDistributor.subscribe()
      self.format = format
      self.frameDistributor = frameDistributor
      frameBuffer = compatibilitySubscription.frameBuffer
      self.compatibilitySubscription = compatibilitySubscription
      tapID = newTapID
      aggregateID = newAggregateID
      ioQueue = DispatchQueue(
        label: "moe.uwucocoa.rilliyakit.output-device-tap",
        qos: .userInteractive
      )
      meterBridge =
        configuration.publishesMeterSnapshots
        ? RealtimeMeterBridge(
          sampleRate: format.sampleRate,
          channelIDs: format.channelIDs,
          configuration: configuration,
          snapshotHandler: { sequence, frameCount, channels in
            snapshotHandler(
              DeviceOutputMeterSnapshot(
                format: format,
                sequence: sequence,
                frameCount: frameCount,
                channels: channels
              )
            )
          }
        ) : nil
    } catch {
      if newAggregateID != kAudioObjectUnknown {
        AudioHardwareDestroyAggregateDevice(newAggregateID)
      }
      if newTapID != kAudioObjectUnknown {
        AudioHardwareDestroyProcessTap(newTapID)
      }
      throw error
    }
  }

  deinit {
    try? stop()
  }

  func start() throws {
    try lock.withLock {
      guard aggregateID != kAudioObjectUnknown, tapID != kAudioObjectUnknown else {
        throw DeviceOutputCaptureError.alreadyStopped
      }
      guard !isRunning else { return }

      let meterBridge = meterBridge
      let frameDistributor = frameDistributor
      var newIOProcedureID: AudioDeviceIOProcID?
      try CoreAudioDeviceOutputTapSupport.check(
        AudioDeviceCreateIOProcIDWithBlock(
          &newIOProcedureID,
          aggregateID,
          ioQueue
        ) { _, input, _, _, _ in
          frameDistributor.write(input)
          meterBridge?.consume(input)
        },
        operation: .createIOProcedure
      )
      guard let newIOProcedureID else {
        throw DeviceOutputCaptureError.hardware(
          operation: .createIOProcedure,
          status: AudioHardwareStatus(rawValue: kAudioHardwareUnspecifiedError)
        )
      }
      ioProcedureID = newIOProcedureID

      do {
        try CoreAudioDeviceOutputTapSupport.check(
          AudioDeviceStart(aggregateID, newIOProcedureID),
          operation: .startDevice
        )
        isRunning = true
      } catch {
        AudioDeviceDestroyIOProcID(aggregateID, newIOProcedureID)
        ioProcedureID = nil
        throw error
      }
    }
  }

  func stop() throws {
    try lock.withLock {
      var firstError: DeviceOutputCaptureError?
      let retainedAggregateID = aggregateID
      if let ioProcedureID, retainedAggregateID != kAudioObjectUnknown {
        if isRunning {
          firstError = CoreAudioDeviceOutputTapSupport.cleanupError(
            AudioDeviceStop(retainedAggregateID, ioProcedureID),
            operation: .stopDevice,
            retaining: firstError
          )
        }
        let destroyStatus = AudioDeviceDestroyIOProcID(retainedAggregateID, ioProcedureID)
        firstError = CoreAudioDeviceOutputTapSupport.cleanupError(
          destroyStatus,
          operation: .destroyIOProcedure,
          retaining: firstError
        )
        if destroyStatus == noErr {
          self.ioProcedureID = nil
        }
      }
      isRunning = false
      meterBridge?.stopPublishing()

      if aggregateID != kAudioObjectUnknown {
        let status = AudioHardwareDestroyAggregateDevice(aggregateID)
        firstError = CoreAudioDeviceOutputTapSupport.cleanupError(
          status,
          operation: .destroyAggregateDevice,
          retaining: firstError
        )
        if status == noErr {
          aggregateID = kAudioObjectUnknown
          ioProcedureID = nil
        }
      }
      if tapID != kAudioObjectUnknown {
        let status = AudioHardwareDestroyProcessTap(tapID)
        firstError = CoreAudioDeviceOutputTapSupport.cleanupError(
          status,
          operation: .destroyTap,
          retaining: firstError
        )
        if status == noErr {
          tapID = kAudioObjectUnknown
        }
      }
      if let firstError {
        throw firstError
      }
    }
  }
}

@available(macOS 14.2, *)
enum CoreAudioDeviceOutputTapSupport {
  struct OutputRoute {
    let deviceID: RilliyaCore.AudioDeviceID
    let streamIndex: UInt
  }

  static func outputRoute(
    for target: DeviceOutputCaptureTarget
  ) throws -> OutputRoute {
    let deviceObjectID: AudioObjectID
    switch target {
    case .systemDefault:
      deviceObjectID = try scalarProperty(
        objectID: AudioObjectID(kAudioObjectSystemObject),
        selector: kAudioHardwarePropertyDefaultOutputDevice,
        operation: .readDefaultOutputDevice,
        initialValue: kAudioObjectUnknown
      )
      guard deviceObjectID != kAudioObjectUnknown else {
        throw DeviceOutputCaptureError.noDefaultOutputDevice
      }
    case .device(let deviceID):
      deviceObjectID = try resolveDevice(deviceID)
    }

    let resolvedDeviceID: RilliyaCore.AudioDeviceID
    switch target {
    case .device(let deviceID):
      resolvedDeviceID = deviceID
    case .systemDefault:
      let uid = try stringProperty(
        objectID: deviceObjectID,
        selector: kAudioDevicePropertyDeviceUID,
        operation: .readDeviceIdentifier
      )
      guard let deviceID = RilliyaCore.AudioDeviceID(rawValue: uid) else {
        throw DeviceOutputCaptureError.invalidPropertyData(operation: .readDeviceIdentifier)
      }
      resolvedDeviceID = deviceID
    }

    guard try deviceIsAlive(deviceObjectID) else {
      throw DeviceOutputCaptureError.deviceUnavailable(resolvedDeviceID)
    }
    let streams = try objectIDsProperty(
      objectID: deviceObjectID,
      selector: kAudioDevicePropertyStreams,
      scope: kAudioObjectPropertyScopeOutput,
      operation: .readDeviceStreams
    )
    guard !streams.isEmpty else {
      throw DeviceOutputCaptureError.noOutputStream(resolvedDeviceID)
    }
    return OutputRoute(
      deviceID: resolvedDeviceID,
      streamIndex: 0
    )
  }

  static func excludedProcessObjectIDs(
    for exclusion: DeviceOutputCaptureProcessExclusion
  ) throws -> [AudioObjectID] {
    guard exclusion.excludesCurrentProcess || !exclusion.processIDs.isEmpty else { return [] }
    let objectIDs = try objectIDsProperty(
      objectID: AudioObjectID(kAudioObjectSystemObject),
      selector: kAudioHardwarePropertyProcessObjectList,
      scope: kAudioObjectPropertyScopeGlobal,
      operation: .readProcesses
    )
    var processObjects: [AudioProcessID: AudioObjectID] = [:]
    for objectID in objectIDs {
      let identifier: pid_t
      do {
        identifier = try scalarProperty(
          objectID: objectID,
          selector: kAudioProcessPropertyPID,
          operation: .readProcessIdentifier,
          initialValue: 0
        )
      } catch DeviceOutputCaptureError.hardware(_, let status)
        where status.rawValue == kAudioHardwareBadObjectError
      {
        continue
      }
      if let processID = AudioProcessID(rawValue: identifier) {
        processObjects[processID] = objectID
      }
    }

    return try resolvedExcludedProcessObjectIDs(
      for: exclusion,
      processObjects: processObjects,
      currentProcessID: AudioProcessID(rawValue: getpid())
    )
  }

  static func resolvedExcludedProcessObjectIDs(
    for exclusion: DeviceOutputCaptureProcessExclusion,
    processObjects: [AudioProcessID: AudioObjectID],
    currentProcessID: AudioProcessID?
  ) throws -> [AudioObjectID] {
    var excludedObjectIDs: Set<AudioObjectID> = []
    for processID in exclusion.processIDs {
      guard let objectID = processObjects[processID] else {
        throw DeviceOutputCaptureError.processNotFound(processID)
      }
      excludedObjectIDs.insert(objectID)
    }
    if exclusion.excludesCurrentProcess, let currentProcessID,
      let objectID = processObjects[currentProcessID]
    {
      excludedObjectIDs.insert(objectID)
    }
    return excludedObjectIDs.sorted()
  }

  static func waitForTapUID(_ tapID: AudioObjectID) throws -> String {
    for attempt in 0..<100 {
      do {
        return try stringProperty(
          objectID: tapID,
          selector: kAudioTapPropertyUID,
          operation: .readTapIdentifier
        )
      } catch {
        guard
          let captureError = error as? DeviceOutputCaptureError,
          case .hardware(_, let status) = captureError,
          status.rawValue == kAudioHardwareBadObjectError,
          attempt < 99
        else {
          throw error
        }
        Thread.sleep(forTimeInterval: 0.02)
      }
    }
    throw DeviceOutputCaptureError.tapUnavailable
  }

  static func setTapUID(_ tapUID: String, on aggregateID: AudioObjectID) throws {
    var address = propertyAddress(kAudioAggregateDevicePropertyTapList)
    var tapList: CFArray? = [tapUID as CFString] as CFArray
    let size = UInt32(MemoryLayout<CFArray?>.stride)
    try withUnsafeMutablePointer(to: &tapList) { pointer in
      try check(
        AudioObjectSetPropertyData(aggregateID, &address, 0, nil, size, pointer),
        operation: .attachTap
      )
    }
  }

  static func waitForFormat(
    on aggregateID: AudioObjectID
  ) throws -> AudioStreamBasicDescription {
    for attempt in 0..<100 {
      do {
        let streams = try objectIDsProperty(
          objectID: aggregateID,
          selector: kAudioDevicePropertyStreams,
          scope: kAudioDevicePropertyScopeInput,
          operation: .readTapFormat
        )
        if let streamID = streams.first {
          return try scalarProperty(
            objectID: streamID,
            selector: kAudioStreamPropertyVirtualFormat,
            operation: .readTapFormat,
            initialValue: AudioStreamBasicDescription()
          )
        }
      } catch {
        guard
          let captureError = error as? DeviceOutputCaptureError,
          case .hardware(_, let status) = captureError,
          status.rawValue == kAudioHardwareBadObjectError,
          attempt < 99
        else {
          throw error
        }
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    throw DeviceOutputCaptureError.tapUnavailable
  }

  static func supports(_ format: AudioStreamBasicDescription) -> Bool {
    guard
      format.mFormatID == kAudioFormatLinearPCM,
      format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
      format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
      format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
      format.mBitsPerChannel == 32,
      format.mChannelsPerFrame > 0
    else {
      return false
    }
    let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    let expectedBytesPerFrame =
      UInt32(MemoryLayout<Float32>.stride)
      * (nonInterleaved ? 1 : format.mChannelsPerFrame)
    return format.mBytesPerFrame == expectedBytesPerFrame
  }

  static func check(_ status: OSStatus, operation: DeviceOutputCaptureOperation) throws {
    guard status == noErr else {
      throw DeviceOutputCaptureError.hardware(
        operation: operation,
        status: AudioHardwareStatus(rawValue: status)
      )
    }
  }

  static func cleanupError(
    _ status: OSStatus,
    operation: DeviceOutputCaptureOperation,
    retaining error: DeviceOutputCaptureError?
  ) -> DeviceOutputCaptureError? {
    guard error == nil, status != noErr else { return error }
    return .hardware(operation: operation, status: AudioHardwareStatus(rawValue: status))
  }

  private static func resolveDevice(
    _ deviceID: RilliyaCore.AudioDeviceID
  ) throws -> AudioObjectID {
    var address = propertyAddress(kAudioHardwarePropertyTranslateUIDToDevice)
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
      throw DeviceOutputCaptureError.invalidPropertyData(operation: .resolveDevice)
    }
    guard objectID != kAudioObjectUnknown else {
      throw DeviceOutputCaptureError.deviceNotFound(deviceID)
    }
    return objectID
  }

  private static func deviceIsAlive(_ deviceObjectID: AudioObjectID) throws -> Bool {
    let value: UInt32 = try scalarProperty(
      objectID: deviceObjectID,
      selector: kAudioDevicePropertyDeviceIsAlive,
      operation: .readDeviceAvailability,
      initialValue: 0
    )
    return value != 0
  }

  private static func objectIDsProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    operation: DeviceOutputCaptureOperation
  ) throws -> [AudioObjectID] {
    var address = propertyAddress(selector, scope: scope)
    var size: UInt32 = 0
    try check(
      AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size),
      operation: operation
    )
    guard size > 0 else { return [] }
    guard Int(size) % MemoryLayout<AudioObjectID>.stride == 0 else {
      throw DeviceOutputCaptureError.invalidPropertyData(operation: operation)
    }
    var values = [AudioObjectID](
      repeating: kAudioObjectUnknown,
      count: Int(size) / MemoryLayout<AudioObjectID>.stride
    )
    try values.withUnsafeMutableBytes { storage in
      guard let baseAddress = storage.baseAddress else { return }
      try check(
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, baseAddress),
        operation: operation
      )
    }
    let returnedCount = Int(size) / MemoryLayout<AudioObjectID>.stride
    guard Int(size) % MemoryLayout<AudioObjectID>.stride == 0,
      returnedCount <= values.count
    else {
      throw DeviceOutputCaptureError.invalidPropertyData(operation: operation)
    }
    return Array(values.prefix(returnedCount))
  }

  private static func scalarProperty<Value>(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    operation: DeviceOutputCaptureOperation,
    initialValue: Value
  ) throws -> Value {
    var address = propertyAddress(selector)
    var value = initialValue
    var size = UInt32(MemoryLayout<Value>.stride)
    try withUnsafeMutableBytes(of: &value) { storage in
      guard let baseAddress = storage.baseAddress else { return }
      try check(
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, baseAddress),
        operation: operation
      )
    }
    guard size == MemoryLayout<Value>.stride else {
      throw DeviceOutputCaptureError.invalidPropertyData(operation: operation)
    }
    return value
  }

  private static func stringProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    operation: DeviceOutputCaptureOperation
  ) throws -> String {
    var address = propertyAddress(selector)
    var size: UInt32 = 0
    try check(
      AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size),
      operation: operation
    )
    guard size == MemoryLayout<CFString?>.stride else {
      throw DeviceOutputCaptureError.invalidPropertyData(operation: operation)
    }
    var value: CFString?
    try withUnsafeMutablePointer(to: &value) { pointer in
      try check(
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer),
        operation: operation
      )
    }
    guard size == MemoryLayout<CFString?>.stride, let value else {
      throw DeviceOutputCaptureError.invalidPropertyData(operation: operation)
    }
    return value as String
  }

  private static func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
  }
}
