# Getting started

RilliyaKit keeps graph assembly separate from node implementation. Most applications only add
configured node values, connect their named ports, and start an engine.

## Connect application audio to a node package

Add only the products used by the target: `RilliyaCaptureNodes`, `RilliyaEngine`, `RilliyaGraph`,
and the third-party node product.

```swift
import RilliyaCaptureNodes
import RilliyaEngine
import RilliyaGraph
import SomeAnalyzerNodes

var graph = AudioGraph()
let source = try graph.add(ApplicationAudioInput(processID: processID))
let analyzer = try graph.add(SpectralAnalyzerNode())

try graph.connect(source.audio, to: analyzer.input)

let engine = try await AudioGraphEngine.prepare(graph)
try await engine.start()
```

The analyzer does not need an output. Its `.sink` activation makes the connected path active, while
disconnected capture and generator nodes remain stopped.

Retain the engine for the desired session and call `try await engine.stop()` during orderly
shutdown. A stopped engine is terminal; prepare a new one after changing graph topology or native
formats.

## Analyze windows without defining a node type

Use `AudioWindowAnalyzerNode` when a package or application only needs owned PCM windows away from
the realtime path:

```swift
let analyzer = try graph.add(
  AudioWindowAnalyzerNode { window in
    await model.consume(
      samples: window.samples(forChannel: 0),
      sampleRate: window.format.sampleRate
    )
  }
)
```

The default uses a 2,048-frame window, a 1,024-frame hop, and bounded buffering. Supply an
`AudioWindowSinkConfiguration` to change those values. If analysis falls behind, new audio is
dropped instead of blocking audio work or growing memory without a bound.

## Capture an input device

`DeviceAudioInput` accepts any physical or virtual Core Audio input exposed by discovery:

```swift
let source = try graph.add(DeviceAudioInput(deviceID: deviceID))
```

The host application must request microphone permission before preparing an engine that activates
this node. Preparation failures preserve their concrete `DeviceInputCaptureError` inside
`AudioGraphNodeFailure.underlyingError`.

## Choose a narrower product

Import `RilliyaGraph` alone for semantic construction and validation. Add `RilliyaEngine` only for
execution and `RilliyaCaptureNodes` only for native capture sources. The `RilliyaKit` product is a
convenient full suite, not a requirement.
