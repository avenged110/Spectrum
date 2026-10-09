// MARK: - MenuBar.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Defines the complete Spectrum menu bar. The application-menu items, the emptied system slots, the
// Edit menu and "Bring All to Front" are the shared MenuBarKit pieces; this file adds Spectrum's own
// content — the File items and the View menu's Channel and Stream submenus.

import AppKit
import SwiftUI

// MARK: - SpectrumMenuBar

/// Defines the complete Spectrum menu bar.
///
/// The generic rules — why the Edit menu is AppKit's (`StandardEditCommands` +
/// `StandardEditMenu`, installed by AppDelegate), why `.windowSize` and
/// `.windowArrangement` are left to AppKit, why View items go in through
/// `CommandGroup(after: .toolbar)` rather than a `CommandMenu("View")` — are
/// documented on the MenuBarKit pieces themselves. Spectrum-specific notes:
///
/// ### Settings window
/// "Settings…" posts `.openSpectrumSettings`; AppDelegate opens the settings
/// window it owns (SettingsKit). There is no SwiftUI `Settings` scene: it would
/// not inherit `.commandsRemoved()` and would re-inject Services, Help and a
/// second "Settings…".
///
/// ### About Spectrum
/// The standard About panel, which picks up the icon, name and version and
/// renders the GPL-3.0 / attribution text from Credits.html.
///
/// ### Channel / Stream shortcuts
/// ⌥C / ⌥S (next) and ⇧⌥C / ⇧⌥S (previous) are visible menu items, so AppKit
/// delivers them regardless of which window or view has focus; hidden buttons
/// are not guaranteed to receive shortcuts. They sit above the checkmarked
/// channel/stream entries and are plain Buttons, outside the Toggle selection.
/// With no file loaded each submenu shows only "No File Loaded".
///
/// ⌥C / ⌥S are also how "ç" and "ß" are typed, and menu key equivalents are
/// matched before text input — so typing either into the Save panel's filename
/// switched the channel or stream (and the export captured a different
/// spectrogram). While a sheet is attached (`viewModel.isSheetPresented`) the
/// four items therefore lose their shortcuts, not just their enabled state:
/// AppKit consumes a key equivalent that matches a DISABLED item too (it
/// beeps), so only a missing shortcut lets the character reach the field. They
/// are also disabled then, and the actions refuse to run, because the items can
/// still be clicked while a panel is open.
///
/// ### Group {} splitting
/// `CommandsBuilder` takes at most ten arguments per block; each `Group` resets
/// the count.
struct SpectrumMenuBar: Commands {

    @Bindable var viewModel: SpectrogramViewModel

    var body: some Commands {

        // ── Application menu ──────────────────────────────────────────────────
        Group {
            AppInfoCommands(appName: "Spectrum")
            AppSettingsCommands {
                NotificationCenter.default.post(name: .openSpectrumSettings, object: nil)
            }
            AppVisibilityCommands(appName: "Spectrum")
            AppTerminationCommands(appName: "Spectrum")
        }

        // ── File, Edit and Window menus ───────────────────────────────────────
        Group {
            // File menu — Open, Save Spectrogram, Close.
            CommandGroup(replacing: .newItem) {
                Button("Open\u{2026}") {
                    viewModel.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(viewModel.isSheetPresented)

                Button("Save Spectrogram\u{2026}") {
                    viewModel.exportSpectrogram()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(viewModel.spectrogramImage == nil || viewModel.isSheetPresented)

                Divider()

                Button("Close Window") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            // No EmptyCommandGroup(.saveItem / .printItem): `.commandsRemoved()`
            // already drops those items, and emptying the slots only left two
            // stray separators at the bottom of the File menu. Likewise no
            // ServicesSuppressionCommands — there is no Services menu to remove,
            // and its empty section doubled a separator in the Spectrum menu.

            // Edit: SwiftUI builds none; AppDelegate installs AppKit's.
            StandardEditCommands()

            BringAllToFrontCommands()
        }

        // ── View menu: Channel and Stream ─────────────────────────────────────
        Group {
            EmptyCommandGroup(.sidebar)
            EmptyCommandGroup(.toolbar)

            // Channel and Stream submenus. Toggle items show the selected index
            // with a checkmark, kept in sync with the GUI pickers through the
            // shared ViewModel.
            CommandGroup(after: .toolbar) {
                Menu("Channel") {
                    if let meta = viewModel.metadata, meta.channelCount > 0 {
                        // Cycle action — sits above the checkmark selection list
                        // and does not participate in Toggle-based selection.
                        Button("Next Channel") {
                            viewModel.cycleChannelForward()
                        }
                        .keyboardShortcut(cycleShortcut("c", [.option]))
                        .disabled(meta.channelCount <= 1 || viewModel.isSheetPresented)

                        Button("Previous Channel") {
                            viewModel.cycleChannelBackward()
                        }
                        .keyboardShortcut(cycleShortcut("c", [.shift, .option]))
                        .disabled(meta.channelCount <= 1 || viewModel.isSheetPresented)

                        Divider()

                        ForEach(0..<meta.channelCount, id: \.self) { index in
                            Toggle(
                                "Channel \(index + 1)",
                                isOn: Binding(
                                    get: { viewModel.settings.channelIndex == index },
                                    set: { isOn in
                                        if isOn { viewModel.selectChannel(index) }
                                    }
                                )
                            )
                            .disabled(meta.channelCount == 1)
                        }
                    } else {
                        Text("No File Loaded")
                            .disabled(true)
                    }
                }

                Menu("Stream") {
                    if let meta = viewModel.metadata, meta.streamCount > 0 {
                        // Cycle action — sits above the checkmark selection list
                        // and does not participate in Toggle-based selection.
                        Button("Next Stream") {
                            viewModel.cycleStreamForward()
                        }
                        .keyboardShortcut(cycleShortcut("s", [.option]))
                        .disabled(meta.streamCount <= 1 || viewModel.isSheetPresented)

                        Button("Previous Stream") {
                            viewModel.cycleStreamBackward()
                        }
                        .keyboardShortcut(cycleShortcut("s", [.shift, .option]))
                        .disabled(meta.streamCount <= 1 || viewModel.isSheetPresented)

                        Divider()

                        ForEach(0..<meta.streamCount, id: \.self) { index in
                            Toggle(
                                "Stream \(index + 1)",
                                isOn: Binding(
                                    get: { viewModel.settings.streamIndex == index },
                                    set: { isOn in
                                        if isOn { viewModel.selectStream(index) }
                                    }
                                )
                            )
                            .disabled(meta.streamCount == 1)
                        }
                    } else {
                        Text("No File Loaded")
                            .disabled(true)
                    }
                }
            }
        }
    }

    /// The cycle shortcut, or none while a sheet is attached (see "Channel /
    /// Stream shortcuts").
    private func cycleShortcut(_ key: KeyEquivalent,
                               _ modifiers: EventModifiers) -> KeyboardShortcut? {
        viewModel.isSheetPresented ? nil : KeyboardShortcut(key, modifiers: modifiers)
    }
}
