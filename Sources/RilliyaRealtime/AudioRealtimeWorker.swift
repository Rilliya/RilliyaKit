// SPDX-License-Identifier: Apache-2.0

import Atomics
import Darwin
import Foundation
import RilliyaAudioWorkgroup

/// One scheduled cycle handed to a realtime worker body.
public struct AudioRealtimeCycle: Equatable, Hashable, Sendable {
  /// The cycle's index since the worker started.
  public let index: UInt64

  /// When the cycle was scheduled to begin, in `mach_absolute_time` units.
  ///
  /// Comparing this to the current time measures how late the scheduler woke the worker.
  public let scheduledWakeUp: UInt64

  /// The cycle's deadline, in `mach_absolute_time` units.
  public let deadline: UInt64

  /// Cycles skipped because the previous body ran past its deadline.
  public let missedCycles: Int

  /// Describes one cycle the worker is about to run.
  public init(index: UInt64, scheduledWakeUp: UInt64, deadline: UInt64, missedCycles: Int) {
    self.index = index
    self.scheduledWakeUp = scheduledWakeUp
    self.deadline = deadline
    self.missedCycles = missedCycles
  }
}

/// Whether a realtime worker runs another cycle.
public enum AudioRealtimeCycleOutcome: Sendable {
  case `continue`
  case stop
}

/// A failure while placing a thread on the realtime scheduler.
public enum AudioRealtimeWorkerError: Error, Equatable, LocalizedError, Sendable {
  /// A started worker cannot be started again.
  case alreadyRunning

  /// The thread could not be created.
  case threadCreationFailed(code: Int32)

  /// The kernel rejected the realtime scheduling policy.
  case schedulingPolicyRejected(code: Int32)

  /// The audio work interval could not be created.
  case workgroupCreationFailed

  /// The thread could not join the audio work interval.
  case workgroupJoinFailed(code: Int32)

  /// A localized explanation suitable for diagnostics.
  public var errorDescription: String? {
    switch self {
    case .alreadyRunning:
      "The realtime worker is already running."
    case .threadCreationFailed(let code):
      "The realtime worker thread could not be created: POSIX error \(code)."
    case .schedulingPolicyRejected(let code):
      "The kernel rejected the realtime scheduling policy: Mach error \(code)."
    case .workgroupCreationFailed:
      "The audio work interval could not be created."
    case .workgroupJoinFailed(let code):
      "The realtime worker could not join its audio work interval: POSIX error \(code)."
    }
  }
}

/// What the scheduler currently thinks of a worker thread.
///
/// A thread that overruns without blocking for about a second is demoted below an ordinary
/// thread until it behaves again. `thread_policy_get` keeps reporting the requested policy
/// throughout, so this reads the thread's live priority instead.
public struct AudioRealtimeThreadDiagnostics: Equatable, Hashable, Sendable {
  /// The scheduler policy in effect, where 2 is realtime.
  public let policy: Int32

  /// The thread's current priority.
  public let currentPriority: Int32

  /// Whether the thread is scheduled with realtime priority right now.
  public var isRealtime: Bool {
    policy == POLICY_RR && currentPriority >= 90
  }
}

/// Runs a body on a fixed audio cadence, on a thread the kernel schedules against a deadline.
///
/// A software clock on an ordinary thread wakes hundreds of microseconds late, which is a large
/// fraction of a short audio cycle. This places the thread on the realtime scheduler and joins it
/// to an audio work interval, which together bring the wake-up error down to a few microseconds.
///
/// The body runs where allocation, locks, and dynamic dispatch are unsafe. Keep it to preallocated
/// storage and concrete types.
public final class AudioRealtimeWorker: @unchecked Sendable {
  /// The body invoked once per cycle.
  public typealias Body = @Sendable (AudioRealtimeCycle) -> AudioRealtimeCycleOutcome

  /// The cadence the worker runs at.
  public let cadence: AudioRealtimeCadence

  /// The budget the worker declares to the scheduler.
  public let budget: AudioRealtimeBudget

