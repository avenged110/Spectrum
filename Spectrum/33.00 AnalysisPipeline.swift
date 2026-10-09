// MARK: - AnalysisPipeline.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Orchestrates the full audio analysis pipeline: streaming decode, multi-window FFT averaging, and
// column emission. Columns are computed concurrently on a TaskGroup, one child task per logical
// core. Emits PipelineEvent values (metadata, progress, companion, complete, error) consumed by
// the ViewModel. A run can compute further channels of the same stream alongside the one it
// displays, from the same decode pass (see `analyze`'s `companionChannels`).

import Accelerate
import Foundation

/// A single column of computed dB magnitude data emitted by the pipeline.
struct PipelineColumn: Sendable {
    let index:      Int
    let magnitudes: [Float]
}

/// Events emitted by the analysis pipeline as processing progresses.
enum PipelineEvent: Sendable {
    /// Audio metadata has been extracted; emitted before any decoding starts.
    /// May be emitted again later with corrected values — after the first
    /// decoded frame resolves the true sample rate or duration, and after the
    /// columns of a file whose header misstates its length have been
    /// recomputed over the samples that actually exist. The latest one always describes the columns.
    case metadata(AudioMetadata)
    /// The pipeline is decoding audio before it can begin rendering columns.
    /// Emitted when the streaming decode has not yet produced enough samples
    /// to compute even the first FFT column after ~300 ms.
    case decoding
    /// A batch of columns has been computed. Carries the column data so the
    /// ViewModel's display-link renderer can paint them at its own 60 fps
    /// cadence, independent of the pipeline's batch rate.
    /// `fraction` is the overall completion fraction [0, 1].
    case progress(fraction: Double, columns: [PipelineColumn])
    /// All columns are complete. `magnitudes` carries the full per-column dB
    /// magnitude arrays so the ViewModel can cache them for palette and
    /// frequency-axis recolors without re-decoding or re-computing any FFTs.
    /// `actualSamples` is the number of PCM samples that were actually decoded —
    /// which may differ from the header-predicted total for truncated or
    /// malformed files. When the difference is large enough that the columns were
    /// recomputed over the actual count (see `streamingCompute`), a corrected
    /// `.metadata` carrying the matching duration precedes this event, so the
    /// time ruler and the cached run describe exactly what the columns cover.
    case complete(magnitudes: [[Float]], actualSamples: Int)
    /// The finished columns of one of the run's companion channels (see
    /// `AnalysisPipeline.analyze`), laid out exactly like the main channel's.
    /// Every companion arrives after the last `.metadata` and before `.complete`.
    case companion(channelIndex: Int, magnitudes: [[Float]])
    /// A fatal error occurred; the pipeline has stopped.
    case error(String)

    var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }

    /// A finished result worth caching even from a canceled run.
    var isResult: Bool {
        switch self {
        case .complete, .companion: return true
        default:                    return false
        }
    }
}

