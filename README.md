# RilliyaKit

RilliyaKit is the open-source audio foundation behind Rilliya. It provides
macOS-native building blocks for discovering, capturing, metering, and routing
audio without depending on application UI types.

The package is under active development and currently requires macOS 14.2 or
later and Swift 6.

## Using the package locally

Add the local checkout to an application's package dependencies:

```swift
.package(path: "../RilliyaKit")
```

Then add `RilliyaKit` to the target dependencies and import the module:

```swift
import RilliyaKit

let discovery = AudioCatalogDiscovery()
let snapshot = try discovery.snapshot()

for process in snapshot.processes where process.isRunningOutput {
  print(process.bundleIdentifier ?? "PID \(process.id.rawValue)")
}
```

`AudioCatalogSnapshot` contains value types for audio processes, devices,
directional endpoints, native streams, and channels. Persistent device UIDs and
runtime process IDs are wrapped in distinct identity types; internal Core Audio
object IDs are not exposed.

Application names, icons, and activation policies are intentionally absent from
RilliyaKit. A GUI can resolve those presentation details from each process ID or
bundle identifier without introducing AppKit into the audio layer.

Use `AudioCatalogDiscovery.updates()` when an application needs changed snapshots
over time. The stream polls at a bounded interval, suppresses equal snapshots,
and stops when its consumer cancels iteration.

On macOS 14.2 and later, `ProcessOutputCapture` can meter one running process's
native output channels without muting normal playback:

```swift
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
