// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import Dispatch
import Foundation

@available(macOS 14.2, *)
struct CoreAudioProcessOutputCaptureBackend: ProcessOutputCaptureBackend {
  func makeResource(
    processID: AudioProcessID,
    configuration: ProcessOutputCaptureConfiguration,
    snapshotHandler: @escaping ProcessOutputCapture.SnapshotHandler
  ) throws -> any ProcessOutputCaptureResource {
    try CoreAudioProcessOutputCaptureResource(
      processID: processID,
      configuration: configuration,
      snapshotHandler: snapshotHandler
    )
  }
}

@available(macOS 14.2, *)
private final class CoreAudioProcessOutputCaptureResource:
  ProcessOutputCaptureResource, @unchecked Sendable
{
  let format: ProcessOutputCaptureFormat

  private let lock = NSLock()
  private let ioQueue: DispatchQueue
  private let meterBridge: RealtimeMeterBridge
  private var tapID: AudioObjectID
  private var aggregateID: AudioObjectID
  private var ioProcedureID: AudioDeviceIOProcID?
  private var isRunning = false

  init(
    processID: AudioProcessID,
    configuration: ProcessOutputCaptureConfiguration,
    snapshotHandler: @escaping ProcessOutputCapture.SnapshotHandler
  ) throws {
    var newTapID = AudioObjectID(kAudioObjectUnknown)
    var newAggregateID = AudioObjectID(kAudioObjectUnknown)

    do {
      let processObjectID = try CoreAudioProcessTapSupport.processObjectID(for: processID)
      let route = try CoreAudioProcessTapSupport.outputRoute(
        processID: processID,
        processObjectID: processObjectID
      )
      let description = CATapDescription(
        processes: [processObjectID],
        deviceUID: route.deviceUID,
        stream: route.streamIndex
      )
      description.name = "RilliyaKit Process Output"
      description.isExclusive = false
      description.isPrivate = true
      description.isMixdown = false
      description.isMono = false
      description.muteBehavior = .unmuted

      try CoreAudioProcessTapSupport.check(
        AudioHardwareCreateProcessTap(description, &newTapID),
        operation: .createTap
      )
      guard newTapID != kAudioObjectUnknown else {
        throw ProcessOutputCaptureError.tapUnavailable
      }
      let tapUID = try CoreAudioProcessTapSupport.waitForTapUID(newTapID)
      let aggregateDescription: [String: Any] = [
        kAudioAggregateDeviceNameKey: "RilliyaKit Process Output",
        kAudioAggregateDeviceUIDKey: "moe.uwucocoa.rilliyakit.capture.\(UUID().uuidString)",
        kAudioAggregateDeviceIsPrivateKey: true,
      ]
      try CoreAudioProcessTapSupport.check(
        AudioHardwareCreateAggregateDevice(
          aggregateDescription as CFDictionary,
          &newAggregateID
        ),
        operation: .createAggregateDevice
      )
      guard newAggregateID != kAudioObjectUnknown else {
        throw ProcessOutputCaptureError.tapUnavailable
      }
      try CoreAudioProcessTapSupport.setTapUID(tapUID, on: newAggregateID)
      let streamFormat = try CoreAudioProcessTapSupport.waitForFormat(on: newAggregateID)
      guard CoreAudioProcessTapSupport.supports(streamFormat) else {
        throw ProcessOutputCaptureError.unsupportedFormat
      }
      guard
        streamFormat.mSampleRate.isFinite,
        streamFormat.mSampleRate > 0,
        streamFormat.mChannelsPerFrame > 0,
        streamFormat.mChannelsPerFrame <= 256
      else {
        throw ProcessOutputCaptureError.unsupportedFormat
      }
      let channelIDs = (0..<Int(streamFormat.mChannelsPerFrame)).compactMap { index in
        AudioChannelIndex(rawValue: index).map {
          AudioChannelID(ownerID: .source(.processOutput(processID)), index: $0)
        }
      }
      guard channelIDs.count == Int(streamFormat.mChannelsPerFrame) else {
        throw ProcessOutputCaptureError.unsupportedFormat
      }
      let format = ProcessOutputCaptureFormat(
        processID: processID,
        sampleRate: streamFormat.mSampleRate,
        channelIDs: channelIDs
      )
      self.format = format
      tapID = newTapID
      aggregateID = newAggregateID
      ioQueue = DispatchQueue(
        label: "moe.uwucocoa.rilliyakit.process-tap.\(processID.rawValue)",
        qos: .userInteractive
      )
      meterBridge = RealtimeMeterBridge(
        sampleRate: format.sampleRate,
        channelIDs: format.channelIDs,
        configuration: configuration,
        snapshotHandler: { sequence, frameCount, channels in
          snapshotHandler(
            ProcessOutputMeterSnapshot(
              format: format,
              sequence: sequence,
              frameCount: frameCount,
              channels: channels
            )
          )
        }
      )
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
    lock.lock()
    defer { lock.unlock() }
    guard aggregateID != kAudioObjectUnknown, tapID != kAudioObjectUnknown else {
      throw ProcessOutputCaptureError.alreadyStopped
    }
    guard !isRunning else { return }

    let meterBridge = meterBridge
    var newIOProcedureID: AudioDeviceIOProcID?
    try CoreAudioProcessTapSupport.check(
      AudioDeviceCreateIOProcIDWithBlock(
        &newIOProcedureID,
        aggregateID,
        ioQueue
      ) { _, input, _, _, _ in
        meterBridge.consume(input)
      },
      operation: .createIOProcedure
    )
    guard let newIOProcedureID else {
      throw ProcessOutputCaptureError.hardware(
        operation: .createIOProcedure,
        status: AudioHardwareStatus(rawValue: kAudioHardwareUnspecifiedError)
      )
    }
    ioProcedureID = newIOProcedureID

    do {
      try CoreAudioProcessTapSupport.check(
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

  func stop() throws {
    lock.lock()
    defer { lock.unlock() }
    var firstError: ProcessOutputCaptureError?
    let retainedAggregateID = aggregateID
    if let ioProcedureID, retainedAggregateID != kAudioObjectUnknown {
      if isRunning {
        firstError = CoreAudioProcessTapSupport.cleanupError(
          AudioDeviceStop(retainedAggregateID, ioProcedureID),
          operation: .stopDevice,
          retaining: firstError
        )
      }
      let destroyStatus = AudioDeviceDestroyIOProcID(retainedAggregateID, ioProcedureID)
      firstError = CoreAudioProcessTapSupport.cleanupError(
        destroyStatus,
        operation: .destroyIOProcedure,
        retaining: firstError
      )
      if destroyStatus == noErr {
        self.ioProcedureID = nil
      }
    }
    isRunning = false
    meterBridge.stopPublishing()

    if aggregateID != kAudioObjectUnknown {
      let status = AudioHardwareDestroyAggregateDevice(aggregateID)
      firstError = CoreAudioProcessTapSupport.cleanupError(
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
      firstError = CoreAudioProcessTapSupport.cleanupError(
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

@available(macOS 14.2, *)
private enum CoreAudioProcessTapSupport {
  struct OutputRoute {
    let deviceUID: String
    let streamIndex: UInt
  }

  static func processObjectID(
    for processID: AudioProcessID
  ) throws -> AudioObjectID {
    let objectIDs = try objectIDsProperty(
      objectID: AudioObjectID(kAudioObjectSystemObject),
      selector: kAudioHardwarePropertyProcessObjectList,
      scope: kAudioObjectPropertyScopeGlobal,
      operation: .readProcesses
    )
    for objectID in objectIDs {
      let identifier: pid_t
      do {
        identifier = try scalarProperty(
          objectID: objectID,
          selector: kAudioProcessPropertyPID,
          operation: .readProcessIdentifier,
          initialValue: 0
        )
      } catch ProcessOutputCaptureError.hardware(_, let status)
        where status.rawValue == kAudioHardwareBadObjectError
      {
        continue
      }
      if identifier == processID.rawValue {
        return objectID
      }
    }
    throw ProcessOutputCaptureError.processNotFound(processID)
  }

  static func outputRoute(
    processID: AudioProcessID,
    processObjectID: AudioObjectID
  ) throws -> OutputRoute {
    let defaultDevice: AudioObjectID = try scalarProperty(
      objectID: AudioObjectID(kAudioObjectSystemObject),
      selector: kAudioHardwarePropertyDefaultOutputDevice,
      operation: .readDefaultOutputDevice,
      initialValue: kAudioObjectUnknown
    )
    let processDevices = try objectIDsProperty(
      objectID: processObjectID,
      selector: kAudioProcessPropertyDevices,
      scope: kAudioObjectPropertyScopeOutput,
      operation: .readProcessDevices
    )
    let deviceID =
      processDevices.contains(defaultDevice)
      ? defaultDevice
      : processDevices.first ?? defaultDevice
    guard deviceID != kAudioObjectUnknown else {
      throw ProcessOutputCaptureError.noOutputDevice(processID)
    }
    let streams = try objectIDsProperty(
      objectID: deviceID,
      selector: kAudioDevicePropertyStreams,
      scope: kAudioObjectPropertyScopeOutput,
      operation: .readDeviceStreams
    )
    guard !streams.isEmpty else {
      throw ProcessOutputCaptureError.noOutputStream(processID)
    }
    let deviceUID = try stringProperty(
      objectID: deviceID,
      selector: kAudioDevicePropertyDeviceUID,
      operation: .readDeviceIdentifier
    )
    return OutputRoute(deviceUID: deviceUID, streamIndex: 0)
  }

  static func waitForTapUID(
    _ tapID: AudioObjectID
  ) throws -> String {
    for attempt in 0..<100 {
      do {
        return try stringProperty(
          objectID: tapID,
          selector: kAudioTapPropertyUID,
          operation: .readTapIdentifier
        )
      } catch {
        guard
          let captureError = error as? ProcessOutputCaptureError,
          case .hardware(_, let status) = captureError
        else {
          throw error
        }
        guard
          status.rawValue == kAudioHardwareBadObjectError,
          attempt < 99
        else {
          throw ProcessOutputCaptureError.hardware(
            operation: .readTapIdentifier,
            status: status
          )
        }
        Thread.sleep(forTimeInterval: 0.02)
      }
    }
    throw ProcessOutputCaptureError.tapUnavailable
  }

  static func setTapUID(
    _ tapUID: String,
    on aggregateID: AudioObjectID
  ) throws {
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
          let captureError = error as? ProcessOutputCaptureError,
          case .hardware(_, let status) = captureError
        else {
          throw error
        }
        guard
          status.rawValue == kAudioHardwareBadObjectError,
          attempt < 99
        else {
          throw ProcessOutputCaptureError.hardware(
            operation: .readTapFormat,
            status: status
          )
        }
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    throw ProcessOutputCaptureError.tapUnavailable
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

  static func check(
    _ status: OSStatus,
    operation: ProcessOutputCaptureOperation
  ) throws {
    guard status == noErr else {
      throw ProcessOutputCaptureError.hardware(
        operation: operation,
        status: AudioHardwareStatus(rawValue: status)
      )
    }
  }

  static func cleanupError(
    _ status: OSStatus,
    operation: ProcessOutputCaptureOperation,
    retaining error: ProcessOutputCaptureError?
  ) -> ProcessOutputCaptureError? {
    guard error == nil, status != noErr else { return error }
    return .hardware(operation: operation, status: AudioHardwareStatus(rawValue: status))
  }

  private static func objectIDsProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    operation: ProcessOutputCaptureOperation
  ) throws -> [AudioObjectID] {
    var address = propertyAddress(selector, scope: scope)
    var size: UInt32 = 0
    try check(
      AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size),
      operation: operation
    )
    guard size > 0 else { return [] }
    guard Int(size) % MemoryLayout<AudioObjectID>.stride == 0 else {
      throw ProcessOutputCaptureError.hardware(
        operation: operation,
        status: AudioHardwareStatus(rawValue: kAudioHardwareUnspecifiedError)
      )
    }
    var values = [AudioObjectID](
      repeating: kAudioObjectUnknown,
      count: Int(size) / MemoryLayout<AudioObjectID>.stride
    )
    try values.withUnsafeMutableBytes { storage in
      guard let baseAddress = storage.baseAddress else { return }
      try check(
        AudioObjectGetPropertyData(
          objectID,
          &address,
          0,
          nil,
          &size,
          baseAddress
        ),
        operation: operation
      )
    }
    let returnedCount = Int(size) / MemoryLayout<AudioObjectID>.stride
    guard
      Int(size) % MemoryLayout<AudioObjectID>.stride == 0,
      returnedCount <= values.count
    else {
      throw ProcessOutputCaptureError.invalidPropertyData(operation: operation)
    }
    return Array(values.prefix(returnedCount))
  }

  private static func scalarProperty<Value>(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    operation: ProcessOutputCaptureOperation,
    initialValue: Value
  ) throws -> Value {
    var address = propertyAddress(selector)
    var value = initialValue
    var size = UInt32(MemoryLayout<Value>.stride)
    try withUnsafeMutableBytes(of: &value) { storage in
      guard let baseAddress = storage.baseAddress else { return }
      try check(
        AudioObjectGetPropertyData(
          objectID,
          &address,
          0,
          nil,
          &size,
          baseAddress
        ),
        operation: operation
      )
    }
    guard size == MemoryLayout<Value>.stride else {
      throw ProcessOutputCaptureError.invalidPropertyData(operation: operation)
    }
    return value
  }

  private static func stringProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    operation: ProcessOutputCaptureOperation
  ) throws -> String {
    var address = propertyAddress(selector)
    var size: UInt32 = 0
    try check(
      AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size),
      operation: operation
    )
    guard size == MemoryLayout<CFString?>.stride else {
      throw ProcessOutputCaptureError.invalidPropertyData(operation: operation)
    }
    var value: CFString?
    try withUnsafeMutablePointer(to: &value) { pointer in
      try check(
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer),
        operation: operation
      )
    }
    guard size == MemoryLayout<CFString?>.stride else {
      throw ProcessOutputCaptureError.invalidPropertyData(operation: operation)
    }
    guard let value else {
      throw ProcessOutputCaptureError.hardware(
        operation: operation,
        status: AudioHardwareStatus(rawValue: kAudioHardwareUnspecifiedError)
      )
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
