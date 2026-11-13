// MARK: - GlobalUtilities.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Miscellaneous utilities shared across the application: the analysis overlay, the
// NSViewRepresentable window accessor, and number formatting. The path-bar chrome and the
// shared open panel are in UtilityKit.

import AppKit
import SwiftUI

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

// MARK: - WindowAccessor

/// An `NSViewRepresentable` shim that captures the hosting `NSWindow` from within
/// a SwiftUI view hierarchy. Attach it via `.background(WindowAccessor(window: $hostingWindow))`.
///
/// The window arrives through `viewWillMove(toWindow:)`, whose argument is an
/// ordinary strong reference, rather than by reading `NSView.window`, which
/// AppKit declares `unowned(unsafe)` (an opt-out of strict memory safety). It
/// also fires only when the window actually changes, so nothing runs on the
/// per-frame `updateNSView` calls a filling spectrogram causes.
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.onWindowChange = report
        return view
    }

    func updateNSView(_ nsView: WindowReportingView, context: Context) {
        nsView.onWindowChange = report
    }

    /// Writes the binding one run-loop turn later: the callback fires while
    /// AppKit is moving the view, in the middle of a SwiftUI update, where a
    /// state write would be "modifying state during view update". The check
    /// inside the task drops a value already superseded or already current.
    private func report(_ newWindow: NSWindow?) {
        let binding = $window
        Task { @MainActor in
            guard binding.wrappedValue !== newWindow else { return }
            binding.wrappedValue = newWindow
        }
    }

    final class WindowReportingView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            onWindowChange?(newWindow)
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
