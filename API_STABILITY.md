# API Stability

RilliyaKit is currently preparing its first public prerelease,
`0.1.0-prealpha.1`.

## Before 1.0

Versions below 1.0 are development releases. Public declarations, behavior, module boundaries,
and persistence formats may change when real consumer feedback shows that a safer or clearer API
is needed.

Released breaking changes are never silent. Each one must include:

- an entry under **Breaking Changes** in `CHANGELOG.md`;
- a concise explanation of the behavior or declaration that changed;
- migration guidance or a replacement API; and
- a new prerelease or package version.

Consumers that need reproducible builds should use an exact prerelease requirement while the API
is evolving:

```swift
.package(
  url: "https://github.com/Rilliya/RilliyaKit.git",
  exact: "0.1.0-prealpha.1"
)
```

## From 1.0

Starting with 1.0, RilliyaKit will follow Semantic Versioning for its documented public source API:

- patch releases contain compatible fixes;
- minor releases add compatible API and behavior; and
- major releases may contain source-breaking changes.

Public API does not include declarations whose names begin with an underscore, package or internal
declarations, implementation details, test seams, undocumented persistence details, or behavior
explicitly documented as unspecified.

RilliyaKit is distributed as a source package. This policy does not promise binary ABI compatibility
or module stability for separately compiled artifacts. If RilliyaKit later distributes binary
frameworks, their ABI policy will be documented independently before release.

## Documentation Is Part of the Contract

Documented ownership, lifecycle, thread-safety, realtime-safety, bounds, error behavior, and
performance guarantees are part of the public API. Implementation details may change as long as
those guarantees remain true for a compatible release.

