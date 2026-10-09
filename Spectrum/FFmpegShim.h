// MARK: - FFmpegShim.h
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Public header for the minimal FFmpeg bridge. Wraps libavformat/libavcodec behind a small C API
// (probe, open, read, close, plus the segment-bounded open used for parallel decoding) so the
// Swift side never touches FFmpeg types directly. The bundled FFmpeg build (see
// ThirdParty/FFmpeg/build-ffmpeg.sh) contains only the demuxers and decoders Spectrum supports;
// everything else is compiled out.

#ifndef FFmpegShim_h
#define FFmpegShim_h

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Result codes returned by SPKFFmpegProbe / SPKFFmpegOpen. Mirrors the
/// categories that AudioDecoder.DecoderError already distinguishes so the
/// Swift side can map them one-to-one.
typedef enum {
    SPKFFmpegOK                   = 0,
    SPKFFmpegErrorCannotOpen      = 1,   ///< avformat could not open/parse the container
    SPKFFmpegErrorNoAudioTrack    = 2,   ///< container has no audio streams at all
    SPKFFmpegErrorNoDecoder       = 3,   ///< audio present but no bundled decoder for it
    SPKFFmpegErrorDecodeFailed    = 4,   ///< decoder opened but produced no usable frame
    SPKFFmpegErrorInvalidArgument = 5,
    SPKFFmpegErrorSeekFailed      = 6    ///< a segment's seek failed (segmented decode only)
} SPKFFmpegStatus;

/// Metadata for one audio stream, filled by probe/open.
typedef struct {
    /// Number of audio streams the bundled decoders can handle.
    int32_t decodableStreamCount;
    /// Total audio streams in the container (decodable or not).
    int32_t totalAudioStreamCount;
    /// Display name of the selected stream's codec ("DTS", "TrueHD", "MLP"),
    /// or — on SPKFFmpegErrorNoDecoder — the names of the undecodable codecs
    /// found, comma-separated, so the error message can name them.
    char    codecName[64];
    int32_t sampleRate;
    int32_t channelCount;
    /// Source bit depth reported by the decoder, 0 if unknown.
    int32_t bitDepth;
    /// Stream bitrate in bits/s, 0 if unknown.
    int64_t bitRate;
    /// Duration in seconds, 0 if unknown.
    double  duration;
    /// Timestamp of the stream's first frame in seconds, 0 if unknown. Segment
    /// windows are on this timeline: an MPEG-TS stream from a Blu-ray commonly
    /// starts at 600 s, not 0.
    double  startTime;
} SPKFFmpegStreamInfo;

/// Opaque decoder handle.
typedef struct SPKFFmpegDecoder SPKFFmpegDecoder;

/// Open `path`, locate the decodable audio streams, and describe the one at
/// `streamIndex` (0-based among *decodable* streams; clamped to range) without
/// decoding any audio. Cheap — used for compatibility checks and metadata.
SPKFFmpegStatus SPKFFmpegProbe(const char *path,
                               int32_t streamIndex,
                               SPKFFmpegStreamInfo *info);

/// Open `path` for decoding. Decodes the first frame eagerly so `info` carries
/// the decoder-reported channel count and bit depth. Returns NULL on failure
/// and writes the reason to `status` (may be NULL).
SPKFFmpegDecoder *SPKFFmpegOpen(const char *path,
                                int32_t streamIndex,
                                SPKFFmpegStreamInfo *info,
                                SPKFFmpegStatus *status);

/// Segment-bounded variant of SPKFFmpegOpen for parallel decoding: delivers
/// only frames whose timestamp lies in [startSeconds, endSeconds), or to the
/// end of stream when endSeconds <= 0. Seeks to shortly before startSeconds
/// and discards the warm-up frames so decoders with inter-frame filter state
/// (DTS, MLP) produce exactly what a sequential decode would at that point.
/// Concatenating the output of contiguous segments reproduces a sequential
/// decode sample-for-sample for the codecs on AudioDecoder's whitelist.
///
/// A segment that starts past the last frame (the container overstated its
/// duration) still opens: it returns a decoder that reads nothing, and its
/// SPKFFmpegSegmentReport says why. A failed seek is SPKFFmpegErrorSeekFailed.
SPKFFmpegDecoder *SPKFFmpegOpenSegment(const char *path,
                                       int32_t streamIndex,
                                       double startSeconds,
                                       double endSeconds,
                                       SPKFFmpegStreamInfo *info,
                                       SPKFFmpegStatus *status);

