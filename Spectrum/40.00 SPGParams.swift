// MARK: - SPGParams.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Value type holding the spectrogram parameters: FFT size, window function, palette, dB range,
// and stream/channel selection. The DSP and display values are fixed at their defaults (there is
// no UI for them); only the stream/channel selection changes at runtime.

import Foundation

/// The spectrogram parameters for one analysis run.
///
/// Not persisted. The DSP and display values once were (under the
/// `SpectrogramSettings` defaults key), but nothing has been able to change
/// them since their UI was removed, so a stored copy could only override the
/// defaults silently; the key is deleted at launch (see
/// `Preferences.removeObsoleteKeys`).
struct SpectrogramSettings: Equatable, Sendable {

    // MARK: - FFT

    /// Log2 of the FFT size. Range: 8–14 (256–16384 samples). Spek default: 11 (2048).
    var fftBits: Int = 11

    /// The FFT window size derived from fftBits.
    var fftSize: Int { 1 << fftBits }

    var windowFunction: WindowFunction = .hann

    // MARK: - Display

    var palette: PaletteType = .spectrum

    /// Upper dB limit. Range: −140 to 0. Default: 0.
    var upperRange: Float = 0

    /// Lower dB limit. Range: −140 to 0. Default: −120.
    var lowerRange: Float = -120

    // MARK: - Stream / Channel selection

    var streamIndex: Int = 0
    var channelIndex: Int = 0
}
