// MARK: - Preferences.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Centralized read/write interface for all UserDefaults-backed preferences. Owns the canonical key
// strings referenced by @AppStorage bindings throughout the app, registers sane defaults at launch,
// and provides typed accessors with side-effect hooks (e.g., Logger.shutdown on logging toggle).

import Foundation

struct Preferences: Loggable {
    nonisolated static let logTag = "[Preferences]"

    // `UserDefaults` is documented as thread-safe but not marked `Sendable` in
    // this SDK, so it cannot be held in a stored static without an unsafe
    // opt-out. Reading `.standard` on each access needs none. It is read from
    // more than the main actor — the logger's enabled check reads
    // `loggingEnabled` on the logger's own actor — which the thread-safety
    // guarantee covers.
    private static var defaults: UserDefaults { .standard }

    // MARK: - Keys
    private enum Keys {
        static let loggingEnabled            = "preferences.loggingEnabled"
        static let frequencyAxisClamp        = "preferences.frequencyAxisClamp"
        static let backgroundPrefetch        = "preferences.backgroundPrefetch"
        static let limitedBackgroundPrefetch = "preferences.limitedBackgroundPrefetch"
    }

    // MARK: - Fixed pipeline parameters
    //
    // Multithreaded column computation, 50% FFT window overlap and segmented
    // (parallel) decoding were once Development-tab toggles; all three proved
    // essential to Spectrum's performance and are now unconditional. The hop
    // fraction is kept here as the single definition AnalysisPipeline reads.

    /// FFT hop as a fraction of the window: 0.5 = 50% overlap, doubling the
    /// number of windows averaged per column.
    static let overlapFraction = 0.5

    // Expose key strings so @AppStorage bindings in SettingsView can reference
    // them without duplicating string literals.
    static var loggingEnabledKey:     String { Keys.loggingEnabled }
    static var frequencyAxisClampKey: String { Keys.frequencyAxisClamp }
    static var backgroundPrefetchKey: String { Keys.backgroundPrefetch }
    static var limitedBackgroundPrefetchKey: String { Keys.limitedBackgroundPrefetch }

    // MARK: - Default Registration
    // Register sane defaults once. Guarantees defined behavior throughout the
    // application without callers needing to handle nil reads from UserDefaults.
    private static let _registeredDefaults: Void = {
        defaults.register(defaults: [
            Keys.loggingEnabled:     false,
            Keys.frequencyAxisClamp: FrequencyAxisClamp.automatic.rawValue,
            Keys.backgroundPrefetch: false,
            Keys.limitedBackgroundPrefetch: false,
        ])
    }()

    // Ensure registration has run. Called explicitly at launch — before any read
    // occurs — so defaults are always in place.
    static func ensureDefaultsRegistered() { _ = _registeredDefaults }