/// Orchestrates audio decoding and FFT processing.
/// All heavy computation runs off the main actor.
///
/// ## Design note — image rendering removed from pipeline
/// `ImageBuilder` is no longer owned by the pipeline. The pipeline's sole
/// responsibility is to compute per-column dB magnitudes and emit them via
/// `.progress` events. The ViewModel owns the `ImageBuilder` and drives
/// rendering through a `CADisplayLink`, producing smooth 60 fps updates
/// independent of the pipeline's batch cadence.
///
/// ## Column computation
/// Columns within each ready batch are dispatched as concurrent `TaskGroup`
/// child tasks — one per logical CPU core. (A sequential Spek-style path once
/// existed behind a Development-tab toggle for comparison; the parallel path
/// won decisively and is now the only one.)
///
/// ## Multi-FFT averaging
/// Each spectrogram column covers a time span of `totalSamples / outputWidth`
/// audio samples. The pipeline distributes multiple overlapping FFT windows
/// across that span at the configured hop (`fftSize * Preferences.overlapFraction`),
/// computes the dB value of each window, then averages those dB values to
/// produce the final column.
///
/// This matches Spek's averaging strategy (arithmetic mean of dB values) and
/// is the correct choice for a spectral coverage tool: dB averaging de-emphasizes
/// momentary transients and reflects the sustained frequency content of each
/// time slice, which is what matters when assessing codec artifacts, high-frequency
/// rolloff, or spectral balance. With 50% overlap enabled, the number of FFTs
/// averaged per column roughly doubles, yielding a more stable reading.
actor AnalysisPipeline: Loggable {

    // MARK: - Public

    /// Analyze an audio file and produce per-column magnitude data.
    ///
    /// - Parameters:
    ///   - url: The audio file URL.
    ///   - settings: Current spectrogram settings (FFT size, window, channel).
    ///   - outputWidth: Number of horizontal pixels (= number of time columns).
    ///   - outputHeight: Number of vertical pixels; passed through for logging only.
    ///   - throttle: The CPU budget for this run — `.unlimited` for a run the user is
    ///     waiting on, `.background()` for a speculative prefetch. Consulted per FFT batch
    ///     (so a promotion widens the very next batch) and honored as a pause gate.
    ///   - companionChannels: Further channels of the same stream to compute in the same
    ///     pass. They share the decode — the expensive part — so a prefetch of every channel
    ///     of a stream decodes the file once instead of once per channel. Their columns are
    ///     emitted only at the end, one `.companion` each; `.progress` carries the main
    ///     channel (`settings.channelIndex`) alone.
    /// - Returns: An async stream of `PipelineEvent`s for progressive UI updates.
    func analyze(
        url: URL,
        settings: SpectrogramSettings,
        outputWidth: Int,
        outputHeight: Int,
        throttle: PipelineThrottle = .unlimited,
        companionChannels: [Int] = []
    ) -> AsyncStream<PipelineEvent> {
        // Use a stored task handle so the continuation's onTermination handler
        // can cancel the inner task when the consumer stops iterating (i.e. when
        // the ViewModel cancels its analysisTask). Without this the unstructured
        // Task keeps running to completion, buffering events into the abandoned
        // stream and burning CPU and memory until the entire file is processed.
        // Rapidly opening files would otherwise stack multiple concurrent runs.
        //
        // The handle is a `let` created before onTermination is installed, so
        // the closure captures an immutable, Sendable value.
        return AsyncStream { continuation in
            let pipelineTask = Task {
                await self.runPipeline(
                    url: url,
                    settings: settings,
                    outputWidth: outputWidth,
                    outputHeight: outputHeight,
                    throttle: throttle,
                    companionChannels: companionChannels,
                    continuation: continuation
                )
            }
            // When the stream's consumer is abandoned or the ViewModel cancels
            // its outer Task, AsyncStream calls onTermination. Cancel the inner
            // pipeline task immediately so it does not continue running to
            // completion after it is no longer needed.
            continuation.onTermination = { _ in
                pipelineTask.cancel()
            }
        }
    }

    /// Upper bound on the header-predicted sample count: about 650 years at
    /// 48 kHz, so only a corrupt header reaches it.
    private static let maxPredictedSamples = 1e15

    // MARK: - Private pipeline execution

    private func runPipeline(
        url: URL,
        settings: SpectrogramSettings,
        outputWidth: Int,
        outputHeight: Int,
        throttle: PipelineThrottle,
        companionChannels: [Int],
        continuation: AsyncStream<PipelineEvent>.Continuation
    ) async {
        log("Pipeline started — \(url.lastPathComponent) @ \(outputWidth)×\(outputHeight)"
            + (companionChannels.isEmpty ? "" : ", companion channels \(companionChannels)"))
        do {
            try await runPipelineUnsafe(
                url: url,
                settings: settings,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                throttle: throttle,
                companionChannels: companionChannels,
                continuation: continuation
            )
        } catch {
            let msg = error.localizedDescription
            log("Pipeline top-level error — \(msg)")
            continuation.yield(.error(msg))
            continuation.finish()
        }
    }

    private func runPipelineUnsafe(
        url: URL,
        settings: SpectrogramSettings,
        outputWidth: Int,
        outputHeight: Int,
        throttle: PipelineThrottle,
        companionChannels: [Int],
        continuation: AsyncStream<PipelineEvent>.Continuation
    ) async throws {

        // ── Step 1: Extract metadata ─────────────────────────────────────────
        let metadata: AudioMetadata
        do {
            metadata = try await AudioDecoder.metadata(for: url, streamIndex: settings.streamIndex)
            log("Metadata: \(metadata.codec), \(metadata.formattedSampleRate), \(metadata.channelDescription), \(metadata.formattedDuration)")
        } catch {
            let msg = error.localizedDescription
            log("Error — \(msg)")
            continuation.yield(.error(msg))
            continuation.finish()
            return
        }

        continuation.yield(.metadata(metadata))

        guard metadata.duration > 0 else {
            let msg = "Unknown duration"
            log("Error — \(msg)")
            continuation.yield(.error(msg))
            continuation.finish()
            return
        }

        guard outputWidth > 0 && outputHeight > 0 else {
            let msg = "Invalid output dimensions (\(outputWidth)×\(outputHeight))"
            log("Error — \(msg)")
            continuation.yield(.error(msg))
            continuation.finish()
            return
        }

        // ── Step 2: Streaming decode + overlapped multi-FFT averaging ────────
        let fftSize = settings.fftSize

        let hop = max(1, Int(Double(fftSize) * Preferences.overlapFraction))

        // Resolve the true sample rate and duration before computing totalSamples.
        // Container headers can carry wrong values (e.g. an AVI declaring 16 kHz
        // for a 32 kHz MP3, or DTS 96/24 in a container that declares 48 kHz);
        // resolvedAudioInfo decodes the first frame and reports what the
        // bitstream actually contains.
        let resolved = await AudioDecoder.resolvedAudioInfo(
            url: url,
            streamIndex:        settings.streamIndex,
            metadataSampleRate: metadata.sampleRate,
            metadataDuration:   metadata.duration
        )
        let sampleRate = resolved.sampleRate

        // If either value differs from the header, publish a corrected metadata
        // event so the frequency ruler, metadata bar, and ImageBuilder ratio are
        // all updated before any .progress events arrive.
        let resolvedMetadata: AudioMetadata
        let rateChanged     = abs(sampleRate - metadata.sampleRate) > 0.5
        let durationChanged = abs(resolved.duration - metadata.duration) > 0.5
        if rateChanged || durationChanged {
            log("Audio info corrected: "
              + "sampleRate \(metadata.sampleRate) → \(sampleRate) Hz, "
              + "duration \(metadata.duration.fixed(2))s "
              + "→ \(resolved.duration.fixed(2))s.")
            resolvedMetadata = AudioMetadata(
                fileName:     metadata.fileName,
                codec:        metadata.codec,
                sampleRate:   sampleRate,
                bitDepth:     metadata.bitDepth,
                channelCount: metadata.channelCount,
                bitrate:      metadata.bitrate,
                duration:     resolved.duration,
                streamCount:  metadata.streamCount
            )
            continuation.yield(.metadata(resolvedMetadata))
        } else {
            resolvedMetadata = metadata
        }

        // A corrupt header can claim an absurd duration, and `Int(_:)` traps on
        // a value past `Int.max`. The capped prediction still lays out a run;
        // the decoded count then corrects it (see `streamingCompute`).
        let predictedSamples = resolvedMetadata.duration * sampleRate
        let totalSamples = predictedSamples.isFinite
            ? Int(min(predictedSamples, Self.maxPredictedSamples)) : 0
        guard totalSamples > 0 else {
            let msg = "No audio samples found"
            log("Error — \(msg)")
            continuation.yield(.error(msg))
            continuation.finish()
            return
        }

        let concurrency = min(ProcessInfo.processInfo.activeProcessorCount, outputWidth)

        log("FFT config — "
            + "size=\(fftSize) (bits=\(settings.fftBits)), "
            + "hop=\(hop) (fraction=\(Preferences.overlapFraction)), "
            + "window=\(settings.windowFunction.displayName), "
            + "bandCount=\(fftSize / 2), "
            + "totalSamples=\(totalSamples)")
        log("Render config — "
            + "concurrency=\(concurrency) "
            + "(activeProcessors=\(ProcessInfo.processInfo.activeProcessorCount)), "
            + "columns=\(outputWidth), "
            + "channel=\(settings.channelIndex), "
            + "stream=\(settings.streamIndex)")

        // The displayed channel first, then each companion once.
        var channels = [settings.channelIndex]
        for c in companionChannels where !channels.contains(c) { channels.append(c) }

        guard let result = await streamingCompute(
            url:           url,
            settings:      settings,
            channels:      channels,
            fftSize:       fftSize,
            hop:           hop,
            columnCount:   outputWidth,
            totalSamples:  totalSamples,
            sampleRate:    sampleRate,
            concurrency:   concurrency,
            throttle:      throttle,
            continuation:  continuation
        ) else {
            // `streamingCompute` returns nil for two reasons:
            //   1. Task cancellation — the outer ViewModel canceled this run
            //      (e.g. user opened a new file or switched channels).
            //   2. Decode error — the decoder failed; in that case streamingCompute
            //      already emitted a .error event and called continuation.finish()
            //      internally, so finish() below is a harmless no-op per
            //      AsyncStream's documented contract (subsequent finish() calls are
            //      ignored). Either way the pipeline is done.
            continuation.finish()
            if Task.isCancelled {
                log("Pipeline canceled.")
            } else {
                log("Pipeline stopped (decode error reported via stream).")
            }
            return
        }

        // ── Step 3: Signal completion ─────────────────────────────────────────
        // The columns were laid out over `coveredSamples` — the actual decoded
        // count when a truncated file forced a recompute, the header prediction
        // otherwise. The ruler must span the same audio the image does, so the
        // duration correction is decided once, here, and published as metadata
        // rather than re-derived downstream from possibly different figures.
        if result.coveredSamples != totalSamples {
            let corrected = resolvedMetadata.with(duration: Double(result.coveredSamples) / sampleRate)
            log("Duration corrected to match the recomputed columns: "
              + "\(resolvedMetadata.duration.fixed(2))s → "
              + "\(corrected.duration.fixed(2))s.")
            continuation.yield(.metadata(corrected))
        }
        log("All columns computed (\(outputWidth)×\(outputHeight)) for channel"
          + (channels.count == 1 ? " \(channels[0])" : "s \(channels)") + ". "
          + "actualSamples=\(result.actualSamples), headerPredicted=\(totalSamples).")
        for slot in channels.indices.dropFirst() {
            continuation.yield(.companion(channelIndex: channels[slot],
                                          magnitudes: result.magnitudes[slot]))
        }
        continuation.yield(.complete(magnitudes: result.magnitudes[0],
                                     actualSamples: result.actualSamples))
        continuation.finish()
        log("Pipeline finished.")
    }

    // MARK: - Streaming decode + multi-FFT computation

    /// Decodes samples from the streaming decoder while computing columns as
    /// soon as their audio data is available. Emits `.progress` events carrying
    /// raw magnitude data — no image rendering occurs here.
    ///
    /// Each ready batch is dispatched as concurrent `TaskGroup` child tasks
    /// (one per logical CPU core).
    ///
    /// `channels` are computed side by side from one decode: slot 0 is the
    /// displayed channel (the only one `.progress` reports), the rest are
    /// companions. `magnitudes[slot][column]` holds every slot's columns.
    ///
    /// Returns `(magnitudes, actualSamples, coveredSamples)` on success, or `nil`
    /// if the task was canceled. `actualSamples` is the number of PCM samples
    /// that were actually decoded, which may be less than `totalSamples` for
    /// truncated or malformed files, or more when the header understates the
    /// length. When the two counts differ significantly,
    /// all columns are recomputed using the actual count so that column-to-time
    /// mapping is correct regardless of what the file's headers declared;
    /// `coveredSamples` is the count the returned columns were laid out over
    /// (`actualSamples` after such a recompute, `totalSamples` otherwise).
    /// Emits an `.error` event and returns `nil` on decode failure.
    ///
    /// ## Memory: a sliding window, not the whole track
    /// Columns are computed strictly left to right, so once column `c` is
    /// reached no sample before the first FFT window of `c` is read again. The
    /// buffer drops that prefix as it goes and holds only audio decoded but not
    /// yet consumed — instead of the entire channel (≈ 1 GB per hour at 48 kHz,
    /// several GB for a long hi-res or DSD file, twice over with a prefetch
    /// running). The one pass that needs every sample, the truncated-file
    /// recompute, decodes the file a second time (`isRecompute`) rather than
    /// keeping everything for a case that only malformed files reach.
    ///
    /// - Parameter isRecompute: the second, corrected pass over a truncated file.
    ///   It emits no `.decoding` or `.progress` events of its own — the caller
    ///   emits all of its columns at once, as before — and never recurses.
    private func streamingCompute(
        url: URL,
        settings: SpectrogramSettings,
        channels: [Int],
        fftSize: Int,
        hop: Int,
        columnCount: Int,
        totalSamples: Int,
        sampleRate: Double,
        concurrency: Int,
        throttle: PipelineThrottle,
        continuation: AsyncStream<PipelineEvent>.Continuation,
        isRecompute: Bool = false
    ) async -> (magnitudes: [[[Float]]], actualSamples: Int, coveredSamples: Int)? {

        // The decoded samples not yet consumed: one array per channel slot, all the same
        // length. `base` is the stream index of `samples[0]`: every index below is
        // absolute, and `decodedEnd()` is the count decoded so far.
        //
        // Plain values, not a shared box. Each FFT batch's child tasks capture a `let`
        // snapshot; copy-on-write makes that free, and since `withTaskGroup` returns only
        // after every child has finished (releasing its snapshot), the next append finds
        // the storage uniquely referenced again and extends it in place.
        var samples = [[Float]](repeating: [], count: channels.count)
        var base = 0
        func decodedEnd() -> Int { base + (samples.first?.count ?? 0) }

        // Accumulate every column's magnitudes in order for the final cache.
        var allMagnitudes = [[[Float]]](repeating: [[Float]](repeating: [], count: columnCount),
                                        count: channels.count)

        var decodeFinished    = false
        var decodeError: (any Error)?
        var nextColumn        = 0
        var decodingEventSent = false

        let firstColThreshold = AnalysisPipeline.computableThreshold(
            col: 0, totalSamples: totalSamples, columnCount: columnCount,
            fftSize: fftSize, hop: hop
        )

        let decodeStream = AudioDecoder.streamingDecode(
            url: url,
            channels:    channels,
            streamIndex: settings.streamIndex,
            throttle:    throttle
        )
        var streamIterator        = decodeStream.makeAsyncIterator()
        let decodingEventDeadline = ContinuousClock.now + .milliseconds(300)

        // ── I/O draining chunk limit ──────────────────────────────────────────
        //
        // Two distinct chunk-read limits govern how many decode chunks are
        // consumed per loop pass:
        //
        //   • `ioFillLimit` — used while waiting for the first computable column.
        //     A larger value drains the I/O stream more aggressively, reducing
        //     the time before the first batch of FFT columns can fire.
        //     Set to `max(concurrency * 4, 16)` so that on a 10-core machine
        //     we pre-fill at least 40 chunks (≈ 2.6 M frames) before checking
        //     computableCeil, rather than stopping at 10 and yielding to the
        //     cooperative thread pool. The drain stops early the moment column 0
        //     becomes computable, though: for a slow codec (6-channel TrueHD
        //     decodes about five times slower than AC-3) waiting for the full
        //     limit left the window blank for several hundred milliseconds
        //     after everything needed for the first column had already arrived.
        //
        //   • `ioSteadyLimit` — used once columns are being computed (steady
        //     state). Kept equal to `concurrency` so the decode loop and the
        //     FFT batch remain roughly balanced and the pipeline does not buffer
        //     more audio than necessary. This matches the original behavior.
        let ioFillLimit   = max(concurrency * 4, 16)
        let ioSteadyLimit = concurrency

        // How far the decoded count may stray from `totalSamples` before the
        // columns are recomputed over the real count: 1 s of audio, so rounding
        // and decoder priming or padding never trigger it. `sampleRate` is the
        // resolved rate from the bitstream, which is what all sample counts in
        // this function are based on.
        let mismatchThreshold = max(1, Int(sampleRate))

        // ── Main interleaved decode + compute loop ────────────────────────────
        while !decodeFinished || nextColumn < columnCount {
            if Task.isCancelled { return nil }
            // A paused background run parks here between passes; the decoder
            // threads park on the same gate, so nothing burns CPU meanwhile.
            await throttle.waitWhilePaused()

            // All columns are computed. Any audio the decoder has left is past
            // the header's length; it is counted below, not buffered or
            // transformed, so the length check can decide whether to recompute.
            if nextColumn == columnCount { break }

            // Select the appropriate chunk limit for this pass.
            // While no columns are yet computable (still filling the initial
            // sample buffer), drain more chunks per pass to minimize latency
            // before the first FFT batch fires. Once steady-state is reached
            // (nextColumn > 0), switch to the balanced limit.
            let chunkLimit = nextColumn == 0 ? ioFillLimit : ioSteadyLimit

            // Drain up to `chunkLimit` decode chunks per pass.
            var chunksConsumedThisPass = 0
            while !decodeFinished && chunksConsumedThisPass < chunkLimit {
                let nextChunk: AudioDecoder.Chunk?
                do {
                    nextChunk = try await streamIterator.next()
                } catch {
                    decodeError    = error
                    decodeFinished = true
                    break
                }
                if let chunk = nextChunk {
                    for slot in samples.indices where slot < chunk.count {
                        samples[slot].append(contentsOf: chunk[slot])
                    }
                    chunksConsumedThisPass += 1
                    if nextColumn == 0 && decodedEnd() >= firstColThreshold { break }
                } else {
                    decodeFinished = true
                    break
                }
            }

            // The file ended well short of the header's length, so every column
            // still to come would be laid out over audio that does not exist,
            // and the recompute below replaces them all anyway. Stop here: for
            // a grossly overstated header each of those columns spans millions
            // of zero-padded windows.
            if !isRecompute, decodeFinished, decodeError == nil,
               totalSamples - decodedEnd() > mismatchThreshold {
                break
            }

            // Emit .decoding once if the decoder stalls before column 0 is ready.
            // Guard on `!decodingEventSent` first so the clock read is skipped
            // entirely after the event has already been emitted — the condition
            // is evaluated on every loop iteration, and `ContinuousClock.now`
            // is not free on high-frequency loops.
            if !isRecompute &&
               !decodingEventSent &&
               nextColumn == 0 &&
               decodedEnd() < firstColThreshold &&
               ContinuousClock.now >= decodingEventDeadline {
                continuation.yield(.decoding)
                decodingEventSent = true
                log("Decode stall detected — emitting .decoding event.")
            }

            // Scan forward to find how many columns are now fully computable.
            let computableCeil: Int
            if decodeFinished {
                computableCeil = columnCount
            } else {
                var ceil = nextColumn
                while ceil < columnCount {
                    let needed = AnalysisPipeline.computableThreshold(
                        col: ceil, totalSamples: totalSamples,
                        columnCount: columnCount, fftSize: fftSize, hop: hop
                    )
                    if needed > decodedEnd() { break }
                    ceil += 1
                }
                computableCeil = ceil
            }

            if computableCeil <= nextColumn {
                if chunksConsumedThisPass == 0 { await Task.yield() }
                continue
            }

            // ── Dispatch FFT batch ────────────────────────────────────────────
            var batchStart = nextColumn

            while batchStart < computableCeil {
                if Task.isCancelled { return nil }
                await throttle.waitWhilePaused()

                // Re-read the cap per batch: a background run that the user
                // adopts widens to the full core count on its next batch.
                let batchWidth  = throttle.fftConcurrency(preferred: concurrency)
                let batchEnd    = min(batchStart + batchWidth, computableCeil)
                let batchSamples = samples
                let batchBase    = base

                var batchResults = [(col: Int, magnitudes: [[Float]])]()
                batchResults.reserveCapacity(batchEnd - batchStart)

                // ── One TaskGroup child task per column ──────────────────────
                // The children read `batchSamples`, a snapshot, so nothing this
                // loop does to `samples` afterwards can reach them.
                //
                // Each child task creates its own FFTProcessor. Construction
                // is effectively free (borrows the shared DFT setup from
                // FFTProcessorCache); the non-Sendable scratch buffers are
                // owned exclusively by each task's stack frame.
                // Explicit priority per batch: a prefetch's tasks sit at
                // .utility, and a promoted run's rise from the next batch.
                let batchPriority = throttle.taskPriority
                await withTaskGroup(of: (Int, [[Float]]).self) { group in
                    for col in batchStart..<batchEnd {
                        group.addTask(priority: batchPriority) {
                            let mags = AnalysisPipeline.computeColumnMagnitudes(
                                col:            col,
                                totalSamples:   totalSamples,
                                columnCount:    columnCount,
                                samples:        batchSamples,
                                base:           batchBase,
                                fftSize:        fftSize,
                                hop:            hop,
                                windowFunction: settings.windowFunction
                            )
                            return (col, mags)
                        }
                    }
                    for await result in group {
                        batchResults.append((col: result.0, magnitudes: result.1))
                    }
                }
                batchResults.sort { $0.col < $1.col }

                // Store magnitudes in the accumulator.
                for entry in batchResults {
                    for slot in entry.magnitudes.indices {
                        allMagnitudes[slot][entry.col] = entry.magnitudes[slot]
                    }
                }

                // Emit magnitude data only — no image rendering in the pipeline.
                // A recompute pass reports its columns all at once (the caller).
                if !isRecompute {
                    let fraction = Double(batchEnd) / Double(columnCount)
                    let columns  = batchResults.map { PipelineColumn(index: $0.col, magnitudes: $0.magnitudes[0]) }
                    continuation.yield(.progress(fraction: fraction, columns: columns))
                }

                // Yield to the cooperative thread pool so the main actor can run
                // its display-link tick between batches. Without this, a pipeline run
                // where all columns become computable at once (e.g., PCM decodes at
                // memory-copy speed so all samples arrive before the first column
                // threshold fires) dispatches every batch back-to-back before the
                // CADisplayLink has a chance to drain pendingColumns, causing the
                // entire spectrogram to appear in a single frame rather than growing
                // progressively left-to-right.
                await Task.yield()

                batchStart = batchEnd
            }

            nextColumn = computableCeil

            // Drop the samples no remaining column reads: everything before
            // the first FFT window of `nextColumn` (see "Memory" above). The
            // prefix is dropped only once it is at least half the buffer, so
            // the copy that compacts it costs O(1) per sample overall; copying
            // into a fresh array (rather than `removeFirst`) also releases the
            // old, larger allocation.
            let keepFrom = nextColumn < columnCount
                ? AnalysisPipeline.firstWindowStart(col: nextColumn, totalSamples: totalSamples,
                                                    columnCount: columnCount, fftSize: fftSize, hop: hop)
                : decodedEnd()
            let drop = min(keepFrom, decodedEnd()) - base
            if drop > 0, drop >= (decodedEnd() - base) / 2 {
                samples = samples.map { Array($0[drop...]) }
                base   += drop
            }
        }

        // A canceled run's decode stream ends early, which would otherwise read
        // as a truncated file and start a recompute decode nobody wants.
        if Task.isCancelled { return nil }

        if let err = decodeError {
            log("Decode error — \(err.localizedDescription)")
            continuation.yield(.error("Cannot decode audio: \(err.localizedDescription)"))
            continuation.finish()
            return nil
        }

        // Every column was computed before the decoder reached the end: the
        // header understates the length (an estimated duration, a stale frame
        // count). Count the remaining samples without keeping them, so the
        // check below can lay the columns out over the whole file instead of
        // silently leaving out its end. A well-formed file has at most a few
        // thousand samples left here (decoder padding), so this costs nothing.
        var tailSamples = 0
        if !isRecompute && !decodeFinished {
            while true {
                if Task.isCancelled { break }
                await throttle.waitWhilePaused()
                let chunk: AudioDecoder.Chunk?
                do {
                    chunk = try await streamIterator.next()
                } catch {
                    // Every column is already computed from audio that decoded
                    // cleanly; a failure past them does not void the run.
                    log("Decode error after the last column — \(error.localizedDescription); "
                        + "counted \(tailSamples) samples past the header length.")
                    break
                }
                guard let chunk else { break }
                tailSamples += chunk.first?.count ?? 0
            }
            // A partial count would cache a run that is missing the file's end.
            if Task.isCancelled { return nil }
        }

        // ── Actual-sample correction ──────────────────────────────────────────
        //
        // For well-formed files, the decoded count (`decodedEnd()`) ≈ `totalSamples` and no
        // recomputation is needed. For truncated or structurally malformed files
        // (e.g. a RIFF header that declares twice the actual content) the two
        // counts can diverge significantly:
        //
        //   • The decoder finished well short of `totalSamples`: the remaining
        //     columns would map past the real audio and come out as uniform
        //     black, so the loop above stopped computing them.
        //
        //   • The early exit (`if nextColumn == columnCount { break }`) fires
        //     when `totalSamples` was *under*estimated, i.e. the actual file is
        //     longer than the headers claimed. The columns then cover only the
        //     header's length, and the tail counted above is the audio they
        //     leave out.
        //
        // When the actual count differs meaningfully from the prediction in
        // either direction (threshold: more than 1 s of audio at the file's
        // sample rate), recompute all columns using `actualSamples` as the true
        // total. This mirrors Spek's approach of deriving spectrogram layout
        // from actual decoded data rather than headers.
        //
        // The recompute pass decodes the file a second time (the first pass kept
        // only a sliding window of samples — see "Memory" above). That doubles
        // the decode time, but only for files whose headers misstate their
        // length by more than a second.
        let actualSamples = decodedEnd() + tailSamples
        var coveredSamples = totalSamples
        if !isRecompute, abs(actualSamples - totalSamples) > mismatchThreshold {
            log("Recomputing \(columnCount) columns with actualSamples=\(actualSamples) "
              + "(headerPredicted=\(totalSamples), "
              + "difference=\(actualSamples - totalSamples) samples).")

            // The samples are gone (sliding window), so decode the file again
            // with the columns laid out over what actually exists. The same
            // column computation over the same samples, so the result is the
            // same as recomputing from a kept buffer.
            guard let corrected = await streamingCompute(
                url: url, settings: settings, channels: channels, fftSize: fftSize, hop: hop,
                columnCount: columnCount, totalSamples: actualSamples,
                sampleRate: sampleRate, concurrency: concurrency, throttle: throttle,
                continuation: continuation, isRecompute: true
            ) else { return nil }
            allMagnitudes  = corrected.magnitudes
            coveredSamples = actualSamples
            log("Recompute complete.")

            // Emit a final .progress event carrying every corrected column so
            // the ViewModel's ImageBuilder (activeBuilder) is updated with the
            // recomputed magnitudes before the .complete event arrives. Without
            // this, activeBuilder holds the original first-pass columns and the
            // displayed image would not reflect the actual-sample correction even
            // though the cached magnitudes are correct.
            let correctedColumns = allMagnitudes[0].enumerated().map {
                PipelineColumn(index: $0.offset, magnitudes: $0.element)
            }
            continuation.yield(.progress(fraction: 1.0, columns: correctedColumns))
            await Task.yield()
        }

        return (magnitudes: allMagnitudes, actualSamples: actualSamples, coveredSamples: coveredSamples)
    }

    // MARK: - Column computation

    /// Compute the averaged dB magnitude spectrum of one spectrogram column for
    /// every channel slot in `samples` (one result per slot, in order).
    ///
    /// Creates its own `FFTProcessor` internally: each `TaskGroup` child task
    /// must own its own processor (non-Sendable scratch buffers cannot be shared
    /// across concurrent tasks). Construction is effectively free because
    /// `FFTProcessorCache` amortizes the expensive DFT setup creation.
    ///
    /// `nonisolated static` so it runs safely in a `TaskGroup` child task.
    private static func computeColumnMagnitudes(
        col: Int,
        totalSamples: Int,
        columnCount: Int,
        samples: [[Float]],
        base: Int,
        fftSize: Int,
        hop: Int,
        windowFunction: WindowFunction
    ) -> [[Float]] {
        // One FFTProcessor per column task: construction is effectively free
        // (borrows the shared DFT setup from FFTProcessorCache), and the
        // instance-level scratch buffers are reused across every window and
        // every channel slot.
        let processor = FFTProcessor(fftSize: fftSize, windowFunction: windowFunction)
        return samples.map { slotSamples in
            computeColumnMagnitudesWithProcessor(
                col:          col,
                totalSamples: totalSamples,
                columnCount:  columnCount,
                samples:      slotSamples,
                base:         base,
                fftSize:      fftSize,
                hop:          hop,
                processor:    processor
            )
        }
    }

    /// Core column-magnitude computation accepting a caller-owned `FFTProcessor`.
    ///
    /// Used by:
    ///   - The **recompute** pass (one shared processor for all correction columns).
    ///   - `computeColumnMagnitudes` (creates the processor in the caller and
    ///     delegates here).
    ///
    /// `nonisolated static` so it can be called from both actor-isolated context
    /// and `TaskGroup` child tasks.
    ///
    /// Separating construction from the core loop lets the recompute pass
    /// allocate a single `FFTProcessor` (four scratch buffers) for the entire
    /// column sequence rather than once per column.
    private static func computeColumnMagnitudesWithProcessor(
        col: Int,
        totalSamples: Int,
        columnCount: Int,
        samples: [Float],
        base: Int,
        fftSize: Int,
        hop: Int,
        processor: FFTProcessor
    ) -> [Float] {
        let bandCount = fftSize / 2
        let (colStart, colEnd) = columnBounds(col: col, totalSamples: totalSamples,
                                               columnCount: columnCount)

        let kFirst = firstWindowIndex(colStart: colStart, fftSize: fftSize, hop: hop)
        let kLast  = Int(floor(Double(colEnd - 1) / Double(hop)))

        var dbAccum  = [Float](repeating: 0, count: bandCount)
        // windowDB, sumBuf and inputBuf are allocated once per column, not per window.
        var windowDB = [Float](repeating: 0, count: bandCount)
        var sumBuf   = [Float](repeating: 0, count: bandCount)
        var inputBuf = [Float](repeating: 0, count: fftSize)
        var windowCount = 0

        // Samples that actually exist: `totalSamples` is the header's prediction,
        // and once the decoder hits EOF the last columns are computed with
        // fewer than that. `fillBuffer` copies only what exists, so every
        // window past this point must take the zero-padding path.
        let available = min(totalSamples, base + samples.count)

        for k in kFirst...max(kFirst, kLast) {
            let winStart = k * hop

            // Determine whether this window is fully within the sample array
            // (no zero-padding required at either edge). When it is, we can
            // skip the `vDSP_vclr` zeroing pass entirely and go straight to the
            // memcpy fill — saving one full pass over `fftSize` floats per
            // interior window, which is the common case for all but the first
            // and last few windows in the file.
            let fullyInterior = winStart >= 0 && winStart + fftSize <= available
            if fullyInterior {
                // Fast path: fill without zeroing first. fillBuffer always
                // writes exactly fftSize floats when the window is interior.
                fillBuffer(from: samples, base: base, start: winStart,
                           fftSize: fftSize, totalSamples: totalSamples,
                           into: &inputBuf)
            } else {
                // Boundary window: zero-pad first, then overwrite with valid samples.
                vDSP.clear(&inputBuf)
                fillBuffer(from: samples, base: base, start: winStart,
                           fftSize: fftSize, totalSamples: totalSamples,
                           into: &inputBuf)
            }

            processor.process(inputBuf, into: &windowDB)

            // Vectorized accumulation into a second buffer, then an O(1) swap:
            // passing `dbAccum` both by value and as `&` would make Swift copy
            // the whole buffer on every window (the by-value argument holds a
            // second reference, so the write is not unique).
            vDSP.add(dbAccum, windowDB, result: &sumBuf)
            swap(&dbAccum, &sumBuf)

            windowCount += 1
        }

        guard windowCount > 0 else {
            return [Float](repeating: -140.0, count: bandCount)
        }

        // Arithmetic mean of dB values across all windows in this column.
        let invCount = Float(1.0) / Float(windowCount)
        vDSP.multiply(invCount, dbAccum, result: &sumBuf)
        return sumBuf
    }

    // MARK: - Helpers

    /// Integer sample range `[start, end)` for column `col`.
    /// Uses `rounded()` to distribute any fractional samples evenly.
    private static func columnBounds(col: Int, totalSamples: Int, columnCount: Int) -> (Int, Int) {
        let start = Int((Double(col)     * Double(totalSamples) / Double(columnCount)).rounded())
        let end   = Int((Double(col + 1) * Double(totalSamples) / Double(columnCount)).rounded())
        return (start, end)
    }

    /// Index of the first hop-aligned FFT window that overlaps a column
    /// starting at `colStart`.
    private static func firstWindowIndex(colStart: Int, fftSize: Int, hop: Int) -> Int {
        max(0, Int(ceil(Double(colStart - fftSize + 1) / Double(hop))))
    }

    /// First sample column `col` reads: the start of its first FFT window.
    /// Non-decreasing in `col`, which is what lets the pipeline drop every
    /// sample before it once `col` is the next column to compute.
    private static func firstWindowStart(col: Int, totalSamples: Int, columnCount: Int,
                                         fftSize: Int, hop: Int) -> Int {
        let (colStart, _) = columnBounds(col: col, totalSamples: totalSamples,
                                         columnCount: columnCount)
        return firstWindowIndex(colStart: colStart, fftSize: fftSize, hop: hop) * hop
    }

    /// Minimum decoded-sample count required before column `col` is computable.
    ///
    /// Equal to the right edge of the last hop-aligned FFT window that
    /// overlaps the column's sample range.
    private static func computableThreshold(
        col: Int,
        totalSamples: Int,
        columnCount: Int,
        fftSize: Int,
        hop: Int
    ) -> Int {
        let (_, colEnd) = columnBounds(col: col, totalSamples: totalSamples,
                                        columnCount: columnCount)
        let lastWindowStart = (max(0, colEnd - 1) / hop) * hop
        return lastWindowStart + fftSize
    }

    /// Fill a caller-owned `fftSize`-element buffer with samples starting at
    /// `start`. Samples before index 0 or beyond `totalSamples` are left as
    /// zero (the caller is responsible for pre-zeroing the buffer when the
    /// window is not fully interior). Uses `memcpy` via unsafe buffer pointers
    /// for the inner copy, which is faster than `Array.replaceSubrange` because
    /// it avoids Swift's bounds-check and COW machinery on every element.
    private static func fillBuffer(
        from samples: [Float],
        base: Int,
        start: Int,
        fftSize: Int,
        totalSamples: Int,
        into buffer: inout [Float]
    ) {
        let srcStart = max(start, 0)
        let srcEnd   = min(start + fftSize, min(totalSamples, base + samples.count))
        guard srcStart < srcEnd else { return }
        // The sliding window never drops a sample a remaining column reads
        // (`firstWindowStart`); reaching below `base` would be a logic error.
        assert(srcStart >= base, "window starts at \(srcStart), before the retained samples at \(base)")
        guard srcStart >= base else { return }
        let destOffset = srcStart - start
        let count      = srcEnd - srcStart
        guard destOffset >= 0, destOffset + count <= min(fftSize, buffer.count) else { return }
        // Copy `count` floats from `samples[srcStart...]` into `buffer[destOffset...]`
        // using a direct memcpy. This is a non-overlapping, contiguous Float copy
        // that the compiler can lower to a single SIMD memcpy instruction sequence.
        //
        // `unsafe`: the guards above prove both ranges in bounds — the source
        // spans `[srcStart − base, srcEnd − base)` within `samples`, the
        // destination `[destOffset, destOffset + count)` within `buffer`. The
        // bounds-checked slice assignment measured ~25% slower per copy at
        // fftSize 4096 (2026-09-27), and this runs once per FFT window.
        unsafe samples.withUnsafeBufferPointer { src in
            unsafe buffer.withUnsafeMutableBufferPointer { dst in
                unsafe (dst.baseAddress! + destOffset).update(
                    from: src.baseAddress! + (srcStart - base),
                    count: count
                )
            }
        }
    }
}
