// SPDX-License-Identifier: Apache-2.0

import RilliyaEngine
import RilliyaGraph
import RilliyaRealtime
import Testing

@Suite("Audio graph engine")
struct AudioGraphEngineTests {
  @Test("Executes a source into an asynchronous terminal analyzer")
  func executesTerminalAnalyzer() async throws {
    let recorder = WindowRecorder()
    var graph = AudioGraph()
    let source = try graph.add(ConstantSourceNode(sample: 0.25))
    let gain = try graph.add(HalfGainNode())
    let analyzer = try graph.add(
      WindowAnalyzerNode { window in
        await recorder.append(window)
      }
    )
    try graph.connect(source.audio, to: gain.input)
    try graph.connect(gain.output, to: analyzer.input)
    let configuration = try AudioGraphEngineConfiguration(
      defaultFormat: .stereo48kHz,
      renderQuantumFrameCount: 2,
      maximumScratchByteCount: 1_024,
      driver: .manual
    )

    let engine = try await AudioGraphEngine.prepare(graph, configuration: configuration)
    if case .ready = await engine.state {
    } else {
      Issue.record("Expected a ready engine")
    }
    try await engine.start()
    try await engine.renderOnce()
    try await engine.renderOnce()
    try await engine.renderOnce()
    let windows = await waitForWindows(recorder, count: 2)
    try await engine.stop()

    #expect(windows.count == 2)
    #expect(Array(windows[0].samples(forChannel: 0)) == [0.125, 0.125, 0.125, 0.125])
    #expect(windows.map(\.startFrame) == [0, 2])
    if case .stopped = await engine.state {
    } else {
      Issue.record("Expected a stopped engine")
    }
  }

  @Test("Built-in window analyzer is a terminal node with bounded shutdown")
  func builtInAnalyzerDoesNotBlockShutdown() async throws {
    let gate = HandlerGate()
    let sinkConfiguration = try AudioWindowSinkConfiguration(
      windowFrameCount: 2,
      hopFrameCount: 2,
      bufferCapacityFrameCount: 4
    )
    var graph = AudioGraph()
    let source = try graph.add(ConstantSourceNode(sample: 0.25))
    let analyzer = try graph.add(
      AudioWindowAnalyzerNode(configuration: sinkConfiguration) { _ in
        await gate.blockUntilReleased()
      }
    )
    try graph.connect(source.audio, to: analyzer.input)
    let engine = try await AudioGraphEngine.prepare(
      graph,
      configuration: manualConfiguration()
    )

    try await engine.start()
    try await engine.renderOnce()
    await gate.waitUntilBlocked()
    try await engine.stop()
    await gate.release()

    #expect(analyzer.input.portID == AudioWindowAnalyzerNode.ports.input)
    if case .stopped = await engine.state {
    } else {
      Issue.record("Expected an uncooperative handler not to block engine shutdown")
    }
  }

