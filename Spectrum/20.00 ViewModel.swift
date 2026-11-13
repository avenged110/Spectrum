// MARK: - ViewModel.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The central @MainActor @Observable view model. Owns the analysis pipeline, ImageBuilder, and a
// CADisplayLink-driven render loop that paints incoming magnitude columns at 60 fps. Manages all UI
// state including metadata, analysis progress, spectrogram image, and settings, and exposes the
// public API called by ContentView, MenuBar, and the exporter.

import CoreGraphics
import Observation
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - AnalysisState

/// The state of spectrogram analysis.
enum AnalysisState: Equatable {
    case idle
    case decoding                       // decode stall — show indeterminate spinner
    case analyzing(progress: Double)
    case complete
    case error(String)
}

// MARK: - DisplayLinkDriver

/// A lightweight `CADisplayLink` wrapper that calls a closure on the main thread
/// at the display's native refresh rate (typically 60 or 120 fps).
///
/// ## Design — AppKit-managed display link (macOS 14+)
/// On macOS, `CADisplayLink` must be obtained from an AppKit object rather than
/// initialized directly. `NSWindow.displayLink(target:selector:)` (macOS 14+,
/// within the project's macOS 15 floor) returns an AppKit-managed link that
/// tracks which physical display the window is on, adjusts its refresh rate
/// automatically when the window moves between displays, and suspends itself
/// when the window is off-screen.
///
/// ## Swift 6 concurrency
/// `Target` is `@MainActor` so its `tick(_:)` selector is main-actor-isolated.
/// Because `NSWindow.displayLink(target:selector:)` always delivers the callback
/// on the main thread this is both correct and verifiable at runtime. Isolating
/// `Target` to `@MainActor` means `driver` and `onTick` — both `@MainActor`
/// properties — can be accessed directly with no closures, no `assumeIsolated`,
/// and no `nonisolated(unsafe)` on the back-reference.
///
/// `deinit` is `isolated` (SE-0371), so it runs on the main actor and can
/// invalidate `displayLink` like every other access (`start`, `stop`, and the
/// AppKit-guaranteed `tick` delivery) — no `nonisolated(unsafe)` opt-out.
@MainActor
final class DisplayLinkDriver {

    /// Called on every display-link tick. Receives the timestamp of the current
    /// frame and the duration of the previous frame (both in seconds).
    var onTick: ((CFTimeInterval, CFTimeInterval) -> Void)?

    private var displayLink: CADisplayLink?

    /// Forwarding NSObject target. `@MainActor` isolation makes `tick(_:)` a
    /// main-actor-isolated method, matching the thread on which the display
    /// link delivers its callback and allowing direct access to all
    /// `@MainActor`-isolated state with no unsafe annotations or closures.
    @MainActor
    private final class Target: NSObject {
        weak var driver: DisplayLinkDriver?
        @objc func tick(_ link: CADisplayLink) {
            driver?.onTick?(link.timestamp, link.duration)
        }
    }
    private var target: Target?

    /// `true` when the link is currently running.
    var isRunning: Bool { displayLink != nil }

    init() {}

    isolated deinit {
        displayLink?.invalidate()
    }

    /// Start firing `onTick` at the display's native refresh rate.
    /// Idempotent — calling `start()` while already running stops the
    /// previous link first.
    func start(window: NSWindow) {
        stop()
        let t = Target()
        t.driver = self
        target = t
        let link = window.displayLink(target: t, selector: #selector(Target.tick(_:)))
        link.add(to: .current, forMode: RunLoop.Mode.common)
        displayLink = link
    }

    /// Stop firing and invalidate the underlying `CADisplayLink`. Idempotent.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        target      = nil
    }
}

// MARK: - SpectrogramViewModel

/// Bridges the analysis pipeline to the SwiftUI views.
///
/// ## Smooth rendering architecture
/// The pipeline computes FFT magnitudes as fast as the CPU allows and emits
/// them in batches via `.progress` events. These batches arrive irregularly
/// and can be large (many columns at once on fast hardware). Painting each
/// batch directly to screen produces visible "jumps" as the spectrogram fills.
///
/// To decouple compute throughput from render cadence:
///
/// 1. The pipeline emits magnitude data only — no `CGImage` snapshots.
/// 2. The ViewModel owns an `ImageBuilder` and a `pendingColumns` queue.
///    Each `.progress` event appends its columns to `pendingColumns`
///    without touching the builder or the published image.
/// 3. A `DisplayLinkDriver` fires at 60 fps. Each tick it drains
///    `pendingColumns` in column order, writes them to the builder,
///    and publishes a single `makeImage()` result. Only columns that arrived
///    since the last tick are written — typically a handful on any given frame
///    — so the per-frame cost is O(new_columns × height) and the render stays
///    well within the 16 ms frame budget even on modest hardware.
///
/// The net effect is that analysis throughput is completely unchanged (the
/// pipeline runs as fast as the CPU allows), but the on-screen fill progresses
/// smoothly at the display's native frame rate rather than in coarse jumps.
///
/// ## Session-scoped magnitude cache
/// Completed analysis runs are stored in `magnitudeCache`, keyed by
/// `MagnitudeCacheKey` (see that type for the full rationale), together with
/// the metadata of the stream they were computed from. When the user switches
/// channels or streams and then switches back, or changes the frequency-axis
/// clamp, `startAnalysis()` finds the previously computed entry in the cache
/// and recolors it instantly — no I/O, no FFT, no wait — restoring that
/// stream's metadata for the bar and rulers. The cache lives only for the
/// current file; loading a new file calls `analyze(url:)`, which wipes the
/// cache entirely. Output dimensions are excluded from the key because the
/// window is fixed — its dimensions never change during a session, so cached
/// entries are always column-count-compatible with the current run. It holds
/// at most `magnitudeCacheCapacity` entries (two 8-channel streams), evicting
/// the least recently used.
///
/// ## Background prefetch
/// With `Preferences.backgroundPrefetch` on, the dead time after a spectrogram
/// finishes is spent computing the file's other channels and streams into the
/// cache — one `AnalysisJob` at a time on its own pipeline instance, under a
/// `PipelineThrottle.background()` budget (half the cores, `.utility` QoS).
/// Each job covers one stream: it computes the stream's first uncached channel
/// and every other uncached one alongside it (`companionChannels`), so the
/// stream is decoded once rather than once per channel.
/// The prefetch is paused (not canceled) whenever a foreground run starts, so
/// the user's selection always gets the whole machine, and resumes when that
/// run completes or is served from cache. Selecting the channel a prefetch is
/// computing adopts that job in place: its columns so far are replayed into a
/// fresh image, its budget is promoted to full, and the remaining events render
/// as they would for any foreground run. Opening a new file, a processing
/// error, or switching the preference off cancels the prefetch and empties
/// its queue.
///
/// ## Frequency-axis clamping
/// The `frequencyAxisClamp` preference is read from `Preferences` (UserDefaults)
/// at each analysis invocation. `ContentView` owns an `@AppStorage` binding on
/// the same key and calls `handleFrequencyAxisClampChange()` whenever the
/// Settings window Picker commits a new value. That method updates
/// `effectiveNyquist` immediately (so the ruler redraws in real time) and then
/// schedules a 300 ms debounced re-analysis — a cache hit whenever the current
/// channel has finished once, since the clamp only changes how cached
/// magnitudes map to pixels — so that rapid Picker interactions do not queue
/// consecutive runs.
@Observable
@MainActor
final class SpectrogramViewModel: Loggable {
    nonisolated static let logTag = "[ViewModel]"

    // MARK: - Published state

    var spectrogramImage: CGImage?
    var metadata: AudioMetadata?
    var analysisState: AnalysisState = .idle
    var settings: SpectrogramSettings

    /// Set to `true` for exactly one animation cycle when a new file is loaded,
    /// causing SpectrogramView to fade out the previous image in sync with the
    /// metadata bar fade-out. Cleared as soon as the first partial image from
    /// the new analysis arrives.
    var isSpectrogramFading: Bool = false

    /// The effective Nyquist ceiling (Hz) for the current render.
    /// Derived from `metadata.sampleRate` and `Preferences.frequencyAxisClamp`.
    /// Published so `SpectrogramView` can pass it to `drawFrequencyRuler`
    /// without any additional computation at the call site.
    /// `nil` until the first `.metadata` event arrives for a given file.
    private(set) var effectiveNyquist: Double? = nil

    /// The file URL currently being analyzed / displayed.
    private(set) var currentFileURL: URL?

    /// The hosting NSWindow, supplied by ContentView via WindowAccessor.
    /// Required so that open/save panels present as sheets on the correct window.
    ///
    /// ## Bug 7 fix — retroactive display-link start
    ///
    /// If `hostingWindow` is nil when `startAnalysis()` runs (a race that can
    /// occur on fast file-open immediately after app launch, before
    /// `ContentView.onAppear` fires and `WindowAccessor` delivers the window),
    /// the display link is deferred. This `didSet` observer detects when the
    /// window subsequently becomes available while an analysis is in progress
    /// and starts the link retroactively, restoring smooth progressive rendering
    /// for that analysis run.
    var hostingWindow: NSWindow? {
        didSet {
            // Spectrum has one main window and no way to reopen it once closed
            // (see MainWindowLifetime in SettingsKit): closing it quits the app,
            // Settings window included.
            if let window = hostingWindow, window !== oldValue {
                MainWindowLifetime.terminateWhenClosed(window)
            }
            if hostingWindow !== oldValue { observeSheets() }
            guard let window = hostingWindow,
                  window !== oldValue,
                  !displayLink.isRunning,
                  foregroundJob != nil else { return }
            log("hostingWindow became available mid-analysis — starting display link retroactively.")
            displayLink.start(window: window)
        }
    }

