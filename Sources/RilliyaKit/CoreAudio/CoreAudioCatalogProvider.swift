// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import Darwin
import Foundation

struct CoreAudioCatalogProvider: AudioHardwareCatalogProvider {
  var currentProcessIdentifier: Int32 {
    getpid()
  }

  func deviceObjectIDs() throws(AudioCatalogError) -> [HardwareObjectID] {
    try objectIDs(
      objectID: systemObjectID,
      objectKind: .system,
      property: .devices,
      selector: kAudioHardwarePropertyDevices
    )
  }

  func processObjectIDs() throws(AudioCatalogError) -> [HardwareObjectID] {
    try objectIDs(
      objectID: systemObjectID,
      objectKind: .system,
      property: .processes,
      selector: kAudioHardwarePropertyProcessObjectList
    )
  }

  func defaultDeviceObjectID(
    for direction: AudioDirection
  ) throws(AudioCatalogError) -> HardwareObjectID? {
    let property: AudioHardwareProperty
    let selector: AudioObjectPropertySelector
    switch direction {
    case .input:
      property = .defaultInputDevice
      selector = kAudioHardwarePropertyDefaultInputDevice
    case .output:
      property = .defaultOutputDevice
      selector = kAudioHardwarePropertyDefaultOutputDevice
    }
    let objectID: AudioObjectID = try scalar(
      objectID: systemObjectID,
      objectKind: .system,
      property: property,
      selector: selector,
      default: kAudioObjectUnknown
    )
    return objectID == kAudioObjectUnknown ? nil : objectID
  }

  func device(
    for objectID: HardwareObjectID
  ) throws(AudioCatalogError) -> HardwareDeviceDescription {
    guard
      let uid = try string(
        objectID: objectID,
        objectKind: .device,
        property: .deviceIdentifier,
        selector: kAudioDevicePropertyDeviceUID
      ),
      !uid.isEmpty
    else {
      throw .invalidData(
        AudioHardwareDataError(
          objectKind: .device,
          property: .deviceIdentifier,
          reason: "the device UID is missing"
        )
      )
    }
    let name =
      try string(
        objectID: objectID,
        objectKind: .device,
        property: .deviceName,
        selector: kAudioObjectPropertyName
      ) ?? uid
    let transportType: UInt32 =
      try optionalScalar(
        objectID: objectID,
        objectKind: .device,
        property: .deviceTransportType,
        selector: kAudioDevicePropertyTransportType,
        default: 0
      ) ?? 0
    let nominalSampleRate: Float64 =
      try optionalScalar(
        objectID: objectID,
        objectKind: .device,
        property: .deviceNominalSampleRate,
        selector: kAudioDevicePropertyNominalSampleRate,
        default: 0
      ) ?? 0
    let isAlive =
      try optionalBoolean(
        objectID: objectID,
        objectKind: .device,
        property: .deviceIsAlive,
        selector: kAudioDevicePropertyDeviceIsAlive
      ) ?? true
    let isRunning =
      try optionalBoolean(
        objectID: objectID,
        objectKind: .device,
        property: .deviceIsRunning,
        selector: kAudioDevicePropertyDeviceIsRunning
      ) ?? false

    return try HardwareDeviceDescription(
      uid: uid,
      name: name,
      transportType: transportType,
      nominalSampleRate: nominalSampleRate,
      isAlive: isAlive,
      isRunning: isRunning,
      input: endpoint(for: objectID, direction: .input),
      output: endpoint(for: objectID, direction: .output)
    )
  }

