# Contributing to RilliyaKit

RilliyaKit welcomes focused bug reports, API feedback, tests, documentation improvements, and
carefully bounded audio features.

## Development Requirements

- macOS 14.2 or later
- Swift 6
- Xcode with the macOS SDK

Run the complete local validation before submitting a change:

```sh
make check
```

Useful focused commands are:

```sh
make format
make format-check
make build-debug
make build-release
make test
```

Tests must be deterministic and must not depend on audio hardware, the current device catalog,
privacy permissions, Spotlight, network services, or private media. Hardware smoke checks are kept
separate from unit tests.

## Public API Changes

Public API must be designed for independent package consumers rather than for the Rilliya
application alone. A public addition should include:

- documentation comments describing purpose, ownership, lifecycle, concurrency, bounds, and errors;
- deterministic tests through a public or narrowly scoped internal seam;
- a concise example for nontrivial workflows;
- an `Unreleased` changelog entry; and
- migration guidance when it replaces released API.

Prefer small initializers for required identity and dependencies. Group optional policy and tuning
values into validated configuration values with safe, useful defaults. Avoid boolean parameters
whose meaning is unclear at the call site.

## Realtime Code

Realtime callbacks and render methods must not allocate, block, acquire locks, log, call application
code, or perform Objective-C messaging. Allocate and validate storage during preparation, publish
bounded controls through realtime-safe primitives, and substitute silence or a bounded error state
after failure.

Every new realtime algorithm must test its frame and channel bounds, nonfinite input behavior,
lifecycle, repeated configuration updates, and cleanup. Performance claims require a reproducible
baseline rather than intuition.

## Style

- Code, comments, documentation, commit messages, and public API names are written in English.
- Follow the repository's `swift-format` configuration.
- Keep modules focused and dependency directions explicit.
- Do not add personal signing identities, local absolute paths, private repository dependencies,
  credentials, or test media to tracked files.
- Use Conventional Commit messages for code changes.

