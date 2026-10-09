// MARK: - ImageBuilder.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Builds the spectrogram CGImage from per-column magnitude data. Allocates a single persistent
// CGContext at initialization and writes ARGB pixels directly into its backing store, eliminating
// the repeated allocation and buffer copies of a naive implementation. Implements a two-ratio
// band/fill model to correctly handle frequency-axis clamping both above and below the file's
// actual Nyquist frequency.

import Accelerate
import CoreGraphics
import Foundation

/// Assembles a spectrogram CGImage from per-column magnitude data.
///
/// ## Persistent-context design
/// The original implementation kept a `[UInt32]` pixel buffer and called
/// `CGContext(data: nil, ...)` on every `makeImage()` invocation, which
/// allocated a new context, copied the entire buffer into it, and created a
/// CGImage — repeated hundreds of times during a single analysis run.
///
/// This version allocates one `CGContext` at init time and writes pixels
/// directly into its backing store. `makeImage()` is a single zero-copy
/// `context.makeImage()` call, eliminating repeated context allocation and
/// buffer copies from the hot path.
///
/// ## Frequency-axis clamping — two-ratio model
/// The pipeline always produces `fftSize / 2` magnitude bands covering
/// `[0, actualNyquist]` Hz. The user may request a fixed axis ceiling
/// (`effectiveNyquist`) that is either below or above `actualNyquist`.
///
/// Two independent ratios govern how `setColumn` maps bands to pixels:
///
/// - **`bandRatio`** — the fraction of the FFT band array to read:
///   `min(effectiveNyquist / actualNyquist, 1.0)`. When the ceiling is below
///   `actualNyquist` (e.g. 22 kHz on a 44.1 kHz file), only the lower
///   `bandRatio` fraction of bands is used. When the ceiling is at or above
///   `actualNyquist`, all bands are used (ratio clamps to 1.0).
///
/// - **`fillRatio`** — the fraction of the image height that data occupies,
///   anchored to the bottom:
///   `min(actualNyquist / effectiveNyquist, 1.0)`. When the ceiling is above
///   `actualNyquist` (e.g. 44 kHz ceiling on a 22 kHz file), data only fills
///   the lower `fillRatio` portion of the image; the top is left black.
///   When the ceiling is at or below `actualNyquist`, data fills the full
///   image height (ratio clamps to 1.0).
///
/// Together the two ratios handle all four combinations correctly:
///
/// | ceiling vs. file Nyquist | bandRatio | fillRatio | effect                      |
/// |--------------------------|-----------|-----------|---------------------------  |
/// | ceiling == actualNyquist | 1.0       | 1.0       | full image, all bands       |
/// | ceiling <  actualNyquist | < 1.0     | 1.0       | full image, truncated bands |
/// | ceiling >  actualNyquist | 1.0       | < 1.0     | lower portion, all bands    |
/// | automatic (== actual)    | 1.0       | 1.0       | identical to first row      |
///
/// ## Pre-computed rendering constants
/// All values that depend only on construction parameters — `invRange`,
/// `dataRows`, `firstDataRow`, `fDataRows` — are computed once at init time
/// and stored as properties. This removes redundant arithmetic from
/// `setColumn`, which is called once per output column (potentially thousands
/// of times per file) and runs the tightest inner loop in the application.
///
/// ## Row-to-band-index lookup table
/// `setColumn` originally recomputed the band index for each pixel row on every
/// call via a float multiply + int cast:
///
///   `bandIndex = min(Int((pixelFromBottom + 0.5) / fDataRows * fActiveCount), activeCount - 1)`
///
/// This per-pixel arithmetic is identical across all columns for a given
/// `(height, activeCount, dataRows)` combination, which is constant within a
/// single analysis run. `setColumn` now builds a `rowBandIndex: [Int]` lookup
/// table the first time it is called (lazily, once `magnitudes.count` is
/// known), and every subsequent column call is a pure table lookup — no float
/// arithmetic in the inner loop. At `height = 1024`, for example, this
/// eliminates 1024 float multiplies, 1024 int casts, and 1024 min() calls
/// per column. For a 1200-column spectrogram that is ~3.7 million operations
/// removed from the rendering hot path.
///
/// ## Vectorized dB normalization
/// `setColumn` also applies the dB → [0,1] normalization using `vDSP_vsmsa`
/// (vector multiply-add: `C = A * B + D`) across the gathered magnitude slice
/// before entering the per-pixel palette-lookup loop. This converts the scalar
/// `(magnitude - lowerRange) * invRange` arithmetic to a single SIMD pass,
/// then a second `vDSP_vclip` pass floor/ceil-clamps all values to [0, 1].
/// The pixel loop then only needs to convert a pre-normalized float to a
/// palette index and write the color — no arithmetic, just a table lookup and
/// a store.
///
/// ## Memory safety
/// `@safe`: the pixel store is a raw pointer into the context's backing
/// store — the zero-copy design above depends on it — but the pointer is
/// private, lives exactly as long as `context`, and every write goes through
/// `setColumn`, which bounds-checks the column and writes only rows
/// `[firstDataRow, height)`. The public interface is arrays and `CGImage`.
///
/// Not Sendable — owned exclusively by the main actor via ViewModel.
@safe
final class ImageBuilder {

