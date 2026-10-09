// MARK: - FFTProcessor.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Computes a single dB-magnitude FFT on a windowed block of audio samples using vDSP. Maintains a
// process-wide cache of DFT setups and window buffers keyed on (fftSize, windowFunction),
// avoiding the expensive twiddle-factor recomputation that would otherwise occur for every window
// in the analysis hot path.

import Accelerate
import Foundation
import os

// MARK: - FFTProcessorCache

/// A process-wide cache of DFT setups and window buffers, keyed on
/// `(fftSize, windowFunction)`. Both are pure functions of their inputs and
/// are safe to share across tasks — a DFT setup is read-only after creation.
///
/// Creating a `vDSP.DiscreteFourierTransform` is expensive (it pre-computes
/// twiddle factors: ~37 µs at fftSize 2048, ~295 µs at 16384, measured
/// 2026-10-07). Recreating it for every column task inside the pipeline —
/// thousands per file, some covering only a handful of windows — would cost
/// more than the transforms themselves.
private enum FFTProcessorCache {

    private struct Key: Hashable {
        let fftSize:        Int
        let windowFunction: WindowFunction
    }

    /// Shares one transform between concurrent column tasks.
    ///
    /// `@unchecked Sendable`: `vDSP.DiscreteFourierTransform` is a class that
    /// owns (and frees) its setup but is not marked Sendable. vDSP documents
    /// setups as needing "only read-only access to the underlying memory,
    /// therefore you can safely run multiple execution routines concurrently"
    /// (vDSP.h, "Multithreading"), and the transform is never mutated after
    /// creation.
    final class SharedTransform: @unchecked Sendable {
        let dft: vDSP.DiscreteFourierTransform<Float>
        init(_ dft: vDSP.DiscreteFourierTransform<Float>) { self.dft = dft }
    }

    struct Entry: Sendable {
        let transform:  SharedTransform
        /// The window's even-indexed coefficients (`window[0]`, `window[2]`, …)
        /// and odd-indexed ones, matching the even/odd split the real DFT
        /// takes as input (see `FFTProcessor.process`).
        let evenWindow: [Float]
        let oddWindow:  [Float]
    }

    // The lock owns the cache, so no access can bypass it. OSAllocatedUnfairLock
    // is available from macOS 13+ (always present on the macOS 15 floor) and is
    // lighter than NSLock — designed for exactly this short-duration,
    // non-recursive hot-path locking pattern.
    private static let cache = OSAllocatedUnfairLock<[Key: Entry]>(initialState: [:])

    static func entry(fftSize: Int, windowFunction: WindowFunction) -> Entry {
        let key = Key(fftSize: fftSize, windowFunction: windowFunction)

        if let hit = cache.withLock({ $0[key] }) {
            return hit
        }

        // Build outside the lock — expensive and non-mutating w.r.t. existing
        // cached entries.
        //
        // fftSize is always a power of two in [256, 16384] (enforced by
        // FFTProcessor.init's clamping logic), which the real DFT supports.
        guard let dft = try? vDSP.DiscreteFourierTransform(
            count: fftSize, direction: .forward, transformType: .complexReal, ofType: Float.self)
        else {
            fatalError("vDSP.DiscreteFourierTransform failed for fftSize \(fftSize)")
        }
        let window = windowFunction.makeBuffer(size: fftSize)
        let half   = fftSize / 2
        let entry  = Entry(transform:  SharedTransform(dft),
                           evenWindow: (0..<half).map { window[2 * $0] },
                           oddWindow:  (0..<half).map { window[2 * $0 + 1] })

        // Double-checked: another task may have raced us to this point. The
        // winner comes back from the same critical section that saw it; a
        // losing duplicate frees its own setup when it goes out of scope.
        return cache.withLock { cache in
            if let existing = cache[key] { return existing }
            cache[key] = entry
            return entry
        }
    }
}

// MARK: - FFTProcessor