  func process(
    for objectID: HardwareObjectID
  ) throws(AudioCatalogError) -> HardwareProcessDescription {
    let processIdentifier: pid_t = try scalar(
      objectID: objectID,
      objectKind: .process,
      property: .processIdentifier,
      selector: kAudioProcessPropertyPID,
      default: 0
    )
    let bundleIdentifier = try optionalString(
      objectID: objectID,
      objectKind: .process,
      property: .processBundleIdentifier,
      selector: kAudioProcessPropertyBundleID
    )
    let isRunning = try boolean(
      objectID: objectID,
      objectKind: .process,
      property: .processIsRunning,
      selector: kAudioProcessPropertyIsRunning
    )
    let isRunningInput = try boolean(
      objectID: objectID,
      objectKind: .process,
      property: .processIsRunningInput,
      selector: kAudioProcessPropertyIsRunningInput
    )
    let isRunningOutput = try boolean(
      objectID: objectID,
      objectKind: .process,
      property: .processIsRunningOutput,
      selector: kAudioProcessPropertyIsRunningOutput
    )
    let inputDeviceObjectIDs = try objectIDs(
      objectID: objectID,
      objectKind: .process,
      property: .processDevices,
      selector: kAudioProcessPropertyDevices,
      scope: kAudioObjectPropertyScopeInput
    )
    let outputDeviceObjectIDs = try objectIDs(
      objectID: objectID,
      objectKind: .process,
      property: .processDevices,
      selector: kAudioProcessPropertyDevices,
      scope: kAudioObjectPropertyScopeOutput
    )
    return HardwareProcessDescription(
      processIdentifier: processIdentifier,
      bundleIdentifier: bundleIdentifier,
      isRunning: isRunning,
      isRunningInput: isRunningInput,
      isRunningOutput: isRunningOutput,
      inputDeviceObjectIDs: inputDeviceObjectIDs,
      outputDeviceObjectIDs: outputDeviceObjectIDs
    )
  }

  private var systemObjectID: AudioObjectID {
    AudioObjectID(kAudioObjectSystemObject)
  }

  private func endpoint(
    for deviceObjectID: AudioObjectID,
    direction: AudioDirection
  ) throws(AudioCatalogError) -> HardwareDeviceEndpointDescription? {
    let scope = scope(for: direction)
    let channelCount = try channelCount(deviceObjectID: deviceObjectID, scope: scope)
    guard channelCount > 0 else { return nil }

    let streamObjectIDs = try objectIDs(
      objectID: deviceObjectID,
      objectKind: .device,
      property: .deviceStreams,
      selector: kAudioDevicePropertyStreams,
      scope: scope
    )
    var streams: [HardwareStreamDescription] = []
    streams.reserveCapacity(streamObjectIDs.count)
    for streamObjectID in streamObjectIDs {
      streams.append(try stream(for: streamObjectID))
    }
    return HardwareDeviceEndpointDescription(channelCount: channelCount, streams: streams)
  }

  private func stream(
    for objectID: AudioObjectID
  ) throws(AudioCatalogError) -> HardwareStreamDescription {
    let isActive =
      try optionalBoolean(
        objectID: objectID,
        objectKind: .stream,
        property: .streamIsActive,
        selector: kAudioStreamPropertyIsActive
      ) ?? false
    let startingChannel: UInt32? = try optionalScalar(
      objectID: objectID,
      objectKind: .stream,
      property: .streamStartingChannel,
      selector: kAudioStreamPropertyStartingChannel,
      default: 0
    )
    let virtualDescription: AudioStreamBasicDescription? = try optionalScalar(
      objectID: objectID,
      objectKind: .stream,
      property: .streamVirtualFormat,
      selector: kAudioStreamPropertyVirtualFormat,
      default: AudioStreamBasicDescription()
    )
    let physicalDescription: AudioStreamBasicDescription? = try optionalScalar(
      objectID: objectID,
      objectKind: .stream,
      property: .streamPhysicalFormat,
      selector: kAudioStreamPropertyPhysicalFormat,
      default: AudioStreamBasicDescription()
    )
    return HardwareStreamDescription(
      isActive: isActive,
      startingChannel: startingChannel.flatMap { $0 > 0 ? Int($0) : nil },
      virtualFormat: virtualDescription.map(AudioStreamFormat.init),
      physicalFormat: physicalDescription.map(AudioStreamFormat.init)
    )
  }

