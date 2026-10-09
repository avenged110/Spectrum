// MARK: - PipelineThrottle.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The CPU budget a pipeline run works under. Foreground runs get the full machine; a background
// prefetch run (see AnalysisJob) starts with half of it and can be paused outright, so a run the
// user is watching never competes with speculative work. The budget is mutable and shared by the
// decoder's worker threads and the pipeline actor, which lets a background run be promoted to
// full speed in place when the user selects the channel it is computing.

import Foundation

/// A mutable CPU budget shared between one pipeline run's decoder threads and FFT batches.
///
/// All state lives behind one `NSCondition` so that both plain `Thread`s (the decoder's
/// segment workers, which block inside libavcodec and cannot `await`) and the pipeline actor
/// can wait on it. Waiters are woken whenever the budget changes.
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
final class PipelineThrottle: @unchecked Sendable {

    /// A budget with no limits — what a foreground run uses.
    static let unlimited = PipelineThrottle(fftConcurrencyCap: .max, decodeWorkerCap: .max,
                                            threadQoS: .userInitiated)

    /// The budget for a speculative prefetch: about half the machine, below the QoS of anything
    /// the user is waiting on. On a 10-core machine that is 5 FFT columns per batch and 4
    /// decoder threads; the foreground's own runs keep `cores − 1` decoders.
    static func background() -> PipelineThrottle {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return PipelineThrottle(fftConcurrencyCap: max(1, cores / 2),
                                decodeWorkerCap:   max(1, (cores - 1) / 2),
                                threadQoS:         .utility)
    }

    private let condition = NSCondition()
    private var _fftConcurrencyCap: Int
    private var _decodeWorkerCap:   Int
    private var _isPaused = false
    private var _threadQoS: QualityOfService
    private var activeDecodeWorkers = 0

    init(fftConcurrencyCap: Int, decodeWorkerCap: Int, threadQoS: QualityOfService) {
        _fftConcurrencyCap = fftConcurrencyCap
        _decodeWorkerCap   = decodeWorkerCap
        _threadQoS         = threadQoS
    }

    // MARK: - Reading the budget

    var isPaused: Bool {
        condition.lock(); defer { condition.unlock() }
        return _isPaused
    }

    /// The QoS for the run's decoder threads: `.userInitiated` for a run the user is waiting
    /// on, `.utility` for a prefetch.
    var threadQoS: QualityOfService {
        condition.lock(); defer { condition.unlock() }
        return _threadQoS
    }

    /// Whether this run is the one the user is waiting on.
    var isForeground: Bool { threadQoS == .userInitiated }

    /// The priority for the pipeline's FFT child tasks, matching `threadQoS`.
    var taskPriority: TaskPriority { isForeground ? .userInitiated : .utility }

    var decodeWorkerCap: Int {
        condition.lock(); defer { condition.unlock() }
        return _decodeWorkerCap
    }

    /// `preferred` (the pipeline's own choice) clamped to the current cap.
    func fftConcurrency(preferred: Int) -> Int {
        condition.lock(); defer { condition.unlock() }
        return max(1, min(preferred, _fftConcurrencyCap))
    }

    // MARK: - Changing the budget

    func pause() {
        condition.lock(); _isPaused = true; condition.broadcast(); condition.unlock()
    }

    func resume() {
        condition.lock(); _isPaused = false; condition.broadcast(); condition.unlock()
    }

    /// Lift every cap, raise the QoS and unpause: the run is now the one the user is waiting
    /// on. The decoder threads waiting for a slot start at once, every thread raises its own
    /// QoS at its next chunk, and FFT batches widen and re-prioritize from the next batch on.
    func promote() {
        condition.lock()
        _fftConcurrencyCap = .max
        _decodeWorkerCap   = .max
        _threadQoS         = .userInitiated
        _isPaused          = false
        condition.broadcast()
        condition.unlock()
    }

    // MARK: - Waiting (decoder threads)

    /// Block the calling thread while paused. Called between chunk reads, so a pause takes
    /// effect within one chunk (≈ 65k frames) per worker.
    func blockWhilePaused() {
        condition.lock()
        while _isPaused { condition.wait() }
        condition.unlock()
    }

    /// Block until a decoder slot is free and the run is not paused, then take the slot.
    func acquireDecodeSlot() {
        condition.lock()
        while _isPaused || activeDecodeWorkers >= _decodeWorkerCap { condition.wait() }
        activeDecodeWorkers += 1
        condition.unlock()
    }

    func releaseDecodeSlot() {
        condition.lock()
        activeDecodeWorkers -= 1
        condition.broadcast()
        condition.unlock()
    }

    // MARK: - Waiting (pipeline actor)

    /// Suspend (without blocking a cooperative-pool thread) while paused. Polled rather than
    /// condition-waited because the caller is an actor; 50 ms is far below anything visible.
    func waitWhilePaused() async {
        while isPaused && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