  @Test("Starts consumers before sources and stops sources before consumers")
  func lifecycleOrderProtectsGraphBoundaries() async throws {
    let recorder = LifecycleRecorder()
    var graph = AudioGraph()
    let source = try graph.add(LifecycleSourceNode(recorder: recorder))
    let sink = try graph.add(LifecycleSinkNode(recorder: recorder))
    try graph.connect(source.audio, to: sink.input)
    let engine = try await AudioGraphEngine.prepare(
      graph,
      configuration: manualConfiguration()
    )

    try await engine.start()
    try await engine.stop()

    #expect(
      await recorder.events == [
        "sink.start",
        "source.start",
        "source.stop",
        "sink.stop",
      ]
    )
  }

  @Test("Rejects a semantic-only node on an active path")
  func rejectsNonExecutableSink() async throws {
    var graph = AudioGraph()
    let sink = try graph.add(SemanticOnlySink())
    do {
      _ = try await AudioGraphEngine.prepare(graph)
      Issue.record("Expected semantic-only node preparation to fail")
    } catch let error as AudioGraphEngineError {
      guard case .nodeIsNotExecutable(let nodeID, let typeID) = error else {
        Issue.record("Received unexpected error: \(error)")
        return
      }
      #expect(nodeID == sink.id)
      #expect(typeID == SemanticOnlySink.typeID)
    }
  }

  @Test("Unsupported signal execution reports its exact connection and endpoints")
  func unsupportedSignalRetainsConnectionContext() async throws {
    var graph = AudioGraph()
    let source = try graph.add(UnsupportedControlNode(role: .source))
    let sink = try graph.add(UnsupportedControlNode(role: .sink))
    let connectionID = try graph.connect(source.output, to: sink.input)

    do {
      _ = try await AudioGraphEngine.prepare(graph)
      Issue.record("Expected control execution to be rejected")
    } catch let error as AudioGraphEngineError {
      guard case .unsupportedSignalConnection(let failedID, let from, let to) = error else {
        Issue.record("Received unexpected error: \(error)")
        return
      }
      #expect(failedID == connectionID)
      #expect(from == source.output)
      #expect(to == sink.input)
      #expect(error.nodeIDs == [source.id, sink.id])
      #expect(error.connectionIDs == [connectionID])
      #expect(error.portAddresses == [source.output, sink.input])
      #expect(error.recoverySuggestion?.contains("semantic-only") == true)
      let contextual: any AudioGraphContextualError = error
      #expect(contextual.connectionIDs == [connectionID])
    }
  }

  @Test("Unsupported feedback execution reports involved topology")
  func feedbackRetainsTopologyContext() async throws {
    var graph = AudioGraph()
    let relay = try graph.add(ExecutableRelayNode(breaksCycle: false, isSink: false))
    let stateBreaker = try graph.add(ExecutableRelayNode(breaksCycle: true, isSink: true))
    let firstConnection = try graph.connect(relay.output, to: stateBreaker.input)
    let secondConnection = try graph.connect(stateBreaker.output, to: relay.input)

    do {
      _ = try await AudioGraphEngine.prepare(graph)
      Issue.record("Expected feedback execution to be rejected")
    } catch let error as AudioGraphEngineError {
      guard case .unsupportedFeedbackCycle(let nodeIDs, let connectionIDs) = error else {
        Issue.record("Received unexpected error: \(error)")
        return
      }
      #expect(Set(nodeIDs) == Set([relay.id, stateBreaker.id]))
      #expect(Set(connectionIDs) == Set([firstConnection, secondConnection]))
      #expect(error.nodeIDs == nodeIDs)
      #expect(error.connectionIDs == connectionIDs)
    }
  }

  @Test("Does not activate a source with no downstream sink")
  func rejectsGraphWithoutSink() async throws {
    var graph = AudioGraph()
    _ = try graph.add(ConstantSourceNode(sample: 0.5))

    do {
      _ = try await AudioGraphEngine.prepare(graph)
      Issue.record("Expected a graph without a sink to fail")
    } catch let error as AudioGraphEngineError {
      guard case .noActiveSink = error else {
        Issue.record("Received unexpected error: \(error)")
        return
      }
    }
  }

  @Test("Leaves an unconsumed executable source unprepared")
  func ignoresInactiveSource() async throws {
    let recorder = WindowRecorder()
    var graph = AudioGraph()
    let source = try graph.add(ConstantSourceNode(sample: 0.25))
    let analyzer = try graph.add(WindowAnalyzerNode { window in await recorder.append(window) })
    _ = try graph.add(ThrowingSourceNode())
    try graph.connect(source.audio, to: analyzer.input)

    let engine = try await AudioGraphEngine.prepare(
      graph,
      configuration: manualConfiguration()
    )
    try await engine.start()
    try await engine.stop()
  }

  @Test("Rejects scratch storage beyond the configured budget")
  func enforcesScratchBudget() async throws {
    let recorder = WindowRecorder()
    var graph = AudioGraph()
    let source = try graph.add(ConstantSourceNode(sample: 0.25))
    let analyzer = try graph.add(WindowAnalyzerNode { window in await recorder.append(window) })
    try graph.connect(source.audio, to: analyzer.input)
    let configuration = try AudioGraphEngineConfiguration(
      defaultFormat: .stereo48kHz,
      renderQuantumFrameCount: 512,
      maximumScratchByteCount: 1_024,
      driver: .manual
    )

    do {
      _ = try await AudioGraphEngine.prepare(graph, configuration: configuration)
      Issue.record("Expected the scratch-memory bound to reject preparation")
    } catch let error as AudioGraphEngineError {
      guard case .scratchMemoryLimitExceeded(let requiredByteCount, let limit) = error else {
        Issue.record("Received unexpected error: \(error)")
        return
      }
      #expect(requiredByteCount == 2_048)
      #expect(limit == 1_024)
    }
  }

  @Test("A start failure is terminal and rolls back prepared lifecycle")
  func startFailureIsTerminal() async throws {
    var graph = AudioGraph()
    let node = try graph.add(FailingStartNode())
    let engine = try await AudioGraphEngine.prepare(
      graph,
      configuration: manualConfiguration()
    )
    do {
      try await engine.start()
      Issue.record("Expected node startup to fail")
    } catch let error as AudioGraphEngineError {
      guard case .nodeFailure(let failure) = error else {
        Issue.record("Received unexpected error: \(error)")
        return
      }
      #expect(failure.nodeID == node.id)
      #expect(failure.nodeTypeID == FailingStartNode.typeID)
      #expect(failure.stage == .start)
      #expect(failure.underlyingError as? TestRuntimeError == .start)
      #expect(error.underlyingError as? TestRuntimeError == .start)
    }
    guard case .failed(let failure) = await engine.state,
      case .nodeFailure(let context) = failure
    else {
      Issue.record("Expected a terminal node failure state")
      return
    }
    #expect(context.nodeID == node.id)
  }

  @Test("Publishes asynchronous render failures with structured node context")
  func publishesAsynchronousRenderFailure() async throws {
    var graph = AudioGraph()
    let node = try graph.add(FailingRenderNode())
    let engine = try await AudioGraphEngine.prepare(graph)
    let updates = await engine.states()
    let failureTask = Task<AudioGraphEngineError?, Never> {
      for await state in updates {
        guard case .failed(let error) = state else { continue }
        return error
      }
      return nil
    }

    try await engine.start()
    let failure = await failureTask.value

    guard let failure, case .nodeRenderFailed(let nodeID, let nodeTypeID, _) = failure else {
      Issue.record("Expected a published render failure")
      return
    }
    #expect(nodeID == node.id)
    #expect(nodeTypeID == FailingRenderNode.typeID)
    #expect(failure.nodeIDs == [node.id])
  }

  private func manualConfiguration() throws -> AudioGraphEngineConfiguration {
    try AudioGraphEngineConfiguration(
      defaultFormat: .stereo48kHz,
      renderQuantumFrameCount: 2,
      maximumScratchByteCount: 1_024,
      driver: .manual
    )
  }
}