    let width:      Int
    let height:     Int
    let palette:    Palette
    let upperRange: Float   // e.g.,    0 dB
    let lowerRange: Float   // e.g., −120 dB

    private let context: CGContext
    /// Direct view of the context's backing store (`width × height` pixels).
    /// Valid for the lifetime of `context`. All writes are bounds-checked by
    /// the `setColumn` guard; the buffer's count adds a debug-build check.
    private let pixels: UnsafeMutableBufferPointer<UInt32>

    /// Fraction of the FFT band array to read. `min(effectiveNyquist /
    /// actualNyquist, 1.0)`. Controls how many bands are sampled.
    private let bandRatio: Double

    /// Fraction of the image height (from the bottom) that data occupies.
    /// `min(actualNyquist / effectiveNyquist, 1.0)`. Controls how many pixel
    /// rows receive magnitude color; rows above the data zone stay black.
    private let fillRatio: Double

    // MARK: - Pre-computed per-instance rendering constants
    //
    // These values depend only on construction parameters (upperRange, lowerRange,
    // fillRatio, height) and are constant for the lifetime of the builder.
    // Pre-computing them removes identical arithmetic from every `setColumn` call,
    // which runs the tightest inner loop in the application (once per output column,
    // thousands of times per file, up to ~height iterations per call).

    /// Reciprocal of the dB display range (1.0 / (upperRange − lowerRange)).
    /// Stored so `setColumn` can multiply rather than divide on every pixel row.
    /// Only valid when `upperRange > lowerRange`; `setColumn` guards on this.
    private let invRange: Float

    /// Number of pixel rows (from the bottom of the image) that receive
    /// magnitude color. Pre-computed from `fillRatio × height`.
    private let dataRows: Int

    /// First row index (inclusive) of the data zone: `height − dataRows`.
    /// Rows `[0 ..< firstDataRow)` remain permanently black; rows
    /// `[firstDataRow ..< height)` are written by `setColumn`.
    private let firstDataRow: Int

    /// `Float(dataRows)` — cached to avoid a repeated `Int → Float` cast
    /// inside the per-pixel loop within `setColumn`.
    private let fDataRows: Float

    // MARK: - Lazy row-to-band-index lookup table
    //
    // Populated on the first `setColumn` call once `magnitudes.count`
    // (`activeCount`) is known. Constant for every subsequent column because
    // `magnitudes.count` is always `fftSize / 2` within a single pipeline run.
    //
    // Layout: `rowBandIndex[i]` is the band index for pixel row
    // `firstDataRow + i`, where `i ∈ [0, dataRows)`.
    //
    // Building this table eliminates all per-pixel float arithmetic (one float
    // multiply, one int cast, one min()) from the inner loop of `setColumn`.
    private var rowBandIndex: [Int] = []

    /// The `activeCount` the table was built for; a column with a different
    /// band count (never within one run, but cheap to check) rebuilds it rather
    /// than indexing past the end of its `magnitudes`.
    private var rowBandIndexActiveCount = 0

    // MARK: - Scratch buffers for vectorized normalization in setColumn
    //
    // Allocated lazily on the first `setColumn` call alongside `rowBandIndex`.
    // Reused on every subsequent call to avoid heap allocations in the hot path.
    //
    // `normBuf` holds the normalized-and-clamped float values for all `dataRows`
    // pixel rows in the current column before the palette-lookup loop.
    // `scaledBuf` holds them between the multiply-add and the clamp.
    private var normBuf:   [Float] = []
    private var scaledBuf: [Float] = []

    // MARK: - Init

