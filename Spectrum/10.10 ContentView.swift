// MARK: - ContentView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The root view of the main window. Composes MetadataBar and SpectrogramView into a vertical stack,
// overlays state-dependent content (error message), and hosts the NSViewRepresentable drag-and-drop
// target that receives audio file URLs from the system pasteboard.

import AppKit
import SwiftUI

/// The root view. SpectrogramView is always present as the base layer;
/// the error overlay (if any) is applied on top of the entire VStack.
/// The analysis overlay (spinner) lives inside SpectrogramView itself,
/// correctly bounded by the inner graph rect.
struct ContentView: View {

    @Environment(SpectrogramViewModel.self) private var viewModel
    @State private var isDragTargeted = false
    @State private var hostingWindow: NSWindow?

    // Mirrors Preferences.frequencyAxisClampKey in UserDefaults. Placing the
    // @AppStorage binding here — rather than on the @Observable ViewModel —
    // ensures SwiftUI's standard @AppStorage diffing fires .onChange reliably.
    // An @ObservationIgnored @AppStorage on an @Observable class is invisible to
    // the SwiftUI observation system, so changes committed by the Settings window
    // Picker would never surface to .onChange(of:) callers in that arrangement.
    @AppStorage(Preferences.frequencyAxisClampKey)
    private var frequencyAxisClampRaw: Int = FrequencyAxisClamp.automatic.rawValue

    // Same arrangement for the background-prefetch checkbox.
    @AppStorage(Preferences.backgroundPrefetchKey)
    private var backgroundPrefetch: Bool = false   // registered default; see Preferences
    @AppStorage(Preferences.limitedBackgroundPrefetchKey)
    private var limitedBackgroundPrefetch: Bool = false   // registered default; see Preferences

    var body: some View {
        VStack(spacing: 0) {
            // Metadata bar — always shown; MetadataBar handles the nil case.
            MetadataBar(
                metadata:        viewModel.metadata,
                fileURL:         viewModel.currentFileURL,
                settings:        viewModel.settings,
                onSelectChannel: { viewModel.selectChannel($0) },
                onSelectStream:  { viewModel.selectStream($0) }
            )

            // The spectrogram view is always rendered. It draws an empty frame
            // with rulers when no data is present, fills in as analysis
            // progresses, and hosts the analysis overlay (spinner) directly
            // inside the graph rect. Error overlays sit on top of the entire
            // VStack via the `.overlay` modifier below.
            SpectrogramView(
                image:            viewModel.spectrogramImage,
                metadata:         viewModel.metadata,
                settings:         viewModel.settings,
                isFading:         viewModel.isSpectrogramFading,
                analysisState:    viewModel.analysisState,
                effectiveNyquist: viewModel.effectiveNyquist
            ) { width, height in
                viewModel.updateOutputDimensions(width: width, height: height)
            }
        }
        // Error overlay — applied to the full VStack (metadata bar + graph)
        // because a fatal error resets the entire ViewModel state and returns
        // the user to the idle screen. Spinner and decoding overlays use
        // SpectrogramView's internal Layer 6 instead and are bounded by the
        // graph border there.
        .overlay {
            if case .error(let message) = viewModel.analysisState {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36, weight: .thin))
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background.opacity(0.85))
            }
        }
        // Drag-target ring wraps the entire window canvas (metadata bar + graph).
        .overlay {
            if isDragTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .background(Color.accentColor.opacity(0.05))
                    .allowsHitTesting(false)
            }
        }
        // DropTargetView is an NSView-backed drag destination that reads the
        // file URL directly from NSPasteboard — synchronously, in the same
        // call stack as performDragOperation — so the system can retire the
        // drag image, focus ring, and cursor all in the same frame, with no
        // visual lag between them.
        .background(
            DropTargetView(
                isTargeted: $isDragTargeted,
                onDrop: { url in
                    viewModel.open(url: url)
                }
            )
        )
        .background(WindowAccessor(window: $hostingWindow))
        .onChange(of: hostingWindow) { _, window in
            viewModel.hostingWindow = window
        }
        .onChange(of: backgroundPrefetch) { _, _ in
            viewModel.handleBackgroundPrefetchChange()
        }
        .onChange(of: limitedBackgroundPrefetch) { _, _ in
            // Tightening the limit may disqualify the open file (cancel);
            // relaxing it may qualify one that was skipped (schedule).
            viewModel.handleBackgroundPrefetchChange()
        }
        .onChange(of: frequencyAxisClampRaw) { _, _ in
            // Forward UserDefaults clamp changes (from the Settings window Picker)
            // to the ViewModel, which updates effectiveNyquist immediately and
            // schedules a debounced re-analysis.
            viewModel.handleFrequencyAxisClampChange()
        }
        .frame(width: 640, height: 480)
    }
}

// MARK: - DropTargetView