  private func channelCount(
    deviceObjectID: AudioObjectID,
    scope: AudioObjectPropertyScope
  ) throws(AudioCatalogError) -> Int {
    var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
    var size: UInt32 = 0
    try check(
      AudioObjectGetPropertyDataSize(deviceObjectID, &address, 0, nil, &size),
      objectKind: .device,
      property: .deviceStreamConfiguration,
      operation: .readPropertySize
    )
    guard size > 0 else { return 0 }

    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size),
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { storage.deallocate() }
    try check(
      AudioObjectGetPropertyData(deviceObjectID, &address, 0, nil, &size, storage),
      objectKind: .device,
      property: .deviceStreamConfiguration,
      operation: .readProperty
    )
    let buffers = UnsafeMutableAudioBufferListPointer(
      storage.bindMemory(to: AudioBufferList.self, capacity: 1)
    )
    return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
  }

  private func objectIDs(
    objectID: AudioObjectID,
    objectKind: AudioHardwareObjectKind,
    property: AudioHardwareProperty,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) throws(AudioCatalogError) -> [AudioObjectID] {
    var address = propertyAddress(selector, scope: scope)
    var size: UInt32 = 0
    try check(
      AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size),
      objectKind: objectKind,
      property: property,
      operation: .readPropertySize
    )
    guard size > 0 else { return [] }
    guard Int(size) % MemoryLayout<AudioObjectID>.stride == 0 else {
      throw invalidData(
        objectKind: objectKind,
        property: property,
        reason: "the byte count is not a multiple of the object identifier size"
      )
    }

    var values = [
      AudioObjectID
    ](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
    let status = values.withUnsafeMutableBytes { storage -> OSStatus in
      guard let baseAddress = storage.baseAddress else { return kAudioHardwareUnspecifiedError }
      return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, baseAddress)
    }
    try check(
      status,
      objectKind: objectKind,
      property: property,
      operation: .readProperty
    )
    return try CoreAudioPropertyDataValidator.objectIDs(
      from: values,
      returnedByteCount: size,
      objectKind: objectKind,
      property: property
    )
  }

  private func boolean(
    objectID: AudioObjectID,
    objectKind: AudioHardwareObjectKind,
    property: AudioHardwareProperty,
    selector: AudioObjectPropertySelector
  ) throws(AudioCatalogError) -> Bool {
    let value: UInt32 = try scalar(
      objectID: objectID,
      objectKind: objectKind,
      property: property,
      selector: selector,
      default: 0
    )
    return value != 0
  }

  private func optionalBoolean(
    objectID: AudioObjectID,
    objectKind: AudioHardwareObjectKind,
    property: AudioHardwareProperty,
    selector: AudioObjectPropertySelector
  ) throws(AudioCatalogError) -> Bool? {
    let value: UInt32? = try optionalScalar(
      objectID: objectID,
      objectKind: objectKind,
      property: property,
      selector: selector,
      default: 0
    )
    return value.map { $0 != 0 }
  }

  private func scalar<T>(
    objectID: AudioObjectID,
    objectKind: AudioHardwareObjectKind,
    property: AudioHardwareProperty,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    default initialValue: T
  ) throws(AudioCatalogError) -> T {
    var address = propertyAddress(selector, scope: scope)
    var value = initialValue
    var size = UInt32(MemoryLayout<T>.stride)
    let status = withUnsafeMutableBytes(of: &value) { storage -> OSStatus in
      guard let baseAddress = storage.baseAddress else { return kAudioHardwareUnspecifiedError }
      return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, baseAddress)
    }
    try check(
      status,
      objectKind: objectKind,
      property: property,
      operation: .readProperty
    )
    guard size == MemoryLayout<T>.stride else {
      throw invalidData(
        objectKind: objectKind,
        property: property,
        reason: "the returned byte count does not match the expected scalar size"
      )
    }
    return value
  }

  private func optionalScalar<T>(
    objectID: AudioObjectID,
    objectKind: AudioHardwareObjectKind,
    property: AudioHardwareProperty,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    default initialValue: T
  ) throws(AudioCatalogError) -> T? {
    guard hasProperty(objectID: objectID, selector: selector, scope: scope) else { return nil }
    return try scalar(
      objectID: objectID,
      objectKind: objectKind,
      property: property,
      selector: selector,
      scope: scope,
      default: initialValue
    )
  }

  private func string(
    objectID: AudioObjectID,
    objectKind: AudioHardwareObjectKind,
    property: AudioHardwareProperty,
    selector: AudioObjectPropertySelector
  ) throws(AudioCatalogError) -> String? {
    var address = propertyAddress(selector)
    var size: UInt32 = 0
    try check(
      AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size),
      objectKind: objectKind,
      property: property,
      operation: .readPropertySize
    )
    try CoreAudioPropertyDataValidator.validateStringByteCount(
      size,
      objectKind: objectKind,
      property: property
    )
    var value: CFString?
    let status = withUnsafeMutablePointer(to: &value) { pointer in
      AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
    }
    try check(
      status,
      objectKind: objectKind,
      property: property,
      operation: .readProperty
    )
    return value as String?
  }

  private func optionalString(
    objectID: AudioObjectID,
    objectKind: AudioHardwareObjectKind,
    property: AudioHardwareProperty,
    selector: AudioObjectPropertySelector
  ) throws(AudioCatalogError) -> String? {
    guard hasProperty(objectID: objectID, selector: selector) else { return nil }
    return try string(
      objectID: objectID,
      objectKind: objectKind,
      property: property,
      selector: selector
    )
  }

  private func hasProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> Bool {
    var address = propertyAddress(selector, scope: scope)
    return AudioObjectHasProperty(objectID, &address)
  }

  private func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
  }

  private func scope(for direction: AudioDirection) -> AudioObjectPropertyScope {
    switch direction {
    case .input:
      return kAudioDevicePropertyScopeInput
    case .output:
      return kAudioDevicePropertyScopeOutput
    }
  }

  private func check(
    _ status: OSStatus,
    objectKind: AudioHardwareObjectKind,
    property: AudioHardwareProperty,
    operation: AudioHardwareOperation
  ) throws(AudioCatalogError) {
    guard status == noErr else {
      throw .hardware(
        AudioHardwareError(
          objectKind: objectKind,
          property: property,
          operation: operation,
          status: AudioHardwareStatus(rawValue: status)
        )
      )
    }
  }

  private func invalidData(
    objectKind: AudioHardwareObjectKind,
    property: AudioHardwareProperty,
    reason: String
  ) -> AudioCatalogError {
    .invalidData(
      AudioHardwareDataError(
        objectKind: objectKind,
        property: property,
        reason: reason
      )
    )
  }
}

