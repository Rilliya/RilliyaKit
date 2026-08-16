# Changelog

All notable changes to RilliyaKit are documented in this file.

RilliyaKit follows Semantic Versioning. Versions below 1.0 are development releases and may
contain source-breaking changes. Every released breaking change is documented in the relevant
version section with migration guidance.

## Unreleased

### Added

- Nothing yet.

### Changed

- Nothing yet.

### Fixed

- Nothing yet.

### Security

- Nothing yet.

### Breaking Changes

- Nothing yet.

## 0.1.0-prealpha.1

### Added

- Focused products for discovery, capture, realtime transport, DSP, and playback.
- Public process-output, output-device mix, and device-input capture using supported macOS Core
  Audio APIs.
- Bounded realtime frame transport and prepared audio source and processor contracts.
- Prepared gain, matrix mixing, delay, noise gate, compressor, and signal generation DSP.
- Public output-device playback using AUHAL.
- Bounded local-file decoding and sample-rate conversion using public Core Audio APIs.
- Bounded background file writing for WAV, AIFF, CAF, and installed public M4A encoders, including
  collision-safe destination handling and advertised AAC bitrate ranges.
- Versioned direct-UDP PCM sending and receiving for explicitly configured peers on trusted local
  networks, with bounded loss concealment and session validation.
- UI-independent typed graph construction with consumer-defined node values, shared
  connection compatibility, configurable resource limits, and nonrecursive cycle validation.
- Bounded graph preparation and execution with on-demand activation, prepared source and
  processor adapters, and asynchronous overlapping analysis-window sinks.
- Ready-to-connect application-output, output-device mix, and input-device graph source nodes that
  avoid unused meter work, plus a closure-backed terminal audio-window analyzer node.
- Validated, persistent virtual audio endpoint models, deterministic visible and bridge device UIDs,
  and an actor-isolated store for reconciling endpoint catalogs with the Rilliya Audio Server
  plug-in.
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
