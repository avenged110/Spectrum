// MARK: - GlobalUtilities.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Miscellaneous utilities shared across the application: the analysis overlay, path-bar chrome,
// the shared open panel, the NSViewRepresentable window accessor, and number formatting.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - AnalysisOverlay

/// Indeterminate progress indicator displayed inside the spectrogram graph area
/// during multi-second processing operations (decoder stalls).
///
/// ## Design intent
/// This view is a pure presentational component: it receives a label string and
/// renders a circular spinner above it, centered within whatever frame it is
/// given. All visibility and animation decisions live in the caller
/// (`SpectrogramView`), keeping this type free of any ViewModel coupling.
///
/// ## Background
/// Uses a solid black fill that completely covers the graph area behind it
/// (partial spectrogram columns, the idle drop prompt, etc.), so the caller
/// does not need to clear or reset any layer state before showing the overlay.
///
/// ## Animation
/// The overlay participates in SwiftUI's `.transition(.opacity)` system.
/// Callers must apply `.transition(.opacity)` to the conditional branch that
/// shows or hides this view, and key an `.animation(value:)` modifier on a
/// parent container so SwiftUI can interpolate opacity on both insertion and
/// removal. Animating from the parent rather than from within this view ensures
/// the transition is driven by a single stable value change and does not flash
/// at the beginning or end of the animation.
struct AnalysisOverlay: View {

    /// Single line of explanatory text shown below the spinner.
    var label: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.9)
                // Force the spinner to render in white so it is legible against
                // the solid black background. ProgressView inherits tint from the
                // environment; explicitly setting it here avoids relying on the
                // system appearance, which could render the spinner dark on dark.
                .tint(.white)
            Text(label)
                .font(.callout)
                // Use a slightly dimmed white rather than full-opacity white so
                // the label is readable but not jarring against the black fill.
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Solid black fill that completely covers whatever is present in the
        // graph area behind the overlay (partial spectrogram, idle prompt, etc.).
        // `.background` fills the frame established by the parent — in practice
        // the inner graph rect in SpectrogramView — so the overlay is always
        // bounded by the graph border and never bleeds into the ruler area.
        // Opacity is driven entirely by the `.transition(.opacity)` / `.animation`
        // pair on the conditional branch in SpectrogramView, so the overlay
        // fades in and out correctly without any opacity modifier here.
        .background(Color.black)
    }
}

// MARK: - PathBarChrome

/// The visual shell of a path bar (background fill + border stroke) at a fixed
/// 24 pt height, accepting arbitrary content via a `@ViewBuilder` slot.
///
/// Separating chrome from content allows callers (e.g. `MetadataBar`) to keep
/// the shell permanently visible while animating only the content layer — so
/// the bar outline never flickers during a crossfade.
struct PathBarChrome<Content: View>: View {

    @ViewBuilder let content: Content

    private let barHeight: CGFloat = 24

    var body: some View {
        ZStack(alignment: .leading) {
            // Shell — always rendered at full opacity.
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor))
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)

            // Content slot — caller controls opacity/animation.
            content
        }
        .frame(height: barHeight)
    }
}

// MARK: - SharedOpenPanel

/// Configuration options for presenting an NSOpenPanel as a sheet.
@MainActor
struct OpenPanelConfiguration {
    var canChooseFiles: Bool = true
    var canChooseDirectories: Bool = false
    var allowsMultipleSelection: Bool = false
    var allowedContentTypes: [UTType] = []

    var title: String?
    var message: String?
    var prompt: String?

    init(
        canChooseFiles: Bool = true,
        canChooseDirectories: Bool = false,
        allowsMultipleSelection: Bool = false,
        allowedContentTypes: [UTType] = [],
        title: String? = nil,
        message: String? = nil,
        prompt: String? = nil
    ) {
        self.canChooseFiles = canChooseFiles
        self.canChooseDirectories = canChooseDirectories
        self.allowsMultipleSelection = allowsMultipleSelection
        self.allowedContentTypes = allowedContentTypes
        self.title = title
        self.message = message
        self.prompt = prompt
    }
}

/// The result of an open-panel presentation.
@MainActor
enum OpenPanelSelection {
    case canceled
    case urls([URL])
}

/// Centralized helper for presenting `NSOpenPanel` as a sheet attached to a window.
@MainActor
enum OpenPanelPresenter {