private actor WindowRecorder {
  private var storage: [AudioAnalysisWindow] = []

  func append(_ window: AudioAnalysisWindow) {
    storage.append(window)
  }

  func windows() -> [AudioAnalysisWindow] {
    storage
  }
}

private actor HandlerGate {
  private var isBlocked = false
  private var blockContinuation: CheckedContinuation<Void, Never>?
  private var observers: [CheckedContinuation<Void, Never>] = []

  func blockUntilReleased() async {
    isBlocked = true
    let observers = observers
    self.observers.removeAll(keepingCapacity: false)
    for observer in observers {
      observer.resume()
    }
    await withCheckedContinuation { continuation in
      blockContinuation = continuation
    }
  }

  func waitUntilBlocked() async {
    if isBlocked { return }
    await withCheckedContinuation { continuation in
      observers.append(continuation)
    }
  }

  func release() {
    blockContinuation?.resume()
    blockContinuation = nil
  }
}

private actor LifecycleRecorder {
  private(set) var events: [String] = []

  func append(_ event: String) {
    events.append(event)
  }
}

private struct LifecycleSourceNode: AudioGraphExecutableNode {
  struct Ports: AudioGraphNodePorts {
    let audio = AudioGraphPortID(rawValue: "audio")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "test.engine.lifecycle-source")
  static let ports = Ports()
  let recorder: LifecycleRecorder

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        .output(
          Self.ports.audio,
          signal: .audio(
            AudioGraphAudioSignalType(
              channelCount: .fixed(1),
              sampleRate: .fixed(48_000)
            )
          )
        )
      ]
    )
  }

  func prepare(
    context: AudioGraphNodePreparationContext
  ) async throws -> any PreparedAudioGraphNode {
    LifecycleRuntime(
      name: "source",
      recorder: recorder,
      outputFormats: [
        Self.ports.audio: try AudioProcessingFormat(sampleRate: 48_000, channelCount: 1)
      ]
    )
  }
}

