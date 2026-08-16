// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaGraph

/// The observable lifecycle of one prepared audio graph engine.
public enum AudioGraphEngineState: @unchecked Sendable {
  /// The graph is prepared but has not started external resources.
  case ready

  /// Nodes and the selected render driver are active.
  case running

  /// The engine stopped normally and cannot be restarted.
  case stopped

  /// An asynchronous render or cleanup failure stopped the engine.
  case failed(AudioGraphEngineError)
}

/// Prepares and runs one validated executable audio graph.
///
/// Graph preparation resolves concrete formats and allocates every render buffer before `start()`.
/// A stopped engine is intentionally terminal; prepare a new engine after changing topology or
/// formats. Control-only node state may be published through node-owned lock-free controls.
public actor AudioGraphEngine {
  /// The immutable configuration used to prepare this engine.
  public nonisolated let configuration: AudioGraphEngineConfiguration

  /// The current lifecycle state.
  public private(set) var state: AudioGraphEngineState = .ready

  private enum Lifecycle {
    case ready
    case running(UUID)
    case stopping
    case stopped
    case failed(AudioGraphEngineError)
  }

  private let plan: PreparedAudioGraphPlan
  private var lifecycle = Lifecycle.ready
  private var driverTask: Task<AudioGraphEngineError?, Never>?
  private var stateContinuations: [UUID: AsyncStream<AudioGraphEngineState>.Continuation] = [:]

  private init(
    configuration: AudioGraphEngineConfiguration,
    plan: PreparedAudioGraphPlan
  ) {
    self.configuration = configuration
    self.plan = plan
  }

  deinit {
    driverTask?.cancel()
    for continuation in stateContinuations.values {
      continuation.finish()
    }
  }

  /// Returns lifecycle updates, including asynchronous render and cleanup failures.
  ///
  /// Every subscriber first receives the current state. Delivery retains only the newest pending
  /// value per subscriber, so an unresponsive observer cannot grow engine memory. Streams finish
  /// after the engine reaches its terminal `stopped` or `failed` state.
  public func states() -> AsyncStream<AudioGraphEngineState> {
    let pair = AsyncStream<AudioGraphEngineState>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    pair.continuation.yield(state)
    if state.isTerminal {
      pair.continuation.finish()
      return pair.stream
    }

    let id = UUID()
    stateContinuations[id] = pair.continuation
    pair.continuation.onTermination = { [weak self] _ in
      Task { await self?.removeStateContinuation(id: id) }
    }
    return pair.stream
  }

  /// Validates the graph, resolves active formats, and prepares every runtime off the render path.
  public static func prepare(
    _ graph: AudioGraph,
    configuration: AudioGraphEngineConfiguration = .standard
  ) async throws -> AudioGraphEngine {
    let snapshot = try graph.snapshot()
    let plan = try await AudioGraphCompiler.prepare(
      snapshot: snapshot,
      configuration: configuration
    )
    return AudioGraphEngine(configuration: configuration, plan: plan)
  }

  /// Starts prepared node resources and the selected render driver.
  public func start() async throws {
    switch lifecycle {
    case .ready:
      break
    case .running:
      return
    case .stopping, .stopped, .failed:
      throw AudioGraphEngineError.alreadyStopped
    }

    do {
      try await plan.start()
    } catch let error as AudioGraphEngineError {
      lifecycle = .failed(error)
      publishState(.failed(error))
      throw error
    }
    let generation = UUID()
    lifecycle = .running(generation)
    publishState(.running)
    guard configuration.driver == .background else { return }

    let task = Task.detached(priority: .high) { [plan] in
      await Self.drive(plan: plan)
    }
    driverTask = task
    Task { [weak self] in
      let failure = await task.value
      await self?.driverFinished(generation: generation, failure: failure)
    }
  }

  /// Renders one quantum for a manually driven engine.
  ///
  /// This actor-isolated convenience is intended for deterministic tools and tests, not direct use
  /// from a Core Audio callback. A future device driver consumes the prepared plan without actor
  /// isolation.
  public func renderOnce() async throws {
    guard configuration.driver == .manual else {
      throw AudioGraphEngineError.manualRenderUnavailable
    }
    guard case .running = lifecycle else {
      throw AudioGraphEngineError.alreadyStopped
    }
    if let failure = plan.render(frameCount: configuration.renderQuantumFrameCount) {
      try? await plan.stop()
      lifecycle = .failed(failure)
      publishState(.failed(failure))
      throw failure
    }
  }

  /// Stops rendering, then attempts cleanup for every started node in reverse order.
  public func stop() async throws {
    switch lifecycle {
    case .ready:
      lifecycle = .stopped
      publishState(.stopped)
      return
    case .running:
      lifecycle = .stopping
    case .stopping:
      return
    case .stopped, .failed:
      return
    }

    let task = driverTask
    driverTask = nil
    task?.cancel()
    _ = await task?.value
    do {
      try await plan.stop()
      lifecycle = .stopped
      publishState(.stopped)
    } catch let error as AudioGraphEngineError {
      lifecycle = .failed(error)
      publishState(.failed(error))
      throw error
    }
  }

  private func driverFinished(
    generation: UUID,
    failure: AudioGraphEngineError?
  ) async {
    guard case .running(let currentGeneration) = lifecycle,
      currentGeneration == generation
    else { return }
    driverTask = nil
    if let failure {
      try? await plan.stop()
      lifecycle = .failed(failure)
      publishState(.failed(failure))
    }
  }

  private func publishState(_ newState: AudioGraphEngineState) {
    state = newState
    for continuation in stateContinuations.values {
      continuation.yield(newState)
    }
    guard newState.isTerminal else { return }
    for continuation in stateContinuations.values {
      continuation.finish()
    }
    stateContinuations.removeAll(keepingCapacity: false)
  }

  private func removeStateContinuation(id: UUID) {
    stateContinuations.removeValue(forKey: id)
  }

  private nonisolated static func drive(
    plan: PreparedAudioGraphPlan
  ) async -> AudioGraphEngineError? {
    let clock = ContinuousClock()
    let quantumSeconds = Double(plan.renderQuantumFrameCount) / plan.driverSampleRate
    let quantum = Duration.seconds(quantumSeconds)
    var deadline = clock.now
    while !Task.isCancelled {
      if let failure = plan.render(frameCount: plan.renderQuantumFrameCount) {
        return failure
      }
      deadline += quantum
      if deadline < clock.now {
        deadline = clock.now
      }
      do {
        try await clock.sleep(until: deadline)
      } catch {
        return nil
      }
    }
    return nil
  }
}

extension AudioGraphEngineState {
  fileprivate var isTerminal: Bool {
    switch self {
    case .stopped, .failed:
      true
    case .ready, .running:
      false
    }
  }
}
