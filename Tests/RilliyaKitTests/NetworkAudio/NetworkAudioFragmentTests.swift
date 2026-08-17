// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaRealtime
import Testing

@testable import RilliyaNetworkAudio

/// A compressed block wider than a datagram is split across consecutive sequences and put back
/// together before it is decoded, because a piece of a block is not audio until the block is.
@Suite("Network audio fragment reassembly")
struct NetworkAudioFragmentReassemblerTests {
  private enum Fixture {
    static let fragmentByteCount = 64
  }

  /// A piece claiming a place further along than its own sequence names no block that exists.
  ///
  /// Subtracting anyway wrapped to near `UInt64.max`, and that became the newest
  /// sequence seen — after which every genuine piece was refused as too late, for the rest of the
  /// session. One datagram, no key needed, and every split block gone with it.
  @Test("A piece claiming a place before the start of the stream cannot wedge reassembly")
  func underflowingPieceCannotWedgeReassembly() throws {
    let harness = try Harness(blockCount: 2)
    let block = harness.block(pieces: 2)

    let hostile = harness.reassembler.admit(
      sequence: 0,
      fragment: try NetworkAudioPacketFragment(index: 1, count: 2),
      payload: block[1]
    )
    #expect(hostile == .tooLate)

    // A genuine two-piece block at sequences 1 and 2 still completes.
    _ = try harness.admit(block, index: 0, of: 2, firstSequence: 1)
    let outcome = try harness.admit(block, index: 1, of: 2, firstSequence: 1)

    #expect(outcome == .completed([harness.joined(block)]))
  }

  @Test("A block arriving in order comes back whole")
  func orderedBlockCompletes() throws {
    let harness = try Harness()
    let block = harness.block(pieces: 4)

    var outcome = NetworkAudioReassembly.held
    for index in 0..<4 {
      outcome = try harness.admit(block, index: index, of: 4, firstSequence: 0)
    }

    #expect(outcome == .completed([harness.joined(block)]))
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

    #expect(outcome == .completed([harness.joined(block)]))
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

/// A split block has to survive the whole path — encoder, wire, reassembler, decoder — or the
/// pieces work and the audio still does not.
@Suite("Network audio lossless over the wire")
struct NetworkAudioLosslessWireTests {
  private enum Fixture {
    static let sampleRate = 48_000.0
    static let channelCount = 2
    static let sessionID = UUID(
      uuid: (
        0x5A, 0x4B, 0x3C, 0x2D, 0x1E, 0x0F, 0x4A, 0x9B,
        0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11
      )
    )
  }

  /// Every block of a lossless stream reaches the queue, which means every piece of every block
  /// arrived and was put back in the right order.
  @Test("A lossless stream crosses the wire in pieces and reaches the queue")
  func losslessStreamReachesTheQueue() throws {
    let codec = NetworkAudioCodec.appleLossless
    let frameCount = try #require(
      codec.frameCount(nearestTo: 10, sampleRate: Fixture.sampleRate, channelCount: 2))
    let format = try NetworkAudioStreamFormat(
      sampleRate: Fixture.sampleRate, channelCount: Fixture.channelCount)
    let frameBuffer = try AudioRealtimeFrameBuffer(
      format: AudioProcessingFormat(
        sampleRate: Fixture.sampleRate, channelCount: Fixture.channelCount),
      capacityFrameCount: 65_536
    )
    let ingestor = try NetworkAudioPacketIngestor(
      configuration: NetworkAudioReceiverConfiguration(
        port: 49_998,
        format: format,
        capacityFrameCount: 65_536
      ),
      frameBuffer: frameBuffer
    )
    let encoder = try NetworkAudioCompressedEncoder(
      codec: codec,
      sampleRate: Fixture.sampleRate,
      channelCount: Fixture.channelCount,
      frameCountPerPacket: frameCount,
      bitRate: 0
    )
    let sampleCount = frameCount * Fixture.channelCount
    let samples = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
    let packet = UnsafeMutableRawBufferPointer.allocate(
      byteCount: codec.maximumPacketByteCount(
        sampleRate: Fixture.sampleRate, channelCount: Fixture.channelCount),
      alignment: 16
    )
    var datagram = Data(count: NetworkAudioPacketCodec.maximumDatagramByteCount)
    defer {
      samples.deallocate()
      packet.deallocate()
    }

    let room =
      1_200 - NetworkAudioPacketCodec.headerByteCount
      - NetworkAudioPacketFragment.headerByteCount
      - NetworkAudioCodec.maximumConfigurationByteCount
    var sequence: UInt64 = 0
    var seed: UInt64 = 0xDEAD_BEEF_CAFE_1234
    var blocksSent = 0
    var pieceCounts: [Int] = []

    for block in 0..<12 {
      for frame in 0..<frameCount {
        let position = Double(block * frameCount + frame)
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        let noise = Double(Int64(bitPattern: seed >> 11)) / Double(1 << 52) * 0.04
        let value = Float(0.2 * sin(2 * .pi * 220 * position / Fixture.sampleRate) + noise)
        for channel in 0..<Fixture.channelCount {
          samples[frame * Fixture.channelCount + channel] = value
        }
      }
      let byteCount = try encoder.encode(input: samples, into: packet)
      guard byteCount > 0 else { continue }
      blocksSent += 1

      let pieceCount = (byteCount + room - 1) / room
      pieceCounts.append(pieceCount)
      for index in 0..<pieceCount {
        let start = index * room
        let length = min(room, byteCount - start)
        let written = try datagram.withUnsafeMutableBytes { destination in
          try NetworkAudioPacketCodec.encode(
            sessionID: Fixture.sessionID,
            sequence: sequence,
            format: format,
            frameCount: frameCount,
            encoding: .appleLossless,
            payload: UnsafeRawBufferPointer(rebasing: packet[start..<(start + length)]),
            codecConfiguration: index == 0 ? encoder.configuration : Data(),
            fragment: pieceCount > 1
              ? try NetworkAudioPacketFragment(index: index, count: pieceCount) : nil,
            into: destination
          )
        }
        _ = ingestor.ingest(datagram.prefix(written), now: sequence * 1_000_000)
        sequence &+= 1
      }
    }

    // The measurement that made splitting necessary: a lossless block is many datagrams wide.
    #expect(pieceCounts.allSatisfy { $0 > 5 })
    let statistics = ingestor.statistics()
    #expect(statistics.rejectedPacketCount == 0)
    // Every block but the codec's first reaches the queue whole.
    #expect(
      statistics.frameBuffer.writtenFrameCount >= UInt64((blocksSent - 2) * frameCount)
    )
  }