/// An `NSViewRepresentable` that registers as an `NSDraggingDestination` and
/// reads the dropped file URL directly from `NSPasteboard` inside
/// `performDragOperation(_:)` — which executes synchronously on the main
/// thread in the same call stack as the system's drag-session teardown.
///
/// This is the key difference from SwiftUI's `.onDrop` + `NSItemProvider`:
/// `NSItemProvider.loadObject` dispatches URL resolution to a background queue
/// and delivers its result via a completion handler, meaning the drag image
/// remains on screen until that async work completes. By reading from
/// `NSPasteboard` directly we resolve the URL with no async hop, so the
/// system can retire the drag image, focus ring, and cursor indicator all in
/// the same frame.
struct DropTargetView: NSViewRepresentable {

    @Binding var isTargeted: Bool
    let onDrop: @MainActor (URL) -> Void

    func makeNSView(context: Context) -> DropReceivingView {
        let view = DropReceivingView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: DropReceivingView, context: Context) {
        context.coordinator.isTargeted = $isTargeted
        context.coordinator.onDrop    = onDrop
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isTargeted: $isTargeted, onDrop: onDrop)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        var isTargeted: Binding<Bool>
        var onDrop: @MainActor (URL) -> Void

        init(isTargeted: Binding<Bool>, onDrop: @escaping @MainActor (URL) -> Void) {
            self.isTargeted = isTargeted
            self.onDrop     = onDrop
        }
    }

    // MARK: - DropReceivingView

    /// The actual `NSView` subclass that conforms to `NSDraggingDestination`.
    final class DropReceivingView: NSView {

        weak var coordinator: Coordinator?

        // .fileURL and NSPasteboard.PasteboardType(UTType.fileURL.identifier) resolve
        // to the same pasteboard type string ("public.file-url"). Registering both
        // was harmless but redundant; one entry is sufficient.
        private static let acceptedTypes: [NSPasteboard.PasteboardType] = [
            .fileURL
        ]

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes(Self.acceptedTypes)
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            registerForDraggedTypes(Self.acceptedTypes)
        }

        // MARK: NSDraggingDestination

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard fileURL(from: sender.draggingPasteboard) != nil else { return [] }
            coordinator?.isTargeted.wrappedValue = true
            // Freeze the window's cursor-rect machinery for the lifetime of this
            // drag session. AppKit's cursor-rect timer fires roughly one second
            // after the cursor stops moving and calls resetCursorRects() across
            // the entire view hierarchy, which pushes the arrow cursor onto the
            // AppKit cursor stack and overwrites the HIServices drag cursor.
            // disableCursorRects() is the only window-level API that reliably
            // prevents that from happening regardless of which view in the
            // hierarchy triggers the reset.
            //
            // `unsafe` here and below: AppKit declares `NSView.window`
            // `unowned(unsafe)`. The view is in the window for the whole drag.
            unsafe window?.disableCursorRects()
            return .copy
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard fileURL(from: sender.draggingPasteboard) != nil else { return [] }
            return .copy
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            coordinator?.isTargeted.wrappedValue = false
            // Re-enable cursor rects now that the drag has left the window.
            // enableCursorRects() is balanced against disableCursorRects() above;
            // calling it here restores normal cursor-tracking behavior so that
            // hover states and other cursor effects work correctly after the drag.
            unsafe window?.enableCursorRects()
        }

        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            guard fileURL(from: sender.draggingPasteboard) != nil else {
                // Reject the drop and ensure the drag ring is cleared immediately.
                // AppKit does not guarantee a draggingExited call when prepare
                // returns false, so we must clear isTargeted and re-enable cursor
                // rects here ourselves to prevent both the blue ring and the
                // cursor freeze from lingering indefinitely.
                coordinator?.isTargeted.wrappedValue = false
                unsafe window?.enableCursorRects()
                return false
            }
            // Disable the system's "animate drag image to destination" behavior
            // here — at the point where the drop has been accepted but before
            // performDragOperation fires — rather than in draggingEntered.
            // Setting it in draggingEntered races with the HIServices drag IPC
            // sequencing, producing a benign but noisy console log
            // ("kDragIPCCompleted / kDragIPCLeaveApplication"). Moving the
            // assignment to prepareForDragOperation avoids that race entirely.
            sender.animatesToDestination = false
            return true
        }

        /// Called synchronously on the main thread by the drag-and-drop subsystem.
        /// The URL is read directly from `NSPasteboard`, which is fully populated
        /// at this point. Returning `true` here tells the system the drop succeeded,
        /// allowing it to immediately retire the drag image and all other drag
        /// indicators in the same frame — with no async gap.
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            coordinator?.isTargeted.wrappedValue = false
            // The drag session is ending via a successful drop; re-enable cursor
            // rects so the window resumes normal cursor tracking after teardown.
            unsafe window?.enableCursorRects()
            guard let url = fileURL(from: sender.draggingPasteboard) else { return false }
            coordinator?.onDrop(url)
            return true
        }

        // MARK: Private helpers

        /// Read the first file URL directly from an `NSPasteboard`.
        /// `readObjects(forClasses:options:)` is synchronous and in-memory —
        /// no async dispatch is involved.
        private func fileURL(from pasteboard: NSPasteboard) -> URL? {
            let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL]
            return urls?.first
        }
    }
}