private struct LifecycleSinkNode: AudioGraphExecutableNode {
  struct Ports: AudioGraphNodePorts {
    let input = AudioGraphPortID(rawValue: "input")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "test.engine.lifecycle-sink")
  static let ports = Ports()
  let recorder: LifecycleRecorder

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        .input(Self.ports.input, signal: .audio(AudioGraphAudioSignalType()))
      ],
      activation: .sink
    )
  }

  func prepare(
    context: AudioGraphNodePreparationContext
  ) async throws -> any PreparedAudioGraphNode {
    _ = try context.singleAudioInputFormat(for: Self.ports.input)
    return LifecycleRuntime(name: "sink", recorder: recorder, outputFormats: [:])
  }
}

private final class LifecycleRuntime: PreparedAudioGraphNode, @unchecked Sendable {
  let outputFormats: [AudioGraphPortID: AudioProcessingFormat]
  let timing = AudioNodeTiming.transparent

  private let name: String
  private let recorder: LifecycleRecorder

  init(
    name: String,
    recorder: LifecycleRecorder,
    outputFormats: [AudioGraphPortID: AudioProcessingFormat]
  ) {
    self.name = name
    self.recorder = recorder
    self.outputFormats = outputFormats
  }

  func start() async throws {
    await recorder.append("\(name).start")
  }

  func render(context: AudioGraphRenderContext) -> AudioRenderResult {
    .rendered
  }

  func stop() async throws {
    await recorder.append("\(name).stop")
  }
}

private func waitForWindows(
  _ recorder: WindowRecorder,
  count: Int
) async -> [AudioAnalysisWindow] {
  let clock = ContinuousClock()
  let deadline = clock.now + .seconds(1)
  while clock.now < deadline {
    let windows = await recorder.windows()
    if windows.count >= count { return windows }
    try? await Task.sleep(for: .milliseconds(1))
  }
  return await recorder.windows()
}

private struct ConstantSourceNode: AudioGraphExecutableNode {
  struct Ports: AudioGraphNodePorts {
    let audio = AudioGraphPortID(rawValue: "audio")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "test.engine.constant-source")
  static let ports = Ports()
  let sample: Float

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        .output(
          Self.ports.audio,
          signal: .audio(
            AudioGraphAudioSignalType(
              channelCount: .fixed(1),
              sampleRate: .fixed(48_000)
            )
          )
        )
      ]
    )
  }

  func prepare(
    context: AudioGraphNodePreparationContext
  ) async throws -> any PreparedAudioGraphNode {
    let format = try AudioProcessingFormat(sampleRate: 48_000, channelCount: 1)
    let preparation = try AudioRenderPreparation(
      format: format,
      maximumFrameCount: context.maximumFrameCount
    )
    return PreparedAudioSourceGraphNode(
      source: ConstantPreparedSource(preparation: preparation, sample: sample),
      outputPortID: Self.ports.audio
    )
  }
}

