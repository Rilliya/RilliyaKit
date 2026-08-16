# Error handling

RilliyaKit reports graph mistakes as structured Swift errors. A host can show a concise message,
highlight the exact graph elements involved, and still recover a custom node package's concrete
error type.

## Preview a connection

Use the same evaluator as the committed mutation while a user drags a connection:

```swift
switch graph.connectionDecision(from: source, to: target) {
case .allowed:
  showValidDropTarget()
case .denied(let failure):
  highlight(ports: failure.portAddresses)
  show(failure.localizedDescription, suggestion: failure.recoverySuggestion)
}
```

`connect(_:to:)` throws `AudioGraphMutationError.connectionDenied` with that complete
`AudioGraphConnectionFailure`. Missing nodes or ports, reversed directions, incompatible signal
types, occupied single-input ports, duplicates, and construction limits are distinct
machine-readable cases.

## Present graph construction errors

Every construction error adopts `AudioGraphContextualError`, as do engine errors. Workflow UI can
therefore share one highlighting path without parsing a localized string:

```swift
do {
  try graph.connect(source, to: target)
} catch let error as AudioGraphMutationError {
  let context: any AudioGraphContextualError = error
  highlight(
    nodes: context.nodeIDs,
    connections: context.connectionIDs,
    ports: context.portAddresses
  )
  show(error.localizedDescription, suggestion: error.recoverySuggestion)
}
```

Use `graph.validate()` for a bounded report before preparation. Each diagnostic has a stable code
and exact node and connection identities. `graph.snapshot()` and `AudioGraphEngine.prepare(_:)`
reject invalid reports, so malformed topology never enters realtime execution.

If a custom node's `makeDescriptor()` throws, `AudioGraphMutationError.underlyingError` retains the
original value for typed handling:

```swift
if let nodeError = error.underlyingError as? MyNodeConfigurationError {
  present(nodeError)
}
```

## Observe preparation and runtime failures

Preparation and `start()` throw `AudioGraphEngineError` directly. Background render failures can
happen after `start()` returns, so observe the bounded state stream as part of the engine's owner:

```swift
let engine = try await AudioGraphEngine.prepare(graph)

let monitor = Task {
  for await state in await engine.states() {
    guard case .failed(let error) = state else { continue }
    highlight(
      nodes: error.nodeIDs,
      connections: error.connectionIDs,
      ports: error.portAddresses
    )
    show(error.localizedDescription, suggestion: error.recoverySuggestion)
  }
}

try await engine.start()
```

The stream keeps only the newest pending state per observer and finishes at `stopped` or `failed`.
Node preparation, start, and stop failures retain the custom node's concrete error in
`AudioGraphEngineError.underlyingError`. Start rollback and shutdown still attempt every required
cleanup in safe graph order before returning the first failure.
