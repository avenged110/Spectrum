// MARK: - AudioDecoder.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The app's entire demux/decode layer, built on the bundled FFmpeg (see ThirdParty/FFmpeg and
// FFmpegShim.c). Every supported format — from a bare WAV to DTS-HD MA inside a 19 GB Matroska —
// goes through the same four-call C bridge: probe (compatibility + metadata), open (first-frame
// truth for sample rate/channels), read (Float32 chunks of the requested channels, all from one
// decode pass), close. Nothing is
// written to temp files and no Apple media framework is involved, so behavior is identical on
// every macOS release and every failure surfaces as a typed `DecoderError`.
//
// Long tracks are decoded in parallel time segments: many short
// segments (about eight per core, at least 30 s each), each decoded by its own demuxer + decoder
// instance (SPKFFmpegOpenSegment), pulled from an in-order queue by a pool of worker threads and
// delivered to the pipeline strictly in order — the current segment streams live while later ones
// decode into memory. The stream contract seen by AnalysisPipeline is a plain sequential stream;
// wall-clock time is roughly the sequential time divided by the worker count. For the codecs on
// `segmentableCodecs` the result is sample-for-sample identical to a sequential decode (verified on
// 80–95 minute TrueHD, DTS-HD MA and DTS tracks), except AC-3 / E-AC-3, which differ only by their
// decoders' per-instance dither noise (uncorrelated noise around −84 dBFS RMS). Every segment
// boundary is also verified as it is crossed, falling back to a sequential decode if one does not
// join up (see "Boundary verification").

import Foundation
import os

enum AudioDecoder: Loggable {
    nonisolated static let logTag = "[AudioDecoder]"

    // MARK: - Errors

    enum DecoderError: LocalizedError {
        /// The file does not exist or cannot be read at all.
        case cannotOpenFile(URL)
        /// The container opened but holds no audio streams.
        case noAudioTrack
        /// The decoder opened but produced no usable frame.
        case cannotReadSamples
        /// Decoding failed mid-stream; `detail` carries the diagnostic.
        case decodeFailed(detail: String)
        /// libavformat could not parse the file. `container` is a display name
        /// for the format implied by the extension (e.g. "WMV", "Unknown").
        case unsupportedContainer(String)
        /// The container opened but no audio stream uses a bundled decoder.
        /// `formats` carries the codec name(s) found, for the alert.
        case incompatibleStreams([String])

        var errorDescription: String? {
            switch self {
            case .cannotOpenFile(let url):       return "Cannot open file: \(url.lastPathComponent)"
            case .noAudioTrack:                  return "The file contains no audio tracks"
            case .cannotReadSamples:             return "Cannot read audio samples"
            case .decodeFailed(let detail):      return detail
            case .unsupportedContainer(let c):   return "\(c) is not a supported container format"
            case .incompatibleStreams(let fmts):
                if fmts.isEmpty {
                    return "The file does not contain a compatible audio stream"
                }
                let list = Self.nameList(fmts)
                return "\(list) \(fmts.count == 1 ? "is" : "are") not a supported stream format"
            }
        }

        /// Joins a list of names for display: "X" / "X and Y" / "X, Y and Z".
        static func nameList(_ names: [String]) -> String {
            switch names.count {
            case 0: return "Unknown"
            case 1: return names[0]
            default:
                let allButLast = names.dropLast().joined(separator: ", ")
                return "\(allButLast) and \(names.last!)"
            }
        }
    }

    /// Sample rate and duration as decoded from the bitstream itself, which can
    /// differ from what the container header claims.
    struct ResolvedAudioInfo {
        let sampleRate: Double
        let duration: Double
    }

    /// Frames per yielded chunk. 65536 × 4 bytes = 256 KB per mono chunk.
    private static let chunkFrameCount = 65536

    // MARK: - Public API

