// MARK: - PipelineThrottle.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The CPU budget a pipeline run works under. Foreground runs get the full machine; a background
// prefetch run (see AnalysisJob) starts with half of it and can be paused outright, so a run the
// user is watching never competes with speculative work. The budget is mutable and shared by the
// decoder's worker threads and the pipeline actor, which lets a background run be promoted to
// full speed in place when the user selects the channel it is computing.

import Foundation
import Synchronization

/// A mutable CPU budget shared between one pipeline run's decoder threads and FFT batches.
///
/// The state lives in a `Mutex`, and an `NSCondition` lets plain `Thread`s (the decoder's
/// segment workers, which block inside libavcodec and cannot `await`) sleep until it changes.
/// Every change is made while holding the condition's lock and followed by a broadcast, and
/// every waiter re-reads the state under that same lock before sleeping, so no wake-up is lost.
/// Both members are `Sendable`, so the class is checked `Sendable` by the compiler — no
/// `@unchecked` opt-out.
///
/// - `fftConcurrencyCap`: the most columns computed concurrently per FFT batch.
/// - `decodeWorkerCap`: how many segment-decoder threads may run at once. The decoder always
///   spawns its full plan of workers; the surplus ones wait for a slot, so raising the cap later
///   (promotion) puts them to work immediately instead of being stuck with the count chosen at
///   open time.
/// - `isPaused`: while set, workers finish the chunk they are on and block, and the pipeline
///   stops dispatching batches. Decoded audio already buffered stays put, so resuming picks up
///   exactly where it left off.
/// - `threadQoS` / `taskPriority`: the QoS the decoder threads run at and the priority of the
///   pipeline's FFT child tasks. Threads re-apply the QoS between chunks and each FFT batch
///   reads the priority afresh, so promotion also moves the work off the efficiency cores that
///   `.utility` work is steered to on Apple silicon.
final class PipelineThrottle: Sendable {

    /// A budget with no limits — what a foreground run uses. A fresh instance per run, not a
    /// shared one: the budget is mutable state (the pause flag, the decode-slot count), and
    /// a canceled run's threads can still be releasing slots while its successor acquires.
    static var unlimited: PipelineThrottle {
        PipelineThrottle(fftConcurrencyCap: .max, decodeWorkerCap: .max, threadQoS: .userInitiated)
    }

    /// The budget for a speculative prefetch: about half the machine, below the QoS of anything
    /// the user is waiting on. On a 10-core machine that is 5 FFT columns per batch and 4
    /// decoder threads; the foreground's own runs keep `cores − 1` decoders.
    static func background() -> PipelineThrottle {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return PipelineThrottle(fftConcurrencyCap: max(1, cores / 2),
                                decodeWorkerCap:   max(1, (cores - 1) / 2),
                                threadQoS:         .utility)
    }

    private struct State {
        var fftConcurrencyCap: Int
        var decodeWorkerCap:   Int
        var isPaused = false
        var threadQoS: QualityOfService
        var activeDecodeWorkers = 0
    }

    private let state: Mutex<State>
    /// Sleeping and waking only; the state itself is in `state`.
    private let condition = NSCondition()

    init(fftConcurrencyCap: Int, decodeWorkerCap: Int, threadQoS: QualityOfService) {
        state = Mutex(State(fftConcurrencyCap: fftConcurrencyCap,
                            decodeWorkerCap: decodeWorkerCap, threadQoS: threadQoS))
    }

    /// Apply `change` and wake every waiter. Holding the condition's lock across the change
    /// is what keeps a waiter from checking the old state, missing the broadcast, and sleeping.
    private func update(_ change: (inout State) -> Void) {
        condition.lock()
        state.withLock { change(&$0) }
        condition.broadcast()
        condition.unlock()
    }

    // MARK: - Reading the budget

    var isPaused: Bool { state.withLock { $0.isPaused } }

    /// The QoS for the run's decoder threads: `.userInitiated` for a run the user is waiting
    /// on, `.utility` for a prefetch.
    var threadQoS: QualityOfService { state.withLock { $0.threadQoS } }

    /// Whether this run is the one the user is waiting on.
    var isForeground: Bool { threadQoS == .userInitiated }

    /// The priority for the pipeline's FFT child tasks, matching `threadQoS`.
    var taskPriority: TaskPriority { isForeground ? .userInitiated : .utility }

    var decodeWorkerCap: Int { state.withLock { $0.decodeWorkerCap } }

    /// `preferred` (the pipeline's own choice) clamped to the current cap.
    func fftConcurrency(preferred: Int) -> Int {
        state.withLock { max(1, min(preferred, $0.fftConcurrencyCap)) }
    }

    // MARK: - Changing the budget

    func pause()  { update { $0.isPaused = true } }

    func resume() { update { $0.isPaused = false } }

    /// Lift every cap, raise the QoS and unpause: the run is now the one the user is waiting
    /// on. The decoder threads waiting for a slot start at once, every thread raises its own
    /// QoS at its next chunk, and FFT batches widen and re-prioritize from the next batch on.
    func promote() {
        update {
            $0.fftConcurrencyCap = .max
            $0.decodeWorkerCap   = .max
            $0.threadQoS         = .userInitiated
            $0.isPaused          = false
        }
    }

    // MARK: - Waiting (decoder threads)

    /// Block the calling thread while paused. Called between chunk reads, so a pause takes
    /// effect within one chunk (≈ 65k frames) per worker.
    func blockWhilePaused() {
        condition.lock()
        while state.withLock({ $0.isPaused }) { condition.wait() }
        condition.unlock()
    }

    /// Block until a decoder slot is free and the run is not paused, then take the slot.
    func acquireDecodeSlot() {
        condition.lock()
        while !state.withLock({ s in
            guard !s.isPaused, s.activeDecodeWorkers < s.decodeWorkerCap else { return false }
            s.activeDecodeWorkers += 1
            return true
        }) {
            condition.wait()
        }
        condition.unlock()
    }

    func releaseDecodeSlot() { update { $0.activeDecodeWorkers -= 1 } }

    // MARK: - Waiting (pipeline actor)

    /// Suspend (without blocking a cooperative-pool thread) while paused. Polled rather than
    /// condition-waited because the caller is an actor; 50 ms is far below anything visible.
    func waitWhilePaused() async {
        while isPaused && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
