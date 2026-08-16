# Creating graph nodes

A node package exposes an ordinary configured Swift value. Applications using that package should
not need to understand its realtime implementation.

## The public consumer surface

A well-shaped node normally gives consumers one initializer with useful defaults and named ports:

```swift
let analyzer = try graph.add(SpectralAnalyzerNode())
try graph.connect(source.audio, to: analyzer.input)
```

Put required settings in a small configuration value when an initializer would otherwise become
long. Keep presentation strings, AppKit values, and host UI out of the node contract.

## A terminal asynchronous analyzer

The smallest analyzer implementation declares one input and prepares a bounded window sink:

```swift
import RilliyaEngine
import RilliyaGraph

public struct SpectralAnalyzerNode: AudioGraphExecutableNode {
  public struct Ports: AudioGraphNodePorts {
    public let input = AudioGraphPortID(rawValue: "input")
    public init() {}
  }

  public static let typeID = AudioGraphNodeTypeID(
    rawValue: "com.example.spectral-analyzer"
  )
  public static let ports = Ports()

  private let configuration: AudioWindowSinkConfiguration
  private let handler: PreparedAudioWindowSink.Handler

  public init(
    configuration: AudioWindowSinkConfiguration = .standard,
    handler: @escaping PreparedAudioWindowSink.Handler
  ) {
    self.configuration = configuration
    self.handler = handler
  }

  public func makeDescriptor() -> AudioGraphNodeDescriptor {
    AudioGraphNodeDescriptor(
      ports: [
        .input(Self.ports.input, signal: .audio(AudioGraphAudioSignalType()))
      ],
      activation: .sink
    )
  }

  public func prepare(
    context: AudioGraphNodePreparationContext
  ) async throws -> any PreparedAudioGraphNode {
    try PreparedAudioWindowSink(
      inputPortID: Self.ports.input,
      format: context.singleAudioInputFormat(for: Self.ports.input),
      configuration: configuration,
      handler: handler
    )
  }
}
```

This node intentionally has no output. The handler runs serially away from the realtime render
path and receives owned samples. It may allocate and suspend, but it should observe task
cancellation before beginning more expensive work.

## Realtime nodes

Use `PreparedAudioSourceGraphNode` to adapt one `PreparedAudioSource` and
`PreparedAudioProcessorGraphNode` to adapt one `PreparedAudioProcessor`. Implement
`PreparedAudioGraphNode` directly only for multiple buses or a specialized topology.

`render(context:)` is trusted in-process realtime code. It must:

- honor the prepared format and maximum frame count;
- fill every output frame or return a failure result;
- avoid allocation, locks, suspension, logging, Objective-C messaging, and application callbacks;
- keep work bounded by the current frame and channel counts.

Allocate buffers, resolve formats, and create external resources in `prepare(context:)`. Start and
stop those resources in the runtime lifecycle methods. RilliyaKit starts downstream consumers
before upstream sources, then stops sources before their consumers.

Stable node and port IDs are machine identities. Do not derive them from localized labels, runtime
channel counts, or UI order. Breaking identity changes belong in the prerelease changelog with
migration guidance.
