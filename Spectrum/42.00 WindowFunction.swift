// MARK: - WindowFunction.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Defines the available DFT window functions (Hann, Hamming, Blackman-Harris, Bartlett,
// Rectangular) and generates their coefficient buffers. Formulas are calibrated to match Spek's
// reference output exactly, using vDSP_hann_window with vDSP_HANN_DENORM and matching coefficient
// constants from Spek's spek-pipeline.cc.

import Accelerate
import Foundation

/// DFT window functions matching Spek's set.
///
/// ## Calibration
/// All windows are implemented to produce the same per-bin dB readings as
/// Spek for a given input signal. The window energy (sum of coefficients)
/// feeds directly into the normalization chain, so the generating formulas
/// must match Spek's exactly.
///
/// Spek's reference formulas (spek-pipeline.cc `get_window`):
/// - Hann:            `0.5 · (1 − cos(2πi / (N−1)))`
/// - Hamming:         `0.53836 − 0.46164 · cos(2πi / (N−1))`
/// - Blackman-Harris: `0.35875 − 0.48829·c + 0.14128·c2 − 0.01168·c3`
///                    where `cₖ = cos(2πki / (N−1))`
enum WindowFunction: String, CaseIterable, Identifiable, Sendable {
    case hann
    case hamming
    case blackmanHarris
    case bartlett
    case rectangular

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hann:           "Hann"
        case .hamming:        "Hamming"
        case .blackmanHarris: "Blackman-Harris"
        case .bartlett:       "Bartlett"
        case .rectangular:    "Rectangular"
        }
    }

    /// Generate a window buffer of the given size.
    func makeBuffer(size: Int) -> [Float] {
        guard size > 0 else { return [] }
        switch self {
        case .hann:           return makeHannWindow(size: size)
        case .hamming:        return makeHammingWindow(size: size)
        case .blackmanHarris: return makeBlackmanHarrisWindow(size: size)
        case .bartlett:       return makeBartlettWindow(size: size)
        case .rectangular:    return [Float](repeating: 1.0, count: size)
        }
    }

    // MARK: - Private generators

    /// Hann window matching Spek's formula exactly:
    ///   `w[i] = 0.5 · (1 − cos(2πi / (N−1)))`
    ///
    /// `vDSP_hann_window` with `vDSP_HANN_DENORM` produces this verbatim; the
    /// `.hanningDenormalized` sequence is that call behind the Swift overlay.
    /// `vDSP_HANN_NORM` scales each coefficient by √(8/3) ≈ 1.633, boosting
    /// energy by 10·log₁₀(8/3) ≈ +4.26 dB relative to Spek's reference.
    private func makeHannWindow(size: Int) -> [Float] {
        vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                    count: size, isHalfWindow: false)
    }

    /// Hamming window matching Spek's exact coefficients:
    ///   `w[i] = 0.53836 − 0.46164 · cos(2πi / (N−1))`
    ///
    /// `vDSP_hamm_window` uses 0.54/0.46 (~0.026 dB difference).
    private func makeHammingWindow(size: Int) -> [Float] {
        var window = [Float](repeating: 0, count: size)
        guard size > 1 else { window[0] = 0.53836; return window }
        let twoPiOverNm1 = Float(2.0 * Double.pi / Double(size - 1))
        for i in 0..<size {
            window[i] = 0.53836 - 0.46164 * cos(twoPiOverNm1 * Float(i))
        }
        return window
    }

    /// 4-term Blackman-Harris matching Spek's exact coefficients:
    ///   `w[i] = 0.35875 − 0.48829·c + 0.14128·c2 − 0.01168·c3`
    ///
    /// `vDSP_blkman_window` implements a 3-term Blackman (0.42/0.50/0.08),
    /// a different window with higher sidelobes.
    private func makeBlackmanHarrisWindow(size: Int) -> [Float] {
        var window = [Float](repeating: 0, count: size)
        guard size > 1 else { window[0] = 0.35875; return window }
        let twoPiOverNm1 = Float(2.0 * Double.pi / Double(size - 1))
        for i in 0..<size {
            let fi = Float(i)
            let c  = cos(twoPiOverNm1 * fi)
            let c2 = cos(twoPiOverNm1 * fi * 2)
            let c3 = cos(twoPiOverNm1 * fi * 3)
            window[i] = 0.35875 - 0.48829 * c + 0.14128 * c2 - 0.01168 * c3
        }
        return window
    }

    /// Bartlett (triangular) window. Not in Spek; included for completeness.
    private func makeBartlettWindow(size: Int) -> [Float] {
        var window = [Float](repeating: 0, count: size)
        // Guard the degenerate size == 1 case, mirroring the same guard used by
        // makeHammingWindow / makeBlackmanHarrisWindow. With size == 1 the
        // denominator `halfN` below is 0, so `(Float(0) - 0) / 0` evaluates to
        // NaN and the function would return `[NaN]` — silently poisoning the
        // entire FFT chain. A length-1 triangular window is the single peak
        // sample, i.e. 1.0 (matching NumPy's `bartlett(1)`).
        guard size > 1 else { window[0] = 1.0; return window }
        let halfN = Float(size - 1) / 2.0
        for i in 0..<size {
            window[i] = 1.0 - abs((Float(i) - halfN) / halfN)
        }
        return window
    }
}
