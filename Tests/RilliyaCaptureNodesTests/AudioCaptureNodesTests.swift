// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaCapture
import RilliyaCore
import RilliyaEngine
import RilliyaGraph
import RilliyaRealtime
import Testing

@testable import RilliyaCaptureNodes

@Suite("Audio capture graph nodes")
struct AudioCaptureNodesTests {
  @Test("Native capture nodes expose one demand-driven audio output")
  func nativeCaptureDescriptors() throws {
    let processID = try #require(AudioProcessID(rawValue: 42))
    let deviceID = try #require(AudioDeviceID(rawValue: "test.input"))

    let application = ApplicationAudioInput(processID: processID)
    let device = DeviceAudioInput(deviceID: deviceID)
    let outputDevice = OutputDeviceAudioInput(deviceID: deviceID)

    for descriptor in [
      application.makeDescriptor(), device.makeDescriptor(), outputDevice.makeDescriptor(),
    ] {
      #expect(descriptor.activation == .onDemand)
      #expect(descriptor.ports.count == 1)
      #expect(descriptor.ports[0].id.rawValue == "audio")
      #expect(descriptor.ports[0].direction == .output)
      #expect(descriptor.ports[0].connectionPolicy == .fanOut)
      guard case .audio(let signal) = descriptor.ports[0].signalType else {
        Issue.record("Expected an audio output")
        continue
      }
      #expect(signal.channelCount == .any)
      #expect(signal.sampleRate == .any)
    }
  }

  @Test("Output-device nodes preserve explicit and default targets")
  func outputDeviceTargets() throws {
    let deviceID = try #require(AudioDeviceID(rawValue: "test.output"))
    let processID = try #require(AudioProcessID(rawValue: 42))
    let exclusion = DeviceOutputCaptureProcessExclusion(
      processIDs: [processID],
      excludesCurrentProcess: false
    )

    #expect(OutputDeviceAudioInput().target == .systemDefault)
    #expect(OutputDeviceAudioInput().processExclusion.excludesCurrentProcess)
    #expect(OutputDeviceAudioInput(deviceID: deviceID).target == .device(deviceID))
    #expect(
      OutputDeviceAudioInput(target: .device(deviceID), processExclusion: exclusion).target
        == .device(deviceID)
    )
    #expect(
      OutputDeviceAudioInput(target: .device(deviceID), processExclusion: exclusion)
        .processExclusion == exclusion
    )
  }

  @Test("A prepared capture source participates in the ordinary engine lifecycle")
  func capturedFramesReachTerminalAnalyzer() async throws {
    let format = try AudioProcessingFormat(sampleRate: 48_000, channelCount: 1)
    let session = try StubCaptureSession(format: format)
    let recorder = WindowRecorder()
    var graph = AudioGraph()
    let source = try graph.add(StubCaptureNode(session: session))
    let analyzer = try graph.add(
      WindowAnalyzerNode { window in
        await recorder.append(window)
      }
    )
    try graph.connect(source.audio, to: analyzer.input)
    let configuration = try AudioGraphEngineConfiguration(
      defaultFormat: format,
      renderQuantumFrameCount: 2,
      maximumScratchByteCount: 1_024,
      driver: .manual
    )
    let engine = try await AudioGraphEngine.prepare(graph, configuration: configuration)

    try await engine.start()
    #expect(session.startCount == 1)
    session.write([0.25, -0.5])
    try await engine.renderOnce()
    let window = try #require(await waitForWindow(recorder))
    try await engine.stop()

    #expect(Array(window.samples(forChannel: 0)) == [0.25, -0.5])
    #expect(session.stopCount == 1)
  }
}

private final class StubCaptureSession: AudioGraphCaptureSession, @unchecked Sendable {
  let frameDistributor: AudioRealtimeFrameDistributor

  private let lock = NSLock()
  private var starts = 0
  private var stops = 0

  init(format: AudioProcessingFormat) throws {
    frameDistributor = try AudioRealtimeFrameDistributor(
      format: format,
      capacityFrameCount: 8,
      maximumSubscriberCount: 1
    )
  }

  func subscribeToFrames() throws -> AudioRealtimeFrameSubscription {
    try frameDistributor.subscribe()
  }

  var startCount: Int {
    lock.withLock { starts }
  }

  var stopCount: Int {
    lock.withLock { stops }
  }

  func start() throws {
    lock.withLock { starts += 1 }
  }

  func stop() throws {
    lock.withLock { stops += 1 }
  }

  func write(_ samples: [Float]) {
    samples.withUnsafeBufferPointer { samples in
      guard let baseAddress = samples.baseAddress else { return }
      var channel = UnsafePointer(baseAddress)
      withUnsafePointer(to: &channel) { channels in
        _ = frameDistributor.writePlanar(
          UnsafeBufferPointer(start: channels, count: 1),
          frameCount: samples.count
        )
      }
    }
  }
}

private struct StubCaptureNode: AudioGraphExecutableNode {
  struct Ports: AudioGraphNodePorts {
    let audio = AudioGraphPortID(rawValue: "audio")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "test.capture.stub-input")
  static let ports = Ports()
  let session: StubCaptureSession

  func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        .output(Self.ports.audio, signal: .audio(AudioGraphAudioSignalType()))
      ]
    )
  }

  func prepare(
    context: AudioGraphNodePreparationContext
  ) async throws -> any PreparedAudioGraphNode {
    try PreparedCapturedAudioSourceNode(
      session: session,
      outputPortID: Self.ports.audio,
      maximumFrameCount: context.maximumFrameCount
    )
  }
}

private struct WindowAnalyzerNode: AudioGraphExecutableNode {
  struct Ports: AudioGraphNodePorts {
    let input = AudioGraphPortID(rawValue: "input")
  }

  static let typeID = AudioGraphNodeTypeID(rawValue: "test.capture.window-analyzer")
  static let ports = Ports()
  let handler: PreparedAudioWindowSink.Handler

  init(handler: @escaping PreparedAudioWindowSink.Handler) {
    self.handler = handler
  }

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
    let configuration = try AudioWindowSinkConfiguration(
      windowFrameCount: 2,
      hopFrameCount: 2,
      bufferCapacityFrameCount: 4
    )
    return try PreparedAudioWindowSink(
      inputPortID: Self.ports.input,
      format: context.singleAudioInputFormat(for: Self.ports.input),
      configuration: configuration,
      handler: handler
    )
  }
}

private actor WindowRecorder {
  private var firstWindow: AudioAnalysisWindow?

  func append(_ window: AudioAnalysisWindow) {
    if firstWindow == nil {
      firstWindow = window
    }
  }

  func window() -> AudioAnalysisWindow? {
    firstWindow
  }
}

private func waitForWindow(_ recorder: WindowRecorder) async -> AudioAnalysisWindow? {
  let clock = ContinuousClock()
  let deadline = clock.now + .seconds(1)
  while clock.now < deadline {
    if let window = await recorder.window() { return window }
    try? await Task.sleep(for: .milliseconds(1))
  }
  return await recorder.window()
}
