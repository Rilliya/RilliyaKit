// SPDX-License-Identifier: Apache-2.0

import Foundation
import RilliyaCore
import Testing

@testable import RilliyaRealtime

/// Measuring audio that only exists on the thread rendering it.
///
/// A generator makes its samples as it plays them, so there is no producer elsewhere to read and
/// no thread but the audio thread to measure on. What that costs is a contract: measure into
/// storage already allocated, never wait for a lock, and hand nothing to application code until
/// the measurement has left that thread.
@Suite("Audio realtime meter", .serialized)
struct AudioRealtimeMeterTests {
  /// A generator's channels belong to the graph rather than to any device.
  private static let channelIDs: [AudioChannelID] = (0..<2).compactMap { rawIndex in
    AudioChannelIndex(rawValue: rawIndex).map {
      AudioChannelID(ownerID: .source(.stream(UUID())), index: $0)
    }
  }

  private static func configuration(
    updatesPerSecond: Int = 1_000
  ) -> AudioRealtimeMeterConfiguration {
    AudioRealtimeMeterConfiguration(
      updatesPerSecond: updatesPerSecond,
      waveformSampleCount: 8,
      minimumDecibels: -80
    )
  }

  /// Feeds one quantum of planar audio and waits for the meter to deliver it.
  private static func measure(
    channels: [[Float]],
    updatesPerSecond: Int = 1_000,
    channelIDs: [AudioChannelID]? = nil
  ) async -> [AudioChannelMeterSnapshot]? {
    let delivered = Delivery()
    let meter = AudioRealtimeMeter(
      sampleRate: 48_000,
      channelIDs: channelIDs ?? Self.channelIDs,
      configuration: configuration(updatesPerSecond: updatesPerSecond),
      snapshotHandler: { _, _, snapshots in delivered.store(snapshots) }
    )
    try? await feed(meter, channels: channels)
    return await awaitDelivery(from: delivered)
  }

  private final class Delivery: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [AudioChannelMeterSnapshot]?

