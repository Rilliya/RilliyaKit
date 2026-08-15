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

let firstChannel = AudioChannelIndex(rawValue: 0)
```

`AudioChannelIndex` uses the zero-based indexing expected by audio buffers and
rejects negative values at initialization.

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
