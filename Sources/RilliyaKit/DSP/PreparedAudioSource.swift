// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A prepared pull source that fills caller-owned planar Float32 output storage.
///
/// Implementations are prepared away from the realtime thread. Calls for one instance must be
/// serialized on a single render thread and must not allocate, lock, log, or invoke unbounded work.
public protocol PreparedAudioSource: AnyObject, Sendable {
  /// The immutable format and frame bound used to prepare this source.
  var preparation: AudioRenderPreparation { get }

  /// Latency and tail behavior reported to a graph compiler.
  var timing: AudioNodeTiming { get }

  /// Pulls one bounded render quantum into caller-owned noninterleaved Float32 channels.
  @discardableResult
  func render(
    outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRenderResult
}

/// A prepared source backed by one bounded capture frame buffer.
///
/// Capture underflow is rendered as silence by ``AudioRealtimeFrameBuffer`` and still counts as a
/// successful render. The buffer and source formats must match exactly.
public final class PreparedAudioFrameBufferSource: PreparedAudioSource, @unchecked Sendable {
  /// The immutable format and frame bound used to prepare this source.
  public let preparation: AudioRenderPreparation

  /// Reading capture frames adds no algorithmic latency or tail.
  public let timing = AudioNodeTiming.transparent

  /// The bounded single-producer, single-consumer capture storage.
  public let frameBuffer: AudioRealtimeFrameBuffer

  /// Creates a pull source for a prepared output quantum.
  public init(
    frameBuffer: AudioRealtimeFrameBuffer,
    maximumFrameCount: Int
  ) throws {
    self.frameBuffer = frameBuffer
    preparation = try AudioRenderPreparation(
      format: frameBuffer.format,
      maximumFrameCount: maximumFrameCount
    )
  }

  /// Pulls capture frames and zero-fills any unavailable tail.
  @discardableResult
  public func render(
    outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRenderResult {
    guard (0...preparation.maximumFrameCount).contains(frameCount) else {
      return .invalidFrameCount
    }
    switch frameBuffer.read(into: outputChannels, frameCount: frameCount) {
    case .read:
      return .rendered
    case .invalidFrameCount:
      return .invalidFrameCount
    case .insufficientChannels:
      return .insufficientChannels
    }
  }
}
