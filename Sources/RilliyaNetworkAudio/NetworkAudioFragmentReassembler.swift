// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Why a reassembler could not be prepared.
public enum NetworkAudioReassemblyError: Error, Equatable, Sendable {
  case invalidBlockCount(Int)
  case invalidByteCount(Int)
}

/// What offering a fragment produced.
public enum NetworkAudioReassembly: Equatable, Sendable {
  /// One or more blocks are now whole, in the order they were sent.
  ///
  /// More than one when a piece completed a block that a later, already-whole block was waiting
  /// behind.
  case completed([Data])

  /// The block is still waiting for pieces.
  case held

  /// This piece belongs to a block already given up on or already delivered.
  case tooLate

  /// This piece has already been offered.
  case duplicate
}

/// Puts a block back together from the datagrams it was split across.
///
/// This runs ahead of decoding rather than behind it, because a piece of a compressed block is
/// not audio until the whole block is present. A block is lost entirely if any of its pieces is,
/// which is what makes splitting expensive on a lossy link and why the pieces a block is still
/// missing are reported: they are exactly what is worth asking the sender for.
///
/// Blocks are released in the order they were sent, not the order they complete: a later block
/// whose pieces all arrived waits for the one before it, which is what makes a further reorder
/// stage unnecessary for a split stream.
///
/// Only a bounded number of blocks are held at once, and a block is given up on when one far
/// enough ahead of it arrives, so a piece that never comes cannot hold storage for ever.
public final class NetworkAudioFragmentReassembler {
  /// How many partly-arrived blocks are held at once.
  public let blockCount: Int

  /// The blocks currently holding pieces.
  public var heldBlockCount: Int { blocks.filter(\.isOccupied).count }

  private struct Block {
    var firstSequence: UInt64 = 0
    var fragmentCount = 0
    var received = 0
    var isOccupied = false
    var present: [Bool] = []
    var lengths: [Int] = []
  }

  private let maximumFragmentByteCount: Int
  private let storage: UnsafeMutableRawPointer
  private var blocks: [Block]
  /// The first sequence of the newest block seen, which decides what is too old to keep.
  private var newestSequence: UInt64?

  /// Prepares a reassembler for a bounded number of blocks.
  public init(blockCount: Int, maximumFragmentByteCount: Int) throws {
    guard blockCount >= 1, blockCount <= 8 else {
      throw NetworkAudioReassemblyError.invalidBlockCount(blockCount)
    }
    guard maximumFragmentByteCount >= 1 else {
      throw NetworkAudioReassemblyError.invalidByteCount(maximumFragmentByteCount)
    }
    self.blockCount = blockCount
    self.maximumFragmentByteCount = maximumFragmentByteCount
    let slotByteCount = NetworkAudioPacketFragment.maximumCount * maximumFragmentByteCount
    storage = .allocate(byteCount: blockCount * slotByteCount, alignment: 16)
    blocks = Array(repeating: Block(), count: blockCount)
  }

  deinit {
    storage.deallocate()
  }

  /// Offers one piece of a block.
  ///
  /// - Parameters:
  ///   - sequence: the piece's own sequence.
  ///   - fragment: where the piece sits in its block.
  ///   - payload: the piece's bytes.
  /// - Returns: the whole block when this piece completed it.
  public func admit(
    sequence: UInt64,
    fragment: NetworkAudioPacketFragment,
    payload: Data
  ) -> NetworkAudioReassembly {
    guard payload.count <= maximumFragmentByteCount else { return .tooLate }
    // Every piece of a block occupies consecutive sequences, so the block is named by the first.
    let firstSequence = sequence &- UInt64(fragment.index)
    if let newest = newestSequence {
      guard firstSequence &+ UInt64(blockCount) > newest else { return .tooLate }
      newestSequence = max(newest, firstSequence)
    } else {
      newestSequence = firstSequence
    }

    let slot = Int(firstSequence % UInt64(blockCount))
    if blocks[slot].isOccupied, blocks[slot].firstSequence != firstSequence {
      // A newer block claims the slot; whatever was there never completed.
      clear(slot)
    }
    if !blocks[slot].isOccupied {
      blocks[slot] = Block(
        firstSequence: firstSequence,
        fragmentCount: fragment.count,
        received: 0,
        isOccupied: true,
        present: Array(repeating: false, count: fragment.count),
        lengths: Array(repeating: 0, count: fragment.count)
      )
    }
    guard blocks[slot].fragmentCount == fragment.count else { return .tooLate }
    guard !blocks[slot].present[fragment.index] else { return .duplicate }

    payload.withUnsafeBytes { bytes in
      guard let source = bytes.baseAddress else { return }
      offset(slot: slot, fragment: fragment.index)
        .copyMemory(from: source, byteCount: payload.count)
    }
    blocks[slot].present[fragment.index] = true
    blocks[slot].lengths[fragment.index] = payload.count
    blocks[slot].received += 1

    guard blocks[slot].received == blocks[slot].fragmentCount else { return .held }
    let ready = releaseInOrder()
    return ready.isEmpty ? .held : .completed(ready)
  }

  /// Releases every whole block from the oldest onward, stopping at the first still waiting.
  private func releaseInOrder() -> [Data] {
    var released: [Data] = []
    while true {
      let occupied = blocks.indices.filter { blocks[$0].isOccupied }
      guard let oldest = occupied.min(by: { blocks[$0].firstSequence < blocks[$1].firstSequence })
      else { break }
      guard blocks[oldest].received == blocks[oldest].fragmentCount else { break }
      released.append(collect(slot: oldest))
      clear(oldest)
    }
    return released
  }

  /// The sequences a held block is still missing, which is what is worth asking for.
  public func missingSequences(limit: Int) -> [UInt64] {
    guard limit > 0 else { return [] }
    var missing: [UInt64] = []
    for slot in blocks.indices where blocks[slot].isOccupied {
      for index in 0..<blocks[slot].fragmentCount
      where !blocks[slot].present[index] && missing.count < limit {
        missing.append(blocks[slot].firstSequence &+ UInt64(index))
      }
    }
    return missing.sorted()
  }

  /// Gives up on the oldest block still waiting, releasing whatever it was holding back.
  ///
  /// A block whose piece never arrives would otherwise hold every later block behind it.
  public func abandonOldest() -> [Data] {
    let occupied = blocks.indices.filter { blocks[$0].isOccupied }
    guard let oldest = occupied.min(by: { blocks[$0].firstSequence < blocks[$1].firstSequence })
    else { return [] }
    guard blocks[oldest].received < blocks[oldest].fragmentCount else { return [] }
    clear(oldest)
    return releaseInOrder()
  }

  /// Forgets everything, as a new session requires.
  public func reset() {
    for slot in blocks.indices { clear(slot) }
    newestSequence = nil
  }

  private func clear(_ slot: Int) {
    blocks[slot].isOccupied = false
    blocks[slot].received = 0
    blocks[slot].present = []
    blocks[slot].lengths = []
  }

  private func offset(slot: Int, fragment: Int) -> UnsafeMutableRawPointer {
    let slotByteCount = NetworkAudioPacketFragment.maximumCount * maximumFragmentByteCount
    return storage.advanced(by: slot * slotByteCount + fragment * maximumFragmentByteCount)
  }

  private func collect(slot: Int) -> Data {
    var block = Data(capacity: blocks[slot].lengths.reduce(0, +))
    for index in 0..<blocks[slot].fragmentCount {
      let length = blocks[slot].lengths[index]
      block.append(
        Data(
          bytes: offset(slot: slot, fragment: index),
          count: length
        )
      )
    }
    return block
  }
}
