// MARK: - AnalysisJob.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// One pipeline run — foreground (the user is watching it fill) or background (a speculative
// prefetch of another channel or stream, which also computes the stream's other uncached channels
// from the same decode). The ViewModel owns at most one of each. Every job
// records what the pipeline has emitted so far, so a background job the user selects can be
// adopted mid-run: the ViewModel replays the recorded metadata and columns into a fresh image,
// takes over the remaining events, and lifts the job's CPU budget to full.

import Foundation

/// Uniquely identifies a set of computed magnitude columns within the current
/// file session. Two analysis runs with the same key produce identical FFT
/// output, so the second run can be skipped entirely and served from cache.
///
/// The key captures every parameter that affects decoded samples or FFT
/// computation — and only those. The pipeline always computes all `fftSize / 2`
/// bands up to the file's own Nyquist, so the palette, the dB range and the
/// frequency-axis clamp are all display-time mappings that `recolorFromCache`
/// re-applies over cached magnitudes at negligible cost. Output dimensions are
/// not part of the key either; the window is fixed and its dimensions never
/// change within a session.
///
/// - `streamIndex` / `channelIndex`: which audio data is decoded.
/// - `fftBits` / `windowFunction`: DSP parameters that determine FFT output.
///
/// The cache itself is scoped to the currently loaded file — it is wiped
/// entirely in `analyze(url:)` whenever a new file is opened, so entries from
/// a previous file are never present during a subsequent session.
struct MagnitudeCacheKey: Hashable, Sendable {
    let streamIndex:     Int
    let channelIndex:    Int
    let fftBits:         Int
    let windowFunction:  WindowFunction

    /// The same stream/channel under the same DSP parameters.
    func with(streamIndex: Int, channelIndex: Int) -> MagnitudeCacheKey {
        MagnitudeCacheKey(streamIndex: streamIndex, channelIndex: channelIndex,
                          fftBits: fftBits, windowFunction: windowFunction)
    }
}

/// What a foreground run needs to render: the values `startAnalysis()` captured when it
/// built the `ImageBuilder`, so the `.metadata` handler can tell whether the builder was
/// seeded with a placeholder ratio and must be rebuilt.
struct ForegroundRunContext {
    let settings:  SpectrogramSettings
    let effective: Double?
    let actual:    Double?
    let width:     Int
    let height:    Int
}

/// A single pipeline run and everything it has emitted so far.
@MainActor
final class AnalysisJob: Loggable {
    nonisolated static let logTag = "[AnalysisJob]"

    let key:      MagnitudeCacheKey
    let settings: SpectrogramSettings
    let url:      URL
    let throttle: PipelineThrottle
    /// The ViewModel's file session this run belongs to. A `.complete` is only cached while
    /// its session is still current: a run canceled by a new open can still deliver one, and
    /// its columns belong to the previous file.
    let session:  Int

    /// Set when the ViewModel is rendering this job; `nil` while it is a background prefetch.
    var foreground: ForegroundRunContext?

    /// Further channels of `key`'s stream computed in the same pass (see
    /// `AnalysisPipeline.analyze`); each arrives as a `.companion` event.
    let companionChannels: [Int]

    /// The latest `.metadata` (the pipeline may emit a corrected one after the first).
    private(set) var metadata: AudioMetadata?
    /// Every column emitted so far, in emission order. An adopter replays them into a fresh
    /// image, and a foreground run whose display mapping changes mid-run (a frequency-axis
    /// clamp change) repaints the ones already on screen into a rebuilt builder.
    private(set) var columns: [PipelineColumn] = []
    private(set) var fraction: Double = 0

    private var task: Task<Void, Never>?
    private(set) var isCanceled = false

    init(key: MagnitudeCacheKey, settings: SpectrogramSettings, url: URL, session: Int,
         throttle: PipelineThrottle, foreground: ForegroundRunContext?,
         companionChannels: [Int] = []) {
        self.key        = key
        self.companionChannels = companionChannels
        self.settings   = settings
        self.url        = url
        self.session    = session
        self.throttle   = throttle
        self.foreground = foreground
    }

    var isBackground: Bool { foreground == nil }

    /// Run the pipeline and deliver each event to `handler` on the main actor.
    ///
    /// After `cancel()`, every event except the results (`.companion` and `.complete`) is
    /// dropped: the newer job that superseded this one owns rendering. Results are still
    /// delivered so a run that finished just as it was canceled lands in the magnitude
    /// cache — the work is never wasted. Cancellation ends the stream, so what remains to drain is whatever the
    /// pipeline had already buffered; the loop keeps going through it rather than
    /// stopping at the first dropped event, since `.complete` may sit behind a few
    /// `.progress` batches.
    func start(on pipeline: AnalysisPipeline, width: Int, height: Int,
               handler: @escaping @MainActor (AnalysisJob, PipelineEvent) -> Void) {
        task = Task(priority: isBackground ? .utility : .userInitiated) { @MainActor [weak self] in
            guard let self else { return }
            let stream = await pipeline.analyze(url: url, settings: settings,
                                                outputWidth: width, outputHeight: height,
                                                throttle: throttle,
                                                companionChannels: companionChannels)
            for await event in stream {
                record(event)
                if Task.isCancelled, !event.isResult { continue }
                handler(self, event)
            }
            if Task.isCancelled { Self.log("canceled mid-stream — \(describe())") }
        }
    }

    func cancel() {
        isCanceled = true
        task?.cancel()
    }

    private func record(_ event: PipelineEvent) {
        switch event {
        case .metadata(let meta):            metadata = meta
        case .progress(let f, let cols):     fraction = f; columns.append(contentsOf: cols)
        case .complete:                      fraction = 1
        case .decoding, .companion, .error:  break
        }
    }

    func describe() -> String {
        "\(url.lastPathComponent) stream=\(key.streamIndex) ch=\(key.channelIndex) "
            + (companionChannels.isEmpty ? "" : "+ch\(companionChannels) ")
            + "(\(isBackground ? "background" : "foreground"), \(Int(fraction * 100))%)"
    }
}