    /// `true` while a sheet — the Open or Save panel, or an alert — is attached
    /// to `hostingWindow`. Open… and Save Spectrogram… are disabled meanwhile (a
    /// second sheet is never presented). The menu bar also disables Next/Previous Channel and
    /// Stream while it is set: their shortcuts, ⌥C and ⌥S, are also how "ç"
    /// and "ß" are typed, and menu key equivalents are matched before text
    /// input — so typing either into the Save panel's filename switched the
    /// channel or stream (and the export then captured a different
    /// spectrogram). A disabled item lets the keystroke through to the field.
    private(set) var isSheetPresented = false

    @ObservationIgnored private var sheetObservers: [any NSObjectProtocol] = []

    private func observeSheets() {
        sheetObservers.forEach(NotificationCenter.default.removeObserver)
        sheetObservers.removeAll()
        isSheetPresented = hostingWindow?.attachedSheet != nil
        guard let window = hostingWindow else { return }
        let center = NotificationCenter.default
        sheetObservers = [
            // Posted before the sheet is attached: it is on its way, so set the
            // flag now rather than read `attachedSheet`, which is still nil.
            center.addObserver(forName: NSWindow.willBeginSheetNotification, object: window,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isSheetPresented = true }
            },
            // The sheet stays attached through its closing animation, and one
            // sheet can chain into another (an export failure alert), so read
            // the window's own state — and while a sheet still shows, re-read it
            // until it is gone or 2 s have passed, at which point a sheet really
            // is up and its own end notification will clear the flag.
            center.addObserver(forName: NSWindow.didEndSheetNotification, object: window,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncSheetState(retries: 40) }
            },
        ]
    }

    private func syncSheetState(retries: Int) {
        let attached = hostingWindow?.attachedSheet != nil
        if isSheetPresented != attached { isSheetPresented = attached }
        guard attached, retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            MainActor.assumeIsolated { self?.syncSheetState(retries: retries - 1) }
        }
    }

    // MARK: - @AppStorage mirror — frequencyAxisClamp

    // The frequencyAxisClamp preference is read directly from Preferences
    // (UserDefaults) at each analysis invocation. ContentView owns its own
    // @AppStorage binding on the same key and calls handleFrequencyAxisClampChange()
    // via .onChange whenever the Settings Picker commits a new value. This
    // approach avoids the @ObservationIgnored / @Observable incompatibility that
    // previously prevented the onChange handler in ContentView from firing: an
    // @ObservationIgnored @AppStorage on an @Observable class is not tracked by
    // the SwiftUI observation system, so its changes are never surfaced to
    // .onChange(of:) callers. Letting ContentView own the @AppStorage binding
    // ensures SwiftUI's standard @AppStorage diffing drives the notification.

    // MARK: - Private: analysis infrastructure

    private let pipeline = AnalysisPipeline()

    /// The run currently being rendered, if any. Canceled and replaced by
    /// every `startAnalysis()` that cannot be served from cache.
    private var foregroundJob: AnalysisJob?

    private var outputWidth:  Int = 0
    private var outputHeight: Int = 0

    // MARK: - Private: background prefetch

    /// Its own actor instance so a prefetch never queues behind — or ahead of —
    /// a foreground run on `pipeline`.
    private let prefetchPipeline = AnalysisPipeline()

    /// The one background run in flight, if any. Paused while `foregroundJob`
    /// exists; adopted into `foregroundJob` if the user selects its key.
    private var prefetchJob: AnalysisJob?

    /// Channel count of every decodable stream of the current file, probed once
    /// per file the first time a prefetch is scheduled. `nil` until then.
    private var prefetchChannelCounts: [Int]?
    private var prefetchProbeTask: Task<Void, Never>?

    // MARK: - Session-scoped magnitude cache

    /// A finished run: its magnitude columns and the metadata of the stream they
    /// were computed from — the pipeline's last `.metadata`, whose duration
    /// already matches the columns for a truncated file. Serving the run means
    /// showing that metadata too — it can differ from what is on screen when
    /// the user comes back from another stream.
    private struct CachedRun {
        let metadata:   AudioMetadata
        let magnitudes: [[Float]]
    }

    /// Maps each unique combination of DSP parameters (represented by
    /// `MagnitudeCacheKey`) to the run produced for that combination. Populated
    /// when the pipeline emits `.complete`; consulted at the start of every new
    /// analysis run. A cache hit bypasses the entire pipeline — no I/O, no FFTs
    /// — and goes straight to `recolorFromCache`.
    ///
    /// Lifecycle:
    /// - **New file**: wiped entirely in `analyze(url:)`.
    /// - **Processing error**: wiped entirely in `presentAlert(.processing)` along
    ///   with all other file state.
    /// - **Output dimensions change**: wiped entirely in `updateOutputDimensions`
    ///   — every entry holds one column per output pixel.
    /// - **Eviction**: least recently used, once `magnitudeCacheCapacity` entries
    ///   are held. Otherwise entries are never invalidated individually.
    ///
    /// Writes are gated by `fileSession` and the current output width (see
    /// `handleEvent`), so a run canceled by one of the wipes above cannot put
    /// its result back after the fact.
    private var magnitudeCache: [MagnitudeCacheKey: CachedRun] = [:]

    /// Keys in least- to most-recently-used order; parallel to `magnitudeCache`.
    private var magnitudeCacheOrder: [MagnitudeCacheKey] = []

    /// Two streams of eight channels each — more than most files carry, so the
    /// prefetch can normally cache a whole file without evicting anything.
    static let magnitudeCacheCapacity = 16

    /// Incremented whenever the cache is wiped for a new file session (a new
    /// open, or the reset after a processing error). Every `AnalysisJob`
    /// carries the session it was started in, and `handleEvent` stores a
    /// `.complete` only if that session is still current: a job canceled by a
    /// new open can still deliver one, and its columns belong to the old file.
    private var fileSession = 0

    // MARK: - Private: smooth render state

    /// The `ImageBuilder` used during active analysis. Owned here so the
    /// display-link renderer can write to it on the main thread without any
    /// actor-crossing overhead.
    private var activeBuilder: ImageBuilder? = nil

    /// Columns produced by the pipeline that have not yet been painted to
    /// `activeBuilder`. Appended in pipeline order; the display-link drains
    /// them in FIFO order each frame.
    private var pendingColumns: [PipelineColumn] = []

    /// The display-link driver. Running only during active analysis; stopped
    /// once the run is finalized, on `.error`, and on cancellation.
    private let displayLink = DisplayLinkDriver()

    /// Set when `.complete` arrives while `pendingColumns` still holds columns
    /// the pacing below has not painted yet; the display link finishes the run
    /// once the queue drains, so the final columns sweep in like the rest
    /// instead of landing in one jump.
    private var completionPending = false

    // MARK: - Private: render pacing

    /// Columns are painted at the run's measured average arrival rate rather
    /// than as they land, so the fill advances evenly even though decode
    /// segments arrive in bursts and the occasional slow segment stalls the
    /// pipeline. The renderer keeps a reserve of about `renderReserve` worth
    /// of columns between arrival and paint: a stall shorter than that is
    /// invisible, a longer one shows as a slowdown rather than a freeze. It is
    /// also the only latency the smoothing adds.
    private static let renderReserve: Duration = .milliseconds(150)

    /// When the first column of the current run arrived, and how many have
    /// arrived since — the average rate is columns ÷ elapsed.
    private var arrivalStart: ContinuousClock.Instant?
    private var arrivedColumns = 0
    /// Fractional columns earned at the average rate but not yet painted.
    private var paintBudget: Double = 0
    private var lastTick: ContinuousClock.Instant?

    // MARK: - Private: open ordering

    /// Incremented by every `open(url:)`. The compatibility probe is asynchronous,
    /// and a slow probe of one file must not land after a faster probe of a file
    /// dropped later — the last file the user chose is the one that opens.
    private var openGeneration = 0

    // MARK: - Private: clamp debounce

    /// Cancels a pending debounced re-analysis when a new clamp change arrives
    /// before the 300 ms window has elapsed.
    private var clampDebounceTask: Task<Void, Never>? = nil

    // MARK: - Animation

    private static let metadataAnimation = Animation.easeInOut(duration: 0.18)

    // MARK: - Init

    init() {
        self.settings = SpectrogramSettings()
        displayLink.onTick = { [weak self] _, _ in
            self?.renderPendingColumns()
        }
        let initMsg = "ViewModel initialized. "
            + "fftSize=\(settings.fftSize) (bits=\(settings.fftBits)), "
            + "window=\(settings.windowFunction.displayName), "
            + "palette=\(settings.palette.rawValue), "
            + "dB=[\(settings.lowerRange), \(settings.upperRange)]"
        log(initMsg)
        let startupClamp = Preferences.frequencyAxisClamp
        let startupMsg = "Startup preferences — "
            + "frequencyAxisClamp=\(startupClamp), "
            + "hopFraction=\(Preferences.overlapFraction)"
        log(startupMsg)
    }

    // MARK: - File handling

    /// The primary entry point for opening a file from any source (drag-and-drop,
    /// open panel, or any future caller).
    ///
    /// Runs a lightweight compatibility pre-check *before* mutating any view state.
    /// If the file contains only incompatible audio streams, the appropriate alert
    /// is presented immediately and the current file/spectrogram is left completely
    /// undisturbed. Only after a clean compatibility check does this method clear
    /// the existing state and begin analysis.
    func open(url: URL) {
        log("open(url:) — \(url.lastPathComponent)")
        openGeneration += 1
        let generation = openGeneration
        // `open(url:)` is a synchronous method on a `@MainActor` class; the
        // Task below runs on the same actor, so `self` is guaranteed alive for
        // its duration. A `[weak self]` capture is therefore unnecessary.
        Task { @MainActor in
            let probe: Result<Void, any Error>
            do { probe = .success(try await AudioDecoder.checkCompatibility(url: url)) }
            catch { probe = .failure(error) }
            guard generation == openGeneration else {
                log("open(url:) — \(url.lastPathComponent) superseded by a later open; ignored.")
                return
            }
            do {
                try probe.get()
            } catch let decoderError as AudioDecoder.DecoderError {
                switch decoderError {
                case .unsupportedContainer(let container):
                    Self.log("Unsupported container for \(url.lastPathComponent) — \(container)")
                    presentAlert(.unsupportedContainer(container))
                    return
                case .incompatibleStreams(let formats):
                    Self.log("Incompatible streams for \(url.lastPathComponent) — \(formats)")
                    presentAlert(.incompatibleStreams(formats))
                    return
                default:
                    // Any other DecoderError: fall through to the pipeline,
                    // which will surface it as a processing error.
                    Self.log("checkCompatibility: unexpected DecoderError — \(decoderError.localizedDescription)")
                }
            } catch {
                // Non-DecoderError: fall through and let the pipeline handle it.
                Self.log("checkCompatibility: unexpected error — \(error.localizedDescription)")
            }
            // Compatibility check passed (or a non-fatal probe error occurred).
            // Clear state and begin analysis.
            analyze(url: url)
        }
    }

    private func analyze(url: URL) {
        log("analyze(url:) — \(url.lastPathComponent)")
        currentFileURL = url

        // Reset isSpectrogramFading to false unconditionally BEFORE the
        // withAnimation block that sets it to true. This guarantees a clean
        // false → true value transition every time a new file is opened,
        // regardless of the state left by any previously canceled analysis.
        //
        // Without this reset, rapid file loads can leave isSpectrogramFading
        // stuck at true when a prior task is canceled before its first
        // .progress event clears the flag. If the flag is already true when
        // analyze() runs, the withAnimation block is a no-op value-wise
        // (true → true), so SwiftUI's onChange(of: isFading) in SpectrogramView
        // never fires — imageOpacity stays at 0 and the entire new spectrogram
        // renders completely invisibly for the lifetime of the analysis run.
        isSpectrogramFading = false

        withAnimation(Self.metadataAnimation) {
            metadata = nil
            isSpectrogramFading = true
        }
        effectiveNyquist      = nil
        settings.streamIndex  = 0
        settings.channelIndex = 0

        // A processing-error alert may still be up for the previous file; its
        // dismissal reset is tied to the previous session (see `presentAlert`)
        // and will not touch this one, so the error state ends here.
        if case .error = analysisState { analysisState = .idle }

        // Wipe the entire magnitude cache — we are starting a fresh file session
        // and any previously cached columns belong to a different file — and drop
        // the previous file's prefetch and any pending clamp debounce with it (a
        // debounce queued just before the open would otherwise fire ~300 ms
        // later and call startAnalysis() on this session, interrupting the run).
        // Bumping the session keeps a straggling `.complete` from the previous
        // file's jobs out of the cache.
        beginFileSession()
        log("analyze(url:) — magnitude cache cleared for new file session \(fileSession).")

        startAnalysis()
    }

    func updateOutputDimensions(width: Int, height: Int) {
        guard width != outputWidth || height != outputHeight else { return }
        log("Output dimensions: \(outputWidth)×\(outputHeight) → \(width)×\(height)")
        outputWidth  = width
        outputHeight = height
        // Cached runs hold exactly one column per output pixel, so every entry
        // computed at the old width is now unusable; the same goes for any run
        // in flight. Both are dropped here — the prefetch is rescheduled after
        // the foreground run below, and `handleEvent` refuses a `.complete`
        // whose column count no longer matches, so a canceled run finishing
        // late cannot put an old-width entry back.
        cancelPrefetchJob()
        tearDownForegroundJob()
        clearMagnitudeCache()
        guard currentFileURL != nil else { return }
        // If a previous analyze() cycle was canceled before its first .progress
        // event cleared isSpectrogramFading, the flag can be stuck at true here.
        // Reset it so startAnalysis() does not launch with an invisible image layer.
        if isSpectrogramFading { isSpectrogramFading = false }
        startAnalysis()
    }

    // MARK: - Frequency axis clamp integration

    /// Called by `ContentView`'s `.onChange(of: frequencyAxisClampRaw)` whenever
    /// the Settings window Picker commits a new value to UserDefaults.
    ///
    /// - Updates `effectiveNyquist` immediately so the frequency ruler redraws
    ///   in real time, even before the debounce fires.
    /// - Schedules a 300 ms debounced full re-analysis, canceling any prior
    ///   pending debounce so only the final stable Picker value triggers a run.
    func handleFrequencyAxisClampChange() {
        let clamp = Preferences.frequencyAxisClamp
        log("frequencyAxisClamp → \(clamp) (rawValue=\(clamp.rawValue))")

        // Update the ruler immediately for a responsive feel.
        if let meta = metadata {
            let newEffective  = resolvedEffectiveNyquist(for: meta, clamp: clamp)
            let actualNyquist = meta.sampleRate / 2.0
            let prevNyquist   = effectiveNyquist.map { $0.fixed(0) } ?? "nil"
            let clampUpdateMsg = "Immediate effectiveNyquist update: "
                + "\(prevNyquist) → "
                + "\(newEffective.fixed(0)) Hz "
                + "(actualNyquist=\(actualNyquist.fixed(0)) Hz, "
                + "displayRatio=\((min(newEffective, actualNyquist) / actualNyquist).fixed(4)))"
            log(clampUpdateMsg)
            effectiveNyquist = newEffective
        } else {
            log("No metadata yet — effectiveNyquist update deferred to next .metadata event.")
        }

        guard currentFileURL != nil else {
            log("No file loaded — clamp change acknowledged but no re-analysis queued.")
            return
        }

        clampDebounceTask?.cancel()
        clampDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                // Canceled — a newer clamp value superseded this debounce.
                return
            }
            guard let self else { return }
            log("Clamp debounce elapsed (300 ms) — starting re-analysis.")
            startAnalysis()
        }
    }

    // MARK: - Channel selection

    /// Refused while a sheet is attached, like the cycle actions below: a
    /// selection mid-export would start a new run the export then captures.
    func selectChannel(_ index: Int) {
        guard let meta = metadata, !isSheetPresented else { return }
        let clamped = max(0, min(index, meta.channelCount - 1))
        guard clamped != settings.channelIndex else { return }
        log("Channel selected: \(clamped) (of \(meta.channelCount))")
        settings.channelIndex = clamped
        startAnalysis()
    }

    func cycleChannelForward() {
        guard let meta = metadata, meta.channelCount > 1, !isSheetPresented else { return }
        settings.channelIndex = (settings.channelIndex + 1) % meta.channelCount
        log("Channel → \(settings.channelIndex) (forward, of \(meta.channelCount))")
        startAnalysis()
    }

    func cycleChannelBackward() {
        guard let meta = metadata, meta.channelCount > 1, !isSheetPresented else { return }
        settings.channelIndex = (settings.channelIndex + meta.channelCount - 1) % meta.channelCount
        log("Channel → \(settings.channelIndex) (backward, of \(meta.channelCount))")
        startAnalysis()
    }

    // MARK: - Stream selection

    func selectStream(_ index: Int) {
        guard let meta = metadata, !isSheetPresented else { return }
        let clamped = max(0, min(index, meta.streamCount - 1))
        guard clamped != settings.streamIndex else { return }
        log("Stream selected: \(clamped) (of \(meta.streamCount))")
        settings.streamIndex  = clamped
        settings.channelIndex = 0
        startAnalysis()
    }

    func cycleStreamForward() {
        guard let meta = metadata, meta.streamCount > 1, !isSheetPresented else { return }
        settings.streamIndex  = (settings.streamIndex + 1) % meta.streamCount
        settings.channelIndex = 0
        log("Stream → \(settings.streamIndex) (forward, of \(meta.streamCount))")
        startAnalysis()
    }

    func cycleStreamBackward() {
        guard let meta = metadata, meta.streamCount > 1, !isSheetPresented else { return }
        settings.streamIndex  = (settings.streamIndex + meta.streamCount - 1) % meta.streamCount
        settings.channelIndex = 0
        log("Stream → \(settings.streamIndex) (backward, of \(meta.streamCount))")
        startAnalysis()
    }

    // MARK: - Export

    func exportSpectrogram() {
        // A second sheet on a window that already shows one is never presented
        // (and never completes), so ⌘S while a panel is up does nothing.
        guard spectrogramImage != nil, let window = hostingWindow, !isSheetPresented else { return }
        let suggestedName: String
        if let url = currentFileURL {
            suggestedName = url.deletingPathExtension().lastPathComponent + ".png"
        } else {
            suggestedName = "spectrogram.png"
        }
        log("Export triggered — suggestedName=\(suggestedName)")
        Exporter.presentSavePanel(window: window, suggestedName: suggestedName)
    }

    // MARK: - Open file dialog

    func presentOpenPanel() {
        // As for export: a second sheet would never be presented, and the
        // presenter's continuation would wait for it forever.
        guard !isSheetPresented else { return }
        Task { @MainActor in
            let configuration = OpenPanelConfiguration(
                canChooseFiles: true,
                canChooseDirectories: false,
                allowsMultipleSelection: false,
                allowedContentTypes: [
                    .audio, .mpeg4Audio, .wav, .aiff, .mp3,
                    // M4V, MOV, and MP4 are video container types in the UTType
                    // system — they do not conform to .audio or .mpeg4Audio, so
                    // they must be listed explicitly to appear in the open panel.
                    UTType(filenameExtension: "m4v") ?? .data,
                    UTType(filenameExtension: "mov") ?? .data,
                    UTType(filenameExtension: "mp4") ?? .data,
                    // Containers demuxed by the bundled FFmpeg build that have
                    // no audio-conforming UTType of their own.
                    UTType(filenameExtension: "mkv") ?? .data,
                    UTType(filenameExtension: "mka") ?? .data,
                    UTType(filenameExtension: "webm") ?? .data,
                    UTType(filenameExtension: "avi") ?? .data,
                    UTType(filenameExtension: "wmv") ?? .data,
                    UTType(filenameExtension: "wma") ?? .data,
                    UTType(filenameExtension: "dts") ?? .data,
                    UTType(filenameExtension: "thd") ?? .data,
                    UTType(filenameExtension: "mlp") ?? .data,
                    UTType(filenameExtension: "wv") ?? .data,
                    UTType(filenameExtension: "dsf") ?? .data,
                    UTType(filenameExtension: "dff") ?? .data,
                    UTType(filenameExtension: "ts") ?? .data,
                    UTType(filenameExtension: "m2ts") ?? .data,
                    UTType(filenameExtension: "mts") ?? .data,
                ],
                title: "Select File",
                message: "Select a file containing at least one compatible audio stream.",
                prompt: "Select"
            )
            let result = await OpenPanelPresenter.present(
                configuration: configuration,
                attachedTo: hostingWindow
            )
            if case .urls(let urls) = result, let url = urls.first {
                self.open(url: url)
            }
        }
    }

    // MARK: - Private: frequency-axis helpers

    /// Compute the effective Nyquist ceiling (Hz) for display under `clamp`.
    ///
    /// For fixed-clamp cases the ceiling is returned unconditionally — even if it
    /// exceeds the file's actual Nyquist. The region above the file's Nyquist
    /// will render as empty (black) space, which is the correct behavior when the
    /// user has explicitly requested a fixed axis scale. `ImageBuilder` uses
    /// separate `bandRatio` and `fillRatio` values derived from this ceiling and
    /// `actualNyquist` to correctly map bands to pixels in both directions.
    ///
    /// - `.automatic`  → natural Nyquist (`sampleRate / 2`).
    /// - `.fixed22kHz` → 22,050 Hz always.
    /// - `.fixed24kHz` → 24,000 Hz always.
    /// - `.fixed44kHz` → 44,100 Hz always.
    /// - `.fixed48kHz` → 48,000 Hz always.
    private func resolvedEffectiveNyquist(
        for meta: AudioMetadata,
        clamp: FrequencyAxisClamp
    ) -> Double {
        switch clamp {
        case .automatic:  return meta.sampleRate / 2.0
        case .fixed22kHz: return 22_050.0
        case .fixed24kHz: return 24_000.0
        case .fixed44kHz: return 44_100.0
        case .fixed48kHz: return 48_000.0
        }
    }

    // MARK: - Private: cache key

    /// Constructs the `MagnitudeCacheKey` for the current analysis parameters.
    private var currentCacheKey: MagnitudeCacheKey {
        MagnitudeCacheKey(
            streamIndex:     settings.streamIndex,
            channelIndex:    settings.channelIndex,
            fftBits:         settings.fftBits,
            windowFunction:  settings.windowFunction
        )
    }

    // MARK: - Private: analysis dispatch

    /// Rebuild the spectrogram image from a cached run using the current
    /// palette, dB range and frequency-axis clamp, and put that run's metadata
    /// on screen. Runs entirely on the main actor — no I/O, no FFTs. Completes
    /// in O(outputWidth × outputHeight) time, typically < 1 ms.
    ///
    /// Returns `false` if the run could not be rendered, so the caller can fall
    /// back to a pipeline run rather than leave nothing on screen.
    @discardableResult
    private func recolorFromCache(_ run: CachedRun) -> Bool {
        let mags = run.magnitudes
        let meta = run.metadata
        guard outputWidth > 0, outputHeight > 0 else {
            log("ERROR: recolorFromCache() — called with zero output dimensions; ignoring.")
            return false
        }
        guard mags.count == outputWidth else {
            // The pipeline produces exactly outputWidth columns, and both the
            // dimension change and the cache write refuse a mismatch, so this
            // should be unreachable; the caller evicts the entry and recomputes.
            log("ERROR: recolorFromCache() — column count mismatch "
                + "(\(mags.count) cached vs \(outputWidth) expected); ignoring.")
            return false
        }

        let clamp         = Preferences.frequencyAxisClamp
        let effective     = resolvedEffectiveNyquist(for: meta, clamp: clamp)
        let actualNyquist = meta.sampleRate / 2.0

        let recolorMsg = "recolorFromCache() — "
            + "palette=\(settings.palette.rawValue), "
            + "dB=[\(settings.lowerRange), \(settings.upperRange)], "
            + "effectiveNyquist=\(effective.fixed(0)) Hz, "
            + "displayRatio=\((min(effective, actualNyquist) / actualNyquist).fixed(4))"
        log(recolorMsg)

        let palette = Palette.make(settings.palette)
        guard let builder = ImageBuilder(
            width:            outputWidth,
            height:           outputHeight,
            palette:          palette,
            upperRange:       settings.upperRange,
            lowerRange:       settings.lowerRange,
            effectiveNyquist: effective,
            actualNyquist:    actualNyquist
        ) else {
            log("ERROR: recolorFromCache() — ImageBuilder init failed.")
            return false
        }

        for (col, columnMags) in mags.enumerated() {
            builder.setColumn(col, magnitudes: columnMags)
        }

        guard let image = builder.makeImage() else {
            log("ERROR: recolorFromCache() — builder.makeImage() returned nil.")
            return false
        }

        // The bar and rulers must describe the run now on screen: coming
        // back from another stream, the metadata still shown is that
        // stream's (channel count, codec, sample rate, duration).
        if metadata != meta {
            withAnimation(Self.metadataAnimation) { metadata = meta }
        }
        effectiveNyquist = effective
        // A fade started for the run this one supersedes (a channel switch
        // whose first column never arrived) would otherwise leave the
        // rebuilt image at zero opacity with nothing left to clear the flag.
        isSpectrogramFading = false
        spectrogramImage    = image
        analysisState       = .complete
        log("recolorFromCache() — image rebuilt successfully.")
        return true
    }

    // MARK: - Private: smooth render — display-link path

    /// Drain `pendingColumns` on each display-link tick, writing newly arrived
    /// columns to `activeBuilder` and publishing a single `makeImage()` result.
    /// Called at ~60 fps during active analysis.
    ///
    /// ## Pacing
    /// Each tick earns `rate × dt × factor` columns and paints that many (whole
    /// columns; the remainder carries over). `rate` is the run's average arrival
    /// rate so far and `factor` is `√(backlog ÷ reserve)`, where `reserve` is
    /// `rate × renderReserve` columns: with less than the reserve queued the
    /// paint slows (building the reserve back up), with more it speeds up, and
    /// it settles where painting exactly tracks arrival with the reserve in
    /// hand. Once `.complete` has arrived there is nothing left to smooth, so
    /// the factor is pinned high and the queue drains promptly. Before a rate
    /// exists (the very first tick) everything queued is painted at once. The
    /// queue is trimmed with `removeFirst(_:)`; it holds at most a few hundred
    /// entries, so the shift is negligible next to the column writes.
    private func renderPendingColumns() {
        guard !pendingColumns.isEmpty, let builder = activeBuilder else { return }

        let now = ContinuousClock.now
        let dt  = lastTick.map { $0.duration(to: now) } ?? .milliseconds(16)
        lastTick = now

        var take = pendingColumns.count
        if let start = arrivalStart {
            let elapsed = start.duration(to: now).seconds
            if elapsed > 0.05 {
                let rate    = Double(arrivedColumns) / elapsed        // columns per second
                let reserve = max(1, rate * Self.renderReserve.seconds)
                let factor  = completionPending
                    ? 1.5
                    : min(1.5, (Double(pendingColumns.count) / reserve).squareRoot())
                paintBudget += rate * dt.seconds * factor
                take = min(pendingColumns.count, Int(paintBudget))
            }
        }
        guard take > 0 else { return }
        paintBudget = max(0, paintBudget - Double(take))

        for entry in pendingColumns.prefix(take) {
            builder.setColumn(entry.index, magnitudes: entry.magnitudes)
        }
        pendingColumns.removeFirst(take)

        // One makeImage() call per tick — always zero-copy from the context's
        // backing store (see ImageBuilder design notes).
        if let image = builder.makeImage() {
            // Clear the fading flag so the bitmap snaps to full opacity.
            isSpectrogramFading = false

            // If the pipeline is still in .decoding when the first column is
            // painted (the .progress handler defers this transition
            // deliberately — see its comment), apply the state change here.
            // This guarantees the overlay's .opacity transition and the bitmap's
            // first appearance happen on the exact same display-link frame,
            // eliminating the one-frame gap where neither is visible.
            if analysisState == .decoding {
                analysisState = .analyzing(progress: 0)
            }

            spectrogramImage = image
        }

        if completionPending && pendingColumns.isEmpty {
            finalizeForegroundRun()
        }
    }

    private func startAnalysis() {
        guard let url = currentFileURL else {
            log("startAnalysis() — skipped: no currentFileURL.")
            return
        }
        guard outputWidth > 0 && outputHeight > 0 else {
            log("startAnalysis() — skipped: dimensions not yet set (\(outputWidth)×\(outputHeight)).")
            return
        }
        // A processing-error alert is up for this file: the Settings window and
        // the menu bar stay usable behind the sheet, but the file is not
        // reanalyzed until the alert's dismissal has reset the session.
        if case .error = analysisState {
            log("startAnalysis() — skipped: processing error pending dismissal.")
            return
        }

        // ─── Cache check ────────────────────────────────────────────────────────
        // Consult the session cache before touching the pipeline. If this exact
        // combination of stream, channel and FFT parameters has already been
        // computed during this file session, recolor from the cached
        // magnitudes immediately — no I/O, no FFTs.
        //
        // The check must happen BEFORE canceling any in-flight job: if a job
        // is currently running for a *different* key (e.g. the user switched
        // channels mid-analysis), we still want to cancel it so it doesn't
        // overwrite the image we are about to render from cache. The cancel +
        // cache-serve path is therefore: cancel job → recolor from cache → return.
        let key = currentCacheKey
        if let run = cachedRun(for: key) {
            if foregroundJob != nil {
                log("startAnalysis() — cache hit; canceling in-flight job for previous key.")
                tearDownForegroundJob()
            }

            log("startAnalysis() — cache hit "
                + "(stream=\(key.streamIndex), ch=\(key.channelIndex), "
                + "fftBits=\(key.fftBits), window=\(key.windowFunction.displayName)); "
                + "serving \(run.magnitudes.count) columns — no pipeline run.")
            if recolorFromCache(run) {
                // Nothing is running in the foreground now: let the prefetch carry on.
                schedulePrefetch()
                return
            }
            // The entry could not be rendered: drop it and compute afresh rather
            // than leave the previous image (or nothing) on screen.
            log("startAnalysis() — cached run unusable; evicting and recomputing.")
            magnitudeCache.removeValue(forKey: key)
            magnitudeCacheOrder.removeAll { $0 == key }
        }
        // ────────────────────────────────────────────────────────────────────────

        // ─── Same run already in flight ─────────────────────────────────────────
        // Only a display-time parameter can bring us here for the key that is
        // already being computed — the frequency-axis clamp, whose debounce
        // lands mid-run whenever the user changes it while a spectrogram is
        // filling. The columns are unaffected, so rather than throw the run
        // away and decode the file again, remap what is on screen and let the
        // run continue.
        if let job = foregroundJob, job.session == fileSession, job.key == key, !job.isCanceled,
           let context = job.foreground,
           context.width == outputWidth, context.height == outputHeight {
            retargetForegroundRun(job, context: context)
            return
        }

        // Read all relevant preferences once, before canceling the previous
        // job, so the values are stable and consistently logged.
        let clamp         = Preferences.frequencyAxisClamp
        let actualNyquist = metadata.map { $0.sampleRate / 2.0 }
        let effective     = metadata.map { resolvedEffectiveNyquist(for: $0, clamp: clamp) }

        let effectiveStr    = effective.map { "\($0.fixed(0)) Hz" } ?? "TBD"
        let startAnalysisMsg = "startAnalysis() — "
            + "file=\(url.lastPathComponent), "
            + "dims=\(outputWidth)×\(outputHeight), "
            + "clamp=\(clamp), "
            + "effectiveNyquist=\(effectiveStr), "
            + "fftSize=\(settings.fftSize), "
            + "window=\(settings.windowFunction.displayName), "
            + "channel=\(settings.channelIndex), stream=\(settings.streamIndex)"
        log(startAnalysisMsg)

        // Cancel any in-flight job and tear down the previous render state.
        if foregroundJob != nil {
            log("Canceling in-flight analysis job.")
        }
        tearDownForegroundJob()

        // Fade out the stale spectrogram immediately. Without this, the old image
        // stays fully opaque while the new pipeline run is in progress — the metadata
        // bar updates quickly (it fires from the async .metadata event), but the graph
        // sits unchanged underneath it, creating a misleading mismatch. Setting
        // isSpectrogramFading = true triggers SpectrogramView's onChange(of: isFading)
        // which animates imageOpacity to 0, giving immediate visual feedback that the
        // graph is being replaced. isSpectrogramFading is reset to false by
        // renderPendingColumns() the moment the first column arrives, at which point
        // the image snaps back to full opacity to show the incoming content.
        //
        // Guard: only fade if there is an image to fade out AND we are not already
        // fading. analyze(url:) sets isSpectrogramFading = true before calling here,
        // so new-file-open paths are already fading and need no second transition.
        // Channel and stream switches reach startAnalysis() directly without going
        // through analyze(url:), so they need this fade to avoid leaving stale content
        // visible while the new pipeline run is in progress.
        if spectrogramImage != nil && !isSpectrogramFading {
            withAnimation(Self.metadataAnimation) {
                isSpectrogramFading = true
            }
        }

        analysisState = .analyzing(progress: 0)

        let capturedSettings  = settings
        let capturedEffective = effective
        let capturedActual    = actualNyquist
        let width             = outputWidth
        let height            = outputHeight

        // Build the ImageBuilder before starting the job so the display-link
        // renderer has a valid target from the very first tick.
        //
        // If metadata is not yet available (first open of a new file), seed
        // the builder with a 1:1 ratio (full band range) as a safe placeholder.
        // When the pipeline emits .metadata, the handler will detect the
        // changed actualNyquist and rebuild the builder with the correct ratio.
        let builderEffective = capturedEffective ?? 1.0
        let builderActual    = capturedActual    ?? 1.0
        let palette          = Palette.make(capturedSettings.palette)

        activeBuilder = ImageBuilder(
            width:            width,
            height:           height,
            palette:          palette,
            upperRange:       capturedSettings.upperRange,
            lowerRange:       capturedSettings.lowerRange,
            effectiveNyquist: builderEffective,
            actualNyquist:    builderActual
        )

        if activeBuilder == nil {
            log("ERROR: startAnalysis() — ImageBuilder init failed "
                + "(effective=\(builderEffective), actual=\(builderActual)). "
                + "Aborting.")
            analysisState = .idle
            return
        }

        if capturedEffective == nil {
            log("NOTE: ImageBuilder seeded with 1:1 placeholder ratio "
                + "(no metadata yet). Will rebuild after .metadata event.")
        }

        // Bug 7: start the display link only if the hosting window is
        // already available. If it is not (rare race on very early open),
        // the hostingWindow didSet observer will start it retroactively
        // when the window is delivered by WindowAccessor.
        if let window = hostingWindow {
            displayLink.start(window: window)
        } else {
            log("WARNING: hostingWindow is nil at startAnalysis() — "
                + "display link deferred; will start retroactively when "
                + "window becomes available.")
        }

        let context = ForegroundRunContext(settings: capturedSettings,
                                           effective: capturedEffective,
                                           actual: capturedActual,
                                           width: width, height: height)

        // ─── Adopt an in-flight prefetch of this very key ──────────────────────
        // The background job has already decoded and computed part (or all) of
        // this spectrogram. Rather than starting over, take it over: replay what
        // it has emitted so far into the builder just created, then let its
        // remaining events flow through the ordinary foreground handler at full
        // speed.
        if let job = prefetchJob, job.key == key, !job.isCanceled {
            prefetchJob = nil
            job.foreground = context
            job.throttle.promote()
            foregroundJob = job
            log("startAnalysis() — adopting prefetch job \(job.describe()); "
                + "replaying \(job.columns.count) columns.")
            if let meta = job.metadata {
                handleForegroundEvent(.metadata(meta), job: job, context: context)
            }
            if !job.columns.isEmpty {
                handleForegroundEvent(.progress(fraction: job.fraction, columns: job.columns),
                                      job: job, context: context)
            }
            // The replayed columns are painted in full on the first tick (no
            // rate exists yet) and must not count toward the arrival rate:
            // that rate governs the render reserve for the columns still to
            // come, and only those arrive at the run's real pace.
            resetRenderPacing()
            return
        }
        // Any other prefetch gives way: it parks until this run is done.
        pausePrefetch()

        let job = AnalysisJob(key: key, settings: capturedSettings, url: url, session: fileSession,
                              throttle: .unlimited, foreground: context)
        foregroundJob = job
        job.start(on: pipeline, width: width, height: height) { [weak self] job, event in
            self?.handleEvent(event, from: job)
        }
    }

    /// Cancel the foreground job (if any) and clear its render state.
    private func tearDownForegroundJob() {
        foregroundJob?.cancel()
        foregroundJob = nil
        displayLink.stop()
        pendingColumns.removeAll()
        completionPending = false
        activeBuilder = nil
        resetRenderPacing()
    }

    private func resetRenderPacing() {
        arrivalStart   = nil
        arrivedColumns = 0
        paintBudget    = 0
        lastTick       = nil
    }

    /// Re-map the run already in flight for the current key onto the current
    /// frequency-axis clamp instead of restarting it: rebuild the builder with
    /// the new ceiling, repaint the columns already on screen into it, and let
    /// the display link carry on with the rest. Pacing, the pending queue and
    /// the completion state are untouched.
    private func retargetForegroundRun(_ job: AnalysisJob, context: ForegroundRunContext) {
        guard let meta = metadata, let actual = context.actual else {
            // The builder is still the 1:1 placeholder; the `.metadata` handler
            // reads the clamp afresh when it rebuilds, so there is nothing to do.
            log("startAnalysis() — same run in flight, metadata pending; clamp applied at .metadata.")
            return
        }
        let effective = resolvedEffectiveNyquist(for: meta, clamp: Preferences.frequencyAxisClamp)
        guard context.effective != effective else {
            log("startAnalysis() — same run in flight with the same display mapping; nothing to do.")
            return
        }
        guard let builder = ImageBuilder(
            width:            context.width,
            height:           context.height,
            palette:          Palette.make(context.settings.palette),
            upperRange:       context.settings.upperRange,
            lowerRange:       context.settings.lowerRange,
            effectiveNyquist: effective,
            actualNyquist:    actual
        ) else {
            log("ERROR: startAnalysis() — ImageBuilder init failed for retarget "
                + "(effective=\(effective), actual=\(actual)); run continues unchanged.")
            return
        }
        // The job records every column in emission order and the pending queue
        // holds the unpainted tail of that sequence, so what is on screen is
        // the recorded prefix ahead of the queue.
        let painted = max(0, job.columns.count - pendingColumns.count)
        for entry in job.columns.prefix(painted) {
            builder.setColumn(entry.index, magnitudes: entry.magnitudes)
        }
        activeBuilder    = builder
        job.foreground   = ForegroundRunContext(settings: context.settings,
                                                effective: effective, actual: actual,
                                                width: context.width, height: context.height)
        effectiveNyquist = effective
        if painted > 0, let image = builder.makeImage() {
            spectrogramImage = image
        }
        log("startAnalysis() — same run in flight; remapped \(painted) painted columns to "
            + "effectiveNyquist=\(effective.fixed(0)) Hz, run continues.")
    }

    /// The foreground run's last columns are painted: publish the final image,
    /// release the run, and let the prefetch continue.
    private func finalizeForegroundRun() {
        completionPending = false
        displayLink.stop()
        resetRenderPacing()
        if let builder = activeBuilder, let finalImage = builder.makeImage() {
            isSpectrogramFading = false
            spectrogramImage    = finalImage
            log("run finalized — final image produced.")
        } else {
            log("WARNING: run finalized without an image (activeBuilder=\(activeBuilder == nil ? "nil" : "set")).")
        }
        activeBuilder = nil
        analysisState = .complete
        foregroundJob = nil   // nil out so the next startAnalysis() sees a clean state

        // The machine is free again: continue (or start) the prefetch.
        schedulePrefetch()
    }

    // MARK: - Private: pipeline event handling

    /// Every event of every job lands here. The cache write on `.complete` is
    /// unconditional; rendering happens only for the current foreground job,
    /// and background bookkeeping only for the current prefetch job. Events of
    /// a job that is neither (a superseded, canceled run) are ignored.
    ///
    /// ## Cancellation and the magnitude cache
    ///
    /// When the user switches channels or streams while a run is in progress,
    /// `startAnalysis()` cancels it before launching the new one. `AnalysisJob`
    /// drops every further event except `.complete`, which it always delivers:
    /// dropping it would mean the finished columns are never stored, so the
    /// next visit to that channel would have to run the pipeline all over again.
    private func handleEvent(_ event: PipelineEvent, from job: AnalysisJob) {
        if case .companion(let channel, let magnitudes) = event {
            // A companion channel of the same run: cached under the same rules
            // as `.complete` below, with the run's metadata (same stream).
            let key = job.key.with(streamIndex: job.key.streamIndex, channelIndex: channel)
            if job.session != fileSession || magnitudes.count != outputWidth {
                log(".companion ch=\(channel) — stale session or width; \(job.describe()); not cached.")
            } else if let meta = job.metadata {
                storeRun(CachedRun(metadata: meta, magnitudes: magnitudes), for: key)
                log(".companion — stored \(magnitudes.count) columns in cache for key "
                    + "(stream=\(key.streamIndex), ch=\(channel), fftBits=\(key.fftBits)). "
                    + "Cache now holds \(magnitudeCache.count) entries.")
            } else {
                log("WARNING: .companion without metadata — \(job.describe()); not cached.")
            }
        }
        if case .complete(let magnitudes, let actualSamples) = event {
            // A run started in a previous file session, or at a previous output
            // width, may still deliver its `.complete` after being canceled —
            // and it has nothing to do with the file, or the pixel grid, on
            // screen now. Only a run of the current session at the current
            // width may enter the cache.
            if job.session != fileSession {
                log(".complete — from file session \(job.session) (current \(fileSession)); "
                    + "\(job.describe()); not cached.")
            } else if magnitudes.count != outputWidth {
                log(".complete — \(magnitudes.count) columns at an output width of "
                    + "\(outputWidth); \(job.describe()); not cached.")
            } else if let meta = job.metadata {
                // The pipeline emits `.metadata` before anything else, so a job
                // that reached `.complete` always has it; the guard only keeps
                // a malformed run out of the cache. The job holds the latest
                // one, so a truncated file's corrected duration is already in it.
                storeRun(CachedRun(metadata: meta, magnitudes: magnitudes), for: job.key)
                log(".complete — stored \(magnitudes.count) columns in cache "
                    + "for key (stream=\(job.key.streamIndex), "
                    + "ch=\(job.key.channelIndex), "
                    + "fftBits=\(job.key.fftBits)). "
                    + "Cache now holds \(magnitudeCache.count) entr\(magnitudeCache.count == 1 ? "y" : "ies"). "
                    + "actualSamples=\(actualSamples), duration=\(meta.formattedDuration).")
            } else {
                log("WARNING: .complete without metadata — \(job.describe()); not cached.")
            }
        }

        if job === foregroundJob, let context = job.foreground {
            guard !job.isCanceled else {
                log(".complete — job canceled; cache written but rendering skipped.")
                return
            }
            handleForegroundEvent(event, job: job, context: context)
        } else if job === prefetchJob {
            handlePrefetchEvent(event, job: job)
        }
        // Any other job is a superseded run that finished anyway — cached
        // above, nothing to draw.
    }

    private func handleForegroundEvent(_ event: PipelineEvent, job: AnalysisJob,
                                       context: ForegroundRunContext) {
        switch event {

        case .metadata(let headerMeta):
            // A truncated file's header duration was already corrected by an
            // earlier run of this stream (the pipeline's final `.metadata`,
            // cached with the run); keep the ruler there rather than flipping
            // back to the header value for the length of this run until the
            // pipeline corrects it again at the end.
            let known = magnitudeCache.first { $0.key.streamIndex == job.key.streamIndex }?.value.metadata
            let meta  = known.map { $0.sampleRate == headerMeta.sampleRate ? headerMeta.with(duration: $0.duration) : headerMeta }
                        ?? headerMeta
            let resolvedClamp     = Preferences.frequencyAxisClamp
            let resolvedEffective = resolvedEffectiveNyquist(for: meta, clamp: resolvedClamp)
            let resolvedActual    = meta.sampleRate / 2.0

            let metadataMsg = ".metadata received — "
                + "codec=\(meta.codec), "
                + "sampleRate=\(meta.formattedSampleRate), "
                + "channels=\(meta.channelDescription), "
                + "duration=\(meta.formattedDuration), "
                + "actualNyquist=\(resolvedActual.fixed(0)) Hz, "
                + "effectiveNyquist=\(resolvedEffective.fixed(0)) Hz "
                + "(clamp=\(resolvedClamp))"
            log(metadataMsg)

            withAnimation(Self.metadataAnimation) {
                metadata = meta
            }
            effectiveNyquist = resolvedEffective

            // Rebuild the ImageBuilder if the placeholder was used (first
            // open) or if the new file has a different sample rate from the
            // previously loaded one (which is captured in context.actual).
            let needsRebuild = context.effective == nil
                           || context.actual != resolvedActual
            if needsRebuild {
                let rebuildMsg = "Rebuilding ImageBuilder with resolved values — "
                    + "placeholderWasUsed=\(context.effective == nil), "
                    + "sampleRateChanged=\(context.actual != resolvedActual), "
                    + "effective=\(resolvedEffective.fixed(0)) Hz, "
                    + "actual=\(resolvedActual.fixed(0)) Hz"
                log(rebuildMsg)
                let newBuilder = ImageBuilder(
                    width:            context.width,
                    height:           context.height,
                    palette:          Palette.make(context.settings.palette),
                    upperRange:       context.settings.upperRange,
                    lowerRange:       context.settings.lowerRange,
                    effectiveNyquist: resolvedEffective,
                    actualNyquist:    resolvedActual
                )
                if let nb = newBuilder {
                    activeBuilder = nb
                    // Keep the context describing what the builder was built
                    // with, so a later `.metadata` or a clamp change mid-run
                    // (`retargetForegroundRun`) compares against the real ratio
                    // rather than the placeholder captured at start.
                    job.foreground = ForegroundRunContext(settings: context.settings,
                                                          effective: resolvedEffective,
                                                          actual: resolvedActual,
                                                          width: context.width,
                                                          height: context.height)
                    log("ImageBuilder rebuilt successfully.")
                } else {
                    log("ERROR: ImageBuilder rebuild failed — "
                        + "effective=\(resolvedEffective), actual=\(resolvedActual).")
                }
            }

        case .companion:
            break   // cached in `handleEvent`; nothing to draw

        case .decoding:
            // Shown any time the decoder stalls before it can produce enough
            // samples for the first FFT column. Cache hits bypass the pipeline
            // entirely, so this state is only ever reached for genuine new runs.
            analysisState = .decoding
            log(".decoding stall — spinner shown.")

        case .progress(let fraction, let columns):
            if completionPending {
                log("WARNING: .progress after .complete — ignored.")
                return
            }
            if arrivalStart == nil { arrivalStart = .now }
            arrivedColumns += columns.count
            pendingColumns.append(contentsOf: columns)
            // Do NOT immediately clear .decoding here.
            // That state drives the overlay visibility; transitioning to
            // .analyzing while pendingColumns are still queued but not yet
            // painted causes a one-frame gap where the overlay has begun
            // fading out but no bitmap is visible yet (the idle placeholder
            // or bare black shows through). The transition is deferred to
            // renderPendingColumns(), which applies it at the exact moment
            // the first image is written to spectrogramImage — guaranteeing
            // the overlay fade-out and the bitmap appearance are simultaneous.
            //
            // For subsequent .progress events (where analysisState is already
            // .analyzing) this guard is a no-op and the fraction update applies
            // immediately as before.
            if analysisState != .decoding {
                analysisState = .analyzing(progress: fraction)
            }   // else: let renderPendingColumns() do the transition

        case .complete(let magnitudes, _):
            // The bar and rulers must describe the run just cached. They
            // normally already do — the pipeline's last `.metadata` went
            // through the handler above — unless that handler kept an earlier
            // run's corrected duration that this run's decode did not confirm.
            if let run = magnitudeCache[job.key], run.metadata != metadata {
                log(".complete — metadata differs from the cached run's (duration \(run.metadata.formattedDuration)); updating.")
                withAnimation(Self.metadataAnimation) { metadata = run.metadata }
            }
            // Columns still queued are painted at the paced rate by the display
            // link, which finalizes the run once the queue is empty; if the
            // link cannot run (no window yet) finish here so the run never hangs.
            if !pendingColumns.isEmpty && displayLink.isRunning {
                completionPending = true
                log(".complete — \(pendingColumns.count) of \(magnitudes.count) columns still queued; finishing at paced rate.")
            } else {
                if let builder = activeBuilder {
                    for entry in pendingColumns {
                        builder.setColumn(entry.index, magnitudes: entry.magnitudes)
                    }
                }
                pendingColumns.removeAll()
                log(".complete — all \(magnitudes.count) columns painted.")
                finalizeForegroundRun()
            }

        case .error(let message):
            displayLink.stop()
            activeBuilder = nil
            pendingColumns.removeAll()
            completionPending   = false
            resetRenderPacing()
            isSpectrogramFading = false
            foregroundJob       = nil   // nil out before the alert so state is consistent
            analysisState = .error(message)
            log(".error — \(message)")
            presentAlert(.processing(message))
        }
    }

    // MARK: - Private: magnitude cache

    /// The cached run for `key`, marking it most recently used.
    private func cachedRun(for key: MagnitudeCacheKey) -> CachedRun? {
        guard let run = magnitudeCache[key] else { return nil }
        touchCacheKey(key)
        return run
    }

    /// Store `run` under `key`, evicting the least recently used entry once the
    /// cache is over capacity.
    private func storeRun(_ run: CachedRun, for key: MagnitudeCacheKey) {
        magnitudeCache[key] = run
        touchCacheKey(key)
        while magnitudeCache.count > Self.magnitudeCacheCapacity,
              let oldest = magnitudeCacheOrder.first {
            magnitudeCacheOrder.removeFirst()
            magnitudeCache.removeValue(forKey: oldest)
            log("Magnitude cache full — evicted stream=\(oldest.streamIndex) ch=\(oldest.channelIndex).")
        }
    }

    private func touchCacheKey(_ key: MagnitudeCacheKey) {
        magnitudeCacheOrder.removeAll { $0 == key }
        magnitudeCacheOrder.append(key)
    }

    private func clearMagnitudeCache() {
        magnitudeCache.removeAll()
        magnitudeCacheOrder.removeAll()
    }

    /// Start a fresh file session: the cache, the prefetch and any pending
    /// clamp debounce all belong to the old one and go with it, and jobs of the
    /// old session can no longer write to the cache (see `fileSession`).
    private func beginFileSession() {
        fileSession += 1
        clampDebounceTask?.cancel()
        clampDebounceTask = nil
        clearMagnitudeCache()
        resetPrefetch()
    }

    // MARK: - Background prefetch

    /// Called by `ContentView` when either Settings checkbox changes.
    func handleBackgroundPrefetchChange() {
        if !Preferences.backgroundPrefetch {
            log("backgroundPrefetch disabled — canceling.")
            cancelPrefetchJob()
        } else if let meta = metadata, !prefetchAllowed(for: meta) {
            log("backgroundPrefetch limited and the open file is out of scope — canceling.")
            cancelPrefetchJob()
        } else {
            log("backgroundPrefetch enabled — scheduling.")
            schedulePrefetch()
        }
    }

    /// Whether the open file may be prefetched at all: always, unless
    /// `limitedBackgroundPrefetch` restricts the feature to files with a single
    /// stereo stream shorter than ten minutes.
    private func prefetchAllowed(for meta: AudioMetadata) -> Bool {
        guard Preferences.limitedBackgroundPrefetch else { return true }
        return meta.streamCount  == Preferences.limitedPrefetchStreamCount
            && meta.channelCount == Preferences.limitedPrefetchChannelCount
            && meta.duration     <  Preferences.limitedPrefetchMaxDuration
    }

    /// Start the next prefetch if nothing is running in the foreground, or
    /// resume the paused one. Safe to call at any time; it is a no-op whenever
    /// a prefetch would be pointless or would compete with the user.
    private func schedulePrefetch() {
        guard Preferences.backgroundPrefetch,
              let url = currentFileURL, let meta = metadata,
              foregroundJob == nil, outputWidth > 0, outputHeight > 0 else { return }
        // A processing error is pending dismissal: its reset cancels the
        // prefetch anyway, so do not start one that only gets thrown away.
        if case .error = analysisState { return }
        guard prefetchAllowed(for: meta) else {
            log("Prefetch skipped — limited to single sub-ten-minute stereo streams; "
                + "file has \(meta.streamCount) stream(s), \(meta.channelCount) channel(s), "
                + "\(meta.duration.saturatingInt) s.")
            return
        }

        if let job = prefetchJob {
            if job.throttle.isPaused {
                log("Prefetch resumed — \(job.describe())")
                job.throttle.resume()
            }
            return
        }

        // The per-stream channel counts are needed to enumerate targets; probe
        // them once per file (a header read per stream), then come back here.
        guard let channelCounts = prefetchChannelCounts else {
            guard prefetchProbeTask == nil else { return }
            let streamCount = meta.streamCount
            prefetchProbeTask = Task { @MainActor [weak self] in
                var counts: [Int] = []
                for stream in 0..<streamCount {
                    let count = (try? await AudioDecoder.metadata(for: url, streamIndex: stream))?.channelCount ?? 0
                    counts.append(count)
                }
                // A canceled probe belongs to a previous session of this file (it
                // was reopened); the new session has its own probe in flight.
                guard !Task.isCancelled, let self, self.currentFileURL == url else { return }
                self.prefetchProbeTask     = nil
                self.prefetchChannelCounts = counts
                Self.log("Prefetch targets — channels per stream: \(counts).")
                self.schedulePrefetch()
            }
            return
        }

        // An empty list means the prefetch was stopped for this file after an
        // error (already logged); no targets remain either way.
        guard !channelCounts.isEmpty else { return }
        let targets = prefetchTargets(channelCounts: channelCounts)
        guard let key = targets.first else {
            log("Prefetch complete — every channel of every stream is cached.")
            return
        }
        // Every other uncached channel of the same stream rides along: one
        // decode of the stream feeds them all.
        let companions = targets.dropFirst()
            .filter { $0.streamIndex == key.streamIndex }
            .map(\.channelIndex)

        var jobSettings = settings
        jobSettings.streamIndex  = key.streamIndex
        jobSettings.channelIndex = key.channelIndex
        let job = AnalysisJob(key: key, settings: jobSettings, url: url, session: fileSession,
                              throttle: .background(), foreground: nil,
                              companionChannels: Array(companions))
        prefetchJob = job
        log("Prefetch started — \(job.describe())")
        job.start(on: prefetchPipeline, width: outputWidth, height: outputHeight) { [weak self] job, event in
            self?.handleEvent(event, from: job)
        }
    }

    /// The uncached (stream, channel) keys under the current DSP parameters, in
    /// prefetch order: walking the streams from the one on screen and wrapping
    /// around. Only the first `magnitudeCacheCapacity` targets are considered:
    /// anything beyond would evict what was just computed.
    private func prefetchTargets(channelCounts: [Int]) -> [MagnitudeCacheKey] {
        let base        = currentCacheKey
        let streamCount = channelCounts.count
        guard streamCount > 0 else { return [] }
        var targets: [MagnitudeCacheKey] = []
        for offset in 0..<streamCount {
            let stream = (base.streamIndex + offset) % streamCount
            for channel in 0..<channelCounts[stream] {
                targets.append(base.with(streamIndex: stream, channelIndex: channel))
            }
        }
        return targets.prefix(Self.magnitudeCacheCapacity)
            .filter { magnitudeCache[$0] == nil }
    }

    private func handlePrefetchEvent(_ event: PipelineEvent, job: AnalysisJob) {
        switch event {
        case .complete:
            log("Prefetch finished — \(job.describe())")
            releaseFinishedPrefetchJob(job)
            // `prefetchTargets` starts with the first key not in the cache; a run
            // that finished but was refused by `handleEvent` would be picked
            // again forever, so stop here instead.
            guard magnitudeCache[job.key] != nil else {
                log("Prefetch result not cached — prefetch stopped for this file.")
                prefetchChannelCounts = []
                return
            }
            schedulePrefetch()
        case .error(let message):
            // Speculative work never surfaces an alert; just stop prefetching
            // this file rather than retrying the same failure on every channel.
            log("Prefetch error — \(job.describe()): \(message). Prefetch stopped for this file.")
            releaseFinishedPrefetchJob(job)
            prefetchChannelCounts = []
        case .metadata, .decoding, .progress, .companion:
            break   // recorded by the job for a possible adoption; companions cached in handleEvent
        }
    }

    /// Forget a prefetch job that has ended (`.complete` or `.error`). Its gate
    /// is opened first, as `cancelPrefetchJob` does: a job can end while paused
    /// with decoder threads still parked on the gate — when a segment fails, its
    /// sequential fallback can fail to open (a file on a volume that went away)
    /// while the other workers wait for the gate — and those threads, each
    /// holding an open decoder, only see that the run is over once it opens.
    /// After `.complete` the decode has ended and nothing waits; opening the
    /// gate there costs nothing.
    private func releaseFinishedPrefetchJob(_ job: AnalysisJob) {
        job.throttle.resume()
        prefetchJob = nil
    }

    /// Park the running prefetch so a foreground run gets the whole machine.
    private func pausePrefetch() {
        guard let job = prefetchJob, !job.throttle.isPaused else { return }
        log("Prefetch paused — \(job.describe())")
        job.throttle.pause()
    }

    /// Abandon the running prefetch; the queue itself survives and the next
    /// `schedulePrefetch()` recomputes it.
    private func cancelPrefetchJob() {
        guard let job = prefetchJob else { return }
        log("Prefetch canceled — \(job.describe())")
        job.throttle.resume()   // never leave threads parked on a dead gate
        job.cancel()
        prefetchJob = nil
    }

    /// Everything prefetch-related back to the no-file state.
    private func resetPrefetch() {
        cancelPrefetchJob()
        prefetchProbeTask?.cancel()
        prefetchProbeTask     = nil
        prefetchChannelCounts = nil
    }

    // MARK: - Error presentation

    /// The two distinct categories of error the app can surface to the user.
    private enum AppError {
        /// The file's container format is not supported at all.
        /// `container` is the human-readable container name (e.g. "MKV"), used
        /// for logging. The user-facing alert shows a fixed message regardless.
        /// Displaying this alert must NOT disturb any existing state.
        case unsupportedContainer(String)

        /// The container is supported but every audio stream uses an
        /// incompatible codec. `formats` carries the codec name(s) found (may
        /// be empty if the codec could not be identified), used for logging.
        /// The user-facing alert shows a fixed message regardless.
        /// Displaying this alert must NOT disturb any existing state.
        case incompatibleStreams([String])

        /// A fatal error encountered during decoding or rendering.
        /// Displaying this alert MUST be followed by a full state reset.
        case processing(String)
    }

    /// Present a modal alert for `error`.
    ///
    /// - **`unsupportedContainer`**: fixed message — "This file's format is not
    ///   supported at this time." Returns the user to prior state unchanged.
    /// - **`incompatibleStreams`**: fixed message — "The file does not contain a
    ///   compatible audio stream." Returns the user to prior state unchanged.
    /// - **`processing`**: shows the pipeline error message and resets the
    ///   ViewModel to idle after the user dismisses the alert.
    private func presentAlert(_ error: AppError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        switch error {
        case .unsupportedContainer:
            alert.messageText     = "Compatibility Error"
            alert.informativeText = "This file's format is not supported at this time."
            // `.unsupportedContainer` and `.incompatibleStreams` both show a
            // static message and return the user to their prior state unchanged.
            // The presentation logic is identical for both cases; no reset is
            // needed on dismissal, so the sheet callback is an empty no-op.
            presentWarningAlert(alert)

        case .incompatibleStreams:
            alert.messageText     = "Compatibility Error"
            alert.informativeText = "The file does not contain a compatible audio stream."
            presentWarningAlert(alert)

        case .processing(let message):
            alert.messageText     = "Processing Error"
            alert.informativeText = message

            // The sheet blocks only the main window: a file dropped or opened
            // from the menu while it is up starts a new session, and this reset
            // must not wipe that one when the user finally dismisses the alert.
            let session = fileSession
            let resetAfterDismissal = { [weak self] in
                guard let self, self.fileSession == session else { return }
                self.tearDownForegroundJob()
                withAnimation(Self.metadataAnimation) {
                    self.metadata            = nil
                    self.isSpectrogramFading = false
                }
                self.effectiveNyquist = nil
                self.spectrogramImage = nil
                self.analysisState    = .idle
                self.currentFileURL   = nil
                // Wipe the cache along with all other file state so a subsequent
                // open of the same file starts completely fresh.
                self.beginFileSession()
                Self.log("ViewModel reset to idle after processing error dismissal.")
            }

            if let window = sheetHostWindow {
                alert.beginSheetModal(for: window) { _ in resetAfterDismissal() }
            } else {
                alert.runModal()
                resetAfterDismissal()
            }
        }
    }

    /// The window to present an alert sheet on: `hostingWindow`, unless it
    /// already shows a sheet (the Open or Save panel) — a second sheet is never
    /// presented and its completion never runs, which would lose the alert and,
    /// for a processing error, the reset that its dismissal performs. `nil`
    /// means run the alert app-modally instead.
    private var sheetHostWindow: NSWindow? {
        guard let window = hostingWindow, window.attachedSheet == nil else { return nil }
        return window
    }

    /// Present `alert` as a sheet attached to `hostingWindow`, or run it
    /// app-modally when no window is available. Used for warning alerts
    /// that require no action on dismissal (unsupported container,
    /// incompatible streams). Extracted to eliminate the identical
    /// `if let window / else` branch that was duplicated for each of
    /// those two cases in the former `presentAlert` implementation.
    private func presentWarningAlert(_ alert: NSAlert) {
        if let window = sheetHostWindow {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }
}
