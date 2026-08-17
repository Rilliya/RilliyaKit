// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RilliyaRealtime

@Suite("Audio realtime cadence")
struct AudioRealtimeCadenceTests {
  /// Apple silicon reports 125/3, so one tick is 41.666… ns and the timer runs at 24 MHz.
  private static let appleSilicon = AudioRealtimeTimebase(numerator: 125, denominator: 3)

  /// Intel reports 1/1, so a tick is a nanosecond.
  private static let intel = AudioRealtimeTimebase(numerator: 1, denominator: 1)

  @Test("A cadence that divides the timer evenly is exact")
  func exactCadence() throws {
    let cadence = try AudioRealtimeCadence(framesPerCycle: 128, sampleRate: 48_000)

    #expect(cadence.periodTicks(timebase: Self.appleSilicon) == 64_000)
    #expect(cadence.periodTicks(timebase: Self.intel) == 2_666_666)
    #expect(cadence.periodNanoseconds == 2_666_666)
  }

  /// A cadence that does not divide the timer evenly is the case a per-cycle increment gets
  /// wrong: 128 frames at 44.1 kHz is 69,659.86 ticks, so accumulating a rounded period drifts
  /// about a tenth of a tick per cycle.
  @Test("A cadence that does not divide evenly never accumulates rounding")
  func driftFreeCadence() throws {
    let cadence = try AudioRealtimeCadence(framesPerCycle: 128, sampleRate: 44_100)
    let timebase = Self.appleSilicon
    let exactPeriod =
      128.0 * 1_000_000_000.0 * Double(timebase.denominator)
      / (44_100.0 * Double(timebase.numerator))

    #expect(abs(exactPeriod - 69_659.863_9) < 0.001)
    for index in [UInt64(1), 1_000, 1_000_000, 10_000_000] {
      let deadline = cadence.deadline(cycleIndex: index, start: 0, timebase: timebase)
      let exact = Double(index) * exactPeriod
      #expect(abs(Double(deadline) - exact) < 1.0)
    }

    // A rounded per-cycle increment would be off by about 1.4 million ticks here.
    let rounded = UInt64(exactPeriod.rounded()) * 10_000_000
    let derived = cadence.deadline(cycleIndex: 10_000_000, start: 0, timebase: timebase)
    #expect(rounded != derived)
  }

  @Test("Deadlines are measured from the given start")
  func deadlinesAreRelativeToStart() throws {
    let cadence = try AudioRealtimeCadence(framesPerCycle: 128, sampleRate: 48_000)
    let start: UInt64 = 1_234_567

    #expect(cadence.deadline(cycleIndex: 0, start: start, timebase: Self.appleSilicon) == start)
    #expect(
      cadence.deadline(cycleIndex: 3, start: start, timebase: Self.appleSilicon)
        == start + 192_000
    )
  }

  @Test("A cadence rejects frame counts and sample rates it cannot schedule")
  func cadenceValidation() {
    #expect(throws: AudioRealtimeSchedulingError.invalidFrameCount(0)) {
      _ = try AudioRealtimeCadence(framesPerCycle: 0, sampleRate: 48_000)
    }
    #expect(throws: AudioRealtimeSchedulingError.invalidFrameCount(65_537)) {
      _ = try AudioRealtimeCadence(framesPerCycle: 65_537, sampleRate: 48_000)
    }
    #expect(throws: AudioRealtimeSchedulingError.invalidSampleRate(0)) {
      _ = try AudioRealtimeCadence(framesPerCycle: 128, sampleRate: 0)
    }
    // A fractional rate cannot be scheduled without accumulating rounding.
    #expect(throws: AudioRealtimeSchedulingError.invalidSampleRate(48_000.5)) {
      _ = try AudioRealtimeCadence(framesPerCycle: 128, sampleRate: 48_000.5)
    }
  }

  @Test("Timebase conversion survives a tick count no uptime will reach")
  func timebaseConversionDoesNotOverflow() {
    let timebase = Self.appleSilicon
    let century: UInt64 = 24_000_000 * 60 * 60 * 24 * 365 * 100

    #expect(timebase.nanoseconds(ticks: 24_000_000) == 1_000_000_000)
    #expect(timebase.ticks(nanoseconds: 1_000_000_000) == 24_000_000)
    #expect(timebase.nanoseconds(ticks: century) == century * 125 / 3)
  }
}

@Suite("Audio realtime budget")
struct AudioRealtimeBudgetTests {
  @Test("A budget rejects a computation the kernel will not accept")
  func computationRange() {
    #expect(throws: AudioRealtimeSchedulingError.self) {
      _ = try AudioRealtimeBudget.matching(computation: .microseconds(49))
    }
    #expect(throws: AudioRealtimeSchedulingError.self) {
      _ = try AudioRealtimeBudget.matching(computation: .milliseconds(51))
    }
    #expect(throws: AudioRealtimeSchedulingError.self) {
      _ = try AudioRealtimeBudget(computation: .microseconds(300), constraint: .microseconds(200))
    }
  }

  @Test("The measured kernel bounds are the accepted range")
  func kernelBounds() throws {
    _ = try AudioRealtimeBudget.matching(computation: AudioRealtimeBudget.minimumComputation)
    _ = try AudioRealtimeBudget(
      computation: AudioRealtimeBudget.maximumComputation,
      constraint: AudioRealtimeBudget.maximumComputation
    )
    #expect(AudioRealtimeBudget.minimumComputation == .microseconds(50))
    #expect(AudioRealtimeBudget.maximumComputation == .milliseconds(50))
  }

  /// The kernel raises any computation below half the constraint, so a budget that does not
  /// pair them two to one is not the budget that ends up in effect.
  @Test(
    "The stored computation is raised to half the constraint",
    arguments: [
      (Duration.microseconds(300), Duration.microseconds(600), Duration.microseconds(300)),
      (Duration.microseconds(300), Duration.microseconds(2_667), Duration.nanoseconds(1_333_500)),
      (Duration.microseconds(2_400), Duration.microseconds(2_533), Duration.microseconds(2_400)),
      (Duration.milliseconds(1), Duration.milliseconds(2), Duration.milliseconds(1)),
    ]
  )
  func clampPrediction(
    computation: Duration,
    constraint: Duration,
    expected: Duration
  ) throws {
    let budget = try AudioRealtimeBudget(computation: computation, constraint: constraint)

    #expect(budget.effectiveComputation == expected)
    #expect(budget.isStoredVerbatim == (expected == computation))
  }

  @Test("A matched budget is stored verbatim and leaves its computation as slack")
  func matchedBudget() throws {
    let budget = try AudioRealtimeBudget.matching(computation: .microseconds(300))

    #expect(budget.constraint == .microseconds(600))
    #expect(budget.isStoredVerbatim)
    #expect(budget.effectiveComputation == .microseconds(300))
    #expect(budget.latency == .microseconds(300))
  }
}