/// Returns 1 when `path` can be decoded in parallel segments: a container
/// with a known duration whose seeks land on exact frame timestamps — MP4/MOV
/// (sample tables), Matroska whose SeekHead advertises a Cues element
/// (without Cues every seek degrades to a linear scan of the file), FLAC,
/// WavPack, DSF/DFF, Ogg and MPEG-TS. Everything else is sequential — AVI,
/// ASF and WAV/AIFF timestamps after a seek are byte-derived, so segment
/// windows would overlap or drop samples, and PCM decodes at memory speed
/// anyway. Codec policy, and the check that every segment boundary really
/// joins up, live in Swift.
int32_t SPKFFmpegIsSegmentable(const char *path);

/// How a segment decoder's window lined up with the stream, for verifying
/// that contiguous segments really join up (see AudioDecoder). Times are in
/// seconds on the stream's own timeline; NAN where nothing was seen.
typedef struct {
    /// Timestamp of the first frame the decoder produced, warm-up included.
    double  firstDecodedTime;
    /// Timestamp of the first frame delivered (inside the window).
    double  firstKeptTime;
    /// End (timestamp + duration) of the last frame delivered so far.
    double  keptEndTime;
    /// One tick of the stream's time base: the resolution of every time above.
    double  timeBaseSeconds;
    /// A frame without a timestamp was seen. Window membership is decided by
    /// timestamp, so such a segment cannot be trusted to join up.
    int32_t missingTimestamps;
    /// The decoder stopped at end of stream rather than at the window's end.
    int32_t reachedEndOfStream;
    /// Samples per channel held by SPKFFmpegPrerollTail.
    int32_t prerollTailLength;
    /// Samples per channel held by SPKFFmpegPostrollHead.
    int32_t postrollLength;
} SPKFFmpegSegmentReport;

void SPKFFmpegGetSegmentReport(const SPKFFmpegDecoder *decoder, SPKFFmpegSegmentReport *report);

/// The last warm-up samples of `channelIndex` decoded just before the
/// segment's first kept frame — the same stretch of audio the previous
/// segment ended with, so the two can be compared. Writes at most `capacity`
/// samples and returns the count (0 for a channel past the first 16).
int32_t SPKFFmpegPrerollTail(const SPKFFmpegDecoder *decoder,
                             int32_t channelIndex,
                             float *out,
                             int32_t capacity);

/// The first samples of `channelIndex` the decoder produced past the segment's
/// end (decoded after its last delivered frame but never delivered) — the
/// same stretch of audio the next segment starts with, so the two can be
/// compared. Available once Read has returned 0. Writes at most `capacity`
/// samples and returns the count (0 for a channel past the first 16, or for
/// a segment that ran to the end of the stream).
int32_t SPKFFmpegPostrollHead(const SPKFFmpegDecoder *decoder,
                              int32_t channelIndex,
                              float *out,
                              int32_t capacity);

/// Decode and write up to `capacity` Float32 samples of each of `channelCount`
/// channels (`channels[i]` into `outs[i]`, each clamped to the stream's
/// channel count) — one decode pass for every channel requested. Returns the
/// number of samples written per channel, 0 at end of stream, or a negative
/// value on an unrecoverable decode error.
int32_t SPKFFmpegReadChannels(SPKFFmpegDecoder *decoder,
                              const int32_t *channels,
                              int32_t channelCount,
                              float *const *outs,
                              int32_t capacity);

/// Decode and write up to `capacity` mono Float32 samples of channel
/// `channelIndex` (clamped to the stream's channel count) into `out`.
/// Returns the number of samples written, 0 at end of stream, or a negative
/// value on an unrecoverable decode error.
int32_t SPKFFmpegRead(SPKFFmpegDecoder *decoder,
                      int32_t channelIndex,
                      float *out,
                      int32_t capacity);

/// Release all resources. Safe to call with NULL.
void SPKFFmpegClose(SPKFFmpegDecoder *decoder);

/// Version string of the bundled libavcodec, for the log.
const char *SPKFFmpegVersionString(void);

#ifdef __cplusplus
}
#endif

#endif /* FFmpegShim_h */