    func store(_ value: [AudioChannelMeterSnapshot]) { lock.withLock { snapshots = value } }
    func take() -> [AudioChannelMeterSnapshot]? { lock.withLock { snapshots } }
    func clear() { lock.withLock { snapshots = nil } }
  }

  @Test("Planar audio is measured per channel")
  func planarAudioIsMeasuredPerChannel() async throws {
    let snapshots = try #require(
      await Self.measure(channels: [
        [Float](repeating: 0.5, count: 64),
        [Float](repeating: 0.25, count: 64),
      ]))

    #expect(snapshots.count == 2)
    #expect(abs(snapshots[0].rootMeanSquare - 0.5) < 0.001)
    #expect(abs(snapshots[1].rootMeanSquare - 0.25) < 0.001)
    #expect(snapshots[0].peak > snapshots[1].peak, "a louder channel should report a higher peak")
    #expect(!snapshots[0].waveform.isEmpty, "a measured channel should have a drawable waveform")
  }

  /// Silence has to be reported, not skipped: a drawing that keeps the last loud frame forever is
  /// worse than one that says the audio stopped.
  @Test("Silence is reported at the configured floor")
  func silenceIsReportedAtTheFloor() async throws {
    let snapshots = try #require(
      await Self.measure(channels: [
        [Float](repeating: 0, count: 64),
        [Float](repeating: 0, count: 64),
      ]))

    #expect(snapshots.allSatisfy { $0.rootMeanSquare == 0 })
    #expect(snapshots.allSatisfy { $0.decibels == -80 })
    #expect(snapshots.allSatisfy { !$0.isClipping })
  }

  @Test("Audio at unit amplitude is reported as clipping")
  func unitAmplitudeClips() async throws {
    let snapshots = try #require(
      await Self.measure(channels: [
        [Float](repeating: 1.0, count: 64),
        [Float](repeating: 0.1, count: 64),
      ]))

    #expect(snapshots[0].isClipping)
    #expect(!snapshots[1].isClipping)
  }

  /// A producer with fewer channels than the meter was prepared for must not leave the rest
  /// showing whatever they last held.
  ///
  /// The channel has to be made loud first. A meter starts silent, so a test that only ever feeds
  /// the narrow case passes whether or not anything clears the channels it did not reach.
  @Test("A channel a later measurement does not reach goes silent")
  func unreachedChannelsReportSilence() async throws {
    let delivered = Delivery()
    let meter = AudioRealtimeMeter(
      sampleRate: 48_000,
      channelIDs: Self.channelIDs,
      configuration: Self.configuration(),
      snapshotHandler: { _, _, snapshots in delivered.store(snapshots) }
    )

    try await Self.feed(
      meter,
      channels: [[Float](repeating: 0.5, count: 64), [Float](repeating: 0.5, count: 64)])
    let loud = try #require(await Self.awaitDelivery(from: delivered))
    #expect(loud[1].rootMeanSquare > 0, "the second channel was never made loud")
    delivered.clear()

    try await Self.feed(meter, channels: [[Float](repeating: 0.5, count: 64)])
    let narrow = try #require(await Self.awaitDelivery(from: delivered))

    #expect(narrow.count == 2)
    #expect(narrow[0].rootMeanSquare > 0)
    #expect(narrow[1].rootMeanSquare == 0, "an unreached channel kept a stale measurement")
    #expect(narrow[1].decibels == -80)
    #expect(narrow[1].waveform.isEmpty, "an unreached channel kept a stale waveform")
  }

  private static func feed(_ meter: AudioRealtimeMeter, channels: [[Float]]) async throws {
    let frameCount = channels.first?.count ?? 0
    var storage = channels.flatMap { $0 }
    storage.withUnsafeMutableBufferPointer { flat in
      guard let base = flat.baseAddress else { return }
      let pointers = (0..<channels.count).map { base.advanced(by: $0 * frameCount) }
      pointers.withUnsafeBufferPointer { meter.consume(planar: $0, frameCount: frameCount) }
    }
  }

  private static func awaitDelivery(
    from delivered: Delivery
  ) async -> [AudioChannelMeterSnapshot]? {
    for _ in 0..<200 {
      if let snapshots = delivered.take() { return snapshots }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return nil
  }

  /// The rate is what keeps measuring off the critical path; measuring every quantum would spend
  /// the audio thread on something only a drawing wants.
  ///
  /// Counted from the delivered sequence rather than from how many deliveries arrive: the delivery
  /// source coalesces, so one delivery is what a correct meter and a meter measuring every quantum
  /// both look like from the outside.
  @Test("Measuring happens at the configured rate, not every quantum")
  func measuringIsRateLimited() async throws {
    let sequences = SequenceRecorder()
    let meter = AudioRealtimeMeter(
      sampleRate: 48_000,
      channelIDs: Self.channelIDs,
      // 30 a second at 48 kHz is one measurement per 1,600 frames.
      configuration: Self.configuration(updatesPerSecond: 30),
      snapshotHandler: { sequence, _, _ in sequences.record(sequence) }
    )

    // Exactly one interval's worth, delivered as 25 quanta of 64 frames.
    for _ in 0..<25 {
      try await Self.feed(
        meter,
        channels: [
          [Float](repeating: 0.5, count: 64), [Float](repeating: 0.5, count: 64),
        ])
    }
    for _ in 0..<200 where sequences.highest == 0 {
      try await Task.sleep(for: .milliseconds(5))
    }

    #expect(
      sequences.highest == 1,
      "one interval of audio produced \(sequences.highest) measurements")
  }

  private final class SequenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func record(_ sequence: UInt64) { lock.withLock { value = max(value, sequence) } }
    var highest: UInt64 { lock.withLock { value } }
  }

  /// A meter that outlives what it was measuring must go quiet rather than repeat itself.
  @Test("A stopped meter delivers nothing more")
  func aStoppedMeterDeliversNothing() async throws {
    let delivered = Counter()
    let meter = AudioRealtimeMeter(
      sampleRate: 48_000,
      channelIDs: Self.channelIDs,
      configuration: Self.configuration(),
      snapshotHandler: { _, _, _ in delivered.increment() }
    )
    meter.stopPublishing()

    try await Self.feed(
      meter,
      channels: [[Float](repeating: 0.5, count: 64), [Float](repeating: 0.5, count: 64)])
    try await Task.sleep(for: .milliseconds(60))

    #expect(delivered.value == 0, "a stopped meter delivered \(delivered.value) measurements")
  }

  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
  }
}
