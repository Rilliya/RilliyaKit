// SPDX-License-Identifier: Apache-2.0

import CoreAudio
import Dispatch

protocol AudioCatalogChangeSource: Sendable {
  func changes() -> AsyncStream<Void>
}

struct CoreAudioCatalogChangeSource: AudioCatalogChangeSource {
  func changes() -> AsyncStream<Void> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let session = CoreAudioCatalogListenerSession()
      continuation.onTermination = { @Sendable _ in
        session.stop()
      }
      session.start(continuation: continuation)
    }
  }
}

private final class CoreAudioCatalogListenerSession: @unchecked Sendable {
  private static let fallbackInterval: DispatchTimeInterval = .seconds(60)

  private let provider = CoreAudioCatalogProvider()
  private let queue = DispatchQueue(
    label: "moe.uwucocoa.rilliyakit.catalog-observation",
    qos: .utility
  )
  private let queueKey = DispatchSpecificKey<Void>()
  private var continuation: AsyncStream<Void>.Continuation?
  private var listeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
  private var fallbackTimer: DispatchSourceTimer?
  private var isStopped = false

  init() {
    queue.setSpecific(key: queueKey, value: ())
  }

  func start(continuation: AsyncStream<Void>.Continuation) {
    queue.async { [weak self, continuation] in
      self?.startOnQueue(continuation: continuation)
    }
  }

  func stop() {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      stopOnQueue()
    } else {
      queue.sync { [self] in
        stopOnQueue()
      }
    }
  }

  private func startOnQueue(continuation: AsyncStream<Void>.Continuation) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !isStopped else { return }
    self.continuation = continuation

    addListener(to: AudioObjectID(kAudioObjectSystemObject))
    refreshObservedObjects()

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + Self.fallbackInterval,
      repeating: Self.fallbackInterval,
      leeway: .seconds(5)
    )
    timer.setEventHandler { [continuation] in
      continuation.yield(())
    }
    fallbackTimer = timer
    timer.resume()
  }

  private func refreshObservedObjects() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !isStopped, continuation != nil else { return }
    guard
      let deviceObjectIDs = try? provider.deviceObjectIDs(),
      let processObjectIDs = try? provider.processObjectIDs()
    else {
      return
    }

    let desiredObjectIDs =
      Set(deviceObjectIDs).union(processObjectIDs).union([
        AudioObjectID(kAudioObjectSystemObject)
      ])
    let observedObjectIDs = Set(listeners.keys)
    for objectID in observedObjectIDs.subtracting(desiredObjectIDs) {
      removeListener(from: objectID)
    }
    for objectID in desiredObjectIDs.subtracting(observedObjectIDs) {
      addListener(to: objectID)
    }
  }

  private func addListener(to objectID: AudioObjectID) {
    guard let continuation, listeners[objectID] == nil else { return }
    let listener: AudioObjectPropertyListenerBlock = {
      [weak self, continuation] addressCount, addresses in
      continuation.yield(())
      guard objectID == AudioObjectID(kAudioObjectSystemObject) else { return }

      var objectListChanged = false
      for index in 0..<Int(addressCount) {
        let selector = addresses[index].mSelector
        if selector == kAudioHardwarePropertyDevices
          || selector == kAudioHardwarePropertyProcessObjectList
        {
          objectListChanged = true
          break
        }
      }
      if objectListChanged {
        self?.queue.async { [weak self] in
          self?.refreshObservedObjects()
        }
      }
    }
    var address = wildcardAddress
    let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, listener)
    if status == noErr {
      listeners[objectID] = listener
    }
  }

  private func removeListener(from objectID: AudioObjectID) {
    guard let listener = listeners.removeValue(forKey: objectID) else { return }
    var address = wildcardAddress
    AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, listener)
  }

  private func stopOnQueue() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !isStopped else { return }
    isStopped = true

    fallbackTimer?.cancel()
    fallbackTimer = nil
    for objectID in Array(listeners.keys) {
      removeListener(from: objectID)
    }
    continuation = nil
  }

  private var wildcardAddress: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertySelectorWildcard,
      mScope: kAudioObjectPropertyScopeWildcard,
      mElement: kAudioObjectPropertyElementWildcard
    )
  }
}

struct PollingAudioCatalogChangeSource: AudioCatalogChangeSource {
  let interval: Duration

  func changes() -> AsyncStream<Void> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task { @Sendable in
        do {
          while !Task.isCancelled {
            try await Task.sleep(for: interval)
            continuation.yield(())
          }
        } catch is CancellationError {
          // Cancellation is the expected stream termination path.
        } catch {
          // Duration-based sleep has no other recoverable failure.
        }
        continuation.finish()
      }
      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }
}
