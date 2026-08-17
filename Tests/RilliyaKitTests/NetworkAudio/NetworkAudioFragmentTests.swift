// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RilliyaNetworkAudio

/// A compressed block wider than a datagram is split across consecutive sequences and put back
/// together before it is decoded, because a piece of a block is not audio until the block is.
@Suite("Network audio fragment reassembly")
struct NetworkAudioFragmentReassemblerTests {
  private enum Fixture {
    static let fragmentByteCount = 64
  }

  @Test("A block arriving in order comes back whole")
  func orderedBlockCompletes() throws {
    let harness = try Harness()
    let block = harness.block(pieces: 4)

    var outcome = NetworkAudioReassembly.held
    for index in 0..<4 {
      outcome = try harness.admit(block, index: index, of: 4, firstSequence: 0)
    }

    #expect(outcome == .completed(harness.joined(block)))
    #expect(harness.reassembler.heldBlockCount == 0)
  }

  /// Pieces cross a network that reorders, so the order they arrive in is not the order they sit
  /// in.
  @Test("A block arriving backwards still comes back in order")
  func reversedBlockCompletes() throws {
    let harness = try Harness()
    let block = harness.block(pieces: 5)

    var outcome = NetworkAudioReassembly.held
    for index in stride(from: 4, through: 0, by: -1) {
      outcome = try harness.admit(block, index: index, of: 5, firstSequence: 0)
    }

    #expect(outcome == .completed(harness.joined(block)))
  }

  @Test("A block is held while a piece is outstanding")
  func incompleteBlockIsHeld() throws {
    let harness = try Harness()
    let block = harness.block(pieces: 4)

    for index in [0, 1, 3] {
      #expect(try harness.admit(block, index: index, of: 4, firstSequence: 0) == .held)
    }

    #expect(harness.reassembler.heldBlockCount == 1)
  }

  /// The pieces a block still lacks are exactly what is worth asking the sender for.
  @Test("The missing pieces are named by their own sequences")
  func missingPiecesAreNamed() throws {
    let harness = try Harness()
    let block = harness.block(pieces: 5)

    for index in [0, 2, 4] {
      _ = try harness.admit(block, index: index, of: 5, firstSequence: 100)
    }

    #expect(harness.reassembler.missingSequences(limit: 8) == [101, 103])
  }

  @Test("A piece offered twice is refused")
  func duplicatePieceIsRefused() throws {
    let harness = try Harness()
    let block = harness.block(pieces: 3)

    _ = try harness.admit(block, index: 1, of: 3, firstSequence: 0)

    #expect(try harness.admit(block, index: 1, of: 3, firstSequence: 0) == .duplicate)
  }

  /// A piece that never comes must not hold storage for ever, so a block far enough behind is
  /// given up on.
  @Test("A block is given up on once newer ones have passed it")
  func staleBlockIsAbandoned() throws {
    let harness = try Harness(blockCount: 2)
    let block = harness.block(pieces: 4)

    _ = try harness.admit(block, index: 0, of: 4, firstSequence: 0)
    for first in [UInt64(4), 8, 12] {
      for index in 0..<4 { _ = try harness.admit(block, index: index, of: 4, firstSequence: first) }
    }

    #expect(try harness.admit(block, index: 1, of: 4, firstSequence: 0) == .tooLate)
    #expect(harness.reassembler.heldBlockCount == 0)
  }

  @Test("A piece claiming a different shape for a block it already knows is refused")
  func inconsistentBlockIsRefused() throws {
    let harness = try Harness()
    let block = harness.block(pieces: 4)

    _ = try harness.admit(block, index: 0, of: 4, firstSequence: 0)

    #expect(try harness.admit(block, index: 1, of: 6, firstSequence: 0) == .tooLate)
  }

  @Test("A new session keeps nothing from the last")
  func resetForgetsEverything() throws {
    let harness = try Harness()
    let block = harness.block(pieces: 4)
    _ = try harness.admit(block, index: 0, of: 4, firstSequence: 0)

    harness.reassembler.reset()

    #expect(harness.reassembler.heldBlockCount == 0)
    #expect(harness.reassembler.missingSequences(limit: 8).isEmpty)
  }

  @Test(
    "A piece claiming a place no block has is refused",
    arguments: [(0, 0), (-1, 4), (4, 4), (0, NetworkAudioPacketFragment.maximumCount + 1)]
  )
  func impossiblePlaceIsRefused(index: Int, count: Int) {
    #expect(throws: NetworkAudioPacketError.self) {
      _ = try NetworkAudioPacketFragment(index: index, count: count)
    }
  }

  @Test(
    "Controls outside the bounded policy are rejected",
    arguments: [(0, 64), (9, 64), (2, 0)]
  )
  func invalidControlsAreRejected(blockCount: Int, byteCount: Int) {
    #expect(throws: NetworkAudioReassemblyError.self) {
      _ = try NetworkAudioFragmentReassembler(
        blockCount: blockCount,
        maximumFragmentByteCount: byteCount
      )
    }
  }

  private final class Harness {
    let reassembler: NetworkAudioFragmentReassembler

    init(blockCount: Int = 4) throws {
      reassembler = try NetworkAudioFragmentReassembler(
        blockCount: blockCount,
        maximumFragmentByteCount: Fixture.fragmentByteCount
      )
    }

    /// Each piece holds a distinct run of bytes, so a block put back wrongly is visible.
    func block(pieces: Int) -> [Data] {
      (0..<pieces).map { index in
        Data((0..<Fixture.fragmentByteCount).map { UInt8((index * 7 + $0) % 251) })
      }
    }

    func joined(_ block: [Data]) -> Data {
      block.reduce(into: Data()) { $0.append($1) }
    }

    func admit(
      _ block: [Data],
      index: Int,
      of count: Int,
      firstSequence: UInt64
    ) throws -> NetworkAudioReassembly {
      reassembler.admit(
        sequence: firstSequence &+ UInt64(index),
        fragment: try NetworkAudioPacketFragment(index: index, count: count),
        payload: block[index]
      )
    }
  }
}
