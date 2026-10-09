// MARK: - MetadataBar.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// A fixed-height, three-row strip rendered above the spectrogram. Displays the file path, file
// name, codec badge, channel/stream pickers, and audio property badges (bit rate, sample rate, bit
// depth). All content animates via opacity transitions tied to the ViewModel's metadata state;
// layout geometry never participates in transitions.

import SwiftUI

/// A three-row strip displayed above the spectrogram.
///
/// All rows carry explicit fixed heights so the bar's total height and the
/// position of every element remain constant whether or not a file is loaded.
/// Content simply fills into its reserved space — nothing ever moves.
///
/// Row 1 (height 24 pt) — PathBarChrome: the bar outline is always visible;
///                         only the icon + path text inside fades.
/// Row 2 (height 22 pt) — File name (left-aligned, truncating) + codec badge
///                         (right-aligned, solid-background pill). Extra 4 pt
///                         of inner horizontal padding beyond hPad on each side.
/// Row 3 (height 24 pt) — Channel Picker | Stream Picker | Bit Rate badge |
///                         Frequency badge | Bit Depth badge. The three badges
///                         always render at equal width, filling the space
///                         between the second picker and the right edge of the
///                         content area. Badge chrome (background + border) is
///                         always visible; only the inner text fades.
///
/// Badge content rules:
///   • No file loaded  → empty (chrome visible, no text)
///   • File loaded, value available → formatted value
///   • File loaded, value unavailable → "N/A"
///
/// Animation: all content that changes between files fades in place via opacity.
/// The animation transaction is opened in SpectrogramViewModel (withAnimation)
/// at the exact point where metadata is set or cleared. The view pins every
/// animated text layer to a fully frozen frame so layout geometry never
/// participates in the opacity interpolation, preventing any shift or wiggle.
///
/// hPad (65 pt) matches SpectrogramView's leftPad so that the left edge of the
/// path bar and the left edge of the pickers align precisely with the graph
/// border, and the right edge of the badge group aligns with the legend border's
/// right edge (also 65 pt from the window's right edge).
struct MetadataBar: View {

    let metadata: AudioMetadata?
    let fileURL: URL?
    let settings: SpectrogramSettings

    /// Called when the user selects a new channel index from the picker.
    let onSelectChannel: (Int) -> Void
    /// Called when the user selects a new stream index from the picker.
    let onSelectStream: (Int) -> Void

    // MARK: - Layout constants

    private let hPad:           CGFloat = 65
    /// Extra inset applied only to row 2, narrowing it 4 pt on each side.
    private let row2ExtraInset: CGFloat = 8
    private let pathRowH:       CGFloat = 24
    private let nameRowH:       CGFloat = 22
    /// Row 3 height matches the PathBarView chrome height exactly (24 pt).
    private let pickerRowH:     CGFloat = 24
    private let rowSpacing:     CGFloat = 5
    private let vPad:           CGFloat = 7
    /// Inter-badge gap — same as the inter-element gap used in the picker HStack.
    private let badgeGap:       CGFloat = 6

    /// Fixed width for the codec badge. Sized to comfortably accommodate the
    /// widest possible codec string at 11 pt heavy so the badge never changes
    /// width between files. The DTS family names from the FFmpeg pipeline set
    /// the ceiling: "DTS-HD HRA" measures ~74 pt, "DTS Express" ~72 pt,
    /// "DTS-HD MA" ~68 pt. Sized so the widest label carries only ~5 pt of
    /// side padding — the widest label can afford the tightest fit — with
    /// every shorter label centered in the same fixed frame.
    private let codecBadgeWidth: CGFloat = 78

    /// Animation duration, kept in sync with SpectrogramViewModel.metadataAnimation.
    private let fadeDuration: Double = 0.18

    /// Total bar height derived from the named row and spacing constants above.
    /// Computed from the constants so it stays correct automatically if any
    /// individual value is adjusted — no need to manually re-sum the literal.
    private var barHeight: CGFloat { vPad + pathRowH + rowSpacing + nameRowH + rowSpacing + pickerRowH + vPad }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Row 1 — parent-folder path (no filename)
            pathRow
                .frame(height: pathRowH)
                .padding(.horizontal, hPad)

            Spacer().frame(height: rowSpacing)