/// Performs a windowed real FFT on a buffer of audio samples and returns
/// magnitude values in decibels. Each instance borrows a shared, immutable
/// DFT setup and window buffer from `FFTProcessorCache` so construction is
/// effectively free after the first use of a given `(fftSize, windowFunction)`
/// pair.
///
/// ## Scratch buffers
/// `process(_:into:)` is called thousands of times per file. To avoid heap
/// allocations on every call, the five intermediate buffers it needs
/// (`evenPart`, `oddPart`, `realPart`, `imagPart`, `powerBuf`) are allocated
/// once at init time and reused across calls. `FFTProcessor` is therefore not
/// `Sendable` — each concurrent task in the pipeline creates its own instance,
/// which is cheap because `FFTProcessorCache` amortizes the setup creation.
///
/// ## Transform
/// `vDSP.DiscreteFourierTransform` (`.complexReal`) takes the `fftSize` real
/// samples as two half-length arrays — the even-indexed samples as the "real"
/// input and the odd-indexed ones as the "imaginary" input — and returns
/// `bandCount` complex bins in the same packed layout as `vDSP_fft_zrip`: bin
/// 0's real part holds DC and its imaginary part holds Nyquist. Every array
/// goes through the bounds-checked Swift overlay, so this file needs no raw
/// pointers. (Until 2026-10-07 it used `vDSP_fft_zrip` through
/// `DSPSplitComplex` pointers. On real music the two agree to within
/// ~0.05 dB; bins near float32's precision limit, ~140 dB below a window's
/// loudest component, are rounding noise in both and can differ by more,
/// which moves at most ~0.02% of pixels by one palette step. The switch costs
/// ~1.6 µs per window at fftSize 2048 — about 0.1 s, or 4%, of a 2-hour
/// analysis. Measured 2026-10-07.)
///
/// Input range: the DFT's internal sums overflow into NaN once a sample
/// reaches ~3e22 (`vDSP_fft_zrip` saturated to infinity instead), and a NaN
/// magnitude traps when ImageBuilder turns it into a palette index. Decoded
/// samples never get near that: FFmpegShim.c replaces non-finite samples with
/// silence and clamps the rest to ±1e6 (`SPK_SAMPLE_LIMIT`), which stays
/// finite at every size and window (verified 2026-10-07).
///
/// ## Normalization
/// Spek's reference formula (spek-fft.cc) is:
///
///   `output[i] = 10·log₁₀((re² + im²) / n²)`   where n = fftSize
///
/// The real forward DFT, like `vDSP_fft_zrip`, scales its output by 2
/// compared to the mathematical DFT, so the raw power for every audible bin is
/// 4× the true squared magnitude: `(2·X[k])² = 4·|X[k]|²`.
///
/// To match Spek exactly, the normalization denominator must cancel that
/// factor: `1 / (4 · fftSize²)` instead of `1 / fftSize²`.
///
/// With this correction a full-scale sine wave (amplitude 1.0) reads −6.02 dB
/// at any FFT size, matching Spek's reference point precisely.
///
/// ## Two-pass normalize + dB conversion (was three passes)
/// Original sequence — three passes over `bandCount` floats:
///   1. `vDSP_vsmul`  — multiply by `normalizeScale`
///   2. `vDSP_vclip`  — floor-clamp at 1e-20
///   3. `vDSP_vdbcon` — convert to dB with reference 1.0
///
/// Optimized sequence — two passes:
///   1. `vDSP_vclip`  — clamp `powerBuf` at `floorBeforeScale`
///                      (= 1e-20 / normalizeScale), writing into `realPart`,
///                      which is free by then.
///                      Clamping in raw-power units before scaling is
///                      numerically identical to clamping after scaling because
///                      `normalizeScale > 0` preserves element order.
///   2. `vDSP_vdbcon` — convert to dB with `dbRef = 1.0 / normalizeScale`.
///                      Formula: 10·log₁₀(A[n] / dbRef)
///                             = 10·log₁₀(A[n] · normalizeScale),
///                      which is exactly what the three-pass sequence computed.
///
/// Net effect: one full vector pass (≥ 2 KB at fftSize 4096) is eliminated on
/// every FFT window — a measurable saving when thousands of windows are
/// processed per analysis run.
final class FFTProcessor {

    let fftSize:   Int
    let bandCount: Int      // fftSize / 2

    // Borrowed from FFTProcessorCache — read-only after creation, safe to share.
    private let transform:  vDSP.DiscreteFourierTransform<Float>
    private let evenWindow: [Float]
    private let oddWindow:  [Float]
    // Pre-computed normalization scalar; retained for documentation parity.
    private let normalizeScale: Float

    // Per-instance scratch buffers — allocated once, reused every process() call.
    // Eliminates five heap allocations per FFT window in the hot path.
    private var evenPart: [Float]  // windowed even-indexed samples (DFT real input)
    private var oddPart:  [Float]  // windowed odd-indexed samples (DFT imaginary input)
    private var realPart: [Float]  // DFT output, real parts
    private var imagPart: [Float]  // DFT output, imaginary parts
    private var powerBuf: [Float]  // squared magnitudes before dB conversion

    // Pre-computed constants for the fused two-pass normalize + dB conversion.
    //
    // floorBeforeScale: the power-domain floor equivalent to 1e-20 after scaling.
    //   = 1e-20 / normalizeScale
    private let floorBeforeScale: Float
    // dbRef: the vDSP_vdbcon reference parameter that folds in the normalization.
    //   = 1.0 / normalizeScale
    // vDSP_vdbcon formula: C[n] = 10·log₁₀(A[n] / *B)
    // → with *B = 1/normalizeScale: C[n] = 10·log₁₀(A[n] · normalizeScale)
    private let dbRef: Float

