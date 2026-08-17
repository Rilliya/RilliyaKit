// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RilliyaNetworkAudio

@Suite("Network audio packet reordering")
struct NetworkAudioPacketReorderBufferTests {
  @Test("Packets arriving in order pass straight through")
  func orderedPacketsAreNotHeld() throws {
    let harness = try Harness(depth: 8)

    for sequence in UInt64(0)..<10 {
      #expect(harness.admit(sequence) == .queued)
      #expect(harness.buffer.heldCount == 0)
    }

    #expect(harness.released == (0..<10).map { .packet(Float($0)) })
  }

  /// The reason this exists: a tunnel delivers `n + 1` before `n`, and both belong in the stream.
  @Test("A swapped pair is put back in order")
  func swappedPairIsReordered() throws {
    let harness = try Harness(depth: 8)

    #expect(harness.admit(0) == .queued)
    #expect(harness.admit(2) == .queued)
    // Nothing may be released while the packet before it is still outstanding.
    #expect(harness.released == [.packet(0)])
    #expect(harness.buffer.heldCount == 1)

    #expect(harness.admit(1) == .queued)

    #expect(harness.released == [.packet(0), .packet(1), .packet(2)])
    #expect(harness.buffer.heldCount == 0)
  }

  @Test("A whole window arriving backwards still comes out forwards")
  func reversedWindowIsReordered() throws {
    let harness = try Harness(depth: 8)

    #expect(harness.admit(0) == .queued)
    for sequence in stride(from: UInt64(7), through: 1, by: -1) {
      #expect(harness.admit(sequence) == .queued)
    }

    #expect(harness.released == (0..<8).map { .packet(Float($0)) })
  }

  @Test("A packet that never arrives becomes a gap once the window fills")
  func lostPacketBecomesAGapAfterTheWindow() throws {
    let harness = try Harness(depth: 4)

    #expect(harness.admit(0) == .queued)
    #expect(harness.admit(2) == .queued)
    #expect(harness.admit(3) == .queued)
    #expect(harness.admit(4) == .queued)
    // Sequence 1 is still awaited, so nothing past it has been released.
    #expect(harness.released == [.packet(0)])

    // This one is a full window past the gap, so 1 is conceded and the run follows.
    #expect(harness.admit(5) == .queued)

    #expect(
      harness.released == [.packet(0), .gap, .packet(2), .packet(3), .packet(4), .packet(5)]
    )
  }

  @Test("Holding nothing means a gap is conceded at once")
  func depthOneConcedesImmediately() throws {
    let harness = try Harness(depth: 1)

    #expect(harness.admit(0) == .queued)
    #expect(harness.admit(2) == .queued)

    #expect(harness.released == [.packet(0), .gap, .packet(2)])
  }

  /// Replay protection is the property the whole encrypted stream rests on: a sequence whose turn
  /// has passed can never be placed, so a captured datagram cannot be re-injected.
  @Test("A packet whose turn has passed is refused")
  func passedPacketIsRefused() throws {
    let harness = try Harness(depth: 4)

    #expect(harness.admit(0) == .queued)
    #expect(harness.admit(1) == .queued)
    #expect(harness.admit(2) == .queued)

    #expect(harness.admit(0) == .tooLate)
    #expect(harness.admit(1) == .tooLate)
    #expect(harness.released == [.packet(0), .packet(1), .packet(2)])
  }

  @Test("A packet already held is refused as a duplicate")
  func heldDuplicateIsRefused() throws {
    let harness = try Harness(depth: 8)

    #expect(harness.admit(0) == .queued)
    #expect(harness.admit(3) == .queued)
    #expect(harness.admit(3) == .duplicate)
    #expect(harness.buffer.heldCount == 1)
  }

  @Test("A replayed run cannot re-enter the stream behind a live one")
  func replayedRunIsRefused() throws {
    let harness = try Harness(depth: 8)

    for sequence in UInt64(0)..<8 { #expect(harness.admit(sequence) == .queued) }
    let delivered = harness.released

    for sequence in UInt64(0)..<8 { #expect(harness.admit(sequence) == .tooLate) }

    #expect(harness.released == delivered)
  }

  @Test("A stream that stops mid-gap gives up what it holds rather than stranding it")
  func flushReleasesHeldPackets() throws {
    let harness = try Harness(depth: 8)

    #expect(harness.admit(0) == .queued)
    #expect(harness.admit(2) == .queued)
    #expect(harness.released == [.packet(0)])

    harness.flush()

    #expect(harness.released == [.packet(0), .gap, .packet(2)])
  }

  @Test("Resetting keeps nothing from the stream that ended")
  func resetDropsHeldPackets() throws {
    let harness = try Harness(depth: 8)

    #expect(harness.admit(0) == .queued)
    #expect(harness.admit(4) == .queued)
    harness.clearReleased()
    harness.buffer.reset()

    #expect(harness.buffer.heldCount == 0)
    #expect(harness.buffer.nextSequence == nil)
    // A new stream starts wherever its first packet says, without a gap for the old one.
    #expect(harness.admit(100) == .queued)
    #expect(harness.released == [.packet(100)])
  }

  /// One datagram naming a distant sequence must not be able to stall the receiver or flood it
  /// with silence, which walking every number between would do.
  @Test("A sequence far beyond the window concedes at most one window of gaps")
  func distantJumpConcedesOnlyTheWindow() throws {
    let harness = try Harness(depth: 4)

    #expect(harness.admit(0) == .queued)
    #expect(harness.admit(1_000_000) == .queued)

    #expect(harness.released.filter { $0 == .gap }.count <= harness.buffer.depth)
    // The far packet is inside the window that jump opened, so it waits like any other.
    #expect(harness.buffer.heldCount == 1)

    harness.flush()
    #expect(harness.released.last == .packet(1_000_000))
    #expect(harness.released.filter { $0 == .gap }.count <= harness.buffer.depth * 2)
  }

  @Test(
    "Controls outside the bounded policy are rejected",
    arguments: [(0, 8, 2), (8, 0, 2), (8, 8, 0)]
  )
  func invalidControlsAreRejected(depth: Int, frameCount: Int, channelCount: Int) {
    #expect(throws: (any Error).self) {
      _ = try NetworkAudioPacketReorderBuffer(
        depth: depth,
        maximumFrameCount: frameCount,
        channelCount: channelCount
      )
    }
  }

  private enum Event: Equatable {
    case packet(Float)
    case gap
  }

  /// Each packet carries its sequence as its only sample, so the released order reads directly.
  private final class Harness {
    let buffer: NetworkAudioPacketReorderBuffer
    private(set) var released: [Event] = []

    init(depth: Int) throws {
      buffer = try NetworkAudioPacketReorderBuffer(
        depth: depth,
        maximumFrameCount: 1,
        channelCount: 1
      )
    }

    func admit(_ sequence: UInt64) -> NetworkAudioReorderAdmission {
      var sample = Float(sequence)
      return withUnsafePointer(to: &sample) { pointer in
        buffer.admit(sequence: sequence, samples: pointer, frameCount: 1) { samples, frameCount in
          record(samples, frameCount)
        }
      }
    }

    func flush() {
      buffer.flush { samples, frameCount in record(samples, frameCount) }
    }

    func clearReleased() {
      released.removeAll()
    }

    private func record(_ samples: UnsafePointer<Float>?, _ frameCount: Int) {
      guard frameCount > 0 else { return }
      released.append(samples.map { Event.packet($0.pointee) } ?? .gap)
    }
  }
}