enum CoreAudioPropertyDataValidator {
  static func objectIDs(
    from allocatedValues: [HardwareObjectID],
    returnedByteCount: UInt32,
    objectKind: AudioHardwareObjectKind,
    property: AudioHardwareProperty
  ) throws(AudioCatalogError) -> [HardwareObjectID] {
    let stride = MemoryLayout<HardwareObjectID>.stride
    guard Int(returnedByteCount) % stride == 0 else {
      throw invalidData(
        objectKind: objectKind,
        property: property,
        reason: "the returned byte count is not a multiple of the object identifier size"
      )
    }
    let returnedCount = Int(returnedByteCount) / stride
    guard returnedCount <= allocatedValues.count else {
      throw invalidData(
        objectKind: objectKind,
        property: property,
        reason: "the returned byte count exceeds the allocated object identifier storage"
      )
    }
    return Array(allocatedValues.prefix(returnedCount))
  }

  static func validateStringByteCount(
    _ byteCount: UInt32,
    objectKind: AudioHardwareObjectKind,
    property: AudioHardwareProperty
  ) throws(AudioCatalogError) {
    guard byteCount == MemoryLayout<CFString?>.stride else {
      throw invalidData(
        objectKind: objectKind,
        property: property,
        reason: "the byte count does not match the expected CFString reference size"
      )
    }
  }

  private static func invalidData(
    objectKind: AudioHardwareObjectKind,
    property: AudioHardwareProperty,
    reason: String
  ) -> AudioCatalogError {
    .invalidData(
      AudioHardwareDataError(
        objectKind: objectKind,
        property: property,
        reason: reason
      )
    )
  }
}

extension AudioStreamFormat {
  fileprivate init(_ description: AudioStreamBasicDescription) {
    self.init(
      sampleRate: description.mSampleRate,
      formatID: description.mFormatID,
      formatFlags: description.mFormatFlags,
      bytesPerPacket: description.mBytesPerPacket,
      framesPerPacket: description.mFramesPerPacket,
      bytesPerFrame: description.mBytesPerFrame,
      channelsPerFrame: description.mChannelsPerFrame,
      bitsPerChannel: description.mBitsPerChannel
    )
  }
}
