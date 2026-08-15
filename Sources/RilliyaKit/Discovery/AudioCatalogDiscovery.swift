// SPDX-License-Identifier: Apache-2.0

/// Discovers the current Core Audio process and device catalog.
public struct AudioCatalogDiscovery: Sendable {
  private let builder: AudioCatalogBuilder
  private let changeSource: any AudioCatalogChangeSource

  /// Creates a catalog discovery service backed by the system Core Audio HAL.
  public init() {
    builder = AudioCatalogBuilder(provider: CoreAudioCatalogProvider())
    changeSource = CoreAudioCatalogChangeSource()
  }

  init(provider: any AudioHardwareCatalogProvider) {
    builder = AudioCatalogBuilder(provider: provider)
    changeSource = PollingAudioCatalogChangeSource(interval: .seconds(1))
  }

  init(
    provider: any AudioHardwareCatalogProvider,
    changeSource: any AudioCatalogChangeSource
  ) {
    builder = AudioCatalogBuilder(provider: provider)
    self.changeSource = changeSource
  }

  /// Reads a value snapshot of the processes and devices currently known to Core Audio.
  ///
  /// Failures to read the top-level device or process lists are thrown. Failures isolated to an
  /// individual entry are reported in ``AudioCatalogSnapshot/issues`` and do not prevent other
  /// entries from being returned.
  public func snapshot() throws(AudioCatalogError) -> AudioCatalogSnapshot {
    try builder.snapshot()
  }

  /// Publishes catalog snapshots when Core Audio reports a relevant change.
  ///
  /// The stream emits its first snapshot immediately, coalesces bursts of property notifications,
  /// and then emits only when the catalog value changes. A low-frequency fallback refresh protects
  /// against a missed HAL notification without continuously scanning the catalog. The stream
  /// finishes with the first top-level discovery failure and stops promptly when its consumer
  /// cancels iteration. Individual entry failures remain available in each snapshot's `issues`.
  public func updates() -> AsyncThrowingStream<AudioCatalogSnapshot, any Error> {
    updates(triggeredBy: changeSource.changes())
  }

  func updates(
    pollingEvery interval: Duration
  ) -> AsyncThrowingStream<AudioCatalogSnapshot, any Error> {
    updates(triggeredBy: PollingAudioCatalogChangeSource(interval: interval).changes())
  }

  private func updates(
    triggeredBy changes: AsyncStream<Void>
  ) -> AsyncThrowingStream<AudioCatalogSnapshot, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task.detached(priority: .utility) { @Sendable in
        var previous: AudioCatalogSnapshot?
        do {
          let initial = try snapshot()
          continuation.yield(initial)
          previous = initial

          for await _ in changes {
            try Task.checkCancellation()
            let current = try snapshot()
            if current != previous {
              continuation.yield(current)
              previous = current
            }
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }
}
