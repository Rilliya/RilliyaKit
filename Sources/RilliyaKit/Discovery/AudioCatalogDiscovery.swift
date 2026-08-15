// SPDX-License-Identifier: Apache-2.0

/// Discovers the current Core Audio process and device catalog.
public struct AudioCatalogDiscovery: Sendable {
  private let builder: AudioCatalogBuilder

  /// Creates a catalog discovery service backed by the system Core Audio HAL.
  public init() {
    builder = AudioCatalogBuilder(provider: CoreAudioCatalogProvider())
  }

  init(provider: any AudioHardwareCatalogProvider) {
    builder = AudioCatalogBuilder(provider: provider)
  }

  /// Reads a value snapshot of the processes and devices currently known to Core Audio.
  ///
  /// Failures to read the top-level device or process lists are thrown. Failures isolated to an
  /// individual entry are reported in ``AudioCatalogSnapshot/issues`` and do not prevent other
  /// entries from being returned.
  public func snapshot() throws(AudioCatalogError) -> AudioCatalogSnapshot {
    try builder.snapshot()
  }

  /// Publishes changed catalog snapshots at a bounded polling interval.
  ///
  /// The stream emits its first snapshot immediately, then emits only when the value changes. It
  /// finishes with the first top-level discovery failure and stops promptly when its consumer
  /// cancels iteration. Individual entry failures remain available in each snapshot's `issues`.
  public func updates() -> AsyncThrowingStream<AudioCatalogSnapshot, any Error> {
    updates(pollingEvery: .seconds(1))
  }

  func updates(
    pollingEvery interval: Duration
  ) -> AsyncThrowingStream<AudioCatalogSnapshot, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task { @Sendable in
        var previous: AudioCatalogSnapshot?
        do {
          while !Task.isCancelled {
            let current = try snapshot()
            if current != previous {
              continuation.yield(current)
              previous = current
            }
            try await Task.sleep(for: interval)
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
