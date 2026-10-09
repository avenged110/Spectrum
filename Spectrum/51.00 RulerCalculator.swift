// MARK: - RulerCalculator.swift
// Copyright © 2026 avenged110.
// Portions Copyright (c) 2010-2013 Alexander Kojevnikov and contributors (Spek, https://github.com/alexkay/spek).
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from Spek and modified by avenged110, 2026.
// Calculates tick positions and labels for the time, frequency, and dB ruler axes. A direct Swift
// port of Spek's SpekRuler::draw() algorithm, including its factor-selection criterion and
// ceiling-proximity suppression logic. Uses cached NSFont metrics to avoid repeated font object
// allocation during the analysis render loop.

import AppKit
import Foundation

/// A single tick mark on a ruler axis.
struct RulerTick {
    /// Position in pixels from the ruler's origin (floor = 0).
    let pixelPosition: CGFloat
    /// Display label (e.g., "1:00", "10 kHz", "−60 dB").
    let label: String
}

/// Calculates ruler tick marks for time, frequency, and dB axes.
///
/// The algorithm is a direct Swift port of Spek's `SpekRuler::draw()` in
/// spek-ruler.cc. The factor-selection and interior-tick-suppression logic
/// are reproduced verbatim; only the drawing calls are replaced with
/// `RulerTick` value construction.
///
/// Spek's selection criterion (from spek-ruler.cc line 25):
///   `fabs(scale * factor) >= spacing * labelLen`
/// where `scale`    = pixels per unit (axis length / unit range),
///       `factor`   = candidate step size (integer units),
///       `spacing`  = per-axis spacing multiplier constant,
///       `labelLen` = width (horizontal axis) or height (vertical axis)
///                    of the representative sample label in pixels.
///
/// Interior ticks are suppressed when they approach the ceiling
/// (spek-ruler.cc line 37):
///   `fabs(scale * (maxUnits - tick)) < labelLen * 1.2`
enum RulerCalculator {

    // MARK: - Cached label metrics

