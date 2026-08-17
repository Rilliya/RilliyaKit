// SPDX-License-Identifier: Apache-2.0

import Atomics
import Darwin
import Foundation
import Testing

@testable import RilliyaRealtime

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

  /// A thread that exits while still joined to a workgroup aborts the process, so a worker
  /// released without an explicit stop has to leave on its own. Reaching the end of this test at
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
}
