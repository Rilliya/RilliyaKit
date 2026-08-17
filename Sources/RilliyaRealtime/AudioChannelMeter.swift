// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaCore

/// A bounded meter and waveform value for one audio channel.
public struct AudioChannelMeterSnapshot: Equatable, Sendable {
  /// The channel represented by this snapshot.
  public let channelID: AudioChannelID

  /// The root-mean-square linear amplitude.
  public let rootMeanSquare: Float

  /// The peak absolute linear amplitude before waveform clamping.
  public let peak: Float

  /// The RMS amplitude expressed in decibels and limited by the configured floor.
  public let decibels: Float

  /// Whether any finite sample reached or exceeded unit amplitude.
  public let isClipping: Bool

  /// A transient-preserving waveform downsample clamped to -1...1.
  public let waveform: [Float]

  /// Creates a channel meter snapshot.
  public init(
    channelID: AudioChannelID,
    rootMeanSquare: Float,
    peak: Float,
    decibels: Float,
    isClipping: Bool,
    waveform: [Float]
  ) {
    self.channelID = channelID
    self.rootMeanSquare = rootMeanSquare
    self.peak = peak
    self.decibels = decibels
    self.isClipping = isClipping
    self.waveform = waveform
  }
}