private final class ConstantPreparedSource: PreparedAudioSource, @unchecked Sendable {
  let preparation: AudioRenderPreparation
  let timing = AudioNodeTiming.transparent
  let sample: Float

  init(preparation: AudioRenderPreparation, sample: Float) {
    self.preparation = preparation
    self.sample = sample
  }

  func render(
    outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRenderResult {
    guard (0...preparation.maximumFrameCount).contains(frameCount) else {
      return .invalidFrameCount
    }
    guard outputChannels.count >= preparation.format.channelCount else {
      return .insufficientChannels
    }
    for channel in 0..<preparation.format.channelCount {
      outputChannels[channel].update(repeating: sample, count: frameCount)
    }
    return .rendered
  }
}

private struct HalfGainNode: AudioGraphExecutableNode {
  struct Ports: AudioGraphNodePorts {
    let input = AudioGraphPortID(rawValue: "input")
    let output = AudioGraphPortID(rawValue: "output")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "test.engine.half-gain")
  static let ports = Ports()

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    let signal = AudioGraphSignalType.audio(AudioGraphAudioSignalType())
    return AudioGraphNodeDescriptor(
      ports: [
        .input(Self.ports.input, signal: signal),
        .output(Self.ports.output, signal: signal),
      ]
    )
  }

  func prepare(
    context: AudioGraphNodePreparationContext
  ) async throws -> any PreparedAudioGraphNode {
    let format = try context.singleAudioInputFormat(for: Self.ports.input)
    let preparation = try AudioRenderPreparation(
      format: format,
      maximumFrameCount: context.maximumFrameCount
    )
    return PreparedAudioProcessorGraphNode(
      processor: HalfGainProcessor(preparation: preparation),
      inputPortID: Self.ports.input,
      outputPortID: Self.ports.output
    )
  }
}

private final class HalfGainProcessor: PreparedAudioProcessor, @unchecked Sendable {
  let preparation: AudioRenderPreparation
  let timing = AudioNodeTiming.transparent

  init(preparation: AudioRenderPreparation) {
    self.preparation = preparation
  }

  func process(
    inputChannels: UnsafeBufferPointer<UnsafePointer<Float>>,
    outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRenderResult {
    guard (0...preparation.maximumFrameCount).contains(frameCount) else {
      return .invalidFrameCount
    }
    guard inputChannels.count >= preparation.format.channelCount,
      outputChannels.count >= preparation.format.channelCount
    else {
      return .insufficientChannels
    }
    for channel in 0..<preparation.format.channelCount {
      for frame in 0..<frameCount {
        outputChannels[channel][frame] = inputChannels[channel][frame] * 0.5
      }
    }
    return .rendered
  }
}

private struct WindowAnalyzerNode: AudioGraphExecutableNode {
  struct Ports: AudioGraphNodePorts {
    let input = AudioGraphPortID(rawValue: "input")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "test.engine.window-analyzer")
  static let ports = Ports()
  let handler: PreparedAudioWindowSink.Handler

  init(handler: @escaping PreparedAudioWindowSink.Handler) {
    self.handler = handler
  }

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        .input(
          Self.ports.input,
          signal: .audio(AudioGraphAudioSignalType())
        )
      ],
      activation: .sink
    )
  }

  func prepare(
    context: AudioGraphNodePreparationContext
  ) async throws -> any PreparedAudioGraphNode {
    let configuration = try AudioWindowSinkConfiguration(
      windowFrameCount: 4,
      hopFrameCount: 2,
      bufferCapacityFrameCount: 8
    )
    return try PreparedAudioWindowSink(
      inputPortID: Self.ports.input,
      format: context.singleAudioInputFormat(for: Self.ports.input),
      configuration: configuration,
      handler: handler
    )
  }
}

private struct SemanticOnlySink: AudioGraphNode {
  static let typeID = AudioGraphNodeTypeID(rawValue: "test.engine.semantic-only")

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(ports: [], activation: .sink)
  }
}