            // Row 2 — file name (left) + codec badge (right)
            nameRow
                .frame(height: nameRowH)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, hPad + row2ExtraInset)

            Spacer().frame(height: rowSpacing)

            // Row 3 — channel picker | stream picker | three metadata badges
            pickerRow
                .frame(height: pickerRowH)
                .padding(.horizontal, hPad)
        }
        .padding(.vertical, vPad)
        .frame(maxWidth: .infinity)
        .frame(height: barHeight)
    }

    // MARK: - Row 1: Parent-folder path

    /// The path bar chrome (background + border) is always fully visible.
    /// Only the icon and attributed path text inside fade when the path changes.
    /// Using PathBarChrome directly — rather than animating the whole PathBarView
    /// — ensures the bar outline never participates in the opacity animation.
    private var pathRow: some View {
        let components: [String]
        if let url = fileURL {
            let dirs = url.pathComponents.dropLast().filter { $0 != "/" }
            components = Array(dirs)
        } else {
            components = []
        }
        let pathKey   = components.joined(separator: "/")
        let hasPath   = !pathKey.isEmpty

        return PathBarChrome {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundStyle(.tint)
                // Frozen frame prevents the Text from shifting during the fade.
                Text(hasPath ? attributedPath(for: components) : AttributedString())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 6)
            .opacity(hasPath ? 1 : 0)
            .animation(.easeInOut(duration: fadeDuration), value: pathKey)
        }
    }

    /// Builds the attributed path string used in the path row.
    private func attributedPath(for components: [String]) -> AttributedString {
        var result = AttributedString()
        if components.count > 1 {
            let directoryPart = components.dropLast().joined(separator: " › ") + " › "
            var dirAttr = AttributedString(directoryPart)
            dirAttr.foregroundColor = NSColor.secondaryLabelColor
            result += dirAttr
        }
        var lastAttr = AttributedString(components.last ?? "")
        lastAttr.foregroundColor = NSColor.labelColor
        result += lastAttr
        return result
    }

    // MARK: - Row 2: File name + codec badge

    private var nameRow: some View {
        HStack(spacing: 0) {

            // File name: pinned to a frozen full-width frame so the text
            // cannot shift horizontally during the opacity animation.
            let nameText = fileURL?.lastPathComponent ?? ""
            Text(nameText)
                .font(.callout.bold())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(nameText.isEmpty ? 0 : 1)
                .animation(.easeInOut(duration: fadeDuration), value: nameText)

            Spacer(minLength: 8)

            // Codec badge: the fixed-width outer frame is always present so
            // the filename column width never shifts. The animated ZStack is
            // pinned to that exact frame, preventing any layout participation
            // by the Text during the fade.
            let codecText = metadata?.codec ?? ""
            ZStack(alignment: .center) {
                if !codecText.isEmpty {
                    Text(codecText)
                        .font(.system(size: 11, weight: .heavy))
                        .lineLimit(1)
                        // Frame matches the outer container exactly — no slack
                        // for layout to drift during opacity interpolation.
                        .frame(width: codecBadgeWidth)
                        .padding(.vertical, 2)
                        .background(Color.primary)
                        .foregroundStyle(Color(NSColor.windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .frame(width: codecBadgeWidth)
            .opacity(codecText.isEmpty ? 0 : 1)
            .animation(.easeInOut(duration: fadeDuration), value: codecText)
        }
    }

    // MARK: - Row 3: Pickers + metadata badges

    private var pickerRow: some View {
        HStack(spacing: 8) {

            // Channel picker — disabled when there is only one channel.
            // The selection binding clamps channelIndex to the valid tag range
            // so that a stale persisted index never produces an invalid-tag
            // warning when metadata has fewer channels than the stored value.
            let channelCount     = metadata?.channelCount ?? 1
            let channelEnabled   = channelCount > 1
            let safeChannelIndex = min(settings.channelIndex, max(0, channelCount - 1))

            Picker("", selection: Binding(
                get: { safeChannelIndex },
                set: { onSelectChannel($0) }
            )) {
                ForEach(0..<max(channelCount, 1), id: \.self) { i in
                    Text("Channel \(i + 1) of \(channelCount)").tag(i)
                }
            }
            .labelsHidden()
            .frame(minWidth: 124, maxWidth: 124)
            .disabled(!channelEnabled)

            // Stream picker — disabled when there is only one stream.
            // Mirrors the channel picker's safeChannelIndex pattern: clamp
            // settings.streamIndex to the valid tag range so that a stale
            // persisted index never produces an invalid-tag warning when the
            // new file has fewer streams than the stored value.
            let streamCount    = metadata?.streamCount ?? 1
            let streamEnabled  = streamCount > 1
            let safeStreamIndex = min(settings.streamIndex, max(0, streamCount - 1))

            Picker("", selection: Binding(
                get: { safeStreamIndex },
                set: { onSelectStream($0) }
            )) {
                ForEach(0..<max(streamCount, 1), id: \.self) { i in
                    Text("Stream \(i + 1) of \(streamCount)").tag(i)
                }
            }
            .labelsHidden()
            .frame(minWidth: 124, maxWidth: 124)
            .disabled(!streamEnabled)

            // Three equal-width badges, each with a permanently visible chrome
            // and an independently fading label.
            HStack(spacing: badgeGap) {
                metadataBadge(bitrateText)
                metadataBadge(sampleRateText)
                metadataBadge(bitDepthText)
            }
        }
    }

    // MARK: - Badge text helpers

    /// Bit rate badge text.
    /// No metadata (no file loaded) → "" (empty chrome). Value unavailable → "N/A".
    private var bitrateText: String {
        guard let meta = metadata else { return "" }
        return meta.formattedBitrate ?? "N/A"
    }

    /// Sample rate badge text.
    /// Sample rate is always present once metadata is decoded.
    private var sampleRateText: String {
        guard let meta = metadata else { return "" }
        return meta.formattedSampleRate
    }

    /// Bit depth badge text.
    /// No metadata → "". Lossless with parseable depth → e.g. "24 bit".
    /// Lossy codec or unreadable depth → "N/A".
    private var bitDepthText: String {
        guard let meta = metadata else { return "" }
        return meta.formattedBitDepth ?? "N/A"
    }

    // MARK: - Badge helper

    /// Renders a metadata badge with permanently visible chrome (background +
    /// border) and a layout-frozen fading label.
    ///
    /// The Text is given `.frame(maxWidth: .infinity, maxHeight: .infinity)` so
    /// it fills the ZStack completely and cannot move relative to the container
    /// during the opacity animation. Without this constraint, SwiftUI's layout
    /// engine re-measures the Text's intrinsic size at each interpolation step,
    /// causing a one-pixel shift (wiggle) at the start or end of the fade.
    private func metadataBadge(_ text: String) -> some View {
        ZStack(alignment: .center) {
            // Chrome — always at full opacity; never animates.
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor))
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)

            // Label — frozen frame prevents any layout shift during the fade.
            Text(text)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                // Filling the full ZStack frame is the key fix: the Text's
                // contribution to layout is constant regardless of its opacity,
                // so the layout engine has nothing to re-negotiate mid-animation.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(text.isEmpty ? 0 : 1)
                .animation(.easeInOut(duration: fadeDuration), value: text)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 24)
    }
}
