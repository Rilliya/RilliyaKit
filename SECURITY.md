# Security Policy

RilliyaKit processes audio inside the host application and interacts with macOS Core Audio. Safety,
bounded resource use, predictable teardown, and realtime-thread isolation are treated as security
properties.

## Supported Versions

No stable version has been released yet. Security fixes currently target the latest commit on
`main` and the newest published prerelease.

## Reporting a Vulnerability

Please use GitHub's private vulnerability reporting for the RilliyaKit repository. Do not open a
public issue for a vulnerability that could expose user audio, corrupt memory, exhaust resources,
bypass permissions, or execute untrusted code.

Include the affected version or commit, macOS and Swift versions, a minimal reproduction when safe,
and the expected security impact. Avoid attaching private audio recordings, credentials, signing
assets, or other personal data.

## Trust Boundaries

- Capture and playback use supported public macOS APIs unless an API is explicitly documented
  otherwise at its declaration and in release notes.
- Realtime render contracts accept unsafe pointers because Core Audio requires them. Implementations
  must obey documented channel and frame bounds.
- Prepared realtime paths must not allocate, block, acquire locks, log, invoke application callbacks,
  or perform Objective-C messaging.
- Custom `PreparedAudioSource` and `PreparedAudioProcessor` implementations are trusted compile-time
  code running in the host process. They are not a sandbox for untrusted binary plug-ins.
- RilliyaKit does not load arbitrary bundles or use `dlopen`. A future untrusted plug-in host must use
  an isolated platform mechanism such as Audio Unit extensions.
- Microphone and other privacy permissions remain under control of the host application and macOS.

## Out of Scope for Public Reports

Expected CPU cost from intentionally extreme but documented graph or DSP configurations is not a
vulnerability when the request remains within published bounds. Missing convenience features and
unsupported hardware are ordinary bug reports unless they create a security or privacy impact.