    /// `NSFont.systemFont(ofSize: 10)` text-size attributes are constant for
    /// the lifetime of the process. Caching them avoids recreating an
    /// `[NSAttributedString.Key: Any]` dictionary on every ruler recalculation —
    /// which can fire many times per second during analysis as each progress
    /// event causes a Canvas redraw.
    @MainActor
    private static let rulerAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10)
    ]

    /// Cached label-dimension lookup. Key = (sampleLabel, isHorizontal).
    /// Populated lazily on first use of each label string; never evicted. The
    /// sample labels are fixed at compile time, and the only file-dependent
    /// entries are the time ruler's last two labels (measured to resolve their
    /// overlap), so a session adds a few dozen bytes per distinct duration.
    ///
    /// Access is exclusively from `@MainActor`-isolated call sites, so no
    /// locking is required.
    @MainActor
    private static var labelLenCache: [LabelKey: Double] = [:]

    private struct LabelKey: Hashable {
        let label: String
        let isHorizontal: Bool
    }

    /// Return the cached pixel length (width or height) of `label` at the ruler
    /// font size. Measures once and stores the result for all future calls.
    @MainActor
    private static func cachedLabelLen(for label: String, isHorizontal: Bool) -> Double {
        let key = LabelKey(label: label, isHorizontal: isHorizontal)
        if let hit = labelLenCache[key] { return hit }
        let size = (label as NSString).size(withAttributes: rulerAttrs)
        let len  = isHorizontal ? Double(size.width) : Double(size.height)
        labelLenCache[key] = len
        return len
    }

    // MARK: - Core (Spek-faithful) generator

    /// Generate tick marks replicating Spek's SpekRuler::draw() logic exactly.
    ///
    /// - Parameters:
    ///   - minUnits: Integer minimum of the axis (e.g., 0).
    ///   - maxUnits: Integer maximum of the axis (e.g., 22000 Hz, 193 s, 0 dB).
    ///   - availablePixels: Pixel length of the axis.
    ///   - factors: Candidate step sizes in ascending order. Spek's C arrays
    ///              used a 0 sentinel for null-termination; Swift arrays carry
    ///              their own length, so no sentinel is needed.
    ///   - spacing: Spek's per-axis spacing multiplier (e.g., 1.5 or 2.0).
    ///   - sampleLabel: A representative label string used to measure label size.
    ///   - isHorizontal: `true` for time (width-based), `false` for freq/dB
    ///                   (height-based) — mirrors Spek's TOP/BOTTOM vs LEFT/RIGHT.
    ///   - formatter: Converts an integer unit value to its display string.
    /// - Returns: Tick marks in pixel-position order (floor → ceiling).
    @MainActor
    static func spekTicks(
        minUnits: Int,
        maxUnits: Int,
        availablePixels: Int,
        factors: [Int],
        spacing: Double,
        sampleLabel: String,
        isHorizontal: Bool,
        formatter: (Int) -> String
    ) -> [RulerTick] {
        guard availablePixels > 0, maxUnits > minUnits else { return [] }

        let scale    = Double(availablePixels) / Double(maxUnits - minUnits)
        let labelLen = cachedLabelLen(for: sampleLabel, isHorizontal: isHorizontal)

        // --- Factor selection (spek-ruler.cc lines 23-29) ---
        // Spek's C factor arrays used a 0 sentinel to mark the end of the list.
        // Swift arrays carry their own length; the 0 sentinels and the guard
        // that broke on them have been removed. The Spek-faithful selection
        // criterion and loop structure are otherwise unchanged.
        var factor = 0
        for f in factors {
            if abs(scale * Double(f)) >= spacing * labelLen {
                factor = f
                break
            }
        }

        // --- Always draw floor and ceiling ticks (spek-ruler.cc lines 32-33) ---
        var ticks: [RulerTick] = [
            RulerTick(pixelPosition: 0,
                      label: formatter(minUnits)),
            RulerTick(pixelPosition: CGFloat(availablePixels),
                      label: formatter(maxUnits))
        ]

        // --- Interior ticks (spek-ruler.cc lines 35-42) ---
        if factor > 0 {
            var tick = minUnits + factor
            while tick < maxUnits {
                // Suppress if too close to the ceiling label (line 37).
                if abs(scale * Double(maxUnits - tick)) < labelLen * 1.2 {
                    break
                }
                let px = scale * Double(tick - minUnits)
                ticks.append(RulerTick(pixelPosition: CGFloat(px),
                                       label: formatter(tick)))
                tick += factor
            }
        }

        return ticks.sorted { $0.pixelPosition < $1.pixelPosition }
    }

    // MARK: - Axis-specific entry points

    /// Time axis ticks (seconds).
    ///
    /// Factors and spacing match Spek's time ruler configuration.
    /// `spacing = 2.0`; sample label = "0:00" (representative short label).
    /// The factor list includes 20 s, matching Spek's output for medium-length
    /// tracks (e.g., a 3:13 track produces 20 s intervals).
    ///
    /// After Spek's tick generation, a post-processing pass removes the
    /// second-to-last tick when its label would overlap the ceiling label.
    /// This matters for long files whose time labels grow from "0:00" (4 chars)
    /// to "1:50:23" (7 chars), nearly doubling the rendered label width beyond
    /// what `sampleLabel = "0:00"` predicts during factor selection.
    @MainActor
    static func timeTicks(
        duration: Double,
        availablePixels: Int
    ) -> [RulerTick] {
        let maxUnits = duration.rounded().saturatingInt
        guard maxUnits > 0 else { return [] }

        let factors = [1, 2, 5, 10, 20, 30, 60, 120, 300, 600, 1800, 3600]

        var ticks = spekTicks(
            minUnits: 0,
            maxUnits: maxUnits,
            availablePixels: availablePixels,
            factors: factors,
            spacing: 2.0,
            sampleLabel: "0:00",
            isHorizontal: true,
            formatter: { timeFormatter(Double($0)) }
        )

        // Post-process: drop the second-to-last tick if it overlaps the ceiling.
        //
        // Spek's interior-tick suppression uses "0:00" as the sample label for
        // its spacing check, which underestimates label width for long files
        // (e.g., "1:50:23" is ~48 px wide vs. ~24 px for "0:00"). As a result,
        // the last interior tick can land close enough to the ceiling label that
        // the two labels visually overlap. We fix this with a post-processing
        // step that measures the actual rendered widths of the last two major
        // ticks and removes the second-to-last one if they would overlap.
        ticks = removePenultimateIfOverlapping(ticks)

        return ticks
    }

    /// Removes the second-to-last tick from `ticks` if its label would
    /// visually overlap the ceiling (final) tick label, based on actual rendered
    /// label widths.
    ///
    /// Only the ceiling tick is never removed.
    /// Behavior is unchanged when labels do not overlap.
    @MainActor
    private static func removePenultimateIfOverlapping(
        _ ticks: [RulerTick]
    ) -> [RulerTick] {
        // `spekTicks` already returns its result sorted by `pixelPosition`, so
        // indices already preserve that order naturally. The previous `isMajor`
        // filter was redundant because every tick is always major.

        // Need at least three ticks (floor, at least one interior, ceiling)
        // for there to be a removable penultimate candidate.
        guard ticks.count >= 3 else { return ticks }

        let penultimateTick = ticks[ticks.count - 2]
        let ceilingTick     = ticks[ticks.count - 1]

        // Measure the actual rendered widths of both labels.
        let penultimateWidth = cachedLabelLen(for: penultimateTick.label, isHorizontal: true)
        let ceilingWidth     = cachedLabelLen(for: ceilingTick.label,     isHorizontal: true)

        // The Canvas draws every time label center-anchored on its tick's pixel
        // position (anchor: .top in GraphicsContext.draw). Check whether the
        // right half of the penultimate label overlaps the left half of the
        // ceiling label. A small constant gap (2 pt) is added to keep labels
        // from touching even when they technically don't overlap.
        let gap: CGFloat = 2
        let penultimateRight = penultimateTick.pixelPosition + CGFloat(penultimateWidth) / 2
        let ceilingLeft      = ceilingTick.pixelPosition     - CGFloat(ceilingWidth)     / 2

        if penultimateRight + gap > ceilingLeft {
            // Overlap (or near-collision) detected — drop the penultimate tick.
            var result = ticks
            result.remove(at: ticks.count - 2)
            return result
        }

        return ticks
    }

    /// Frequency axis ticks (Hz).
    ///
    /// Factors and spacing match Spek's frequency ruler configuration.
    /// `spacing = 1.5`; sample label = "22 kHz".
    /// For a 44.1 kHz file (Nyquist 22050 Hz), this produces 2 kHz intervals.
    @MainActor
    static func frequencyTicks(
        nyquist: Double,
        availablePixels: Int
    ) -> [RulerTick] {
        let maxUnits = Int(nyquist.rounded())
        guard maxUnits > 0 else { return [] }

        let factors = [1000, 2000, 5000, 10000, 20000]

        return spekTicks(
            minUnits: 0,
            maxUnits: maxUnits,
            availablePixels: availablePixels,
            factors: factors,
            spacing: 1.5,
            sampleLabel: "22 kHz",
            isHorizontal: false,
            formatter: { frequencyFormatter(Double($0)) }
        )
    }

    /// Decibel axis ticks.
    ///
    /// Uses Spek's factor list and label-measurement algorithm.
    /// `spacing = 3.0` ensures the 10 dB candidate is skipped in favor of
    /// 20 dB at typical graph heights with the default −120 → 0 dB range.
    @MainActor
    static func dbTicks(
        lowerRange: Double,
        upperRange: Double,
        availablePixels: Int
    ) -> [RulerTick] {
        let minUnits = Int(lowerRange.rounded())
        let maxUnits = Int(upperRange.rounded())
        guard maxUnits > minUnits else { return [] }

        let factors = [1, 2, 5, 10, 20, 50]

        return spekTicks(
            minUnits: minUnits,
            maxUnits: maxUnits,
            availablePixels: availablePixels,
            factors: factors,
            spacing: 3.0,
            sampleLabel: "-120 dB",
            isHorizontal: false,
            formatter: { dbFormatter(Double($0)) }
        )
    }

    // MARK: - Formatters

    /// Seconds → "M:SS" or "H:MM:SS".
    static func timeFormatter(_ seconds: Double) -> String {
        let totalSeconds = seconds.rounded().saturatingInt
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return "\(h):\(m.zeroPadded(2)):\(s.zeroPadded(2))"
        } else {
            return "\(m):\(s.zeroPadded(2))"
        }
    }

    /// Hz → nearest integer "X kHz" above 1000 Hz, or "X Hz" below.
    static func frequencyFormatter(_ hz: Double) -> String {
        if hz >= 1_000 {
            return "\(Int((hz / 1_000.0).rounded())) kHz"
        } else {
            return "\(Int(hz.rounded())) Hz"
        }
    }

    /// dB value → "X dB" (integer).
    static func dbFormatter(_ db: Double) -> String {
        "\(Int(db.rounded())) dB"
    }
}
