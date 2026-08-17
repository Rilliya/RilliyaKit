# Changelog

All notable changes to RilliyaKit are documented in this file.

RilliyaKit follows Semantic Versioning. Versions below 1.0 are development releases and may
contain source-breaking changes. Every released breaking change is documented in the relevant
version section with migration guidance.

## Unreleased

### Added

- `RilliyaDSP` converts between sample rates. `AudioSampleRateConverter` handles interleaved and
  planar layouts and carries between blocks whatever a conversion did not consume, so a long
  stream does not drift. `AudioSampleRateLadder` resolves a source rate to a supported one by
  preferring an exact match, then the next rate above, and only coming down when a codec's
  ceiling requires it.
- `RilliyaNetworkAudio` carries compressed audio as well as float samples. `NetworkAudioCodec`
  describes Opus, AAC Low Delay, AAC Enhanced Low Delay, and Apple Lossless, and reports what
  each can carry by asking the system rather than by assertion, so a macOS release that adds or
  removes an encoder changes the answer. Measured between two Macs at 48 kHz stereo: 3346 kbit/s
  uncompressed against 213 for Opus, 484 for AAC ELD, and 2061 for Apple Lossless.
- `NetworkAudioReceiver` places packets that arrive out of order instead of discarding them,
  bounded by `reorderDepth`. At 30 % reordering this took a stream from 1403 stale packets and
  1402 gaps down to 1 and 0.
- `NetworkAudioReceiver` asks a sender for a packet the network dropped, bounded by a measured
  round trip: it asks only while the answer could still arrive before that audio is due, asks
  once per gap, and a sender answers within a quarter of the rate it is already sending at. At
  2 % loss this took 220 gaps down to 5.
- A codec block wider than one datagram is split across datagrams and put back together, which
  is what lets Apple Lossless cross a 1500-byte network at all. Pieces are released in the order
  they were sent.
- `NetworkAudioFormatDiscovery` reports the sample rate and channel count of a stream already
  arriving on a port, for a receiver that would otherwise have to be told. Measured 2.2 s to
  identify a 44.1 kHz mono stream and 2.0 s for 96 kHz eight-channel.
- `VirtualAudioEndpointStore` takes the bundle identifier of the driver it manages, so the type
  is usable by a host other than the one it was written for.

### Changed

- The reserved word in the packet header now carries the length of a codec's configuration, and
  a codec that needs one sends it behind the payload and inside the seal. The header remains 48
  bytes.

### Fixed

- `AudioSampleRateConverter` no longer re-offers the start of its input to the converter, which
  had left a converted stream measurably off pitch — 35 to 43 Hz on a 440 Hz tone.

### Security

- Sealing takes a nonce domain, so a request and a packet at the same sequence no longer produce
  the same nonce under one key. Reusing an AES-GCM nonce is the single failure the construction
  does not survive.
- `NetworkAudioPacketReorderBuffer.advance(to:)` is bounded by its window. A packet naming a far
  future sequence previously made it walk every sequence in between, which one datagram could
  use to occupy a receiver.
- `NetworkAudioFormatDiscovery` refuses port 0. `NWEndpoint.Port` accepts it as "any port", which
  would have bound a listener somewhere other than where the caller asked.
- A sender acts on a retransmission request only when the request is sealed under the session
  key, so an unkeyed request cannot make a keyed sender send.
- Removed every `try!` and force unwrap this package's own lint rules forbid, so malformed input
  reaches an error rather than a trap.

### Breaking Changes

- `NetworkAudioSessionCipher.seal` and `open` take a nonce domain. A caller that sealed anything
  itself must pass `.audio`.
- The packet header's reserved word is no longer reserved. A sender and receiver from different
  builds do not interoperate; both sides must be updated together.

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