    /// Presents a configured `NSOpenPanel` as a sheet.
    ///
    /// - Parameters:
    ///   - configuration: Configuration options for the panel.
    ///   - window: The window to attach the sheet to.
    ///             If `nil`, falls back to `keyWindow` then `mainWindow`.
    /// - Returns: `.urls([URL])` if the user confirmed, `.canceled` otherwise.
    static func present(
        configuration: OpenPanelConfiguration,
        attachedTo window: NSWindow? = nil
    ) async -> OpenPanelSelection {
        let panel = NSOpenPanel()

        panel.canChooseFiles = configuration.canChooseFiles
        panel.canChooseDirectories = configuration.canChooseDirectories
        panel.allowsMultipleSelection = configuration.allowsMultipleSelection

        if !configuration.allowedContentTypes.isEmpty {
            panel.allowedContentTypes = configuration.allowedContentTypes
        }

        // Default initial directory: ~/Desktop.
        if let desktop = FileManager.default.urls(
            for: .desktopDirectory, in: .userDomainMask).first {
            panel.directoryURL = desktop
        }

        if let title = configuration.title { panel.title = title }
        if let message = configuration.message { panel.message = message }
        if let prompt = configuration.prompt { panel.prompt = prompt }

        // Enforce fixed size and non-resizable behavior.
        panel.styleMask.remove(.resizable)
        panel.setContentSize(NSSize(width: 600, height: 400))
        panel.isMovable = false

        let targetWindow = window ?? NSApp.keyWindow ?? NSApp.mainWindow

        return await withCheckedContinuation { continuation in
            if let targetWindow {
                panel.beginSheetModal(for: targetWindow) { response in
                    if response == .OK {
                        continuation.resume(returning: .urls(panel.urls))
                    } else {
                        continuation.resume(returning: .canceled)
                    }
                }
            } else {
                // Fallback: app-modal (should rarely occur).
                panel.begin { response in
                    if response == .OK {
                        continuation.resume(returning: .urls(panel.urls))
                    } else {
                        continuation.resume(returning: .canceled)
                    }
                }
            }
        }
    }
}

// MARK: - WindowAccessor

/// An `NSViewRepresentable` shim that captures the hosting `NSWindow` from within
/// a SwiftUI view hierarchy. Attach it via `.background(WindowAccessor(window: $hostingWindow))`.
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Defer the binding write one run-loop turn so the NSView is fully
        // inserted into the window hierarchy before we read view.window.
        // `unsafe` here and in updateNSView: AppKit declares `NSView.window`
        // `unowned(unsafe)`; it is read on the main actor while the view is live.
        Task { @MainActor in
            self.window = unsafe view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Capture the window reference into a local so the value is stable
        // across the async hop. Both the identity check and the binding write
        // are performed inside the same @MainActor Task, ensuring they execute
        // atomically on a single actor hop. This prevents the race that arises
        // when multiple updateNSView calls arrive in rapid succession: if the
        // guard ran outside the Task (against the binding's value at call time),
        // all callers could pass it before any Task had actually written the new
        // value, dispatching redundant writes. Performing both operations inside
        // the Task means each one re-reads self.window against the already-written
        // state, so only the first write proceeds and the rest are no-ops.
        //
        // The synchronous check below only skips the Task in the common case —
        // `updateNSView` runs on every render of the containing view, which is
        // every display-link frame while a spectrogram fills — and never
        // replaces the check inside the Task.
        let current = unsafe nsView.window
        guard current !== window else { return }
        Task { @MainActor in
            guard current !== self.window else { return }
            self.window = current
        }
    }
}

// MARK: - Duration

extension Duration {
    /// The duration in seconds, as a `Double`.
    var seconds: Double {
        let (s, atto) = components
        return Double(s) + Double(atto) / 1e18
    }
}

// MARK: - Number formatting
//
// Replacements for `String(format:)`, whose C-variadic initializer strict
// memory safety flags as unsafe. Both match the printf output they replace.

extension BinaryFloatingPoint {
    /// `self` with exactly `digits` fraction digits — `String(format: "%.<digits>f", self)`.
    /// POSIX locale, as printf: a period separator and no grouping.
    func fixed(_ digits: Int) -> String {
        Double(self).formatted(.number
            .precision(.fractionLength(digits))
            .grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX")))
    }
}

extension BinaryFloatingPoint {
    /// `self` truncated toward zero, saturating at `Int`'s bounds, with NaN as
    /// 0. `Int(_:)` traps on all three, and a damaged header can claim a
    /// duration past `Int.max` seconds, which every label must survive.
    var saturatingInt: Int {
        if isNaN { return 0 }
        if self >= Self(Int.max) { return .max }   // Self(Int.max) rounds up to 2⁶³
        if self < Self(Int.min) { return .min }
        return Int(self)
    }
}

extension BinaryInteger {
    /// `self` left-padded with zeros to at least `width` characters —
    /// `String(format: "%0<width>d", self)`.
    func zeroPadded(_ width: Int) -> String {
        let digits = String(self)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
