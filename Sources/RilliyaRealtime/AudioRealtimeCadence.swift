// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

/// A validation failure for realtime worker scheduling.
public enum AudioRealtimeSchedulingError: Error, Equatable, LocalizedError, Sendable {
  /// A cadence must render a positive, bounded number of frames per cycle.
  case invalidFrameCount(Int)

  /// A cadence must run at a whole number of frames per second.
  case invalidSampleRate(Double)

  /// The kernel rejects a computation budget outside its realtime quantum range.
  case computationOutOfRange(Duration)

  /// A deadline must leave room for the work it bounds.
  case constraintBelowComputation(computation: Duration, constraint: Duration)

  /// A localized explanation suitable for diagnostics.
  public var errorDescription: String? {
    switch self {
    case .invalidFrameCount(let frameCount):
      "A realtime cadence must render between 1 and \(AudioRealtimeCadence.maximumFrameCount) frames per cycle; received \(frameCount)."
    case .invalidSampleRate(let sampleRate):
      "A realtime cadence must run at a whole sample rate between 1 and 768,000 Hz; received \(sampleRate)."
    case .computationOutOfRange(let computation):
      "A realtime computation budget must be between 50 microseconds and 50 milliseconds; received \(computation)."
    case .constraintBelowComputation(let computation, let constraint):
      "A realtime deadline of \(constraint) cannot bound a computation budget of \(computation)."
    }
  }
}

/// The mach timebase, as a rational conversion between ticks and nanoseconds.
public struct AudioRealtimeTimebase: Equatable, Hashable, Sendable {
  /// The timebase reported by the running system.
  public static let system: AudioRealtimeTimebase = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return AudioRealtimeTimebase(numerator: UInt64(info.numer), denominator: UInt64(info.denom))
  }()

  /// Nanoseconds per tick, as the numerator of `numerator / denominator`.
  public let numerator: UInt64

  /// Nanoseconds per tick, as the denominator of `numerator / denominator`.
  public let denominator: UInt64

  public init(numerator: UInt64, denominator: UInt64) {
    precondition(numerator > 0 && denominator > 0)
    self.numerator = numerator
    self.denominator = denominator
  }

  /// Converts ticks to nanoseconds without the overflow a plain `ticks * numerator` reaches after
  /// a few years of uptime.
  public func nanoseconds(ticks: UInt64) -> UInt64 {
    let product = ticks.multipliedFullWidth(by: numerator)
    guard product.high < denominator else { return .max }
    return denominator.dividingFullWidth(product).quotient
  }

  /// Converts nanoseconds to ticks.
  public func ticks(nanoseconds: UInt64) -> UInt64 {
    let product = nanoseconds.multipliedFullWidth(by: denominator)
    guard product.high < numerator else { return .max }
    return numerator.dividingFullWidth(product).quotient
  }
}

/// How often a realtime worker runs, expressed the way audio code knows it.
public struct AudioRealtimeCadence: Equatable, Hashable, Sendable {
  /// The largest render quantum a cadence accepts, matching the realtime buffer bound.
  public static let maximumFrameCount = 65_536

  /// The frames one cycle produces.
  public let framesPerCycle: Int

  /// The whole sample rate the cycle runs at.
  public let sampleRate: UInt64

  /// Creates a validated cadence.
  ///
  /// The sample rate must be whole: a cadence derived from a fractional rate cannot be expressed
  /// exactly in ticks, and the rounding would accumulate across cycles.
  public init(framesPerCycle: Int, sampleRate: Double) throws {
    guard (1...Self.maximumFrameCount).contains(framesPerCycle) else {
      throw AudioRealtimeSchedulingError.invalidFrameCount(framesPerCycle)
    }
    guard sampleRate.isFinite,
      sampleRate >= 1,
      sampleRate <= 768_000,
      abs(sampleRate.rounded() - sampleRate) < 0.001
    else {
      throw AudioRealtimeSchedulingError.invalidSampleRate(sampleRate)
    }
    self.framesPerCycle = framesPerCycle
    self.sampleRate = UInt64(sampleRate.rounded())
  }