    /// - Parameters:
    ///   - effectiveNyquist: The axis display ceiling (Hz) requested by the
    ///     current `FrequencyAxisClamp` preference. May be greater than, equal
    ///     to, or less than `actualNyquist`.
    ///   - actualNyquist: The true Nyquist of the audio file (`sampleRate / 2`).
    init?(
        width:            Int,
        height:           Int,
        palette:          Palette,
        upperRange:       Float,
        lowerRange:       Float,
        effectiveNyquist: Double,
        actualNyquist:    Double
    ) {
        guard width > 0, height > 0,
              effectiveNyquist > 0, actualNyquist > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue)

        guard let ctx = unsafe CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        guard let dataPtr = unsafe ctx.data else { return nil }

        self.width      = width
        self.height     = height
        self.palette    = palette
        self.upperRange = upperRange
        self.lowerRange = lowerRange
        self.context    = ctx
        unsafe self.pixels = UnsafeMutableBufferPointer(
            start: dataPtr.bindMemory(to: UInt32.self, capacity: width * height),
            count: width * height)

        // bandRatio: how far into the magnitudes array to read.
        // Clamped to [0, 1] — when effectiveNyquist >= actualNyquist we read
        // all available bands.
        self.bandRatio = min(effectiveNyquist / actualNyquist, 1.0)

        // fillRatio: what fraction of the image height (bottom-anchored) data
        // occupies. Clamped to [0, 1] — when effectiveNyquist <= actualNyquist
        // data fills the entire image height.
        self.fillRatio = min(actualNyquist / effectiveNyquist, 1.0)

        // Pre-compute rendering constants from the now-fully-initialized properties.
        let rangeSpan    = upperRange - lowerRange
        // invRange is only consumed inside the inner loop when rangeSpan > 0.
        // `setColumn` still guards with `guard rangeSpan > 0` so a zero span
        // is never reached in practice; store 0 as a safe sentinel regardless.
        self.invRange    = rangeSpan > 0 ? 1.0 / rangeSpan : 0

        let dr           = max(1, min(
            Int((self.fillRatio * Double(height)).rounded()),
            height
        ))
        self.dataRows    = dr
        self.firstDataRow = height - dr
        self.fDataRows   = Float(dr)

