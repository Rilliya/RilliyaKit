import Atomics
import Darwin
import Foundation
import Testing
import os.lock

@testable import RilliyaRealtime

// SPDX-License-Identifier: Apache-2.0

@Suite("Audio realtime worker")
struct AudioRealtimeWorkerTests {
  private enum Fixture {
    static let framesPerCycle = 128
    static let sampleRate = 48_000.0
    static let computation = Duration.microseconds(300)
    static let settleTimeout = Duration.seconds(2)

    static func cadence() throws -> AudioRealtimeCadence {
      try AudioRealtimeCadence(framesPerCycle: framesPerCycle, sampleRate: sampleRate)
    }

    static func budget() throws -> AudioRealtimeBudget {
      try AudioRealtimeBudget.matching(computation: computation)
    }
  }

  /// The one non-flaky assertion that the policy took effect: the scheduler reports the thread as
  /// realtime. `thread_policy_get` keeps reporting the requested policy even after a demotion, so
  /// this reads the live priority instead.
  @Test("A started worker runs on the realtime scheduler")
  func workerTakesRealtimePriority() throws {
    let counter = ManagedAtomic<Int>(0)
    let worker = AudioRealtimeWorker(
      label: "moe.uwucocoa.rilliya.test.realtime",
      cadence: try Fixture.cadence(),
      budget: try Fixture.budget()
    ) { _ in
      counter.wrappingIncrement(ordering: .relaxed)
      return .continue
    }
    try worker.start()
    defer { worker.stop() }

    let diagnostics = try #require(worker.schedulingDiagnostics())
    #expect(diagnostics.isRealtime)
    #expect(worker.isRunning)
  }

  @Test("A worker without a workgroup still takes the realtime policy")
  func workerWithoutWorkgroup() throws {
    let worker = AudioRealtimeWorker(
      label: "moe.uwucocoa.rilliya.test.no-workgroup",
      cadence: try Fixture.cadence(),
      budget: try Fixture.budget(),
      joinsAudioWorkgroup: false
    ) { _ in .continue }
    try worker.start()
    defer { worker.stop() }

    #expect(try #require(worker.schedulingDiagnostics()).isRealtime)
  }

  @Test("Cycles arrive in order with an index that never repeats")
  func cyclesAreOrdered() throws {
    let ordered = ManagedAtomic<Bool>(true)
    let lastIndex = ManagedAtomic<UInt64>(0)
    let observed = ManagedAtomic<Int>(0)
    let worker = AudioRealtimeWorker(
      label: "moe.uwucocoa.rilliya.test.order",
      cadence: try Fixture.cadence(),
      budget: try Fixture.budget()
    ) { cycle in
      let previous = lastIndex.exchange(cycle.index, ordering: .relaxed)
      if observed.loadThenWrappingIncrement(ordering: .relaxed) > 0, cycle.index <= previous {
        ordered.store(false, ordering: .relaxed)
      }
      return .continue
    }

    try worker.start()
    Thread.sleep(forTimeInterval: 0.25)
    worker.stop()

    let stayedOrdered = ordered.load(ordering: .relaxed)
    let cycleCount = observed.load(ordering: .relaxed)
    #expect(stayedOrdered)
    #expect(cycleCount > 0)
  }

  /// Cycle count is far more stable across machines than a jitter percentile, so the timing
  /// assertion is on delivery rather than on wake-up error.
  @Test("A worker delivers close to the nominal cycle count", .timeLimit(.minutes(1)))
  func workerRunsOnCadence() throws {
    let observed = ManagedAtomic<Int>(0)
    let missed = ManagedAtomic<Int>(0)
    let cadence = try Fixture.cadence()
    let worker = AudioRealtimeWorker(
      label: "moe.uwucocoa.rilliya.test.cadence",
      cadence: cadence,
      budget: try Fixture.budget()
    ) { cycle in
      observed.wrappingIncrement(ordering: .relaxed)
      if cycle.missedCycles > 0 {
        missed.wrappingIncrement(by: cycle.missedCycles, ordering: .relaxed)
      }
      return .continue
    }

    let seconds = 1.0
    try worker.start()
    Thread.sleep(forTimeInterval: seconds)
    worker.stop()

    let expected = seconds / (Double(cadence.periodNanoseconds) / 1_000_000_000)
    let delivered = Double(observed.load(ordering: .relaxed))
    let missedCycles = missed.load(ordering: .relaxed)
    #expect(delivered > expected * 0.9)
    #expect(delivered < expected * 1.1)
    #expect(missedCycles == 0)
  }

  @Test("A body that reports stop ends the worker")
  func bodyCanStop() throws {
    let finished = DispatchSemaphore(value: 0)
    let worker = AudioRealtimeWorker(
      label: "moe.uwucocoa.rilliya.test.body-stop",
      cadence: try Fixture.cadence(),
      budget: try Fixture.budget()
    ) { _ in
      finished.signal()
      return .stop
    }

    try worker.start()
    #expect(finished.wait(timeout: .now() + 2) == .success)
    worker.stop()
    #expect(!worker.isRunning)
  }