  /// Losing one piece loses the block it belonged to, and nothing else.
  @Test("A block missing a piece is lost, and the stream carries on")
  func aLostPieceLosesOnlyItsBlock() throws {
    let harness = try Harness()
    let block = harness.block(pieces: 4)

    // The first block loses a piece; the second is whole.
    for index in [0, 1, 3] { _ = try harness.admit(block, index: index, of: 4, firstSequence: 0) }
    var completed = 0
    for index in 0..<4 {
      if case .completed(let blocks) = try harness.admit(
        block, index: index, of: 4, firstSequence: 4)
      {
        completed += blocks.count
      }
    }

    #expect(completed == 1)
  }

  private final class Harness {
    let reassembler: NetworkAudioFragmentReassembler

    init() throws {
      reassembler = try NetworkAudioFragmentReassembler(
        blockCount: 2,
        maximumFragmentByteCount: 64
      )
    }

    func block(pieces: Int) -> [Data] {
      (0..<pieces).map { index in Data((0..<64).map { UInt8((index * 7 + $0) % 251) }) }
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

/// Blocks leave in the order they were sent, not the order they finish arriving, which is what
/// makes a further reorder stage unnecessary for a split stream.
@Suite("Network audio block ordering")
struct NetworkAudioBlockOrderTests {
  @Test("A block that finishes early waits for the one before it")
  func laterBlockWaits() throws {
    let harness = try Harness()
    let block = harness.block(pieces: 2)

    // The second block completes while the first is still a piece short.
    _ = try harness.admit(block, index: 0, of: 2, firstSequence: 0)
    let early = try harness.admit(block, index: 0, of: 2, firstSequence: 2)
    let stillEarly = try harness.admit(block, index: 1, of: 2, firstSequence: 2)

    #expect(early == .held)
    #expect(stillEarly == .held)

    // Completing the first releases both, oldest first.
    let outcome = try harness.admit(block, index: 1, of: 2, firstSequence: 0)
    guard case .completed(let released) = outcome else {
      Issue.record("the first block did not release both")
      return
    }
    #expect(released.count == 2)
  }

  /// A block whose piece never arrives would otherwise hold every later block behind it.
  @Test("Giving up on a stalled block releases what was waiting behind it")
  func abandoningReleasesTheQueue() throws {
    let harness = try Harness()
    let block = harness.block(pieces: 2)

    _ = try harness.admit(block, index: 0, of: 2, firstSequence: 0)
    _ = try harness.admit(block, index: 0, of: 2, firstSequence: 2)
    #expect(try harness.admit(block, index: 1, of: 2, firstSequence: 2) == .held)

    let released = harness.reassembler.abandonOldest()

    #expect(released.count == 1)
    #expect(harness.reassembler.heldBlockCount == 0)
  }

  @Test("Giving up when nothing is stalled releases nothing")
  func abandoningNothingReleasesNothing() throws {
    let harness = try Harness()

    #expect(harness.reassembler.abandonOldest().isEmpty)
  }

  private final class Harness {
    let reassembler: NetworkAudioFragmentReassembler

    init() throws {
      reassembler = try NetworkAudioFragmentReassembler(
        blockCount: 4,
        maximumFragmentByteCount: 64
      )
    }

    func block(pieces: Int) -> [Data] {
      (0..<pieces).map { index in Data((0..<64).map { UInt8((index * 7 + $0) % 251) }) }
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
