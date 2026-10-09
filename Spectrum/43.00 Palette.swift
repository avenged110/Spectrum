// MARK: - Palette.swift
// Copyright © 2026 avenged110.
// Portions Copyright (c) 2010-2013 Alexander Kojevnikov and contributors (Spek, https://github.com/alexkay/spek).
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from Spek and modified by avenged110, 2026.
// Maps normalized 0–1 magnitude values to packed ARGB UInt32 pixel colors via a 256-entry lookup
// table. Contains the Spectrum palette, a faithful Swift port of Spek's PALETTE_SPECTRUM (a
// modified Dan Bruton visible-light spectrum ramp), and the PaletteType enum for future palette
// extensibility.

import Foundation

/// A color palette mapping normalized 0–1 values to ARGB packed UInt32 pixels.
struct Palette: Sendable {
    /// 256 ARGB entries. Index 0 = coldest (silence), 255 = hottest (loudest).
    let colors: [UInt32]

    /// Look up a color for a normalized value in [0.0, 1.0].
    ///
    /// The caller (ImageBuilder.setColumn) is responsible for clamping the
    /// input to [0, 1] before calling this method. A defensive clamp is applied
    /// here anyway so that an out-of-contract call (e.g. a negative value
    /// produced by a numerical edge case) never results in an index-out-of-bounds
    /// crash — the inner pixel loop is tight enough that the branch predicts well.
    @inline(__always)
    func color(for normalizedValue: Float) -> UInt32 {
        let index = max(0, min(255, Int(normalizedValue * 255)))
        return colors[index]
    }

    static func make(_ type: PaletteType) -> Palette {
        Palette(colors: type.generateColors())
    }
}

/// The set of available color palettes.
///
/// Currently Spectrum uses a single palette — a faithful port of Spek's
/// `PALETTE_SPECTRUM` (modified Dan Bruton visible-light spectrum).
/// The enum is kept in place so palette infrastructure (settings persistence,
/// keyboard cycling, UI pickers) can be extended with additional palettes
/// later without structural changes.
enum PaletteType: String, CaseIterable, Identifiable, Sendable {
    /// Modified Dan Bruton visible-light spectrum (Spek's `PALETTE_SPECTRUM`).
    /// Ramp: black → violet/blue → blue → cyan → green → yellow → red.
    case spectrum

    var id: String { rawValue }

    var displayName: String { "Spectrum" }

    func generateColors() -> [UInt32] {
        (0..<256).map { i in
            let t = Double(i) / 255.0
            let (r, g, b) = spectrumColor(t)
            return packARGB(r: r, g: g, b: b)
        }
    }

    // MARK: - Palette implementation

    /// Faithful Swift port of Spek's `spectrum()` function (spek-palette.cc).
    ///
    /// A modified Dan Bruton visible-light spectrum approximation. The input
    /// is scaled by 0.6625 so the full 0–1 range maps to approximately the
    /// violet-through-red portion of the visible spectrum, with a gentle
    /// intensity fade to black near zero.
    ///
    /// Ramp: black → violet/blue → blue → cyan → green → yellow → red.
    ///
    /// Note: at exactly `t = 1.0` the scaled level equals the strict upper
    /// bound (0.6625) of the final segment, so no branch fires and the output
    /// is black. This is a known Spek edge case reproduced faithfully; it
    /// affects only the single table entry at index 255 and is imperceptible
    /// in practice.
    private func spectrumColor(_ t: Double) -> (Double, Double, Double) {
        let level = t * 0.6625
        var r = 0.0, g = 0.0, b = 0.0

        if level >= 0 && level < 0.15 {
            r = (0.15 - level) / (0.15 + 0.075)
            b = 1.0
        } else if level >= 0.15 && level < 0.275 {
            g = (level - 0.15) / (0.275 - 0.15)
            b = 1.0
        } else if level >= 0.275 && level < 0.325 {
            g = 1.0
            b = (0.325 - level) / (0.325 - 0.275)
        } else if level >= 0.325 && level < 0.5 {
            r = (level - 0.325) / (0.5 - 0.325)
            g = 1.0
        } else if level >= 0.5 && level < 0.6625 {
            r = 1.0
            g = (0.6625 - level) / (0.6625 - 0.5)
        }

        let cf = (level >= 0.0 && level < 0.1) ? level / 0.1 : 1.0
        return (r * cf, g * cf, b * cf)
    }

    // MARK: - Packing

    private func packARGB(r: Double, g: Double, b: Double) -> UInt32 {
        let ri = UInt32(max(0, min(255, r * 255.0 + 0.5)))
        let gi = UInt32(max(0, min(255, g * 255.0 + 0.5)))
        let bi = UInt32(max(0, min(255, b * 255.0 + 0.5)))
        return (0xFF << 24) | (ri << 16) | (gi << 8) | bi
    }
}