  @Test("Starting a running worker reports that it is already running")
  func doubleStart() throws {
    let worker = AudioRealtimeWorker(
      label: "moe.uwucocoa.rilliya.test.double-start",
      cadence: try Fixture.cadence(),
      budget: try Fixture.budget()
    ) { _ in .continue }
    try worker.start()
    defer { worker.stop() }

    #expect(throws: AudioRealtimeWorkerError.alreadyRunning) {
      try worker.start()
    }
  }

  @Test("Stopping is idempotent and a stopped worker can start again")
  func stopIsIdempotent() throws {
    let worker = AudioRealtimeWorker(
      label: "moe.uwucocoa.rilliya.test.restart",
      cadence: try Fixture.cadence(),
      budget: try Fixture.budget()
    ) { _ in .continue }

    try worker.start()
    worker.stop()
    worker.stop()
    #expect(!worker.isRunning)

    try worker.start()
    #expect(worker.isRunning)
    worker.stop()
  }

  /// A released worker has to leave its workgroup on its own.
  ///
  /// A thread that exits while still joined to a workgroup aborts the process, so relying on an
  /// explicit stop would turn a forgotten call into a crash. Reaching the end of this test at
  /// all is the assertion.
  @Test("Releasing a running worker leaves its workgroup instead of aborting")
  func deinitLeavesTheWorkgroup() throws {
    for _ in 0..<8 {
      let worker = AudioRealtimeWorker(
        label: "moe.uwucocoa.rilliya.test.deinit",
        cadence: try Fixture.cadence(),
        budget: try Fixture.budget()
      ) { _ in .continue }
      try worker.start()
      Thread.sleep(forTimeInterval: 0.01)
    }

    #expect(Bool(true))
  }

  @Test("Diagnostics report nothing before a start and after a stop")
  func diagnosticsFollowLifecycle() throws {
    let worker = AudioRealtimeWorker(
      label: "moe.uwucocoa.rilliya.test.diagnostics",
      cadence: try Fixture.cadence(),
      budget: try Fixture.budget()
    ) { _ in .continue }

    #expect(worker.schedulingDiagnostics() == nil)
    try worker.start()
    #expect(worker.schedulingDiagnostics() != nil)
    worker.stop()
    #expect(worker.schedulingDiagnostics() == nil)
  }

  /// A worker whose thread cannot take the realtime policy has to say so.
  ///
  /// It deadlocked instead: `start()` waited for the new thread while holding the lock that
  /// thread needed in order to record what had stopped it, so neither side could move and the
  /// caller never returned. Nothing above it could recover, because a caller holding its own lock
  /// across `start()` wedged that lock too.
  ///
  /// The call is made on a thread of its own with a bounded wait, so a return of the deadlock
  /// fails this test instead of hanging the suite.
  @Test("A worker that cannot take the realtime policy says so instead of hanging")
  func startupFailureIsReportedRatherThanHung() throws {
    // Ticks this far from the system's turn an ordinary budget into a computation no kernel
    // accepts, which is the rejection a caller has to hear about.
    let hostile = AudioRealtimeTimebase(numerator: 1, denominator: 7_158)
    let worker = AudioRealtimeWorker(
      label: "moe.uwucocoa.rilliya.test.hostile-timebase",
      cadence: try Fixture.cadence(),
      budget: try Fixture.budget(),
      joinsAudioWorkgroup: false,
      timebase: hostile
    ) { _ in .continue }

    let outcome = StartOutcome()
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      outcome.record { try worker.start() }
      finished.signal()
    }

    let returned = finished.wait(timeout: .now() + 5)
    #expect(returned == .success, "start() never returned, which is the deadlock")
    guard returned == .success else { return }

    #expect(outcome.thrown is AudioRealtimeWorkerError)
    #expect(!worker.isRunning)
    worker.stop()
  }

  /// Two callers stopping at once must both wait for the thread.
  ///
  /// The one that lost the race returned immediately, reporting a stopped worker whose body was
  /// still running — and the body's storage is torn down on that word, so the caller that freed it
  /// could free it underneath the thread still reading it.
  ///
  /// The body is made slow to leave, because the window is otherwise too narrow to observe: what
  /// is measured is that both calls take as long as the thread takes to finish, not merely that
  /// they both return.
  @Test("A second stop waits for the thread rather than returning early")
  func concurrentStopWaitsForTheThread() throws {
    let leaving = Duration.milliseconds(400)
    let worker = AudioRealtimeWorker(
      label: "moe.uwucocoa.rilliya.test.concurrent-stop",
      cadence: try Fixture.cadence(),
      budget: try Fixture.budget(),
      joinsAudioWorkgroup: false
    ) { _ in
      // Slow enough that a caller returning without joining is plainly visible.
      Thread.sleep(forTimeInterval: 0.4)
      return .continue
    }

    try worker.start()
    Thread.sleep(forTimeInterval: 0.05)

    let elapsed = OSAllocatedUnfairLock<[Duration]>(initialState: [])
    let finished = DispatchSemaphore(value: 0)
    let clock = ContinuousClock()
    for _ in 0..<2 {
      Thread.detachNewThread {
        let started = clock.now
        worker.stop()
        let took = clock.now - started
        elapsed.withLock { $0.append(took) }
        finished.signal()
      }
    }

    #expect(finished.wait(timeout: .now() + 10) == .success, "the first stop never returned")
    #expect(finished.wait(timeout: .now() + 10) == .success, "the second stop never returned")

    let times = elapsed.withLock { $0 }
    #expect(times.count == 2)
    // Both waited for the body to leave; the loser of the race did not slip out early.
    for took in times {
      #expect(
        took > leaving / 2,
        "a stop returned after \(took), before the thread could have finished"
      )
    }
    #expect(!worker.isRunning)
  }

  /// Carries what `start()` did off the thread it was called on.
  private final class StartOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func record(_ body: () throws -> Void) {
      do {
        try body()
      } catch {
        lock.withLock { self.error = error }
      }
    }

    var thrown: Error? { lock.withLock { error } }
  }
}
