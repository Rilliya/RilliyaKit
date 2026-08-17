# RilliyaKit

RilliyaKit is the open-source audio foundation behind Rilliya. It provides
macOS-native building blocks for discovering, capturing, metering, processing,
and playing audio without depending on application UI types.

Once node packages are imported, the common path is intentionally small:

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

An analyzer may be a terminal node with no output. Sources, processors, sinks, and third-party
nodes use the same `add` and `connect` operations; configuration stays in the node value with
ordinary Swift defaults. Format negotiation, bounded buffers, realtime scheduling, and lifecycle
ordering remain inside the engine. See [Getting started](Documentation/GettingStarted.md) for two
short paths and [Creating graph nodes](Documentation/CreatingGraphNodes.md) when publishing a node
package. [Error handling](Documentation/ErrorHandling.md) shows how workflow UI can preview invalid
connections and present exact node, connection, port, and custom-node error context. Complete
buildable examples live in [`Examples`](Examples).

The package is preparing its first public prerelease, `0.1.0-prealpha.1`, and
currently requires macOS 14.2 or later and Swift 6. Public API may change before
1.0, but released breaking changes are documented with migration guidance in
the [changelog](CHANGELOG.md) and governed by the [API stability policy](API_STABILITY.md).

## Using the package locally

Add the local checkout to an application's package dependencies:

```swift
.package(path: "../RilliyaKit")
```

Choose only the products the target uses. For catalog discovery, add
`RilliyaCore` and `RilliyaDiscovery`, then import their modules:

```swift
import RilliyaCore
import RilliyaDiscovery

let discovery = AudioCatalogDiscovery()
let snapshot = try discovery.snapshot()

for process in snapshot.processes where process.isRunningOutput {
  print(process.bundleIdentifier ?? "PID \(process.id.rawValue)")
}
```

The `RilliyaKit` product remains available as a convenient full suite. It is a
collection of the focused modules below rather than an umbrella import, so source
files still import the modules that define the APIs they use.

## Products and modules

| Product and module | Purpose | Package dependencies |
| --- | --- | --- |
| `RilliyaCore` | Stable identities, catalog values, stream formats, and shared errors | None |
| `RilliyaRealtime` | Prepared render contracts and a bounded realtime PCM frame buffer | Swift Atomics |
| `RilliyaDiscovery` | Public Core Audio process and device catalog discovery | `RilliyaCore` |
| `RilliyaCapture` | Process-output, output-device mix, and input-device capture with bounded meters | `RilliyaCore`, `RilliyaRealtime` |
| `RilliyaDSP` | Prepared gain, mixing, delay, noise gate, sample rate conversion, and signal generation | `RilliyaRealtime`, Swift Atomics |
| `RilliyaFilePlayback` | Bounded background decoding of Core Audio-supported local files into realtime PCM | `RilliyaRealtime` |
| `RilliyaFileWriting` | Bounded background encoding and file output using installed public Core Audio encoders | `RilliyaRealtime` |
| `RilliyaNetworkAudio` | Versioned direct-UDP audio sending and receiving over a local network, optionally sealed and optionally compressed | `RilliyaRealtime` |
| `RilliyaPlayback` | Prepared-source playback to a Core Audio output device | `RilliyaCore`, `RilliyaRealtime` |
| `RilliyaVirtualAudio` | Stable, validated models for globally managed virtual audio endpoints | None |
| `RilliyaGraph` | UI-independent typed graph construction and validation | None |
| `RilliyaEngine` | Bounded graph preparation, execution, and asynchronous analysis windows | `RilliyaGraph`, `RilliyaRealtime` |
| `RilliyaCaptureNodes` | Ready-to-connect application and device capture nodes | `RilliyaCore`, `RilliyaCapture`, `RilliyaEngine`, `RilliyaGraph`, `RilliyaRealtime` |
| `RilliyaKit` | All modules above | All modules above |

For example, an app that already knows a device UID and only needs to send a
custom realtime source to that device can depend on `RilliyaCore`,
`RilliyaRealtime`, and `RilliyaPlayback`. It does not need to build discovery,
capture, file decoding, or DSP code. Library linkage is intentionally left
unspecified so Swift Package Manager can choose the appropriate linkage for each
client build.