    /// Verify that `url` can be opened and that at least one audio stream is
    /// decodable, throwing a typed error otherwise. Called by the ViewModel
    /// before any UI state is mutated. A header read only — milliseconds even
    /// for multi-gigabyte files.
    static func checkCompatibility(url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let (status, info) = FFmpegShim.probe(url, streamIndex: 0)
            log("\(url.lastPathComponent): probe status=\(status.rawValue) codec=\(codecName(of: info)) "
                + "streams=\(info.decodableStreamCount)/\(info.totalAudioStreamCount)")
            try throwIfFailed(status, info: info, url: url)
        }.value
    }

    /// Container/stream metadata for the decodable audio stream at `streamIndex`
    /// (0-based, clamped to the last decodable stream).
    static func metadata(for url: URL, streamIndex: Int = 0) async throws -> AudioMetadata {
        try await Task.detached(priority: .userInitiated) {
            let (status, info) = FFmpegShim.probe(url, streamIndex: streamIndex)
            try throwIfFailed(status, info: info, url: url)
            let kbps = Int((Double(info.bitRate) / 1000.0).rounded())
            return AudioMetadata(
                fileName:     url.lastPathComponent,
                codec:        displayCodec(codecName(of: info), url: url),
                sampleRate:   Double(info.sampleRate),
                bitDepth:     info.bitDepth > 0 ? Int(info.bitDepth) : nil,
                // Never negative, whatever a damaged header says: the menu
                // bar and the prefetch planner build `0..<channelCount` ranges.
                channelCount: max(0, Int(info.channelCount)),
                bitrate:      kbps > 0 ? kbps : nil,
                duration:     info.duration,
                streamCount:  max(Int(info.decodableStreamCount), 1)
            )
        }.value
    }

    /// The true sample rate and duration for `url`, from the decoded bitstream:
    /// opens the decoder far enough to decode the first frame (e.g. DTS 96/24 in
    /// a container that declares 48 kHz). Falls back to the metadata values if
    /// the decoder cannot be opened; the decode pass reports the real error.
    static func resolvedAudioInfo(
        url: URL,
        streamIndex: Int = 0,
        metadataSampleRate: Double,
        metadataDuration: Double
    ) async -> ResolvedAudioInfo {
        await Task.detached(priority: .userInitiated) {
            var info   = SPKFFmpegStreamInfo()
            var status = SPKFFmpegOK
            guard let decoder = FFmpegDecoder(url: url, streamIndex: streamIndex,
                                              info: &info, status: &status) else {
                return ResolvedAudioInfo(sampleRate: metadataSampleRate, duration: metadataDuration)
            }
            decoder.close()
            return ResolvedAudioInfo(sampleRate: Double(info.sampleRate),
                                     duration:   info.duration > 0 ? info.duration : metadataDuration)
        }.value
    }

    // MARK: - Segmented decoding policy

    /// Whitelist of codecs whose segmented decode matches a sequential one
    /// (each verified with the segmented-decode experiment harness): bit-identical
    /// for all but AC-3 / E-AC-3, whose decoders add per-instance dither noise —
    /// the same noise floor, but not bit-identical. AAC and MP1/2/3 are deliberately
    /// absent: the AAC decoder's perceptual-noise substitution and the MPEG audio
    /// decoder's state produce small non-reproducible differences, so those always
    /// decode sequentially. Vorbis, WavPack and DSD joined on 2026-10-07 together
    /// with their native containers (see SPKFFmpegIsSegmentable); every boundary
    /// is checked at run time either way (see "Boundary verification").
    private static let segmentableCodecs: Set<String> = [
        "DTS", "DTS-HD MA", "DTS-HD HRA", "DTS:X", "DTS:X IMAX", "DTS Express", "DTS 96/24", "DTS-ES",
        "TrueHD", "MLP", "FLAC", "ALAC", "PCM", "Opus", "AC3", "E-AC3",
        "Vorbis", "WavPack", "DSD", "DSD64", "DSD128", "DSD256", "DSD512",
    ]

    /// Codecs whose decoders add per-instance dither, so two decodes of the same
    /// audio never match bit for bit. Their boundaries are checked by timestamp
    /// only; every other codec's are also compared sample for sample.
    private static let ditheredCodecs: Set<String> = ["AC3", "E-AC3"]

    /// Shortest segment worth a seek plus 0.5 s of pre-roll decode (≤ 2%
    /// overhead at this length). Tracks shorter than two of these stay sequential.
    private static let minimumSegmentSeconds = 30.0

    /// Segments per worker to aim for. More, shorter segments make the in-order
    /// delivery finer-grained at a small pre-roll cost; eight is where the fill
    /// looks continuous.
    private static let segmentsPerWorker = 8

    /// Where each segment starts (seconds; `[0]` for a sequential decode) and
    /// how many worker threads to run. Blocking (opens the file briefly) — call
    /// off the main actor.
    ///
    /// ## Staggered first wave
    /// Segments are delivered to the pipeline in order, so the spectrogram
    /// advances only when the *earliest* unfinished segment completes. With
    /// equal segments, all `W` workers start together and finish together: the
    /// pipeline receives `W` segments in one burst, then nothing until the next
    /// wave — visibly choppy. Instead the first `W` segments ramp in length
    /// (`S/W, 2S/W, …, S`) and every later one is `S`. Worker `i` finishes its
    /// ramp segment at `i·S/W` decode-seconds and then takes segment `W+i`,
    /// finishing it at `(i/W + 1)·S`; so segment `k` completes at about
    /// `k·S/W` for every `k`, and the in-order frontier advances one segment
    /// every `S/W` — a steady stream at the pool's full throughput rather than
    /// bursts of `W`. (The ramp also puts the first column on screen sooner:
    /// the live-streamed segment 0 is now only `S/W` long.)
    ///
    /// ## Start offset
    /// Segment windows are on the stream's own timeline, which does not always
    /// begin at 0: an MPEG-TS stream from a Blu-ray commonly starts at 600 s.
    /// Laid out from 0, every boundary would fall before the first frame and
    /// segment 0 would be empty, abandoning the segmented decode at once (an
    /// 8× speed-up lost on a 60-min TrueHD M2TS, measured 2026-10-07). The plan is
    /// therefore laid out over `[0, duration)` and shifted by `startTime`.
    /// Negative start times (MP4 edit lists) are left alone: segment 0 already
    /// opens from the first frame, whatever its timestamp.
    private static func segmentPlan(url: URL, codec: String, duration: Double,
                                    startTime: Double) -> (starts: [Double], workers: Int) {
        let sequential: ([Double], Int) = ([0], 1)
        guard segmentableCodecs.contains(codec), duration >= 2 * minimumSegmentSeconds else { return sequential }
        guard FFmpegShim.isSegmentable(url) else {
            log("\(url.lastPathComponent): not segmentable (no seek index or unknown duration) — sequential decode.")
            return sequential
        }
        // Leave one core for the pipeline's consumer, the FFT batches and the UI.
        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        let full    = max(minimumSegmentSeconds, duration / Double(workers * segmentsPerWorker))

        var starts: [Double] = [0]
        var index = 0
        while true {
            let length    = index < workers ? full * Double(index + 1) / Double(workers) : full
            let next      = starts[index] + length
            // The last segment absorbs any remainder shorter than half a
            // segment rather than leaving a stub worth less than its seek.
            if next + full / 2 > duration { break }
            starts.append(next)
            index += 1
        }
        guard starts.count >= 2 else { return sequential }
        // `starts[0]` stays 0: the first segment opens from the stream's beginning.
        let offset = startTime.isFinite ? max(0, startTime) : 0
        if offset > 0 {
            for k in starts.indices.dropFirst() { starts[k] += offset }
        }
        return (starts, min(workers, starts.count))
    }

    // MARK: - Streaming decode

    /// One decoded chunk: element `i` holds the samples of the `i`-th requested
    /// channel, all of the same length.
    typealias Chunk = [[Float]]

    /// Decode the file into Float32 sample chunks of each channel in `channels`
    /// (indices into the stream's channels, clamped to its count; empty means
    /// channel 0) from the decodable audio stream at `streamIndex`, streamed
    /// through an `AsyncThrowingStream` so the caller can begin FFT processing
    /// before the whole file has been read. Every requested channel comes out
    /// of the same decode pass — asking for six channels costs one decode, not
    /// six. Chunks are in order; the final one may be short.
    /// `throttle` is the CPU budget the run works under (see PipelineThrottle):
    /// it sets the decoder threads' QoS, how many segment workers may run at
    /// once, and can pause the decode between chunks.
    static func streamingDecode(
        url: URL,
        channels: [Int] = [0],
        streamIndex: Int = 0,
        throttle: PipelineThrottle = .unlimited
    ) -> AsyncThrowingStream<Chunk, any Error> {
        let channels = channels.isEmpty ? [0] : channels
        return AsyncThrowingStream { continuation in
            // Cooperative cancellation shared by every decoder thread: set when
            // the consumer stops iterating (the pipeline exits early once all
            // columns are computed, or the analysis is canceled).
            let canceled = OSAllocatedUnfairLock(initialState: false)
            continuation.onTermination = { _ in canceled.withLock { $0 = true } }

            Task.detached(priority: throttle.taskPriority) {
                await runDecode(url: url, streamIndex: streamIndex, channels: channels,
                                throttle: throttle, continuation: continuation, canceled: canceled)
            }
        }
    }

    /// Body of `streamingDecode`, kept as a separate function so the stream
    /// closure stays small enough for the type checker.
    private static func runDecode(
        url: URL, streamIndex: Int, channels: [Int], throttle: PipelineThrottle,
        continuation: AsyncThrowingStream<Chunk, any Error>.Continuation,
        canceled: OSAllocatedUnfairLock<Bool>
    ) async {
        // Probe once for codec + duration so the segment plan can be
        // decided before any decoder is opened.
        let (probeStatus, probe) = FFmpegShim.probe(url, streamIndex: streamIndex)
        do { try throwIfFailed(probeStatus, info: probe, url: url) }
        catch { continuation.finish(throwing: error); return }

        let codec   = codecName(of: probe)
        let plan     = segmentPlan(url: url, codec: codec, duration: probe.duration,
                                   startTime: probe.startTime)
        let segments = plan.starts.count
        let version  = FFmpegShim.versionString
        let planText = segments > 1
            ? "\(segments) segments on \(plan.workers) worker threads"
                + (throttle.decodeWorkerCap < plan.workers ? " (\(throttle.decodeWorkerCap) active)" : "")
            : "sequential"
        log("Decoding \(url.lastPathComponent) stream=\(streamIndex) channels=\(channels) "
            + "[\(codec), \(probe.sampleRate) Hz, \(probe.channelCount) ch] via libavcodec \(version) — \(planText).")

        if segments == 1 {
            await decodeSequentially(url: url, streamIndex: streamIndex, channels: channels, skip: 0,
                                     throttle: throttle, canceled: canceled, into: continuation)
            return
        }

        // Segmented. A boundary that fails verification hands the rest of the
        // stream to one sequential decoder. That runs only after
        // `decodeInSegments` has returned: segments the workers finished but
        // nobody read still hold their chunks (finishing a stream keeps what it
        // buffered), and all of them go when its locals do, rather than staying
        // in memory for the whole sequential re-decode.
        guard let skip = await decodeInSegments(url: url, streamIndex: streamIndex, channels: channels,
                                                codec: codec, plan: plan, throttle: throttle,
                                                canceled: canceled, into: continuation) else {
            continuation.finish()
            return
        }
        await decodeSequentially(url: url, streamIndex: streamIndex, channels: channels,
                                 skip: skip, throttle: throttle,
                                 canceled: canceled, into: continuation)
    }

    /// The segmented decode: worker threads fill one stream per segment, and
    /// the segments are verified and forwarded to `continuation` in order.
    /// Returns nil when the stream was delivered in full (or the run was
    /// canceled), otherwise how many samples per channel were delivered before
    /// a boundary failed — where the caller's sequential fallback resumes.
    /// Never finishes `continuation`; the caller does.
    private static func decodeInSegments(
        url: URL, streamIndex: Int, channels: [Int], codec: String,
        plan: (starts: [Double], workers: Int), throttle: PipelineThrottle,
        canceled: OSAllocatedUnfairLock<Bool>,
        into continuation: AsyncThrowingStream<Chunk, any Error>.Continuation
    ) async -> Int? {
        let segments = plan.starts.count

        // Segmented: one unbounded stream per segment, filled by a pool of
        // worker threads that take segments from the queue in order. The
        // consumer below drains the streams in order — the segment being
        // decoded right now streams live; the ones the workers have already
        // finished are handed over in full. Memory peaks near one track per
        // requested channel, as it does for the sequential path once the
        // pipeline has buffered the file.
        let clock = ContinuousClock.now
        var streams: [AsyncThrowingStream<Chunk, any Error>] = []
        var sinks:   [AsyncThrowingStream<Chunk, any Error>.Continuation] = []
        var states:  [SegmentState] = []
        for _ in 0..<segments {
            let (stream, sink) = AsyncThrowingStream.makeStream(of: Chunk.self, bufferingPolicy: .unbounded)
            streams.append(stream); sinks.append(sink); states.append(SegmentState())
        }
        // Set when a boundary fails verification: the workers stop and the
        // rest of the stream is decoded sequentially instead.
        let abandoned = OSAllocatedUnfairLock(initialState: false)
        let workersShouldStop: @Sendable () -> Bool = {
            canceled.withLock { $0 } || abandoned.withLock { $0 }
        }
        let queue = OSAllocatedUnfairLock(initialState: 0)   // next segment index to decode
        let sinksForWorkers  = sinks
        let statesForWorkers = states
        for w in 0..<plan.workers {
            let thread = Thread {
                while !workersShouldStop() {
                    let k = queue.withLock { next -> Int in defer { next += 1 }; return next }
                    guard k < segments else { break }
                    // A background run caps how many workers decode at once; the
                    // rest wait here and start the moment the cap is lifted.
                    throttle.acquireDecodeSlot()
                    // A run canceled while this worker waited for its slot: leave
                    // without opening a decoder (a seek plus a first-frame decode)
                    // the consumer would never read from.
                    if workersShouldStop() { throttle.releaseDecodeSlot(); break }
                    decodeSegment(url: url, streamIndex: streamIndex, channels: channels,
                                  start: plan.starts[k],
                                  end:   k == segments - 1 ? 0 : plan.starts[k + 1],
                                  worker: true, skip: 0, throttle: throttle,
                                  shouldStop: workersShouldStop, state: statesForWorkers[k],
                                  into: sinksForWorkers[k])
                    throttle.releaseDecodeSlot()
                }
                // On cancellation, segments no worker will start again are
                // never finished by `decodeSegment`, and the consumer below
                // may be waiting on one of them; it would then never return,
                // pinning every segment decoded so far in memory. Finish them
                // all (finishing a finished sink is a no-op, and a worker still
                // mid-segment only loses yields nobody reads).
                if workersShouldStop() {
                    for sink in sinksForWorkers { sink.finish() }
                }
            }
            thread.name = "AudioDecoder worker \(w + 1)"
            // Below the pipeline's .userInitiated so FFT batches and rendering
            // win when the machine is saturated; still eligible for every core.
            // A background run's workers sit lower still (.utility); each
            // re-applies the throttle's QoS per chunk, so a promotion lifts it.
            thread.qualityOfService = workerQoS(for: throttle)
            thread.start()
        }

        // ── In-order delivery with boundary verification ─────────────────────
        var verifier = BoundaryVerifier(channelCount: channels.count,
                                        compareSamples: !ditheredCodecs.contains(codec))
        var fallbackReason: String?
        segmentLoop: for k in 0..<segments {
            if canceled.withLock({ $0 }) { break }
            var iterator = streams[k].makeAsyncIterator()
            var firstChunk = true
            while true {
                let chunk: Chunk?
                do { chunk = try await iterator.next() }
                catch {
                    // A segment failing where a sequential decode might not (a
                    // seek gone wrong): the caller's sequential fallback either
                    // gets past it or reports the real error.
                    fallbackReason = "segment \(k) failed (\(error.localizedDescription))"
                    break segmentLoop
                }
                guard let chunk else { break }
                if firstChunk {
                    firstChunk = false
                    if k > 0, let problem = verifier.checkStart(of: k, at: plan.starts[k], firstChunk: chunk,
                                                                state: states[k]) {
                        fallbackReason = problem
                        break segmentLoop
                    }
                }
                verifier.deliver(chunk)
                continuation.yield(chunk)
            }
            if canceled.withLock({ $0 }) { break }
            if let problem = verifier.checkEnd(of: k, at: plan.starts[k], isLast: k == segments - 1,
                                               state: states[k]) {
                fallbackReason = problem
                break segmentLoop
            }
        }
        if let reason = fallbackReason, !canceled.withLock({ $0 }) {
            abandoned.withLock { $0 = true }
            for sink in sinks { sink.finish() }
            log("segmented decode of \(url.lastPathComponent) abandoned — \(reason). "
                + "Continuing sequentially from sample \(verifier.delivered) "
                + "(\(verifier.boundariesVerified) boundaries had verified).")
            return verifier.delivered
        }
        let elapsed = clock.duration(to: .now)
        if canceled.withLock({ $0 }) {
            log("segmented decode canceled — \(verifier.delivered) samples delivered in \(elapsed).")
        } else {
            log("segmented decode complete — \(verifier.delivered) samples in \(elapsed); "
                + "\(verifier.boundariesVerified) boundaries verified"
                + (verifier.compareSamples ? " sample for sample." : " by timestamp."))
        }
        return nil
    }

    /// One decoder on one thread from the start of the stream, its chunks
    /// forwarded to `continuation` as read. `skip` samples per channel are
    /// decoded and dropped first — the fallback's way of resuming exactly where
    /// a segmented decode left off.
    private static func decodeSequentially(
        url: URL, streamIndex: Int, channels: [Int], skip: Int, throttle: PipelineThrottle,
        canceled: OSAllocatedUnfairLock<Bool>,
        into continuation: AsyncThrowingStream<Chunk, any Error>.Continuation
    ) async {
        let (stream, sink) = AsyncThrowingStream.makeStream(of: Chunk.self, bufferingPolicy: .unbounded)
        let thread = Thread {
            decodeSegment(url: url, streamIndex: streamIndex, channels: channels,
                          start: 0, end: 0, worker: false, skip: skip, throttle: throttle,
                          shouldStop: { canceled.withLock { $0 } }, state: nil, into: sink)
        }
        thread.name = skip > 0 ? "AudioDecoder sequential fallback" : "AudioDecoder sequential"
        thread.qualityOfService = throttle.threadQoS   // re-applied per chunk in decodeSegment
        thread.start()
        do {
            for try await chunk in stream { continuation.yield(chunk) }
            continuation.finish()
        } catch { continuation.finish(throwing: error) }
    }

    /// Decode one time window of the stream into `sink`, synchronously on the
    /// calling thread. `start == 0` opens the whole stream from its beginning;
    /// `end == 0` means to end of stream. `skip` samples per channel are dropped
    /// before anything is yielded. `state`, for a segment of a segmented
    /// decode, receives the segment's report once it is open (before the first
    /// chunk is yielded) and again when it ends (before the sink finishes), for
    /// the consumer's boundary checks.
    ///
    /// `worker` selects the pool workers' QoS (see `workerQoS`) over the
    /// sequential thread's.
    ///
    /// Runs on plain `Thread`s, never on a `Task`: the loop blocks inside
    /// libavcodec for seconds at a time, and with one decoder per core that
    /// would occupy every thread of Swift's cooperative pool — starving the
    /// pipeline's consumer, its FFT batches and the UI until decoding finished
    /// (measured: nothing rendered until ~50% done). Kernel threads are
    /// preempted like any other work, so chunks reach the pipeline as soon as
    /// they are decoded and the spectrogram starts filling immediately.
    private static func decodeSegment(
        url: URL, streamIndex: Int, channels: [Int],
        start: Double, end: Double, worker: Bool, skip: Int, throttle: PipelineThrottle,
        shouldStop: @Sendable () -> Bool, state: SegmentState?,
        into sink: AsyncThrowingStream<Chunk, any Error>.Continuation
    ) {
        var info   = SPKFFmpegStreamInfo()
        var status = SPKFFmpegOK
        let segment: (start: Double, end: Double)? = start > 0 || end > 0 ? (start, end) : nil
        guard let decoder = FFmpegDecoder(url: url, streamIndex: streamIndex, segment: segment,
                                          info: &info, status: &status) else {
            if status == SPKFFmpegErrorSeekFailed {
                sink.finish(throwing: DecoderError.decodeFailed(detail: "seek to \(Int(start)) s failed"))
                return
            }
            do    { try throwIfFailed(status, info: info, url: url)
                    sink.finish(throwing: DecoderError.cannotReadSamples) }
            catch { sink.finish(throwing: error) }
            return
        }
        // `decoder` closes itself when it goes out of scope.
        state?.recordOpening(report: decoder.segmentReport,
                             prerollTails: channels.map { decoder.prerollTail(channel: $0) },
                             sampleRate: Double(info.sampleRate))

        // One region of `chunkFrameCount` floats per requested channel.
        var buffer = [Float](repeating: 0, count: chunkFrameCount * channels.count)
        var toSkip = skip
        var appliedQoS = Thread.current.qualityOfService
        while !shouldStop() {
            throttle.blockWhilePaused()
            if shouldStop() { break }
            // A promoted run raises its threads' QoS from here; a QoS change is
            // a syscall, so only apply it when it actually differs.
            let wantedQoS = worker ? workerQoS(for: throttle) : throttle.threadQoS
            if wantedQoS != appliedQoS {
                Thread.current.qualityOfService = wantedQoS
                appliedQoS = wantedQoS
            }
            let n = decoder.read(channels: channels, capacity: chunkFrameCount, into: &buffer)
            if n < 0 {
                sink.finish(throwing: DecoderError.decodeFailed(
                    detail: "libavcodec could not decode the \(codecName(of: info)) stream"))
                return
            }
            if n == 0 { break }
            let from = min(toSkip, n)
            toSkip -= from
            guard from < n else { continue }
            sink.yield(channels.indices.map { c in
                Array(buffer[c * chunkFrameCount + from ..< c * chunkFrameCount + n])
            })
        }
        state?.recordEnd(report: decoder.segmentReport,
                         postrollHeads: channels.map { decoder.postrollHead(channel: $0) })
        sink.finish()
    }

    /// The QoS for a segment worker under `throttle`: one notch below a
    /// foreground run's `.userInitiated` (see the worker-thread comment in
    /// `runDecode`), the throttle's own QoS otherwise.
    private static func workerQoS(for throttle: PipelineThrottle) -> QualityOfService {
        throttle.isForeground ? .default : throttle.threadQoS
    }

    // MARK: - Boundary verification
    //
    // Segmented decoding relies on two things a container could get wrong: that
    // a seek lands early enough for the decoder to warm up, and that frame
    // timestamps after a seek agree with a sequential decode's, so that
    // contiguous windows partition the frames exactly once. Both were verified
    // for every whitelisted container, but only on the files at hand — so every
    // run also checks each boundary as it is crossed, before any of the new
    // segment's audio is passed on:
    //
    //   • no frame of either segment lacked a timestamp;
    //   • the new segment's decoder started at least `minimumWarmup` before the
    //     boundary (the seek did not overshoot);
    //   • the audio the new segment decoded as warm-up just before the boundary
    //     is bit-identical to the end of what the previous segment delivered,
    //     and the audio the previous segment's decoder went on to produce past
    //     its end (decoded, never delivered) is bit-identical to the new
    //     segment's first samples — the same stretches decoded twice must come
    //     out the same, from both sides of the join, which only happens if the
    //     new segment starts at exactly the right sample and its decoder has
    //     caught up with the previous one's state (a decoder whose state drifts
    //     only after the boundary, like AAC's noise substitution, fails here);
    //   • the new segment's first frame starts where the previous one's last
    //     frame ended: to within a sample (or one tick of the stream's clock)
    //     wherever the audio comparison cannot decide — the dithered AC-3
    //     family, whose decoders never repeat themselves, or a boundary in
    //     digital silence, where any offset would "match" — and to within
    //     `timestampJitter` once the comparison has passed. (Ogg Vorbis frame
    //     timestamps after a seek are interpolated within a page and measured
    //     10 ms off on a real file whose audio joined up exactly.)
    //
    // A later segment that turns out empty is accepted only if its decoder
    // really ran out of stream (a container that overstates its duration).
    // Anything else abandons the segmented decode: the workers stop and the
    // rest of the stream is decoded sequentially from the first sample not yet
    // delivered — slower, but exactly what a sequential decode produces, and
    // everything delivered before the failed boundary was itself verified.

    /// Least warm-up a segment's decoder must have had before its boundary.
    private static let minimumWarmup = 0.2

    /// Fewest overlapping samples worth comparing per channel.
    private static let minimumCompareSamples = 256

    /// How far a segment's first timestamp may sit from the previous segment's
    /// last frame end when the audio comparison has proven the join exact.
    private static let timestampJitter = 0.05

    /// What one segment's decoder reported, written by its worker thread and
    /// read by the consumer once the segment's first chunk (or its end) has
    /// arrived — the stream's own synchronization orders the two.
    final class SegmentState: Sendable {
        struct Opening: Sendable {
            let report:       SPKFFmpegSegmentReport
            let prerollTails: [[Float]]
            let sampleRate:   Double
        }
        private let opening = OSAllocatedUnfairLock<Opening?>(initialState: nil)
        struct Ending: Sendable {
            let report:        SPKFFmpegSegmentReport
            let postrollHeads: [[Float]]
        }
        private let ending  = OSAllocatedUnfairLock<Ending?>(initialState: nil)

        func recordOpening(report: SPKFFmpegSegmentReport, prerollTails: [[Float]], sampleRate: Double) {
            opening.withLock { $0 = Opening(report: report, prerollTails: prerollTails, sampleRate: sampleRate) }
        }
        func recordEnd(report: SPKFFmpegSegmentReport, postrollHeads: [[Float]]) {
            ending.withLock { $0 = Ending(report: report, postrollHeads: postrollHeads) }
        }
        var openingReport: Opening? { opening.withLock { $0 } }
        var endReport: Ending? { ending.withLock { $0 } }
    }

    /// The consumer's side of the checks: what has been delivered so far, and
    /// the end of the last frame it came from.
    struct BoundaryVerifier {
        let compareSamples: Bool
        private(set) var delivered = 0
        private(set) var boundariesVerified = 0
        /// The last delivered samples of each channel, up to `tailCapacity`.
        private var tails: [[Float]]
        /// End time of the last delivered frame, from the last non-empty segment.
        private var lastEnd: Double?
        /// A segment ended without a trustworthy timestamp on every frame.
        private var lastEndUntrusted = false
        /// What the last non-empty segment's decoder produced past its end.
        private var postrollHeads: [[Float]] = []
        /// `delivered` when the current segment began.
        private var deliveredBeforeSegment = 0
        private static let tailCapacity = 4096

        init(channelCount: Int, compareSamples: Bool) {
            self.compareSamples = compareSamples
            tails = Array(repeating: [], count: channelCount)
        }

        mutating func deliver(_ chunk: Chunk) {
            guard let n = chunk.first?.count, n > 0 else { return }
            delivered += n
            for c in tails.indices where c < chunk.count {
                if n >= Self.tailCapacity {
                    tails[c] = Array(chunk[c].suffix(Self.tailCapacity))
                } else {
                    tails[c].append(contentsOf: chunk[c])
                    if tails[c].count > Self.tailCapacity {
                        tails[c].removeFirst(tails[c].count - Self.tailCapacity)
                    }
                }
            }
        }

        /// Checks segment `k`'s start against what has been delivered; nil when
        /// it joins up, otherwise why not.
        mutating func checkStart(of k: Int, at start: Double, firstChunk: Chunk, state: SegmentState) -> String? {
            guard let opening = state.openingReport else { return "segment \(k) reported nothing" }
            let r = opening.report
            if lastEndUntrusted { return "a frame before segment \(k) had no timestamp" }
            if r.missingTimestamps != 0 { return "a frame at segment \(k)'s start had no timestamp" }
            guard r.firstDecodedTime.isFinite, r.firstKeptTime.isFinite else {
                return "segment \(k) has no timestamps"
            }
            if r.firstDecodedTime > start - AudioDecoder.minimumWarmup {
                return "segment \(k)'s seek landed at \(r.firstDecodedTime.fixed(3)) s, "
                    + "too late to warm up for \(start.fixed(3)) s"
            }
            guard let lastEnd else { return "no frame end before segment \(k)" }
            // Whether the sample comparison proved the join: it ran, matched,
            // and saw real signal (constant audio matches at any offset).
            var provenBySamples = false
            if compareSamples {
                var compared = 0, informative = false
                for c in tails.indices {
                    let preroll = opening.prerollTails[c]
                    let ours    = tails[c]
                    let m = min(preroll.count, ours.count)
                    // The shim keeps warm-up audio for the first 16 channels only.
                    if preroll.isEmpty { continue }
                    if m < AudioDecoder.minimumCompareSamples {
                        return "only \(m) warm-up samples before segment \(k) to compare"
                    }
                    let theirs = preroll.suffix(m), mine = ours.suffix(m)
                    if !theirs.elementsEqual(mine, by: { $0.bitPattern == $1.bitPattern }) {
                        return "segment \(k)'s warm-up audio differs from the previous segment's end"
                    }
                    if let first = mine.first, mine.contains(where: { $0 != first }) { informative = true }
                    compared += 1
                }
                if compared == 0 { return "no warm-up audio to compare before segment \(k)" }
                // The other side of the join: the previous decoder's post-roll
                // against this segment's first samples.
                compared = 0
                for c in postrollHeads.indices where c < firstChunk.count {
                    let post = postrollHeads[c]
                    if post.isEmpty { continue }   // a channel past the first 16
                    let m = min(post.count, firstChunk[c].count)
                    if m < AudioDecoder.minimumCompareSamples {
                        return "only \(m) samples after the boundary before segment \(k) to compare"
                    }
                    let mine = firstChunk[c].prefix(m)
                    if !post.prefix(m).elementsEqual(mine, by: { $0.bitPattern == $1.bitPattern }) {
                        return "segment \(k)'s first samples differ from what the previous segment's decoder produced there"
                    }
                    if let first = mine.first, mine.contains(where: { $0 != first }) { informative = true }
                    compared += 1
                }
                if compared == 0 { return "no audio past the previous segment's end to compare with segment \(k)" }
                provenBySamples = informative
            }
            let rate = opening.sampleRate > 0 ? opening.sampleRate : 48_000
            let tolerance = provenBySamples ? AudioDecoder.timestampJitter
                                            : max(2 * r.timeBaseSeconds, 2 / rate)
            let offset = r.firstKeptTime - lastEnd
            if abs(offset) > tolerance {
                return "segment \(k) starts \((offset * 1000).fixed(3)) ms "
                    + "\(offset > 0 ? "after" : "before") the previous one ends"
                    + (compareSamples && !provenBySamples ? " (silent boundary, timestamps must agree)" : "")
            }
            boundariesVerified += 1
            return nil
        }

        /// Checks segment `k` after its last chunk. An empty segment is fine
        /// only where the stream really ended.
        mutating func checkEnd(of k: Int, at start: Double, isLast: Bool, state: SegmentState) -> String? {
            guard let ending = state.endReport else {
                return "segment \(k) ended without a report"
            }
            let r = ending.report
            defer { deliveredBeforeSegment = delivered }
            if r.firstKeptTime.isFinite {
                lastEnd = r.keptEndTime
                lastEndUntrusted = r.missingTimestamps != 0
                postrollHeads = ending.postrollHeads
                return nil
            }
            if delivered > deliveredBeforeSegment {
                return "segment \(k) delivered audio without timestamps"
            }
            // Nothing in the window.
            if k == 0 { return "the first segment decoded nothing" }
            guard r.reachedEndOfStream != 0, r.missingTimestamps == 0,
                  !r.firstDecodedTime.isFinite || r.firstDecodedTime <= start else {
                return "segment \(k) is empty but the stream did not end there"
            }
            return nil
        }
    }

    // MARK: - Helpers

    /// Map a shim status onto the `DecoderError` categories the ViewModel handles.
    private static func throwIfFailed(_ status: SPKFFmpegStatus, info: SPKFFmpegStreamInfo, url: URL) throws {
        switch status {
        case SPKFFmpegOK:                 return
        case SPKFFmpegErrorNoAudioTrack:  throw DecoderError.noAudioTrack
        case SPKFFmpegErrorNoDecoder:
            let names = codecName(of: info)
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            throw DecoderError.incompatibleStreams(names)
        case SPKFFmpegErrorDecodeFailed:  throw DecoderError.cannotReadSamples
        case SPKFFmpegErrorCannotOpen:
            // A file whose extension names a supported container but which
            // libavformat still cannot parse is damaged or misnamed — "cannot
            // open" is the honest message. Anything else is an unsupported format.
            let ext = url.pathExtension.lowercased()
            guard FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)),
                  !supportedContainerExtensions.contains(ext) else {
                throw DecoderError.cannotOpenFile(url)
            }
            throw DecoderError.unsupportedContainer(containerDisplayName(ext))
        default:                          throw DecoderError.cannotOpenFile(url)
        }
    }

    /// Extensions of every container the bundled FFmpeg build can demux (see
    /// ThirdParty/FFmpeg/build-ffmpeg.sh). Used only to word the error for a
    /// file that names one of these but fails to parse.
    private static let supportedContainerExtensions: Set<String> = [
        "flac", "mp3", "aac", "wav", "wave", "aif", "aiff", "aifc", "caf",
        "opus", "ogg", "oga", "ac3", "eac3", "dts", "thd", "mlp", "wv", "dsf", "dff",
        "m4a", "m4v", "mp4", "mov", "mkv", "mka", "webm", "avi", "wmv", "wma", "asf",
        "ts", "m2ts", "mts",
    ]

    /// Codec label for the metadata bar. Uncompressed audio is labeled by its
    /// container ("WAV", "AIFF", "CAF") because that is how users know those
    /// files; inside a media container it is simply "PCM".
    private static func displayCodec(_ codec: String, url: URL) -> String {
        guard codec == "PCM" else { return codec }
        switch url.pathExtension.lowercased() {
        case "wav", "wave":  return "WAV"
        case "aif", "aiff":  return "AIFF"
        case "aifc":         return "AIFC"
        case "caf":          return "CAF"
        default:             return "PCM"
        }
    }

    /// Human-readable container name for an "unsupported container" alert —
    /// only ever an extension outside `supportedContainerExtensions`.
    private static func containerDisplayName(_ ext: String) -> String {
        ext.isEmpty ? "Unknown" : ext.uppercased()
    }

    /// `codecName` imports as a tuple of 64 CChars; read it as a C string.
    /// Reads up to the first NUL but never past the 64-byte field, so a name
    /// the shim failed to terminate cannot overrun into the next field. The
    /// tuple is walked with `Mirror` rather than viewed as raw bytes: it runs
    /// a handful of times per file, where the cost is immaterial, and needs
    /// no opt-out of strict memory safety.
    private static func codecName(of info: SPKFFmpegStreamInfo) -> String {
        let bytes = Mirror(reflecting: info.codecName).children
            .lazy
            .compactMap { $0.value as? CChar }
            .prefix { $0 != 0 }
            .map { UInt8(bitPattern: $0) }
        return String(decoding: Array(bytes), as: UTF8.self)
    }
}

