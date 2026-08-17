// SPDX-License-Identifier: Apache-2.0

import Atomics
import Foundation

/// Carries retransmission requests from the network queue to the thread that can answer them.
///
/// The datagram history and the packet buffer belong to the realtime thread. Answering on the
/// queue a request arrived on would have two threads writing one buffer, which puts one packet's
/// bytes on the wire under another's sequence number and stores those wrong bytes as the history
/// for that sequence, poisoning every later answer for it.
///
/// A lock would fix that and is not available: the realtime body runs where locks are unsafe. So
/// requests cross as data instead — one producer, one consumer, fixed storage, atomic indices.
///
/// The cost is that an answer waits for the next cycle, up to one packet's worth of time. A
/// receiver only asks while it still has a round trip of audio queued, and a cycle is a small
/// fraction of that.
final class NetworkAudioRetransmissionMailbox: @unchecked Sendable {
  /// The most sequences one request can name.
  static let strideCount = NetworkAudioRetransmissionRequest.maximumSequenceCount

  /// How many requests are held before the oldest unread one is dropped.
  let capacity: Int

  private let sequences: UnsafeMutablePointer<UInt64>
  private let counts: UnsafeMutablePointer<Int>
  /// Written by the consumer only.
  private let readIndex = ManagedAtomic<UInt64>(0)
  /// Written by the producer only.
  private let writeIndex = ManagedAtomic<UInt64>(0)

  init(capacity: Int = 4) {
    precondition(capacity >= 1)
    self.capacity = capacity
    sequences = .allocate(capacity: capacity * Self.strideCount)
    sequences.initialize(repeating: 0, count: capacity * Self.strideCount)
    counts = .allocate(capacity: capacity)
    counts.initialize(repeating: 0, count: capacity)
  }

  deinit {
    sequences.deinitialize(count: capacity * Self.strideCount)
    sequences.deallocate()
    counts.deinitialize(count: capacity)
    counts.deallocate()
  }

  /// Leaves one request for the realtime thread.
  ///
  /// Call from the network queue only.
  ///
  /// - Returns: whether it was taken. A full mailbox drops the request rather than waiting, which
  ///   is what a queue serving a realtime thread has to do.
  @discardableResult
  func deposit(_ wanted: [UInt64]) -> Bool {
    guard !wanted.isEmpty, wanted.count <= Self.strideCount else { return false }
    let write = writeIndex.load(ordering: .relaxed)
    let read = readIndex.load(ordering: .acquiring)
    guard write &- read < UInt64(capacity) else { return false }

    let slot = Int(write % UInt64(capacity))
    for (offset, sequence) in wanted.enumerated() {
      sequences[slot * Self.strideCount + offset] = sequence
    }
    counts[slot] = wanted.count
    // Releasing, so the consumer that sees this index also sees the sequences written above.
    writeIndex.store(write &+ 1, ordering: .releasing)
    return true
  }

  /// Takes the next request into `destination`.
  ///
  /// Call from the realtime thread only.
  ///
  /// - Parameter destination: storage for at least ``strideCount`` sequences.
  /// - Returns: how many sequences were written, or `nil` when nothing is waiting.
  func take(into destination: UnsafeMutablePointer<UInt64>) -> Int? {
    let read = readIndex.load(ordering: .relaxed)
    guard read != writeIndex.load(ordering: .acquiring) else { return nil }

    let slot = Int(read % UInt64(capacity))
    let count = counts[slot]
    for offset in 0..<count {
      destination[offset] = sequences[slot * Self.strideCount + offset]
    }
    readIndex.store(read &+ 1, ordering: .releasing)
    return count
  }
}