Public APIs use RilliyaKit value types rather than transient Core Audio object
identifiers. Realtime objects are explicitly prepared with bounded storage before
rendering; their render paths avoid allocation, locks, logging, and application
callbacks.

`RilliyaGraph` is a UI-independent graph contract under active development. Its graph accepts
trusted consumer-defined node values, stable semantic port IDs, audio and typed control signals,
bounded graph policy, shared connection validation, and nonrecursive cycle detection.
`RilliyaEngine` prepares the active subgraph, resolves concrete formats, allocates bounded planar
storage, and drives its executable node runtimes. `RilliyaCaptureNodes` supplies ready-to-connect
application-output and physical or virtual input-device sources.

```swift
import RilliyaGraph

var graph = AudioGraph()
let source = try graph.add(MySource())
let processor = try graph.add(MyProcessor())

try graph.connect(source.audio, to: processor.input)

let snapshot = try graph.snapshot()
```

Graph resource limits have safe defaults and may be raised explicitly. A deterministic
test constructs and validates 10,000 nodes without recursive traversal; large graphs
remain bounded rather than claiming unlimited realtime work.

An executable node adopts `AudioGraphExecutableNode` and prepares its runtime only after upstream
formats are known. Existing `PreparedAudioSource` and `PreparedAudioProcessor` implementations
have single-bus graph adapters. Most asynchronous analyzers can use the ready-made
`AudioWindowAnalyzerNode`: the render path writes only to a bounded SPSC buffer, while the
consumer's handler receives owned overlapping windows away from audio work.

```swift
let analyzer = try graph.add(
  AudioWindowAnalyzerNode { window in
    await analyze(window)
  }
)
```

Nodes with no connected path to a sink are not prepared or started. A sink may have no output at
all; analysis does not require a playback destination. Window handlers are trusted asynchronous
code and should observe task cancellation. The current background driver requires one sample rate
across its active subgraphs and reports a typed error when explicit sample-rate conversion is
needed.

`AudioCatalogSnapshot` contains value types for audio processes, devices,
directional endpoints, native streams, and channels. Persistent device UIDs and
runtime process IDs are wrapped in distinct identity types; internal Core Audio
object IDs are not exposed.

Application names, icons, and activation policies are intentionally absent from
RilliyaKit. A GUI can resolve those presentation details from each process ID or
bundle identifier without introducing AppKit into the audio layer.

Use `AudioCatalogDiscovery.updates()` when an application needs changed snapshots
over time. The stream observes public Core Audio property notifications, coalesces
bursts, suppresses equal snapshots, and stops when its consumer cancels iteration.
A low-frequency fallback refresh protects against a missed HAL notification.

On macOS 14.2 and later, `ProcessOutputCapture` can meter one running process's
native output channels without muting normal playback:

```swift
import RilliyaCapture
import RilliyaCore

if let processID = snapshot.processes.first(where: \.isRunningOutput)?.id {
  let capture = try ProcessOutputCapture(processID: processID) { snapshot in
    for channel in snapshot.channels {
      print(channel.channelID, channel.decibels)
    }
  }

  try capture.start()
  // Retain the capture while it is in use, then release its Core Audio resources.
  try capture.stop()
}
```

Capture callbacks are delivered on a private non-audio queue. Each snapshot is
bounded by `ProcessOutputCaptureConfiguration`; the real-time IO callback uses
preallocated storage and never invokes application code directly.

`DeviceOutputCapture` captures the process mix destined for an output device. Pass a persistent
UID from discovery, or resolve the current system default during preparation:

```swift
import RilliyaCapture

let capture = try DeviceOutputCapture(target: .systemDefault) { snapshot in
  print(snapshot.format.deviceID, snapshot.channels.map(\.peak))
}

try capture.start()
try capture.stop()
```

Use `DeviceOutputCapture(deviceID:)` to select a concrete output device. A `.systemDefault` target
is resolved once; it does not migrate when the default changes. Core Audio device taps bind one
output stream, so RilliyaKit captures stream zero and publishes that index in the runtime format.
The signal is Core Audio's mix of process output destined for that stream, before device-specific
hardware processing.

