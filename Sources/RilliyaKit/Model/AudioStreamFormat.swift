// SPDX-License-Identifier: Apache-2.0

/// A native audio stream format reported by Core Audio.
public struct AudioStreamFormat: Hashable, Sendable {
  /// The number of sample frames per second.
  public let sampleRate: Double

  /// The native Core Audio format identifier.
  public let formatID: UInt32

  /// The native Core Audio format flags.
  public let formatFlags: UInt32

  /// The number of bytes in one packet.
  public let bytesPerPacket: UInt32

  /// The number of sample frames in one packet.
  public let framesPerPacket: UInt32

  /// The number of bytes in one sample frame.
  public let bytesPerFrame: UInt32

  /// The number of interleaved or noninterleaved channels in one frame.
  public let channelsPerFrame: UInt32

  /// The number of significant bits in one channel sample.
  public let bitsPerChannel: UInt32

  /// Creates an audio stream format from native Core Audio values.
  public init(
    sampleRate: Double,
    formatID: UInt32,
    formatFlags: UInt32,
    bytesPerPacket: UInt32,
    framesPerPacket: UInt32,
    bytesPerFrame: UInt32,
    channelsPerFrame: UInt32,
    bitsPerChannel: UInt32
  ) {
    self.sampleRate = sampleRate
    self.formatID = formatID
    self.formatFlags = formatFlags
    self.bytesPerPacket = bytesPerPacket
    self.framesPerPacket = framesPerPacket
    self.bytesPerFrame = bytesPerFrame
    self.channelsPerFrame = channelsPerFrame
    self.bitsPerChannel = bitsPerChannel
  }
}