    init(fftSize: Int, windowFunction: WindowFunction) {
        // Clamp to the nearest valid power-of-two in [256, 16384]. Powers of two
        // are clamped too: the real DFT has no setup for the tiniest sizes.
        let clampedSize: Int
        if fftSize > 0 && (fftSize & (fftSize - 1)) == 0 {
            clampedSize = max(256, min(fftSize, 16384))
        } else {
            var p = 1
            while p < fftSize && p < 16384 { p <<= 1 }
            clampedSize = max(256, min(p, 16384))
        }

        self.fftSize   = clampedSize
        self.bandCount = clampedSize / 2

        let entry = FFTProcessorCache.entry(
            fftSize: clampedSize,
            windowFunction: windowFunction
        )
        self.transform      = entry.transform.dft
        self.evenWindow     = entry.evenWindow
        self.oddWindow      = entry.oddWindow
        self.normalizeScale = Float(1.0) / (4.0 * Float(clampedSize) * Float(clampedSize))

        // Pre-compute fused-pass constants.
        self.floorBeforeScale = Float(1e-20) / self.normalizeScale
        self.dbRef            = Float(1.0)   / self.normalizeScale

        // Allocate scratch buffers once for the lifetime of this instance.
        self.evenPart = [Float](repeating: 0, count: clampedSize / 2)
        self.oddPart  = [Float](repeating: 0, count: clampedSize / 2)
        self.realPart = [Float](repeating: 0, count: clampedSize / 2)
        self.imagPart = [Float](repeating: 0, count: clampedSize / 2)
        self.powerBuf = [Float](repeating: 0, count: clampedSize / 2)
    }

    // MARK: - Public

    /// Compute the windowed FFT of `samples` and write `bandCount` dB magnitude
    /// values into the caller-supplied `output` buffer (must be exactly
    /// `bandCount` elements). Reuses pre-allocated scratch buffers; no heap
    /// allocation occurs after the first call.
    ///
    /// If `samples.count` does not equal `fftSize`, the input is zero-padded
    /// or truncated.
    func process(_ samples: [Float], into output: inout [Float]) {
        precondition(output.count == bandCount)

        // ── Step 1: Window and split into even/odd samples (one pass) ────────
        // The real DFT takes sample 2i as the real part and sample 2i+1 as the
        // imaginary part of its i-th input. Windowing during the split saves a
        // separate pass. The scratch arrays are moved into locals for the loop
        // (and back after the transform) so each store is a plain bounds-checked
        // write rather than a property access that rechecks the array's
        // uniqueness every element — 2.7× faster at fftSize 2048.
        var even = evenPart, odd = oddPart
        evenPart = []; oddPart = []
        let half  = bandCount
        let valid = min(samples.count, fftSize)
        if valid == fftSize {
            for i in 0..<half {
                even[i] = samples[2 &* i] * evenWindow[i]
                odd[i]  = samples[2 &* i &+ 1] * oddWindow[i]
            }
        } else {
            // Short input: samples past the end are zero, as zero-padding gives.
            for i in 0..<half {
                let e = 2 &* i, o = e &+ 1
                even[i] = e < valid ? samples[e] * evenWindow[i] : 0
                odd[i]  = o < valid ? samples[o] * oddWindow[i]  : 0
            }
        }

        // ── Step 2: Real DFT, then squared magnitudes ────────────────────────
        transform.transform(inputReal: even, inputImaginary: odd,
                            outputReal: &realPart, outputImaginary: &imagPart)
        evenPart = even; oddPart = odd

        // re² + im², as `vDSP_zvmags` computed it. Squaring into `evenPart`
        // (free again until the next call) keeps source and destination
        // distinct, as the bounds-checked overlay requires.
        vDSP.square(realPart, result: &evenPart)
        vDSP.add(multiplication: (imagPart, imagPart), evenPart, result: &powerBuf)

        // ── Steps 3 + 4: Floor clamp + normalize + dB conversion (two passes) ─
        //
        // Fused two-pass sequence (see class-level comment for full derivation):
        //
        //   Pass 1 — vDSP_vclip: clamp raw power values at `floorBeforeScale`
        //     (= 1e-20 / normalizeScale), into `realPart` — free once the
        //     magnitudes are computed, and exactly `bandCount` long.
        //     Clamping in raw-power units is numerically identical to clamping
        //     after scaling because normalizeScale > 0 preserves order.
        //
        //   Pass 2 — vDSP_vdbcon: convert to dB using `dbRef = 1/normalizeScale`.
        //     Formula: 10·log₁₀(A[n] / dbRef) = 10·log₁₀(A[n] · normalizeScale),
        //     which is exactly what the former three-pass (vsmul → vclip → vdbcon)
        //     sequence produced.
        //
        // Separate source and destination buffers let both passes use the
        // bounds-checked overlay: passing one array as both source and `inout`
        // result is an exclusivity violation, and working around that with a
        // copy would cost a buffer copy on every window. A dedicated extra
        // buffer instead measured ~4.5% slower at fftSize 16384 (2026-09-27).
        vDSP.clip(powerBuf, to: floorBeforeScale...Float.greatestFiniteMagnitude, result: &realPart)
        vDSP.convert(power: realPart, toDecibels: &output, zeroReference: dbRef)
    }

}
