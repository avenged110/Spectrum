// MARK: - SpectrogramView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The main spectrogram rendering view. Layers a pixel-exact bitmap Image (interpolation disabled)
// beneath two Canvas passes: one for static chrome (graph border, palette strip, dB ruler) and one
// for metadata-dependent rulers (time and frequency axes) that crossfade via SwiftUI's transition
// engine when a new file loads.

import CoreImage
import SwiftUI

/// The main spectrogram rendering view. Uses a layered layout: a SwiftUI
/// `Image` view renders the spectrogram bitmap with `.interpolation(.none)`
/// for pixel-exact sharpness, and two `Canvas` layers overlaid on top.
///
/// ## Layer structure
/// - **Layer 1** — solid black graph background.
/// - **Layer 2** — spectrogram bitmap; fades out when a new file loads and
///   reappears as partial columns arrive.
/// - **Layer 3** — static chrome: graph border, palette strip, and dB ruler.
///   These are functions of settings only, never metadata, and stay fully
///   opaque at all times.
/// - **Layer 4** — metadata-dependent rulers: time axis (bottom) and frequency
///   axis (left). This canvas is given an explicit `.id(metadata)` so SwiftUI
///   treats each new `AudioMetadata` value as a distinct view. Combined with
///   `.transition(.opacity)` and `.animation(.easeInOut, value: metadata)`,
///   SwiftUI automatically crossfades the outgoing and incoming ruler sets
///   simultaneously — with no manual opacity state, no Tasks, and no timers.
///   The animation is anchored directly to the `metadata` value change, which
///   is set inside the same `withAnimation` block the ViewModel uses for the
///   rest of the UI, so all elements animate in lockstep.
/// - **Layer 5** — idle-state drop prompt (waveform icon + instructional text).
///   Shown only when `renderedImage` is `nil` (no file has been opened yet, or
///   the ViewModel has reset after a processing error). Sized and positioned to
///   fill the graph rect exactly so it sits inside the border. Fades out as
///   soon as the bitmap layer becomes visible, preserving the existing
///   empty → filling state flow without any additional ViewModel state.
/// - **Layer 6** — analysis overlay (spinner + label). Shown during Matroska
///   decoder stalls (`.decoding`). Positioned
///   and sized to fill the graph rect exactly, so it is bounded by the graph
///   border and never bleeds into the ruler area or the metadata bar. The
///   border stroke is drawn outward from `spectrogramRect` (inset by
///   −0.5 pt on each side) so the full 1 pt stroke lands outside all content
///   fills — the border remains a clean, unobscured line regardless of what
///   is rendered inside the graph area. Fades in and out using the same
///   0.18 s easeInOut curve used everywhere else.
///
/// ## Palette strip caching
/// The palette strip is a pure function of `PaletteType` and the strip's pixel
/// height. Pre-rendering it into a `CGImage` once (stored in `@State`) avoids
/// re-drawing up to 400 individual 1-pt `Path` fills on every Canvas redraw.
///
/// ## onChange batching
/// `imageOpacity` is governed exclusively by `onChange(of: isFading)`.
/// `onChange(of: image)` updates only `renderedImage`. Keeping these two state
/// mutations in separate handlers eliminates the SwiftUI "tried to update
/// multiple times per frame" fault that would occur if both handlers fired
/// during the same display-link tick and each mutated overlapping `@State`.
struct SpectrogramView: View {

    let image: CGImage?
    let metadata: AudioMetadata?
    let settings: SpectrogramSettings

    /// Set by the ViewModel when a new file is loaded and cleared as soon as
    /// the first partial image of the new analysis arrives. SpectrogramView
    /// uses this flag to fade out only the heat-map image inside the graph
    /// border; all other chrome (border, rulers, legend) remains fully static.
    let isFading: Bool

    /// The current analysis state, forwarded from the ViewModel. Used solely
    /// to drive Layer 6 (the analysis overlay). Passed in rather than read
    /// from the environment so this view has no direct ViewModel dependency.
    let analysisState: AnalysisState

    /// The effective Nyquist ceiling (Hz) to use for the frequency ruler.
    /// Computed by the ViewModel from `metadata.sampleRate` and the
    /// `frequencyAxisClamp` preference. For fixed-clamp modes this value may
    /// exceed the file's actual Nyquist, in which case the ruler extends to the
    /// forced ceiling and the region above the file's content renders as empty
    /// space. When `nil` (before metadata arrives), `drawFrequencyRuler` falls
    /// back to `metadata.sampleRate / 2`.
    let effectiveNyquist: Double?

