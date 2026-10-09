// MARK: - SpectrumApp.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The application entry point. Registers preference defaults and bootstraps the logger before
// anything else runs, configures the root SwiftUI scene, disables automatic window tabbing,
// strips all system-provided menu commands in favor of SpectrumMenuBar, and
// defines the app-wide Notification.Name constants used to coordinate menu actions with
// AppDelegate. The settings window is built by AppDelegate from the shared
// SettingsKit, outside the SwiftUI scene graph.

import AppKit
import SwiftUI

@main
struct SpectrumApp: App {

    @State private var viewModel: SpectrogramViewModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Preferences and the logger come first: the view model below reads
        // preferences and logs from its initializer, and this runs before any
        // app-delegate callback — `applicationWillFinishLaunching` is too late.
        // (A `@State` property initializer would run before this body, so the
        // view model is created here, explicitly, after both.)
        Preferences.ensureDefaultsRegistered()
        Logger.bootstrap(.init(
            fileName: "Spectrum.log",
            destination: .userLibraryLogs(subdirectory: "Spectrum"),
            isEnabled: { Preferences.loggingEnabled }))
        Logger.prepareLogDirectory()
        Preferences.removeObsoleteKeys()   // after bootstrap, so the removal is logged

        // Must be set before any NSWindow is created.
        MenuBarPolicy.disableAutomaticWindowTabbing()

        _viewModel = State(initialValue: SpectrogramViewModel())
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(viewModel)
                // Files opened from Finder ("Open With", a Dock-icon drop) go
                // through the same path as a drop on the window.
                .onAppear { appDelegate.fileOpenHandler = { [viewModel] in viewModel.open(url: $0) } }
                // Let the existing window claim those open events; otherwise
                // WindowGroup spawns a fresh (empty) window for each one.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        // Fix the window at exactly 640×480.
        .defaultSize(width: 640, height: 480)
        .windowResizability(.contentSize)
        // Strip every system-provided command group so SpectrumMenuBar has
        // full, uncontested control of the menu bar.
        .commandsRemoved()
        .commands {
            SpectrumMenuBar(viewModel: viewModel)
        }

        // NOTE: A SwiftUI Settings scene is intentionally absent.
        //
        // Adding a Settings scene introduces an independent scene scope that
        // does not inherit .commandsRemoved() from the WindowGroup above.
        // This causes SwiftUI to re-inject system menu items — Services,
        // Help, and a duplicate "Settings…" entry — that are otherwise
        // cleanly suppressed. The settings window is therefore managed
        // entirely by SettingsWindowController in AppDelegate, using an
        // NSTabViewController with tabStyle = .toolbar to produce the
        // standard macOS toolbar-tab settings window appearance.
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted by SpectrumMenuBar when the user selects "Settings…".
    /// AppDelegate observes this and opens the settings window.
    static let openSpectrumSettings = Notification.Name("openSpectrumSettings")
}

// MARK: - AppDelegate

/// Handles application lifecycle events that SwiftUI's scene API does not
/// directly expose, and owns the settings window controller.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, Loggable {
    nonisolated static let logTag = "[AppDelegate]"

    /// The settings window, built from the shared `SettingsKit` in
    /// `applicationWillFinishLaunching`.
    ///
    /// A single tab (General), so the toolbar tab bar is hidden and the pane is
    /// hosted directly.
    private(set) var settingsWindowController: SettingsWindowController!

    /// Opens a file handed to the app by Finder. Installed once the main window
    /// appears; until then the most recent URL waits in `pendingOpenURL`, since
    /// on a cold launch `application(_:open:)` arrives before any view exists.
    var fileOpenHandler: ((URL) -> Void)? {
        didSet {
            guard let handler = fileOpenHandler, let url = pendingOpenURL else { return }
            pendingOpenURL = nil
            handler(url)
        }
    }
    private var pendingOpenURL: URL?

    /// Assembles the settings window configuration. A standalone method rather than
    /// a `lazy` initializer: a `lazy var` whose initializer closure builds the tab
    /// list crashes SILGen under `-swift-version 6`.
    private static func makeSettingsWindowController() -> SettingsWindowController {
        let tabs: [SettingsTabSpec] = [
            .swiftUI(id: "general", title: "General", symbol: "gearshape") {
                GeneralTabView()
            }
        ]
        // Sized to the tab's content at the fixed width, so the last row ends at the
        // standard 18 pt padding with no dead space below it, instead of a hand-tuned
        // constant that drifts whenever a caption changes.
        return SettingsWindowController(.init(
            title: "Spectrum Settings",
            sizing: .fitToContent(width: 480),
            tabs: tabs,
            tabBar: tabs.count == 1 ? .hidden : .toolbar))
    }

    /// Preferences and the logger are already set up by `SpectrumApp.init()`.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Hide "Start Dictation…" and "Emoji & Symbols": AppKit reads these keys
        // once, while building the menu bar, so this is the last moment.
        MenuBarPolicy.suppressInputMenuItems()

        // Built after defaults and the logger: measuring the tab views instantiates
        // their @AppStorage bindings and the logging section.
        settingsWindowController = Self.makeSettingsWindowController()

        // Observe the settings-open notification posted by SpectrumMenuBar.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenSettings),
            name: .openSpectrumSettings,
            object: nil
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable full-screen capability on all existing windows and suppress
        // the macOS-injected "Enter Full Screen" menu item in the View menu.
        // NSWindowCollectionBehavior.fullScreenNone prevents AppKit from adding
        // the full-screen toggle button and removes the menu item entirely.
        for window in NSApp.windows {
            disableFullScreen(for: window)
        }

        // SwiftUI builds no Edit menu (MenuBar empties both of its slots);
        // install AppKit's, which validates against the first responder.
        StandardEditMenu.install(undoRedo: .responderChain)
    }

    /// Finder "Open With" / Dock-icon drop. Spectrum analyzes one file at a time,
    /// so only the first URL is used.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        log("application(_:open:) — \(url.lastPathComponent)\(urls.count > 1 ? " (+\(urls.count - 1) ignored)" : "")")
        if let handler = fileOpenHandler {
            handler(url)
        } else {
            pendingOpenURL = url
        }
    }

    /// Quit the application when the last window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Flush the logger before the process exits so buffered messages are not lost.
    /// The blocking form: the process exits as soon as this returns, and a
    /// fire-and-forget shutdown would race it and drop the last flush interval's
    /// worth of lines.
    func applicationWillTerminate(_ notification: Notification) {
        Logger.shutdownLoggingBlocking()
    }

    // MARK: - Full-screen suppression

    /// Remove full-screen capability from `window` so AppKit does not inject
    /// "Enter Full Screen" into the View menu and does not show the green
    /// full-screen button in the title bar.
    private func disableFullScreen(for window: NSWindow) {
        var behavior = window.collectionBehavior
        behavior.remove(.fullScreenPrimary)
        behavior.remove(.fullScreenAuxiliary)
        behavior.insert(.fullScreenNone)
        window.collectionBehavior = behavior
    }

    // MARK: - Notification handlers

    @objc private func handleOpenSettings() {
        settingsWindowController.open()
    }
}
