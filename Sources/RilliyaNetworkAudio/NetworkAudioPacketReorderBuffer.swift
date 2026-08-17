// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Why a packet offered to a reorder buffer was not queued.
public enum NetworkAudioReorderAdmission: Equatable, Sendable {
  /// The packet is in the window and its samples were taken.
  case queued

  /// The packet is already in the window, so it is a duplicate or a replay.
  case duplicate

  /// The packet's turn has already passed, so placing it would put it in the wrong moment.
  case tooLate
}

/// Errors from configuring a reorder buffer.
public enum NetworkAudioReorderError: Error, Equatable, Sendable {
  case invalidDepth(Int)
  case invalidFrameCount(Int)
  case invalidChannelCount(Int)
}

/// Puts arriving packets back into sequence order, holding a bounded number that arrive early.
///
/// A network that reorders — a tunnel above all — delivers packet `n + 1` before `n`. Writing
/// them in arrival order scrambles the audio, and refusing the late one loses it twice over:
/// once as the packet dropped, and once as the silence already written in its place. Holding a
/// few packets until their predecessors arrive costs nothing while the order is right, because a
/// packet whose turn it already is passes straight through.
///
/// A packet whose turn has passed is refused, so a replayed datagram can never be placed. The
/// sequence a session admits therefore never repeats, which is also what keeps its AES-GCM nonces
/// unique.
///
/// All storage is allocated during initialization; admitting a packet performs no allocation.
public final class NetworkAudioPacketReorderBuffer {
  /// Releases one packet's samples, or a gap when `samples` is `nil`.
  public typealias Release = (_ samples: UnsafePointer<Float>?, _ frameCount: Int) -> Void

  /// How many packets may be held while waiting for one that has not arrived.
  ///
  /// The wait is bounded by arrivals rather than a clock: once this many later packets are in
  /// hand, the missing one is treated as lost. Depth `1` holds nothing and accepts strictly
  /// increasing sequences only.
  public let depth: Int

  /// The packets held, waiting for an earlier one.
  public var heldCount: Int { presentCount }

  /// The next sequence that will be released, or `nil` before the first packet.
  public var nextSequence: UInt64? { expected }

  private let maximumFrameCount: Int
  private let channelCount: Int
  private let sampleCapacity: Int
  private let storage: UnsafeMutablePointer<Float>
  private var sequences: [UInt64]
  private var frameCounts: [Int]
  private var present: [Bool]
  private var expected: UInt64?
  private var presentCount = 0
  private var lastReleasedFrameCount = 0

  /// Prepares a buffer for one stream's packet size.
  public init(depth: Int, maximumFrameCount: Int, channelCount: Int) throws {
    guard depth >= 1 else { throw NetworkAudioReorderError.invalidDepth(depth) }
    guard maximumFrameCount >= 1 else {
      throw NetworkAudioReorderError.invalidFrameCount(maximumFrameCount)
    }
    guard channelCount >= 1 else {
      throw NetworkAudioReorderError.invalidChannelCount(channelCount)
    }
    self.depth = depth
    self.maximumFrameCount = maximumFrameCount
    self.channelCount = channelCount
    sampleCapacity = maximumFrameCount * channelCount
    storage = .allocate(capacity: sampleCapacity * depth)
    storage.initialize(repeating: 0, count: sampleCapacity * depth)
    sequences = Array(repeating: 0, count: depth)
    frameCounts = Array(repeating: 0, count: depth)
    present = Array(repeating: false, count: depth)
  }

  deinit {
    storage.deinitialize(count: sampleCapacity * depth)
    storage.deallocate()
  }

  /// Offers one packet's interleaved samples, releasing whatever its arrival completes.
  ///
  /// - Parameters:
  ///   - sequence: the packet's sequence within its session.
  ///   - samples: interleaved samples, `frameCount * channelCount` of them.
  ///   - frameCount: the packet's frames.
  ///   - release: called for each packet now in order, and for each gap given up on.
  /// - Returns: whether the packet was taken, or why it was refused.
  @discardableResult
  public func admit(
    sequence: UInt64,
    samples: UnsafePointer<Float>,
    frameCount: Int,
    releasing release: Release
  ) -> NetworkAudioReorderAdmission {
    guard frameCount >= 0, frameCount <= maximumFrameCount else { return .tooLate }
    let expected = expected ?? sequence
    self.expected = expected

    guard sequence >= expected else { return .tooLate }
    // A packet this far ahead means the ones between it and the window are not coming.
    if sequence >= expected &+ UInt64(depth) {
      advance(to: sequence &- UInt64(depth) &+ 1, releasing: release)
    }

    let slot = Int(sequence % UInt64(depth))
    if present[slot], sequences[slot] == sequence { return .duplicate }

    sequences[slot] = sequence
    frameCounts[slot] = frameCount
    present[slot] = true
    presentCount += 1
    if frameCount > 0 {
      storage.advanced(by: slot * sampleCapacity)
        .update(from: samples, count: frameCount * channelCount)
    }

    releaseReadyRun(releasing: release)
    return .queued
  }

  /// Gives up on everything still held, releasing it in order.
  ///
  /// A stream that stops mid-gap would otherwise strand the packets that did arrive.
  public func flush(releasing release: Release) {
    guard let expected, presentCount > 0 else { return }
    let highest = (0..<depth).filter { present[$0] }.map { sequences[$0] }.max() ?? expected
    advance(to: highest &+ 1, releasing: release)
  }

  /// Forgets the stream, keeping no packets from it.
  public func reset() {
    for slot in 0..<depth { present[slot] = false }
    presentCount = 0
    expected = nil
    lastReleasedFrameCount = 0
  }

  /// Releases the run starting at the expected sequence, stopping at the first absent packet.
  private func releaseReadyRun(releasing release: Release) {
    guard var sequence = expected else { return }
    while true {
      let slot = Int(sequence % UInt64(depth))
      guard present[slot], sequences[slot] == sequence else { break }
      releaseSlot(slot, releasing: release)
      sequence &+= 1
    }
    expected = sequence
  }

  /// Releases everything below `target`, treating an absent packet as a gap.
  ///
  /// The walk is bounded by the window rather than by the distance jumped: a sequence far ahead
  /// leaves nothing held behind it, so emitting one gap per number would let a single datagram
  /// name a sequence far enough away to stall the receiver and flood it with silence.
  private func advance(to target: UInt64, releasing release: Release) {
    guard let current = expected, target > current else { return }
    let walk = min(target &- current, UInt64(depth))
    var sequence = current
    while sequence < current &+ walk {
      let slot = Int(sequence % UInt64(depth))
      if present[slot], sequences[slot] == sequence {
        releaseSlot(slot, releasing: release)
      } else {
        release(nil, lastReleasedFrameCount)
      }
      sequence &+= 1
    }
    expected = target
  }

  private func releaseSlot(_ slot: Int, releasing release: Release) {
    let frameCount = frameCounts[slot]
    present[slot] = false
    presentCount -= 1
    lastReleasedFrameCount = frameCount
    release(storage.advanced(by: slot * sampleCapacity), frameCount)
  }
}
