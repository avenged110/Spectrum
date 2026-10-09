// MARK: - Exporter.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Handles PNG export of the spectrogram window. Captures the content view using AppKit's
// recommended layer-backed bitmap approach, presents a NSSavePanel sheet attached to the window,
// and writes the result atomically to the user-chosen path.

import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Exports the spectrogram window content (everything below the titlebar) to a PNG file.
enum Exporter {

    // MARK: - PNG write

    /// Save a CGImage as PNG to the given URL.
    private static func exportPNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw ExportError.cannotCreatePNG
        }
        try pngData.write(to: url, options: .atomic)
    }

    // MARK: - Window-content capture

    /// Render the content view of `window` (everything below the system titlebar)
    /// into a CGImage at the view's backing-store resolution.
    ///
    /// `NSView.bitmapImageRepForCachingDisplay(in:)` followed by
    /// `cacheDisplay(in:to:)` is the recommended AppKit approach for capturing
    /// an off-screen bitmap that respects layer-backed views, Core Animation
    /// layers, and the current display's scale factor — without requiring the
    /// window to be key or frontmost.
    @MainActor
    private static func captureContentView(of window: NSWindow) -> CGImage? {
        guard let contentView = window.contentView else { return nil }
        let bounds = contentView.bounds

        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        contentView.cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }

    // MARK: - Save panel

    /// Present a save panel as a sheet attached to `window`, capture the
    /// window's content view at that moment, and write the result as PNG.
    ///
    /// - Parameters:
    ///   - window: The window whose content will be captured and whose sheet
    ///             the save panel will be attached to.
    ///   - suggestedName: The default filename shown in the panel.
    @MainActor
    static func presentSavePanel(
        window: NSWindow,
        suggestedName: String
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true

        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }

            // Capture the content view one run-loop turn after the sheet
            // dismisses so the sheet is no longer composited into the snapshot.
            // Task { @MainActor in } is the Swift-native equivalent of
            // DispatchQueue.main.async inside an already-@MainActor context,
            // avoiding the GCD import dependency for this single hop.
            Task { @MainActor in
                guard let image = captureContentView(of: window) else {
                    let alert = NSAlert()
                    alert.messageText = "Export Failed"
                    alert.informativeText = "Could not capture the window content."
                    // beginSheetModal is preferred over runModal() inside a
                    // @MainActor Task: runModal() spins a nested event loop that
                    // blocks the cooperative executor, while beginSheetModal
                    // presents the alert asynchronously without blocking.
                    alert.beginSheetModal(for: window) { _ in }
                    return
                }
                do {
                    try exportPNG(image, to: url)
                } catch {
                    let alert = NSAlert(error: error)
                    alert.beginSheetModal(for: window) { _ in }
                }
            }
        }
    }

    // MARK: - Errors

    enum ExportError: LocalizedError {
        case cannotCreatePNG

        var errorDescription: String? {
            switch self {
            case .cannotCreatePNG: "Failed to create PNG image data"
            }
        }
    }
}