private struct UnsupportedControlNode: AudioGraphExecutableNode {
  enum Role: Sendable {
    case source
    case sink
  }

  struct Ports: AudioGraphNodePorts {
    let input = AudioGraphPortID(rawValue: "input")
    let output = AudioGraphPortID(rawValue: "output")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "test.engine.unsupported-control")
  static let ports = Ports()
  let role: Role

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    switch role {
    case .source:
      AudioGraphNodeDescriptor(
        ports: [.output(Self.ports.output, signal: .scalar(.integer))]
      )
    case .sink:
      AudioGraphNodeDescriptor(
        ports: [.input(Self.ports.input, signal: .scalar(.integer))],
        activation: .sink
      )
    }
  }

  func prepare(
    context: AudioGraphNodePreparationContext
  ) async throws -> any PreparedAudioGraphNode {
    throw TestRuntimeError.prepare
  }
}

private struct ExecutableRelayNode: AudioGraphExecutableNode {
  struct Ports: AudioGraphNodePorts {
    let input = AudioGraphPortID(rawValue: "input")
    let output = AudioGraphPortID(rawValue: "output")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "test.engine.executable-relay")
  static let ports = Ports()
  let breaksCycle: Bool
  let isSink: Bool

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    let signal = AudioGraphSignalType.audio(AudioGraphAudioSignalType())
    return AudioGraphNodeDescriptor(
      ports: [
        .input(Self.ports.input, signal: signal),
        .output(Self.ports.output, signal: signal),
      ],
      cycleBehavior: breaksCycle ? .breaksCycle : .combinational,
      activation: isSink ? .sink : .onDemand
    )
  }

  func prepare(
    context: AudioGraphNodePreparationContext
  ) async throws -> any PreparedAudioGraphNode {
    throw TestRuntimeError.prepare
  }
}

private enum TestRuntimeError: Error, Equatable {
  case prepare
  case start
}

private struct ThrowingSourceNode: AudioGraphExecutableNode {
  struct Ports: AudioGraphNodePorts {
    let audio = AudioGraphPortID(rawValue: "audio")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "test.engine.throwing-source")
  static let ports = Ports()

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        .output(
          Self.ports.audio,
          signal: .audio(AudioGraphAudioSignalType())
        )
      ]
    )
  }

  func prepare(
    context: AudioGraphNodePreparationContext
  ) async throws -> any PreparedAudioGraphNode {
    throw TestRuntimeError.prepare
  }
}

private struct FailingStartNode: AudioGraphExecutableNode {
  static let typeID = AudioGraphNodeTypeID(rawValue: "test.engine.failing-start")

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(ports: [], activation: .sink)
  }

  func prepare(
    context: AudioGraphNodePreparationContext
  ) async throws -> any PreparedAudioGraphNode {
    FailingStartRuntime()
  }
}

private final class FailingStartRuntime: PreparedAudioGraphNode, @unchecked Sendable {
  let outputFormats: [AudioGraphPortID: AudioProcessingFormat] = [:]
  let timing = AudioNodeTiming.transparent

  func start() async throws {
    throw TestRuntimeError.start
  }

  func render(context: AudioGraphRenderContext) -> AudioRenderResult {
    .rendered
  }
}

private struct FailingRenderNode: AudioGraphExecutableNode {
  static let typeID = AudioGraphNodeTypeID(rawValue: "test.engine.failing-render")

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(ports: [], activation: .sink)
  }

  func prepare(
    context: AudioGraphNodePreparationContext
  ) async throws -> any PreparedAudioGraphNode {
    FailingRenderRuntime()
  }
}

private final class FailingRenderRuntime: PreparedAudioGraphNode, @unchecked Sendable {
  let outputFormats: [AudioGraphPortID: AudioProcessingFormat] = [:]
  let timing = AudioNodeTiming.transparent

  func render(context: AudioGraphRenderContext) -> AudioRenderResult {
    .invalidFrameCount
  }
}
