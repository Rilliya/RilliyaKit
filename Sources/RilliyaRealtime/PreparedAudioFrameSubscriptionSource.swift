// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A prepared pull source backed by one independently paced distributor subscription.
public final class PreparedAudioFrameSubscriptionSource: PreparedAudioSource, @unchecked Sendable {
  /// The immutable format and frame bound used to prepare this source.
  public let preparation: AudioRenderPreparation

  /// Reading queued source frames adds no algorithmic latency or tail.
  public let timing = AudioNodeTiming.transparent

  /// The independently paced subscription consumed by this source.
  public let subscription: AudioRealtimeFrameSubscription

  /// Creates a pull source for a prepared output quantum.
  public init(
    subscription: AudioRealtimeFrameSubscription,
    maximumFrameCount: Int
  ) throws {
    self.subscription = subscription
    preparation = try AudioRenderPreparation(
      format: subscription.format,
      maximumFrameCount: maximumFrameCount
    )
  }

  /// Pulls subscription frames and zero-fills an inactive or unavailable source.
  @discardableResult
  public func render(
    outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRenderResult {
    guard (0...preparation.maximumFrameCount).contains(frameCount) else {
      return .invalidFrameCount
    }
    guard outputChannels.count >= preparation.format.channelCount else {
      return .insufficientChannels
    }
    switch subscription.read(into: outputChannels, frameCount: frameCount) {
    case .read:
      return .rendered
    case .inactive:
      for channel in 0..<preparation.format.channelCount {
        outputChannels[channel].update(repeating: 0, count: frameCount)
      }
      return .rendered
    case .invalidFrameCount:
      return .invalidFrameCount
    case .insufficientChannels:
      return .insufficientChannels
    }
  }
}