        // Fill with opaque black. Rows above the data zone remain black
        // permanently; rows in the data zone are overwritten by setColumn.
        unsafe pixels.initialize(repeating: 0xFF000000)
    }

    // MARK: - Column writing

    /// Write one column of the spectrogram.
    ///
    /// `magnitudes` has `fftSize / 2` entries (from `FFTProcessor`), covering
    /// `[0, actualNyquist]` Hz. Index 0 = DC (lowest frequency).
    ///
    /// Only the lower `fillRatio` fraction of pixel rows receives magnitude
    /// color; rows above that zone remain the black initialized at construction.
    /// Within the data zone, `bandRatio` controls which portion of the
    /// magnitudes array is sampled.
    ///
    /// ## Hot-path optimizations
    ///
    /// On the first call, a `rowBandIndex` lookup table and a `normBuf` scratch
    /// buffer are allocated based on `magnitudes.count`. All subsequent calls
    /// reuse them, eliminating per-column allocations and per-pixel float arithmetic.
    ///
    /// The per-column work is split into two phases:
    ///
    ///   **Phase 1 (vectorized)** — gather magnitudes into a contiguous `dataRows`-
    ///   element slice using the `rowBandIndex` table, then apply the dB → [0,1]
    ///   normalization and clamp in two `vDSP` passes (multiply-add + clip).
    ///
    ///   **Phase 2 (scalar)** — iterate the `normBuf` values and write palette
    ///   colors into the pixel column. Each iteration is now a single multiply-
    ///   to-index + table lookup + store — no float arithmetic.
    func setColumn(_ columnIndex: Int, magnitudes: [Float]) {
        guard columnIndex >= 0, columnIndex < width else { return }
        let totalBandCount = magnitudes.count
        guard totalBandCount > 0 else { return }

        // `invRange` is pre-stored, but the range guard is retained here to
        // ensure a zero-span builder never writes garbage pixels. In practice
        // the range is always SpectrogramSettings' fixed −120…0 dB, so this
        // guard is a pure defense-in-depth check.
        guard upperRange > lowerRange else { return }

        // Number of FFT bands to sample — the active slice of the magnitude
        // array. Capped to totalBandCount to guard against floating-point drift.
        // `activeCount` depends on `magnitudes.count`, which is constant within
        // a single pipeline run (always `fftSize / 2`) but is not fixed at init
        // time, so it is computed per call rather than stored.
        let activeCount  = max(1, min(
            Int((bandRatio * Double(totalBandCount)).rounded()),
            totalBandCount
        ))
        let fActiveCount = Float(activeCount)

        // ── Lazy table initialization ────────────────────────────────────────
        // Build `rowBandIndex` and `normBuf` on the first call, or whenever
        // `activeCount` changes — which does not occur in normal operation since
        // `magnitudes.count` is fixed for the lifetime of a pipeline run, but a
        // table built for more bands than this column carries would read past
        // the end of `magnitudes`.
        if rowBandIndex.count != dataRows || rowBandIndexActiveCount != activeCount {
            rowBandIndex            = buildRowBandIndex(activeCount: activeCount, fActiveCount: fActiveCount)
            rowBandIndexActiveCount = activeCount
            normBuf                 = [Float](repeating: 0, count: dataRows)
            scaledBuf               = [Float](repeating: 0, count: dataRows)
        }

        // ── Phase 1: Gather + vectorized normalize ───────────────────────────
        //
        // Step 1a: Gather `dataRows` magnitude values using the precomputed
        // band-index table. This is a scalar loop over `dataRows` entries but
        // each iteration is a single array read — no arithmetic, no branching.
        // The result is a contiguous `dataRows`-element slice that vDSP can
        // operate on in the next step.
        for i in 0..<dataRows {
            normBuf[i] = magnitudes[rowBandIndex[i]]
        }

        // Step 1b: Normalize: normBuf[i] = (normBuf[i] - lowerRange) * invRange
        // Using vDSP_vsmsa: C[n] = A[n] * B + D
        //   A = normBuf, B = invRange, D = -lowerRange * invRange
        //
        // Step 1c: Clamp to [0.0, 1.0] in a single vectorized pass.
        //
        // Ping-pong between two buffers (normBuf → scaledBuf → normBuf): passing
        // one array both by value and as `&` is an exclusivity violation, and
        // copying around it would cost a buffer copy on every call.
        vDSP.add(multiplication: (normBuf, invRange), -lowerRange * invRange, result: &scaledBuf)
        vDSP.clip(scaledBuf, to: 0...1, result: &normBuf)

        // ── Phase 2: Palette lookup + pixel write ────────────────────────────
        //
        // `normBuf[i]` is now guaranteed ∈ [0, 1]. The palette lookup reduces
        // to a single multiply-to-index + table read per pixel — no conditional,
        // no clamp, no float arithmetic in this loop.
        let colorsPtr = palette.colors
        for i in 0..<dataRows {
            let row   = firstDataRow + i
            let color = colorsPtr[Int(normBuf[i] * 255)]
            unsafe pixels[row * width + columnIndex] = color
        }
    }

    // MARK: - Image production

    /// Produce a CGImage from the current pixel state.
    ///
    /// Zero-copy: the image references the context's existing backing store.
    /// Used for both progressive rendering (partial columns written so far)
    /// and final export (all columns written). The former `partialImage()` and
    /// `finalize()` methods — which were byte-for-byte identical — are unified
    /// into this single entry point.
    func makeImage() -> CGImage? {
        context.makeImage()
    }

    // MARK: - Private helpers

    /// Build the `rowBandIndex` lookup table for the current `activeCount`.
    ///
    /// `rowBandIndex[i]` is the band index for the i-th row of the data zone
    /// (counting from `firstDataRow`, i.e. from the top of the data zone downward).
    /// The mapping mirrors the original per-pixel formula:
    ///
    ///   pixelFromBottom = Float(dataRows - 1 - i)   (row 0 of data zone = top = highest freq)
    ///   bandPosition    = (pixelFromBottom + 0.5) / fDataRows * fActiveCount
    ///   bandIndex       = min(Int(bandPosition), activeCount - 1)
    ///
    /// Pre-computing this once eliminates all float arithmetic from the
    /// innermost loop of `setColumn`.
    private func buildRowBandIndex(activeCount: Int, fActiveCount: Float) -> [Int] {
        var table = [Int](repeating: 0, count: dataRows)
        for i in 0..<dataRows {
            // `i` counts from 0 (top of data zone = highest displayed frequency)
            // down to dataRows-1 (bottom = DC). `pixelFromBottom` inverts to the
            // original formula's coordinate system (0 = DC row at bottom of image).
            let pixelFromBottom = Float(dataRows - 1 - i)
            let bandPosition    = (pixelFromBottom + 0.5) / fDataRows * fActiveCount
            table[i]            = min(Int(bandPosition), activeCount - 1)
        }
        return table
    }
}