  private let label: String
  private let joinsAudioWorkgroup: Bool
  private let body: Body
  private let timebase: AudioRealtimeTimebase
  private let shouldStop = ManagedAtomic<Bool>(false)
  private let machThread = ManagedAtomic<UInt32>(0)
  private let lock = NSLock()
  private var thread: pthread_t?
  /// Guards the startup handoff on its own rather than sharing ``lock``.
  ///
  /// `start()` waits for the new thread while holding ``lock``, so a thread that needed ``lock``
  /// to report why it could not start could never report it, and both sides would wait for ever.
  /// Serialises teardown, so a second `stop()` waits for the first rather than returning early.
  private let stopLock = NSLock()
  private let startupLock = NSLock()
  private var startupError: AudioRealtimeWorkerError?
  private let startupSemaphore = DispatchSemaphore(value: 0)

  /// Prepares a worker without creating its thread.
  public init(
    label: String,
    cadence: AudioRealtimeCadence,
    budget: AudioRealtimeBudget,
    joinsAudioWorkgroup: Bool = true,
    timebase: AudioRealtimeTimebase = .system,
    body: @escaping Body
  ) {
    self.label = label
    self.cadence = cadence
    self.budget = budget
    self.joinsAudioWorkgroup = joinsAudioWorkgroup
    self.timebase = timebase
    self.body = body
  }

  deinit {
    stop()
  }

  /// Whether the worker thread is running.
  public var isRunning: Bool {
    lock.withLock { thread != nil }
  }

  /// Creates the thread and returns once it has taken the realtime policy, or throws what stopped
  /// it from doing so.
  public func start() throws {
    lock.lock()
    defer { lock.unlock() }
    guard thread == nil else { throw AudioRealtimeWorkerError.alreadyRunning }
    shouldStop.store(false, ordering: .relaxed)
    startupLock.withLock { startupError = nil }

    let context = Unmanaged.passRetained(self).toOpaque()
    let spawned = spawnAudioRealtimeThread(context: context)
    guard spawned.code == 0, let created = spawned.thread else {
      Unmanaged<AudioRealtimeWorker>.fromOpaque(context).release()
      throw AudioRealtimeWorkerError.threadCreationFailed(code: spawned.code)
    }

    startupSemaphore.wait()
    if let error = startupLock.withLock({ startupError }) {
      pthread_join(created, nil)
      throw error
    }
    thread = created
  }

  /// Stops the worker and waits for its thread to finish.
  ///
  /// Does nothing when the worker is not running, so a repeated call is safe. A second caller
  /// arriving while the first is still waiting waits with it: returning early would report a
  /// stopped worker whose body is still running, and the body's storage is torn down on that word.
  public func stop() {
    stopLock.lock()
    defer { stopLock.unlock() }
    let running = lock.withLock { () -> pthread_t? in
      let running = thread
      thread = nil
      return running
    }
    guard let running else { return }
    shouldStop.store(true, ordering: .relaxed)
    pthread_join(running, nil)
  }

