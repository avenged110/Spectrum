// MARK: - SettingsView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// SwiftUI content view for the settings window's single General tab.
//
// The window chrome, the focus sink, the log-file monitor and the whole Debug Logging
// block come from the shared SettingsKit.swift; what remains here is Spectrum's
// own tab content and in what order it appears.

import SwiftUI

// MARK: - General Tab

@MainActor
struct GeneralTabView: View {

    // @AppStorage bindings write directly to UserDefaults and keep the UI in
    // sync automatically. The key strings are sourced from Preferences so there
    // is a single canonical definition throughout the codebase.
    @AppStorage(Preferences.frequencyAxisClampKey)
        private var frequencyAxisClamp: Int = FrequencyAxisClamp.automatic.rawValue
    @AppStorage(Preferences.backgroundPrefetchKey)
        private var backgroundPrefetch: Bool = false   // registered default; see Preferences
    @AppStorage(Preferences.limitedBackgroundPrefetchKey)
        private var limitedBackgroundPrefetch: Bool = false   // registered default; see Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // ── Background Prefetch ───────────────────────────────────────────
            // ContentView mirrors the same key and forwards changes to the
            // ViewModel, which starts or cancels the prefetch accordingly.
            Toggle(isOn: $backgroundPrefetch) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prepare other channels and streams in the background")
                    Text("After the selected spectrogram has rendered, process and cache the file’s remaining channels and streams while idle so they will be ready, if needed. This convenience will result in a bounded, but significant background computational load every time a file is opened, scaling with channel/stream count and duration.")
                        .font(.system(size: NSFont.smallSystemFontSize))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Child of the row above: only interactive while the parent is on.
            // It follows the parent in both directions — on when the parent is
            // switched on (so unconstrained prefetching is opt-out rather than
            // opt-in), and off when the parent is switched off so a disabled
            // row never carries a stale checkmark.
            Toggle(isOn: $limitedBackgroundPrefetch) {
                Text("Limit to files with one sub-ten minute stereo stream")
            }
            .disabled(!backgroundPrefetch)
            .settingsChildRowInset()
            .onChange(of: backgroundPrefetch) { _, isOn in
                limitedBackgroundPrefetch = isOn
            }

            Divider()

            // ── Frequency Axis Scale ──────────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Frequency axis scale:")
                    Picker("", selection: $frequencyAxisClamp) {
                        ForEach(FrequencyAxisClamp.allCases) { clamp in
                            Text(clamp.displayName).tag(clamp.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    Spacer()
                }
                Text("Force the frequency axis to always use a consistent scale, or allow Spectrum to define the scale automatically, depending on the characteristics of the input file.")
                    .font(.system(size: NSFont.smallSystemFontSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 19)

            Divider()

            // ── Debug Logging ─────────────────────────────────────────────────
            // The shared section supplies the toggle, the caption, and the
            // Reveal/Clear buttons gated on the log file's existence by its own
            // LogFileMonitor. It writes the preference through its own
            // @AppStorage binding on the same key, logs the toggle, and handles
            // logForced/shutdownLogging on disable — nothing is left for a hook.
            SettingsLoggingSection(
                loggingEnabledKey: Preferences.loggingEnabledKey,
                title: "Debug logging"
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
    }
}