    /// Keys earlier versions wrote that nothing reads any more: the persisted
    /// spectrogram settings (see `SpectrogramSettings`) and the preferences of
    /// removed features — the FFmpeg toggle, multithreading, the overlap
    /// setting (now a constant) and segmented decode (now always on). Deleting
    /// an absent key is a no-op, so this is safe on every launch.
    static func removeObsoleteKeys() {
        for key in ["SpectrogramSettings",
                    "preferences.ffmpegEnabled",
                    "preferences.multithreading",
                    "preferences.overlapFraction",
                    "preferences.segmentedDecode"]
        where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            log("Removed obsolete preference \(key).")
        }
    }

    // MARK: - Preferences
    // loggingEnabled: read by the Logger's enabled predicate on every message.
    // Written only through the @AppStorage binding in the shared
    // SettingsLoggingSection, whose `.onChange(of:)` handler also logs the
    // toggle and — when logging is disabled — flushes and shuts the Logger down
    // (logForced + Logger.shutdownLogging), so the "logging toggled" entry is
    // emitted while logging is still active.
    static var loggingEnabled: Bool { defaults.bool(forKey: Keys.loggingEnabled) }

    // frequencyAxisClamp: integer-backed enum with five modes.
    //   0 (.automatic)  — axis scale determined by the audio file's sample rate.
    //   1 (.fixed22kHz) — always display 0–22 kHz.
    //   2 (.fixed24kHz) — always display 0–24 kHz.
    //   3 (.fixed44kHz) — always display 0–44 kHz.
    //   4 (.fixed48kHz) — always display 0–48 kHz.
    static var frequencyAxisClamp: FrequencyAxisClamp {
        get {
            let raw = defaults.integer(forKey: Keys.frequencyAxisClamp)
            return FrequencyAxisClamp(rawValue: raw) ?? .automatic
        }
        set {
            setIfChanged(newValue.rawValue, forKey: Keys.frequencyAxisClamp,
                logMessage: "frequencyAxisClamp set to \(newValue)")
        }
    }

    // backgroundPrefetch: after the selected channel's spectrogram is done,
    // compute the file's other channels and streams into the magnitude cache
    // in the background (see SpectrogramViewModel's "Background prefetch").
    // true  = prefetch under a half-machine, low-QoS budget, paused whenever
    //         the user starts a run of their own.
    // false = only ever compute what the user selects.
    static var backgroundPrefetch: Bool {
        get { defaults.bool(forKey: Keys.backgroundPrefetch) }
        set {
            setIfChanged(newValue, forKey: Keys.backgroundPrefetch,
                logMessage: "backgroundPrefetch set to \(newValue)")
        }
    }

    // limitedBackgroundPrefetch: child of backgroundPrefetch. Meaningful only
    // while the parent is on; the Settings window disables the checkbox when
    // the parent is off and mirrors every parent toggle into it (on with on,
    // off with off), so unconstrained prefetching is opt-out, not opt-in.
    // true  = only prefetch files with exactly one stream of exactly two
    //         channels whose duration is under ten minutes
    //         (see `limitedPrefetchMaxDuration`).
    // false = prefetch every file, whatever its channel/stream count or length.
    static var limitedBackgroundPrefetch: Bool {
        get { defaults.bool(forKey: Keys.limitedBackgroundPrefetch) }
        set {
            setIfChanged(newValue, forKey: Keys.limitedBackgroundPrefetch,
                logMessage: "limitedBackgroundPrefetch set to \(newValue)")
        }
    }

    /// The stream/channel shape and duration ceiling a file must satisfy to be
    /// prefetched while `limitedBackgroundPrefetch` is on.
    static let limitedPrefetchStreamCount  = 1
    static let limitedPrefetchChannelCount = 2
    static let limitedPrefetchMaxDuration: TimeInterval = 10 * 60

    // MARK: - Change Guards
    //
    // Typed overloads replace the former generic `setIfChanged<T: Equatable>`
    // that used runtime `as?` casts to dispatch to the correct UserDefaults read
    // method. The concrete overloads below are resolved at compile time, avoiding
    // any runtime type-check overhead on every preference write.

    /// Write a `Bool` to UserDefaults only if the stored value differs.
    private static func setIfChanged(
        _ value: Bool,
        forKey key: String,
        logMessage: String? = nil
    ) {
        guard defaults.bool(forKey: key) != value else { return }
        defaults.set(value, forKey: key)
        if let message = logMessage { log(message) }
    }

    /// Write an `Int` to UserDefaults only if the stored value differs.
    private static func setIfChanged(
        _ value: Int,
        forKey key: String,
        logMessage: String? = nil
    ) {
        guard defaults.integer(forKey: key) != value else { return }
        defaults.set(value, forKey: key)
        if let message = logMessage { log(message) }
    }

}

// MARK: - FrequencyAxisClamp

/// The frequency-axis scale modes available to the user.
///
/// Fixed cases force the axis display ceiling to the named value regardless of
/// the loaded file's sample rate. When the ceiling exceeds the file's actual
/// Nyquist, the region above the file's Nyquist renders as empty (black) space,
/// which is the correct and intended behavior. When the ceiling is below the
/// file's actual Nyquist, only frequencies up to the ceiling are rendered.
enum FrequencyAxisClamp: Int, CaseIterable, Identifiable, Sendable {
    /// Scale is determined automatically by the file's sample rate.
    case automatic  = 0
    /// Always render the axis from 0 to 22,050 Hz.
    case fixed22kHz = 1
    /// Always render the axis from 0 to 24,000 Hz.
    case fixed24kHz = 2
    /// Always render the axis from 0 to 44,100 Hz.
    case fixed44kHz = 3
    /// Always render the axis from 0 to 48,000 Hz.
    case fixed48kHz = 4

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .automatic:  "Automatic"
        case .fixed22kHz: "0 – 22 kHz"
        case .fixed24kHz: "0 – 24 kHz"
        case .fixed44kHz: "0 – 44 kHz"
        case .fixed48kHz: "0 – 48 kHz"
        }
    }
}