// MARK: - FFmpeg shim boundary
//
// The only code that touches FFmpegShim.h's pointers. Paths go in as their
// file-system representation for the duration of one call, stream info comes
// back by value, and decoder handles are owned by `FFmpegDecoder`, so the rest
// of AudioDecoder works with Swift values only.

private enum FFmpegShim {
    static func probe(_ url: URL, streamIndex: Int) -> (status: SPKFFmpegStatus, info: SPKFFmpegStreamInfo) {
        var info = SPKFFmpegStreamInfo()
        let status = unsafe url.withUnsafeFileSystemRepresentation {
            unsafe SPKFFmpegProbe($0, Int32(streamIndex), &info)
        }
        return (status, info)
    }

    static func isSegmentable(_ url: URL) -> Bool {
        unsafe url.withUnsafeFileSystemRepresentation { unsafe SPKFFmpegIsSegmentable($0) } == 1
    }

    /// The shim returns a pointer to a static C string, the one remaining way
    /// to read it; it never changes, so it is read once.
    static let versionString: String = unsafe String(cString: SPKFFmpegVersionString())
}

/// An open shim decoder. Noncopyable, so exactly one owner closes the handle —
/// in `deinit` — and it cannot be used after closing or closed twice.
///
/// `@safe`: the handle is private, valid from a successful open until
/// `deinit`, and `read` sizes every call from the destination array.
@safe
private struct FFmpegDecoder: ~Copyable {
    private let handle: OpaquePointer

