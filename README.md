# RilliyaKit

RilliyaKit is the open-source audio foundation behind Rilliya. It provides
macOS-native building blocks for discovering, capturing, metering, processing,
and playing audio without depending on application UI types.

The package is under active development and currently requires macOS 14.2 or
later and Swift 6.

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
| `RilliyaCapture` | Process-output and device-input capture with bounded meters | `RilliyaCore`, `RilliyaRealtime` |
| `RilliyaDSP` | Prepared gain, mixing, delay, noise gate, and signal generation | `RilliyaRealtime`, Swift Atomics |
| `RilliyaPlayback` | Prepared-source playback to a Core Audio output device | `RilliyaCore`, `RilliyaRealtime` |
| `RilliyaKit` | All modules above | All modules above |

For example, an app that already knows a device UID and only needs to send a
custom realtime source to that device can depend on `RilliyaCore`,
`RilliyaRealtime`, and `RilliyaPlayback`. It does not need to build discovery,
capture, or DSP code. Library linkage is intentionally left unspecified so Swift
Package Manager can choose the appropriate linkage for each client build.

Public APIs use RilliyaKit value types rather than transient Core Audio object
identifiers. Realtime objects are explicitly prepared with bounded storage before
rendering; their render paths avoid allocation, locks, logging, and application
callbacks.

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

## License

RilliyaKit is available under the Apache License 2.0. See `LICENSE` for details.