The default `DeviceOutputCaptureProcessExclusion` omits the host process when it has a current HAL
process object, preventing common same-device feedback paths. Add explicit `AudioProcessID` values
to the policy to omit other active processes, or use `.none` when an exact all-process mix is
required and the capture will not feed the same device. The host application's `Info.plist` must
contain `NSAudioCaptureUsageDescription`; macOS prompts for system-audio recording permission when
tap IO first starts.

`DeviceInputCapture` provides the same bounded meter surface for a physical or
virtual Core Audio input device. It accepts the persistent `AudioDeviceID` exposed
by catalog discovery and uses AUHAL to obtain planar Float32 channels:

```swift
import RilliyaCapture

if let deviceID = snapshot.inputDevices.first?.id {
  let capture = try DeviceInputCapture(deviceID: deviceID) { snapshot in
    print(snapshot.channels.map(\.peak))
  }

  try capture.start()
  try capture.stop()
}
```

The host application is responsible for requesting microphone permission before
constructing an input capture. RilliyaKit reports permission and native lifecycle
failures as typed `DeviceInputCaptureError` values.

`RilliyaVirtualAudio` defines the persistent boundary between workflows, a device manager, and a
Core Audio driver. An input endpoint supplies Rilliya audio to other applications; an output
endpoint accepts other applications' audio for Rilliya to consume. The catalog stores stable UUIDs
rather than transient HAL object IDs, rejects ambiguous names, and advances a revision with every
successful mutation:

```swift
import RilliyaVirtualAudio

var catalog = VirtualAudioEndpointCatalog.empty
let remoteMicrophone = try catalog.create(
  VirtualAudioEndpointConfiguration(
    name: "Remote Microphone",
    direction: .input,
    format: VirtualAudioEndpointFormat(sampleRate: 48_000, channelCount: 1)
  )
)

// Persist remoteMicrophone.id in any workflow that targets this global device.
```

These values do not install a driver or claim that a virtual device is active. A host must reconcile
the catalog with an Audio Server plug-in and report driver state separately. Keeping the pure model
independent lets command-line tools and third-party device managers reuse it without linking the
Rilliya application. See [Integrating the virtual audio driver](Documentation/VirtualAudioDriverIntegration.md)
for the driver boundary, signing requirements, and a complete endpoint-management example.

`PreparedAudioSignalGeneratorSource` provides prepared sine, band-limited square,
triangle, and sawtooth oscillators plus deterministic white, pink, and brown noise.
It allocates its scratch storage before rendering and writes planar Float32 PCM
without allocation, locking, logging, or callbacks on the realtime thread.

```swift
import RilliyaDSP
import RilliyaRealtime

let format = try AudioProcessingFormat(sampleRate: 48_000, channelCount: 2)
let preparation = try AudioRenderPreparation(format: format, maximumFrameCount: 512)
let source = try PreparedAudioSignalGeneratorSource(
  preparation: preparation,
  configuration: AudioSignalGeneratorConfiguration(
    waveform: .sine,
    frequency: 440,
    amplitude: 0.25
  )
)
```

`AudioFileFrameStream` opens any local format supported by Core Audio, decodes and
sample-rate converts it away from the realtime thread, and publishes planar Float32
PCM through one fixed-capacity buffer. It supports one pass, a bounded finite play
count, or continuous looping without loading the complete file into memory:

```swift
import RilliyaFilePlayback

let configuration = try AudioFileFrameStreamConfiguration(
  sampleRate: 48_000,
  loopMode: .playCount(3)
)
let file = try AudioFileFrameStream(url: fileURL, configuration: configuration)

file.start()
// Connect file.frameBuffer to one prepared graph consumer.
// Later, wait for deterministic teardown:
await file.stop()
```

The stream deliberately owns decoding rather than a codec registry. Additional
format adapters can remain separate modules and feed the same
`AudioRealtimeFrameBuffer` contract without adding their code to clients that only
use system formats.

`AudioFileWriter` is the matching sink boundary. A realtime graph writes planar
Float32 PCM only to its bounded frame buffer; conversion, encoding, disk IO, and
file finalization run on a utility task. The capability query prevents a host from
offering codecs for which macOS only supplies a decoder.