    /// Opens stream `streamIndex` of `url` — the whole stream, or only
    /// `segment` (start and end, in seconds). Returns nil when the shim does;
    /// `status` then holds the reason. `info` is filled either way.
    init?(url: URL, streamIndex: Int, segment: (start: Double, end: Double)? = nil,
          info: inout SPKFFmpegStreamInfo, status: inout SPKFFmpegStatus) {
        let opened = unsafe url.withUnsafeFileSystemRepresentation { path in
            if let segment {
                unsafe SPKFFmpegOpenSegment(path, Int32(streamIndex), segment.start, segment.end,
                                            &info, &status)
            } else {
                unsafe SPKFFmpegOpen(path, Int32(streamIndex), &info, &status)
            }
        }
        guard let opened = unsafe opened else { return nil }
        unsafe handle = opened
    }

    deinit { unsafe SPKFFmpegClose(handle) }

    /// Closes the decoder now rather than at the end of the owner's scope.
    consuming func close() {}

    /// Decodes up to `capacity` frames of every channel in `channels` into
    /// `buffer`, channel `channels[i]` at offset `i × capacity` (`buffer` holds at
    /// least `channels.count × capacity` floats). Returns the frame count, 0 at
    /// end of stream, negative on error.
    func read(channels: [Int], capacity: Int, into buffer: inout [Float]) -> Int {
        precondition(!channels.isEmpty && capacity > 0 && buffer.count >= channels.count * capacity)
        let indices = channels.map { Int32(clamping: $0) }
        return Int(unsafe buffer.withUnsafeMutableBufferPointer { flat in
            // Every pointer lies inside `flat`, at the start of its channel's region.
            let outs = unsafe indices.indices.map { unsafe Optional(flat.baseAddress! + $0 * capacity) }
            return unsafe outs.withUnsafeBufferPointer { outPtrs in
                unsafe indices.withUnsafeBufferPointer { idx in
                    unsafe SPKFFmpegReadChannels(handle, idx.baseAddress, Int32(idx.count),
                                                 outPtrs.baseAddress, Int32(clamping: capacity))
                }
            }
        })
    }

    /// How this decoder's segment window lined up with the stream so far.
    var segmentReport: SPKFFmpegSegmentReport {
        var report = SPKFFmpegSegmentReport()
        unsafe SPKFFmpegGetSegmentReport(handle, &report)
        return report
    }

    /// The audio of `channel` decoded past the segment's end but not delivered
    /// (empty for a segment that ran to the end of the stream).
    func postrollHead(channel: Int) -> [Float] {
        var out = [Float](repeating: 0, count: 16384)
        let n = unsafe out.withUnsafeMutableBufferPointer {
            unsafe SPKFFmpegPostrollHead(handle, Int32(clamping: channel), $0.baseAddress, Int32($0.count))
        }
        return Array(out.prefix(Int(max(0, n))))
    }

    /// The warm-up audio of `channel` decoded just before the segment's first
    /// kept frame (empty for a decoder opened at the start of the stream).
    func prerollTail(channel: Int) -> [Float] {
        var out = [Float](repeating: 0, count: 4096)
        let n = unsafe out.withUnsafeMutableBufferPointer {
            unsafe SPKFFmpegPrerollTail(handle, Int32(clamping: channel), $0.baseAddress, Int32($0.count))
        }
        return Array(out.prefix(Int(max(0, n))))
    }
}
