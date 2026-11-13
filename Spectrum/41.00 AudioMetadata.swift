// MARK: - AudioMetadata.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Value type carrying metadata extracted from an audio file's headers: sample rate, codec,
// duration, channel count, bit depth, bitrate, and stream count. Provides formatted string
// accessors for display in the metadata bar and conforms to Hashable to serve as SwiftUI view
// identity for ruler transition animations.

import Foundation

/// Metadata extracted from an audio file's headers.
struct AudioMetadata: Sendable, Equatable, Hashable {
    let fileName: String
    let codec: String
    let sampleRate: Double
    let bitDepth: Int?
    let channelCount: Int
    let bitrate: Int?          // kbps
    let duration: TimeInterval
    let streamCount: Int

    /// The same stream with `duration` replaced — for a file the decoder found
    /// shorter than its header claimed.
    func with(duration: TimeInterval) -> AudioMetadata {
        AudioMetadata(fileName: fileName, codec: codec, sampleRate: sampleRate,
                      bitDepth: bitDepth, channelCount: channelCount, bitrate: bitrate,
                      duration: duration, streamCount: streamCount)
    }

    /// Formatted duration string (e.g., "3:45" or "1:02:15"), in the time
    /// ruler's own format.
    var formattedDuration: String {
        RulerCalculator.timeFormatter(max(0, duration))
    }

    /// Formatted sample rate (e.g., "44100 Hz" or "96000 Hz").
    var formattedSampleRate: String {
        "\(Int(sampleRate)) Hz"
    }

    /// Formatted bitrate (e.g., "320 kbps") or nil.
    var formattedBitrate: String? {
        guard let bitrate else { return nil }
        return "\(bitrate) kbps"
    }

    /// Formatted bit depth (e.g., "16-bit") or nil for lossy codecs.
    var formattedBitDepth: String? {
        guard let bitDepth else { return nil }
        return "\(bitDepth)-bit"
    }

    /// Channel description (e.g., "stereo", "mono", "5.1").
    var channelDescription: String {
        switch channelCount {
        case 1: "mono"
        case 2: "stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(channelCount) ch"
        }
    }
}
