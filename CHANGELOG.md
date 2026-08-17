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
- `AudioRealtimeWorker.start()` reports a startup failure instead of deadlocking. It waited for
  the new thread while holding the lock that thread needed in order to say why it could not start,
  so any rejected scheduling policy hung the caller for ever — and a caller holding its own lock
  across `start()`, as the network sender does, wedged that lock with it.
- `AudioRealtimeWorker.stop()` called twice at once no longer returns from the second call before
  the thread has finished.
- Encoding a `NetworkAudioPacket` carries which piece of a block it is and any codec configuration
  it holds. Both were dropped, so neither survived a round trip.
- A block is no longer placed by `firstSequence % blockCount`. Every block of a stream is the same
  number of pieces wide, so the starts shared a factor with the depth and all of them landed in
  one slot: the window was one block however deep it was set, and a piece asked for could never
  arrive in time to be used. The reassembler now holds four blocks, which is what makes
  retransmission work at all on a split stream.
- The sender declares what a cycle costs when it sends a split block. It declared the cost of one
  datagram while handing over as many as the block was split into — eighteen measured for stereo
  Apple Lossless, spanning 1089 µs against 700 µs declared, which is how a realtime thread is
  demoted out of the realtime scheduler.
- A discovery cancelled while its listener was still being built no longer leaks that listener and
  its UDP port. Measured across a sweep of cancel instants, five of 220 cancelled discoveries held
  their port three seconds later.
- A stopped `NetworkAudioReceiver` no longer accepts a connection whose handler was already queued,
  which had let it go on writing audio into its frame buffer after it was stopped.

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
- **Remote heap buffer overflow.** The fragmented flag waives the rule tying a payload's length to
  the frames it claims — right for a piece of a compressed block, wrong for samples, which are
  sized to fit one datagram by construction. Nothing downstream looked at the flag again, so one
  datagram claiming samples, the flag, and a long payload was copied straight into storage sized
  for a block. Reproduced under AddressSanitizer against a receiver reading a real socket, from a
  single unauthenticated datagram. The flag now belongs to compressed encodings only; the sample
  write is additionally clamped to its storage, and the storage is initialised so that reading
  past the last packet returns silence rather than heap.
- A sender mints its session identity per run rather than carrying one in its configuration. Two
  senders built from one configuration value derived the same session key and both began at
  sequence zero, which is the same nonce over different audio.
- A retransmission request carries nothing that stops it being replayed, so a sender answers any
  one sequence once. A captured request otherwise made it resend for as long as an attacker
  repeated it.
- A retransmission request is answered on the thread that owns the datagram history rather than on
  the network queue. The two shared the history and one packet buffer with no synchronisation:
  ThreadSanitizer reported the history race, and the shared buffer would put one packet's bytes on
  the wire under another's sequence and then store those bytes as the history for it.
- A fragment naming a place further along than its own sequence is refused. The subtraction wrapped
  to near `UInt64.max` and became the newest sequence seen, after which every genuine piece was
  refused — one datagram disabled reassembly, and with it Apple Lossless, for the whole session.

### Breaking Changes

- `NetworkAudioSessionCipher.seal`, `open`, and `NonceDomain` are no longer public. Sealing
  correctly means naming the right nonce domain, and naming the wrong one silently reuses a nonce
  under the session key, which produces no visible symptom and defeats the encryption entirely.
  Nothing outside the module used them. Send a request through
  `NetworkAudioRetransmissionRequest.encoded(cipher:)`, which names the domain for you.
- The packet header's reserved word is no longer reserved. A sender and receiver from different
  builds do not interoperate; both sides must be updated together.
- `NetworkAudioSenderConfiguration` no longer takes or holds a `sessionID`. The identity belongs to
  a run, not to a configuration a caller may reuse. Read it from `NetworkAudioSender`'s
  `activeSessionID` once started.
- `NetworkAudioCompressedDecoder.reset()` is gone. It had no caller and no behaviour any test could
  pin — emptying it changed nothing any decoder does. Build a new decoder for a new stream, which
  is what the receiver does.

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
