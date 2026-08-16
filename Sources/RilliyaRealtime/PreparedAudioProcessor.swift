// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A prepared processor that can run without allocating, locking, or invoking user callbacks.
///
/// Implementations are prepared away from the realtime thread. Calls to `process` for one instance
/// must be serialized on a single render thread; control updates may arrive concurrently.
public protocol PreparedAudioProcessor: AnyObject, Sendable {
  /// The immutable format and frame bound used to prepare this processor.
  var preparation: AudioRenderPreparation { get }

  /// Latency, intentional delay, and tail behavior reported to a graph compiler.
  var timing: AudioNodeTiming { get }

  /// Processes noninterleaved Float32 PCM into caller-owned output storage.
  ///
  /// One output channel may exactly equal its corresponding input channel for in-place processing.
  /// Partial overlap, cross-channel aliasing, and overlap between channels are unsupported. The
  /// pointer collections and every sample allocation must remain valid for the duration of this
  /// call.
  @discardableResult
  func process(
    inputChannels: UnsafeBufferPointer<UnsafePointer<Float>>,
    outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRenderResult
}