  /// The nominal cycle period.
  public var period: Duration {
    .nanoseconds(Int64(periodNanoseconds))
  }

  /// The nominal cycle period in nanoseconds, rounded once for display rather than for scheduling.
  public var periodNanoseconds: UInt64 {
    UInt64(framesPerCycle) * 1_000_000_000 / sampleRate
  }

  /// The period in ticks, exact only when the rate divides evenly.
  ///
  /// Scheduling uses ``deadline(cycleIndex:start:timebase:)`` instead: 128 frames at 44.1 kHz is
  /// 69,659.86 ticks, so accumulating a rounded period drifts about seven milliseconds an hour.
  public func periodTicks(timebase: AudioRealtimeTimebase = .system) -> UInt64 {
    deadline(cycleIndex: 1, start: 0, timebase: timebase)
  }

  /// The absolute deadline of one cycle, derived from its index so rounding never accumulates.
  public func deadline(
    cycleIndex: UInt64,
    start: UInt64,
    timebase: AudioRealtimeTimebase = .system
  ) -> UInt64 {
    // ticks = cycleIndex * framesPerCycle * 1e9 * denominator / (sampleRate * numerator)
    let scale = UInt64(framesPerCycle) * 1_000_000_000 * timebase.denominator
    let divisor = sampleRate * timebase.numerator
    let product = cycleIndex.multipliedFullWidth(by: scale)
    guard product.high < divisor else { return .max }
    return start &+ divisor.dividingFullWidth(product).quotient
  }
}

/// What a realtime worker promises the scheduler each cycle.
///
/// The kernel rewrites any computation below half the constraint, so a budget that pairs them
/// exactly two to one is the only one whose declared value is the value in effect.
public struct AudioRealtimeBudget: Equatable, Hashable, Sendable {
  /// The smallest computation the kernel accepts.
  public static let minimumComputation = Duration.microseconds(50)

  /// The largest computation the kernel accepts.
  public static let maximumComputation = Duration.milliseconds(50)

  /// The processing time the worker expects to need each cycle.
  public let computation: Duration

  /// The deadline that work must finish within.
  public let constraint: Duration

  /// Creates a validated budget.
  public init(computation: Duration, constraint: Duration) throws {
    guard computation >= Self.minimumComputation, computation <= Self.maximumComputation else {
      throw AudioRealtimeSchedulingError.computationOutOfRange(computation)
    }
    guard constraint >= computation else {
      throw AudioRealtimeSchedulingError.constraintBelowComputation(
        computation: computation,
        constraint: constraint
      )
    }
    self.computation = computation
    self.constraint = constraint
  }

  /// A budget the kernel stores verbatim, reserving only the time the work actually needs.
  public static func matching(computation: Duration) throws -> AudioRealtimeBudget {
    try AudioRealtimeBudget(computation: computation, constraint: computation * 2)
  }

  /// The computation the kernel stores, which is raised to half the constraint when the declared
  /// value sits below it.
  public var effectiveComputation: Duration {
    max(computation, constraint / 2)
  }

  /// Whether the kernel keeps the declared computation rather than raising it.
  public var isStoredVerbatim: Bool {
    effectiveComputation == computation
  }

  /// The scheduling slack between finishing the work and reaching the deadline.
  public var latency: Duration {
    constraint - computation
  }
}

extension Duration {
  /// The duration in whole nanoseconds, saturating rather than trapping.
  package var wholeNanoseconds: UInt64 {
    let (seconds, attoseconds) = components
    guard seconds >= 0, attoseconds >= 0 else { return 0 }
    let fromSeconds = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
    guard !fromSeconds.overflow else { return .max }
    let sum = fromSeconds.partialValue.addingReportingOverflow(
      UInt64(attoseconds / 1_000_000_000)
    )
    return sum.overflow ? .max : sum.partialValue
  }
}