```swift
import RilliyaFileWriting

let configuration = try AudioFileWriterConfiguration(
  destinationURL: destinationURL,
  container: .m4a,
  encoding: .aac(bitRate: 192_000),
  sampleRate: 48_000,
  channelCount: 2
)
let writer = try AudioFileWriter(configuration: configuration)
let actualURL = try await writer.start()

// Produce into writer.frameBuffer from one realtime source, then stop that source.
_ = await writer.stop()
```

The default collision policy preserves earlier recordings by selecting an unused
numeric suffix. Replacing a file requires an explicit configuration choice so a
host can place user confirmation at the UI boundary.

`RilliyaNetworkAudio` provides a focused direct-UDP transport for a local network.
A sender and receiver agree on one explicit sample rate and channel count; the
versioned packet header carries a session ID and monotonic sequence, and both sides
use fixed-capacity PCM queues. Network IO, packet allocation, validation, and
interleaving remain away from the graph render path.

```swift
import RilliyaNetworkAudio

let format = try NetworkAudioStreamFormat(sampleRate: 48_000, channelCount: 2)
let receiver = try NetworkAudioReceiver(
  configuration: NetworkAudioReceiverConfiguration(port: 48_620, format: format)
)
try receiver.start()

// Connect receiver.frameBuffer to one prepared graph consumer.
```

Four things are optional and off unless configured, so a client pays for only what
it asks for:

| Option | What it does | Cost when enabled |
| --- | --- | --- |
| `sharedKey` | Seals every packet with AES-GCM under a per-session key derived by HKDF-SHA256, which also authenticates the header and rejects replays | 16 bytes per packet |
| `encoding` | Carries the audio as Opus, AAC-LD, AAC-ELD, or Apple Lossless instead of float samples | 48 kHz stereo measured between two Macs: 3346 kbit/s uncompressed, 213 Opus, 484 AAC-ELD, 2061 lossless |
| `reorderDepth` | Holds packets briefly so ones that arrive out of order are still placed | The depth's worth of added latency |
| `requestsRetransmission` | Asks the sender again for a gap, but only while the answer could still arrive before its audio is due | A request datagram per gap, bounded to a quarter of the send rate |

Without a `sharedKey` the audio crosses the network in the clear and anything can
inject packets into the session; set one for any network you do not control.

`NetworkAudioFormatDiscovery` reports the sample rate and channel count of a stream
already arriving on a port, for a receiver that would otherwise have to be told.

This transport is intentionally not RTMP and does not provide internet congestion
control or traversal of anything but a local network. Streaming-service protocols
and remote-network transports belong in separate modules so clients do not pay for
them accidentally.

## Custom realtime sources and processors

RilliyaKit intentionally leaves its prepared render contracts open. A client module
can implement `PreparedAudioSource` to produce audio, or `PreparedAudioProcessor` to
transform one noninterleaved Float32 bus, then connect that source to
`DeviceOutputPlayback`. No Rilliya app type or internal API is required.

These protocols are a trusted, compile-time extension surface. Implementations run
inside the host process and can be called directly by a Core Audio realtime thread.
They must obey the documented frame and pointer bounds and must not allocate, block,
log, call application code, or perform Objective-C messaging during render. A Swift
protocol cannot enforce those realtime rules or isolate unsafe pointer access, so
these APIs must not be used to load untrusted binary plug-ins.

Rilliya does not load arbitrary bundles or use `dlopen`. A future host for untrusted
third-party effects should use Apple's Audio Unit extension model and request
out-of-process instantiation. The Rilliya GUI's node registry is not currently a
public plug-in SDK; the open render contracts are the supported developer extension
point for this release.

## Local development

The repository provides stable entry points for all required local checks:

```sh
make format
make format-check
make build-debug
make build-release
make test
make check
```

`make check` runs formatting validation, debug and release builds, and all unit
tests. Tests do not require audio hardware or privacy permissions.

See [CONTRIBUTING.md](CONTRIBUTING.md) for public API and realtime contribution
requirements. Please report security and privacy issues through the private process
described in [SECURITY.md](SECURITY.md).

## License

RilliyaKit is available under the Apache License 2.0. See `LICENSE` for details.