    /// Called once on appear (and again if the view's size ever changes) to
    /// report the usable spectrogram pixel dimensions to the ViewModel.
    var onSizeChanged: (Int, Int) -> Void

    // Layout constants (matching Spek's padding). Static so they are shared
    // across all instances rather than duplicated in each view's storage.
    private static let leftPad:           CGFloat = 65
    private static let topPad:            CGFloat = 8
    private static let rightPad:          CGFloat = 85
    private static let bottomPad:         CGFloat = 40
    private static let paletteStripWidth: CGFloat = 10
    private static let gap:               CGFloat = 10
    private static let borderLineWidth:   CGFloat = 1

    private static let fadeDuration: Double = 0.18

    /// The last non-nil image received from the pipeline.
    @State private var renderedImage: CGImage? = nil
    /// Drives the opacity of the spectrogram Image layer.
    /// Governed exclusively by `onChange(of: isFading)` — never written by
    /// `onChange(of: image)` — so that only one handler mutates this property
    /// per render pass.
    @State private var imageOpacity: Double = 1

    /// Cached pre-rendered palette strip. Rebuilt only when the palette type
    /// or the available strip height changes — not on every Canvas redraw.
    @State private var cachedPaletteImage: CGImage? = nil
    @State private var cachedPaletteKey: PaletteStripKey = .init(paletteType: .spectrum, pixelHeight: 0)

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let spectrogramRect = Self.graphRect(for: size)

            ZStack(alignment: .topLeading) {

                // ── Layer 1: black graph background ───────────────────────────
                Color.black
                    .frame(width: spectrogramRect.width,
                           height: spectrogramRect.height)
                    .offset(x: spectrogramRect.minX, y: spectrogramRect.minY)

                // ── Layer 2: spectrogram bitmap ────────────────────────────────
                if let cgImage = renderedImage {
                    Image(decorative: cgImage, scale: 1.0)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: spectrogramRect.width,
                               height: spectrogramRect.height)
                        .offset(x: spectrogramRect.minX, y: spectrogramRect.minY)
                        .opacity(imageOpacity)
                }

                // ── Layer 3: static chrome (border, palette strip, dB ruler) ───
                // Independent of metadata; never animates. Keyed on everything
                // it draws from, so a new spectrogram frame — which re-runs this
                // body up to 60 times a second while a file fills — does not
                // redraw it (see `KeyedCanvas`).
                KeyedCanvas(key: ChromeKey(
                    rect: spectrogramRect, palette: settings.palette,
                    lowerRange: settings.lowerRange, upperRange: settings.upperRange,
                    paletteImage: cachedPaletteImage.map(ObjectIdentifier.init)
                )) { context in
                    drawPaletteStrip(context: &context, rect: spectrogramRect)
                    drawDBRuler(context: &context,      rect: spectrogramRect)
                    drawBorder(context: &context,       rect: spectrogramRect)
                }
                .equatable()

                // ── Layer 4: metadata-dependent rulers (time + frequency) ───────
                // .id(metadata) gives each distinct metadata value its own view
                // identity. SwiftUI then applies .transition(.opacity) to
                // simultaneously fade out the departing instance and fade in the
                // arriving one — a true crossfade with zero manual state.
                // .animation is keyed on metadata so it fires at exactly the
                // same moment the ViewModel sets the new value, in lockstep with
                // every other animated element in the UI. Keyed like layer 3.
                KeyedCanvas(key: RulerKey(rect: spectrogramRect, metadata: metadata,
                                          effectiveNyquist: effectiveNyquist)) { context in
                    drawTimeRuler(context: &context,      rect: spectrogramRect)
                    drawFrequencyRuler(context: &context, rect: spectrogramRect)
                }
                .equatable()
                .id(metadata)
                .transition(.opacity)
                .animation(
                    .easeInOut(duration: Self.fadeDuration),
                    value: metadata
                )