  /// Reads the scheduler's live view of the worker thread, or `nil` when it is not running.
  public func schedulingDiagnostics() -> AudioRealtimeThreadDiagnostics? {
    let port = machThread.load(ordering: .relaxed)
    guard port != 0 else { return nil }
    var info = thread_extended_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        thread_info(port, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return AudioRealtimeThreadDiagnostics(
      policy: info.pth_policy,
      currentPriority: info.pth_curpri
    )
  }

  fileprivate func run() {
    machThread.store(pthread_mach_thread_np(pthread_self()), ordering: .relaxed)
    if let error = applySchedulingPolicy() {
      startupLock.withLock { startupError = error }
      startupSemaphore.signal()
      return
    }

    var workgroup: OpaquePointer?
    if joinsAudioWorkgroup {
      switch joinWorkgroup() {
      case .success(let joined):
        workgroup = joined
      case .failure(let error):
        startupLock.withLock { startupError = error }
        startupSemaphore.signal()
        return
      }
    }
    // A thread that exits while still joined trips a libdispatch cleanup handler that aborts the
    // process, so leaving has to happen on every path out of this function.
    defer {
      if let workgroup {
        rilliya_audio_workgroup_leave(workgroup)
        rilliya_audio_workgroup_destroy(workgroup)
      }
      machThread.store(0, ordering: .relaxed)
    }

    startupSemaphore.signal()
    loop(workgroup: workgroup)
  }

  private func applySchedulingPolicy() -> AudioRealtimeWorkerError? {
    var policy = thread_time_constraint_policy_data_t(
      period: UInt32(truncatingIfNeeded: cadence.periodTicks(timebase: timebase)),
      computation: UInt32(
        truncatingIfNeeded: timebase.ticks(nanoseconds: budget.computation.wholeNanoseconds)
      ),
      constraint: UInt32(
        truncatingIfNeeded: timebase.ticks(nanoseconds: budget.constraint.wholeNanoseconds)
      ),
      preemptible: 0
    )
    let count = mach_msg_type_number_t(
      MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &policy) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        thread_policy_set(
          pthread_mach_thread_np(pthread_self()),
          thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY),
          $0,
          count
        )
      }
    }
    guard result == KERN_SUCCESS else {
      return .schedulingPolicyRejected(code: result)
    }
    return nil
  }

  private func joinWorkgroup() -> Result<OpaquePointer, AudioRealtimeWorkerError> {
    guard let workgroup = label.withCString({ rilliya_audio_workgroup_create($0) }) else {
      return .failure(.workgroupCreationFailed)
    }
    let code = rilliya_audio_workgroup_join(workgroup)
    guard code == 0 else {
      rilliya_audio_workgroup_destroy(workgroup)
      return .failure(.workgroupJoinFailed(code: code))
    }
    return .success(workgroup)
  }

  private func loop(workgroup: OpaquePointer?) {
    let epoch = mach_absolute_time()
    var index: UInt64 = 0
    var missedCycles = 0

    while !shouldStop.load(ordering: .relaxed) {
      let scheduledWakeUp = cadence.deadline(cycleIndex: index, start: epoch, timebase: timebase)
      let deadline = cadence.deadline(cycleIndex: index + 1, start: epoch, timebase: timebase)
      if let workgroup {
        _ = rilliya_audio_workgroup_interval_start(workgroup, mach_absolute_time(), deadline)
      }
      let outcome = body(
        AudioRealtimeCycle(
          index: index,
          scheduledWakeUp: scheduledWakeUp,
          deadline: deadline,
          missedCycles: missedCycles
        )
      )
      if let workgroup {
        _ = rilliya_audio_workgroup_interval_finish(workgroup)
      }
      guard outcome == .continue else { break }

      index &+= 1
      missedCycles = 0
      var wakeUp = cadence.deadline(cycleIndex: index, start: epoch, timebase: timebase)
      let now = mach_absolute_time()
      while wakeUp <= now {
        index &+= 1
        missedCycles += 1
        wakeUp = cadence.deadline(cycleIndex: index, start: epoch, timebase: timebase)
      }
      if shouldStop.load(ordering: .relaxed) { break }
      guard mach_wait_until(wakeUp) == KERN_SUCCESS else { break }
    }
  }
}

/// Creates the user-interactive thread the worker runs on.
private func spawnAudioRealtimeThread(
  context: UnsafeMutableRawPointer
) -> (code: Int32, thread: pthread_t?) {
  var attributes = pthread_attr_t()
  pthread_attr_init(&attributes)
  defer { pthread_attr_destroy(&attributes) }
  pthread_attr_set_qos_class_np(&attributes, QOS_CLASS_USER_INTERACTIVE, 0)
  var created: pthread_t?
  let code = pthread_create(&created, &attributes, audioRealtimeWorkerMain, context)
  return (code, created)
}

private func audioRealtimeWorkerMain(
  _ context: UnsafeMutableRawPointer
) -> UnsafeMutableRawPointer? {
  let worker = Unmanaged<AudioRealtimeWorker>.fromOpaque(context)
  worker.takeUnretainedValue().run()
  worker.release()
  return nil
}
