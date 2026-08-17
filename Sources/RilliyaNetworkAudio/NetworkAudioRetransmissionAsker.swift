// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Decides what to ask a sender for, and whether asking is worth it at all.
///
/// A resent packet is only useful if it arrives before the audio it holds is due. That leaves a
/// budget of one round trip, which this measures rather than assumes: a request is timed against
/// the packet that answers it, and once the round trip is longer than the queue the receiver
/// holds, asking would spend a datagram on audio that would arrive too late to place.
///
/// A sequence is asked for once. Asking twice for the same gap doubles the cost of a loss without
/// improving the odds, since a request lost on a link that lost the audio is likely lost for the
/// same reason.
struct NetworkAudioRetransmissionAsker {
  /// How long a round trip is assumed to be before one has been measured.
  ///
  /// Optimistic on purpose: a receiver that assumes the worst never asks, and so never learns.
  static let assumedRoundTrip = Duration.milliseconds(5)

  /// How much of the queue's depth a round trip may occupy and still leave time to place the
  /// answer.
  static let usableFraction = 0.5

  /// The round trip last measured, or `nil` while none has been.
  private(set) var roundTrip: Duration?

  /// Sequences asked for and not yet answered, with when they were asked.
  private var outstanding: [UInt64: UInt64] = [:]

  /// Sequences asked for at any point in this session.
  private var asked: Set<UInt64> = []

  /// The largest number of sequences remembered before the oldest are forgotten.
  private let memory: Int

  init(memory: Int = 4_096) {
    self.memory = max(memory, 1)
  }

  /// The sequences worth asking for now, given how much audio the queue is holding.
  ///
  /// - Parameters:
  ///   - missing: what the reorder buffer says has not arrived.
  ///   - queued: how much audio is between the queue and the listener.
  ///   - now: the current time.
  /// - Returns: the sequences to name, which is empty when there is no time to spend.
  mutating func sequencesToAsk(
    missing: [UInt64],
    queued: Duration,
    now: UInt64
  ) -> [UInt64] {
    guard !missing.isEmpty else { return [] }
    let trip = roundTrip ?? Self.assumedRoundTrip
    // An answer that arrives after its audio was due is a datagram spent on nothing.
    guard Double(trip.wholeNanoseconds) < Double(queued.wholeNanoseconds) * Self.usableFraction
    else { return [] }

    var wanted: [UInt64] = []
    for sequence in missing
    where !asked.contains(sequence)
      && wanted.count < NetworkAudioRetransmissionRequest.maximumSequenceCount
    {
      wanted.append(sequence)
    }
    guard !wanted.isEmpty else { return [] }
    for sequence in wanted {
      asked.insert(sequence)
      outstanding[sequence] = now
    }
    forgetOldest()
    return wanted
  }

  /// Records that a sequence arrived, timing it against when it was asked for.
  ///
  /// - Returns: whether this sequence was one that had been asked for.
  @discardableResult
  mutating func noteArrival(sequence: UInt64, now: UInt64) -> Bool {
    guard let askedAt = outstanding.removeValue(forKey: sequence) else { return false }
    guard now > askedAt else { return true }
    let measured = Duration.nanoseconds(Int64(min(now - askedAt, UInt64(Int64.max))))
    // The newest measurement is weighted rather than replacing, so one slow answer does not stop
    // a receiver asking again.
    if let previous = roundTrip {
      roundTrip = (previous * 3 + measured) / 4
    } else {
      roundTrip = measured
    }
    return true
  }

  /// Forgets the session, as a sender that restarted requires.
  mutating func reset() {
    outstanding.removeAll(keepingCapacity: true)
    asked.removeAll(keepingCapacity: true)
    roundTrip = nil
  }

  /// Whether anything asked for is still outstanding.
  var outstandingCount: Int { outstanding.count }

  private mutating func forgetOldest() {
    guard asked.count > memory else { return }
    // Only the recent matter: a sequence far behind the window can never be asked for again.
    let threshold = asked.max().map { $0 &- UInt64(memory) } ?? 0
    asked = asked.filter { $0 > threshold }
    outstanding = outstanding.filter { $0.key > threshold }
  }
}