                // ── Layer 5: idle-state drop prompt ────────────────────────────
                // Shown only when no image has ever been rendered in this session
                // (renderedImage is nil). Positioned and sized to fill the graph
                // rect exactly — not the full window canvas — so it sits cleanly
                // inside the border. Fades out with the same duration used
                // everywhere else in the UI as soon as the first image data
                // arrives. Using renderedImage (not isFading or analysisState)
                // means the prompt disappears at the exact moment the bitmap
                // layer becomes visible, with no separate state required.
                //
                // Note: .transition/.animation must be on the outermost ZStack
                // (below) rather than on the VStack itself. When the `if` branch
                // evaluates to false the VStack is removed from the hierarchy
                // immediately, so a modifier attached to it cannot animate the
                // departure. Attaching .animation(value: renderedImage == nil) to
                // the ZStack ensures SwiftUI sees the value change and executes
                // the .opacity transition on both insertion and removal.
                if renderedImage == nil {
                    VStack(spacing: 14) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text("Drop an audio file here or press ⌘O to select one.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: spectrogramRect.width,
                           height: spectrogramRect.height)
                    .offset(x: spectrogramRect.minX, y: spectrogramRect.minY)
                    .transition(.opacity)
                }

                // ── Layer 6: analysis overlay (spinner + label) ─────────────────
                // Shown during decoder stalls (.decoding). Confined to the inner graph rect
                // (spectrogramRect) so it never covers the ruler area or the
                // metadata bar above. Fades in and out using the same 0.18 s
                // easeInOut curve used for all other animated UI elements.
                //
                // Animation design: a Bool (`isShowingOverlay`) is derived from
                // `analysisState` and used as the `.animation(value:)` key on
                // the ZStack below. SwiftUI diffs the Bool across frames and
                // fires the transition on the `if` branch precisely when the
                // value changes — which is the correct trigger for both insertion
                // (false → true) and removal (true → false). Using a dedicated
                // Bool rather than keying on `analysisState` directly avoids
                // spurious re-animations when unrelated state fields on the enum
                // change (e.g., progress fraction updates).
                //
                // The `label` string is derived once from `analysisState` and
                // kept stable for the duration of the overlay's visibility, so
                // the text does not flicker as progress events arrive.
                if isShowingOverlay {
                    AnalysisOverlay(label: overlayLabel)
                        .frame(width: spectrogramRect.width,
                               height: spectrogramRect.height)
                        .offset(x: spectrogramRect.minX, y: spectrogramRect.minY)
                        .transition(.opacity)
                }

            }
            // The animation context for Layer 5 (drop-prompt) and Layer 6
            // (analysis overlay). A single .animation on the ZStack covers both
            // conditional branches: SwiftUI sees the keyed-value changes and
            // interpolates the .opacity transitions for both insertion and
            // removal on the same frame. Two separate .animation modifiers would
            // work, but one is simpler and they share the same duration anyway.
            .animation(
                .easeInOut(duration: Self.fadeDuration),
                value: renderedImage == nil
            )
            .animation(
                .easeInOut(duration: Self.fadeDuration),
                value: isShowingOverlay
            )
            .onAppear {
                reportSize(size)
                if let image { renderedImage = image }
                rebuildPaletteImageIfNeeded(height: spectrogramRect.height)
            }
            .onChange(of: size) { _, newSize in
                reportSize(newSize)
                rebuildPaletteImageIfNeeded(height: Self.graphRect(for: newSize).height)
            }
            // Update only the image buffer. imageOpacity is intentionally NOT
            // set here — it is the sole responsibility of onChange(of: isFading)
            // below. Separating these concerns prevents SwiftUI from seeing two
            // independent @State mutations on the same property within a single
            // display-link frame, which produces the
            // "onChange … tried to update multiple times per frame" fault.
            //
            // Bug fix (Issue 1): also handle the nil case. When the ViewModel
            // clears spectrogramImage = nil after a processing error is dismissed,
            // renderedImage must be cleared too so the stale spectrogram does not
            // keep rendering until the next file is loaded.
            .onChange(of: image) { _, newImage in
                if let newImage {
                    renderedImage = newImage
                } else {
                    renderedImage = nil
                    imageOpacity  = 1   // reset opacity so the next image fades in correctly
                }
            }
            // Sole authority over imageOpacity. When isFading becomes true the
            // image fades out; when it becomes false (which the ViewModel does
            // as soon as the first partial image of the new analysis arrives)
            // the image snaps back to full opacity to immediately show the
            // incoming content.
            .onChange(of: isFading) { _, fading in
                if fading {
                    withAnimation(.easeInOut(duration: Self.fadeDuration)) {
                        imageOpacity = 0
                    }
                } else {
                    imageOpacity = 1
                }
            }
            .onChange(of: settings.palette) { _, _ in
                rebuildPaletteImageIfNeeded(height: spectrogramRect.height)
            }
        }
    }

    // MARK: - Canvas keys

    /// Everything layer 3 draws from.
    private struct ChromeKey: Equatable, Sendable {
        let rect: CGRect
        let palette: PaletteType
        let lowerRange: Float
        let upperRange: Float
        /// The cached strip, by identity: a rebuilt strip is a new image.
        let paletteImage: ObjectIdentifier?
    }

    /// Everything layer 4 draws from.
    private struct RulerKey: Equatable, Sendable {
        let rect: CGRect
        let metadata: AudioMetadata?
        let effectiveNyquist: Double?
    }

    // MARK: - Overlay helpers

    /// `true` when the analysis overlay (Layer 6) should be visible.
    /// Derived from `analysisState` and used as the `.animation(value:)` key
    /// so the transition fires precisely on insertion and removal.
    private var isShowingOverlay: Bool {
        switch analysisState {
        case .decoding: return true
        default:        return false
        }
    }

    /// The label string displayed below the spinner in the analysis overlay.
    /// Only meaningful when `isShowingOverlay` is `true`; returns an empty
    /// string otherwise so any stale value during fade-out is harmless.
    private var overlayLabel: String {
        switch analysisState {
        case .decoding: return "Decoding audio…"
        default:        return ""
        }
    }

    /// The inner graph rect for a view of `size`: the padding around it holds
    /// the rulers, the palette strip and the dB ruler.
    private static func graphRect(for size: CGSize) -> CGRect {
        CGRect(x: leftPad, y: topPad,
               width:  max(1, size.width  - leftPad - rightPad),
               height: max(1, size.height - topPad  - bottomPad))
    }

    /// Report the usable graph pixel dimensions to the ViewModel.
    private func reportSize(_ size: CGSize) {
        let w = Int((size.width  - Self.leftPad - Self.rightPad).rounded())
        let h = Int((size.height - Self.topPad  - Self.bottomPad).rounded())
        onSizeChanged(max(1, w), max(1, h))
    }

    // MARK: - Palette strip cache

    private struct PaletteStripKey: Equatable {
        let paletteType: PaletteType
        let pixelHeight: Int
    }

    /// Rebuild the cached palette strip CGImage when the palette type or height
    /// has changed. The key comparison covers both cases, so no `force` flag is
    /// required.
    private func rebuildPaletteImageIfNeeded(height: CGFloat) {
        let pixelHeight = max(1, Int(height.rounded()))
        let newKey = PaletteStripKey(paletteType: settings.palette, pixelHeight: pixelHeight)
        guard newKey != cachedPaletteKey else { return }
        cachedPaletteImage = buildPaletteImage(paletteType: settings.palette,
                                               pixelHeight: pixelHeight)
        cachedPaletteKey = newKey
    }

    /// Render the palette gradient into a `paletteStripWidth × pixelHeight`
    /// CGImage. Called at most once per `(paletteType, pixelHeight)` pair.
    private func buildPaletteImage(paletteType: PaletteType, pixelHeight: Int) -> CGImage? {
        let palette = Palette.make(paletteType)
        let w       = Int(Self.paletteStripWidth)
        let h       = pixelHeight

        // The Spek spectrum palette has a documented edge case where index 255
        // maps to black. Capping at 254/255 ensures the top row renders as deep
        // red rather than black, so the strip fills flush to its top border.
        let maxNormalized = Float(254) / Float(255)

        // BGRA bytes — the in-memory order of the palette's packed ARGB words
        // on a little-endian machine, which is how ImageBuilder lays them out.
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            let rawNorm = 1.0 - (Float(row) / Float(h))
            let norm    = min(rawNorm, maxNormalized)
            let argb    = palette.color(for: norm < 0 ? 0 : norm)
            let pixel: [UInt8] = [UInt8(truncatingIfNeeded: argb),
                                  UInt8(truncatingIfNeeded: argb >> 8),
                                  UInt8(truncatingIfNeeded: argb >> 16),
                                  UInt8(truncatingIfNeeded: argb >> 24)]
            for x in 0..<w {
                let offset = (row * w + x) * 4
                bytes.replaceSubrange(offset ..< offset + 4, with: pixel)
            }
        }

        // Core Image turns the bytes into a CGImage through bounds-checked
        // `Data` rather than a raw pointer into a bitmap context's store. Color
        // management is off in `paletteContext`, so the bytes pass through
        // unchanged (verified identical to the former CGContext path).
        let space = CGColorSpaceCreateDeviceRGB()
        let source = CIImage(bitmapData: Data(bytes), bytesPerRow: w * 4,
                             size: CGSize(width: w, height: h), format: .BGRA8, colorSpace: space)
        return Self.paletteContext.createCGImage(source, from: source.extent,
                                                 format: .BGRA8, colorSpace: space)
    }

    /// Renders the palette strip. Built once; color management off (no
    /// working or output color space) so palette bytes reach the image as-is.
    @MainActor
    private static let paletteContext = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace:  NSNull(),
        .cacheIntermediates: false,
    ])

    // MARK: - Drawing

    private func drawBorder(context: inout GraphicsContext, rect: CGRect) {
        // CoreGraphics strokes centered on the path: for a 1 pt line, 0.5 pt
        // falls inside the rect and 0.5 pt outside. Expanding the stroke path
        // outward by half the line width (0.5 pt on each side) shifts the
        // stroke center to the outer edge of `rect`, so the full 1 pt stroke
        // lands entirely outside the content area. This guarantees the border
        // is never obscured by any fill (bitmap, overlay, background) that is
        // sized to `rect`.
        //
        // All ruler tick marks and the palette strip use `borderEdgeRect(for:)`
        // to obtain this same expanded rect, ensuring their dock points align
        // with the visible outer edge of the border stroke rather than the inner
        // `rect` boundary.
        context.stroke(
            Path(borderEdgeRect(for: rect)),
            with: .color(.primary),
            lineWidth: Self.borderLineWidth
        )
    }

    /// The rect whose edges coincide with the visible outer edge of the border
    /// stroke. All geometry that should visually "touch" the border line —
    /// ruler tick marks, palette strip top/bottom — must reference this rect
    /// rather than the raw `spectrogramRect`, which is 0.5 pt inside the stroke
    /// center on every side.
    private func borderEdgeRect(for rect: CGRect) -> CGRect {
        rect.insetBy(dx: -Self.borderLineWidth / 2, dy: -Self.borderLineWidth / 2)
    }

    // MARK: - Time ruler (bottom edge)

    private func drawTimeRuler(context: inout GraphicsContext, rect: CGRect) {
        guard let meta = metadata, meta.duration > 0 else { return }

        let edgeRect = borderEdgeRect(for: rect)
        let ticks = RulerCalculator.timeTicks(
            duration: meta.duration,
            availablePixels: Int(edgeRect.width)
        )

        // Ticks must originate from the outer edge of the border stroke, not
        // the inner rect boundary, so they appear flush against the visible line.
        let tickBaseY:  CGFloat = edgeRect.maxY
        let tickLength: CGFloat = 4

        for tick in ticks {
            let x = edgeRect.minX + tick.pixelPosition

            var path = Path()
            path.move(to:    CGPoint(x: x, y: tickBaseY))
            path.addLine(to: CGPoint(x: x, y: tickBaseY + tickLength))
            context.stroke(path, with: .color(.primary), lineWidth: 1)

            let text = Text(tick.label)
                .font(.system(size: 10))
                .foregroundStyle(.primary)
            context.draw(text,
                         at: CGPoint(x: x, y: tickBaseY + 10),
                         anchor: .top)
        }
    }

    // MARK: - Frequency ruler (left edge)

    private func drawFrequencyRuler(context: inout GraphicsContext, rect: CGRect) {
        guard let meta = metadata else { return }

        // Use the display ceiling supplied by the ViewModel, which reflects the
        // frequencyAxisClamp preference. For fixed-clamp modes this value may
        // exceed the file's actual Nyquist — the region above the file's Nyquist
        // renders as empty (black) space, which is the intended behavior for a
        // forced axis scale. Fall back to the natural Nyquist if the ViewModel
        // has not yet published a value (e.g. on first layout before metadata
        // arrives).
        let actualNyquist   = meta.sampleRate / 2.0
        let nyquist         = effectiveNyquist ?? actualNyquist

        let edgeRect = borderEdgeRect(for: rect)
        let ticks = RulerCalculator.frequencyTicks(
            nyquist: nyquist,
            availablePixels: Int(edgeRect.height)
        )

        // Ticks must originate from the outer edge of the border stroke, not
        // the inner rect boundary, so they appear flush against the visible line.
        let tickBaseX:  CGFloat = edgeRect.minX
        let tickLength: CGFloat = 4

        for tick in ticks {
            let y = edgeRect.maxY - tick.pixelPosition

            var path = Path()
            path.move(to:    CGPoint(x: tickBaseX, y: y))
            path.addLine(to: CGPoint(x: tickBaseX - tickLength, y: y))
            context.stroke(path, with: .color(.primary), lineWidth: 1)

            let text = Text(tick.label)
                .font(.system(size: 10))
                .foregroundStyle(.primary)
            context.draw(text,
                         at: CGPoint(x: tickBaseX - 10, y: y),
                         anchor: .trailing)
        }
    }

    // MARK: - Palette strip (right side)

    private func paletteStripRect(for spectrogramRect: CGRect) -> CGRect {
        // The strip's top and bottom must align with the outer edge of the graph
        // border stroke (not the inner rect boundary) so the strip borders are
        // flush with the graph border line. borderEdgeRect expands spectrogramRect
        // by half the line width on each side — we only need the y-axis expansion
        // here; the strip's x position is still measured from spectrogramRect.maxX.
        let edgeRect = borderEdgeRect(for: spectrogramRect)
        return CGRect(
            x: spectrogramRect.maxX + Self.gap,
            y: edgeRect.minY,
            width: Self.paletteStripWidth,
            height: edgeRect.height
        )
    }

    /// Draw the palette strip using the pre-rendered cached CGImage. Before
    /// `onAppear` has filled the cache (the first layout pass), the same image
    /// is built on the spot rather than drawn a second, slower way.
    private func drawPaletteStrip(context: inout GraphicsContext, rect: CGRect) {
        let stripRect = paletteStripRect(for: rect)
        let image = cachedPaletteImage
            ?? buildPaletteImage(paletteType: settings.palette,
                                 pixelHeight: max(1, Int(rect.height.rounded())))
        if let image {
            context.draw(Image(decorative: image, scale: 1.0), in: stripRect)
        }
        context.stroke(Path(stripRect), with: .color(.primary), lineWidth: 1)
    }

    // MARK: - dB ruler (right of palette strip)

    private func drawDBRuler(context: inout GraphicsContext, rect: CGRect) {
        let stripRect   = paletteStripRect(for: rect)
        let tickBaseX   = stripRect.maxX
        let tickLength: CGFloat = 4
        let labelX      = tickBaseX + 10

        // availablePixels must match the strip's actual rendered height (which
        // now includes the 0.5 pt border expansion on each side) so that tick
        // positions are proportionally correct across the full strip extent.
        // Using stripRect.maxY as the baseline keeps the zero-position tick
        // flush with the strip's bottom border edge.
        let ticks = RulerCalculator.dbTicks(
            lowerRange: Double(settings.lowerRange),
            upperRange: Double(settings.upperRange),
            availablePixels: Int(stripRect.height)
        )

        for tick in ticks {
            let y = stripRect.maxY - tick.pixelPosition

            var path = Path()
            path.move(to:    CGPoint(x: tickBaseX, y: y))
            path.addLine(to: CGPoint(x: tickBaseX + tickLength, y: y))
            context.stroke(path, with: .color(.primary), lineWidth: 1)

            let text = Text(tick.label)
                .font(.system(size: 10))
                .foregroundStyle(.primary)
            context.draw(text,
                         at: CGPoint(x: labelX, y: y),
                         anchor: .leading)
        }
    }
}

// MARK: - KeyedCanvas

/// A `Canvas` that redraws only when `key` changes.
///
/// A `Canvas`'s drawing closure is a new value on every evaluation of the view
/// that builds it, and SwiftUI cannot compare closures, so a bare `Canvas` in
/// `SpectrogramView` redrew all of its ruler labels on every spectrogram frame —
/// about 0.5 ms each, twice a frame, measured on a filling 20-minute file.
/// Declaring the view `Equatable` on `key` alone (applied with `.equatable()`)
/// lets SwiftUI skip it whenever the key is unchanged. `key` must therefore
/// capture every value `draw` reads; the environment (light or dark appearance)
/// still reaches the canvas as usual.
private struct KeyedCanvas<Key: Equatable & Sendable>: View, Equatable {
    let key: Key
    let draw: (inout GraphicsContext) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }

    var body: some View {
        Canvas { context, _ in draw(&context) }
    }
}
