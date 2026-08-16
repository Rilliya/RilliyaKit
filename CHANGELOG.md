# Changelog

All notable changes to RilliyaKit are documented in this file.

RilliyaKit follows Semantic Versioning. Versions below 1.0 are development releases and may
contain source-breaking changes. Every released breaking change is documented in the relevant
version section with migration guidance.

## Unreleased

### Added

- Focused products for discovery, capture, realtime transport, DSP, and playback.
- Public process-output and device-input capture using supported macOS Core Audio APIs.
- Bounded realtime frame transport and prepared audio source and processor contracts.
- Prepared gain, matrix mixing, delay, noise gate, compressor, and signal generation DSP.
- Public output-device playback using AUHAL.
- UI-independent typed graph construction with consumer-defined node values, shared
  connection compatibility, configurable resource limits, and nonrecursive cycle validation.
- Bounded graph preparation and execution with on-demand activation, prepared source and
  processor adapters, and asynchronous overlapping analysis-window sinks.
- Ready-to-connect application-output and input-device graph source nodes that avoid unused meter
  work, plus a closure-backed terminal audio-window analyzer node.
- Structured graph and engine failures with exact node, connection, and port context, preserved
  custom-node errors, recovery suggestions, and bounded asynchronous engine-state observation.

### Changed

- GitHub CI builds every product and example for code changes, caches SwiftPM work by toolchain,
  and selects affected unit-test targets from module dependencies.

### Fixed

- Nothing yet.

### Security

- Nothing yet.

### Breaking Changes

- Connection preview and mutation denial now carry `AudioGraphConnectionFailure`; access its
  machine-readable reason through `.issue` and its attempted endpoints through `.source` and
  `.target`.
- Invalid third-party node descriptors are grouped under `.invalidNodeDefinition`, while errors
  thrown by `makeDescriptor()` are wrapped by `.nodeDescriptorFailed` and remain available through
  `underlyingError`.
- `setConnection(id:isEnabled:)` now throws `.missingConnection` for stale identities instead of
  returning `false`.

## 0.1.0-prealpha.1

This section will be finalized from `Unreleased` when the first public prerelease is tagged.
