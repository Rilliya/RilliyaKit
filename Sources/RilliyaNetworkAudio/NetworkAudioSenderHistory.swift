// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Keeps the datagrams recently sent, so one asked for again can be found.
///
/// A packet is only worth keeping while a receiver could still place it: past its jitter buffer's
/// reach it is of no use to anyone. The depth is therefore a time bound expressed in packets, and
/// storage is allocated once.
final class NetworkAudioSenderHistory {
  /// How many recent datagrams are kept.
  let depth: Int

  private let datagramByteCount: Int
  private let storage: UnsafeMutableRawPointer
  private var sequences: [UInt64]
  private var lengths: [Int]
  private var present: [Bool]
  /// Which slots have already been resent once.
  ///
  /// A request carries no protection against being replayed, so without this one captured request
  /// would make a sender resend the same datagrams for as long as an attacker cared to repeat it.
  /// A receiver asks once per gap by design, so answering once is what it expects anyway.
  private var answered: [Bool]

  init(depth: Int, maximumDatagramByteCount: Int) {
    precondition(depth >= 1)
    precondition(maximumDatagramByteCount >= 1)
    self.depth = depth
    datagramByteCount = maximumDatagramByteCount
    storage = .allocate(byteCount: depth * maximumDatagramByteCount, alignment: 16)
    sequences = Array(repeating: 0, count: depth)
    lengths = Array(repeating: 0, count: depth)
    present = Array(repeating: false, count: depth)
    answered = Array(repeating: false, count: depth)
  }

  deinit {
    storage.deallocate()
  }

  /// Remembers one datagram, forgetting whatever occupied its slot.
  func record(sequence: UInt64, datagram: UnsafeRawBufferPointer) {
    guard let source = datagram.baseAddress, datagram.count <= datagramByteCount else { return }
    let slot = Int(sequence % UInt64(depth))
    storage.advanced(by: slot * datagramByteCount)
      .copyMemory(from: source, byteCount: datagram.count)
    sequences[slot] = sequence
    lengths[slot] = datagram.count
    present[slot] = true
    answered[slot] = false
  }

  /// Copies the datagram for `sequence` into `destination`, once.
  ///
  /// A second request naming the same sequence gets nothing: see ``answered``.
  ///
  /// - Returns: the bytes copied, or `nil` when that packet is no longer kept or has already been
  ///   resent.
  func takeDatagram(
    for sequence: UInt64,
    into destination: UnsafeMutableRawBufferPointer
  ) -> Int? {
    let slot = Int(sequence % UInt64(depth))
    guard present[slot], sequences[slot] == sequence, !answered[slot] else { return nil }
    let length = lengths[slot]
    guard let base = destination.baseAddress, destination.count >= length else { return nil }
    base.copyMemory(from: storage.advanced(by: slot * datagramByteCount), byteCount: length)
    answered[slot] = true
    return length
  }

  /// Forgets everything, as a new session must.
  func reset() {
    for slot in 0..<depth {
      present[slot] = false
      answered[slot] = false
    }
  }
}

/// How much a sender will resend, and how quickly.
///
/// A request is small and its answer is not, so without a ceiling one datagram could make a
/// sender send many. This is that ceiling: a bucket that refills at a fraction of the rate the
/// sender is already sending at, so retransmission can never become the larger half of the flow
/// however many requests arrive.
struct NetworkAudioRetransmissionBudget {
  /// The share of the nominal packet rate that may be spent resending.
  static let defaultFraction = 0.25

  /// The largest burst allowed before the rate applies.
  static let burst = Double(NetworkAudioRetransmissionRequest.maximumSequenceCount)

  private let refillPerNanosecond: Double
  private var tokens: Double
  private var lastRefill: UInt64?

  init(
    packetsPerSecond: Double, fraction: Double = NetworkAudioRetransmissionBudget.defaultFraction
  ) {
    let rate = max(packetsPerSecond, 0) * max(fraction, 0)
    refillPerNanosecond = rate / 1_000_000_000
    tokens = Self.burst
  }

  /// Whether one more packet may be resent now, spending a token if so.
  mutating func allows(now: UInt64) -> Bool {
    if let lastRefill, now > lastRefill {
      tokens = min(Self.burst, tokens + Double(now - lastRefill) * refillPerNanosecond)
    }
    lastRefill = now
    guard tokens >= 1 else { return false }
    tokens -= 1
    return true
  }
}
