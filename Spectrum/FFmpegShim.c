// MARK: - FFmpegShim.c
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Implementation of the minimal FFmpeg bridge declared in FFmpegShim.h. Demuxes with libavformat,
// decodes with libavcodec, and converts whatever sample format the decoder emits (U8/S16/S32/FLT/DBL,
// planar or interleaved) to mono Float32 for a single requested channel itself; libswresample is
// linked only because the Opus decoder requires it internally.

#include "FFmpegShim.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dict.h>
#include <libavutil/log.h>
#include <libavutil/samplefmt.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// MARK: - Decoder handle

/// Warm-up samples kept per channel for SPKFFmpegPrerollTail: about 85 ms at
/// 48 kHz, plenty to tell two decodes of the same stretch apart.
#define SPK_TAIL_LENGTH   4096
#define SPK_TAIL_CHANNELS 16
/// Samples per channel decoded past a segment's end for SPKFFmpegPostrollHead:
/// about 0.34 s at 48 kHz, so decoder state that drifts only after the
/// boundary (noise generators and the like) shows up in the comparison.
#define SPK_POST_LENGTH   16384

struct SPKFFmpegDecoder {
    AVFormatContext *format;
    AVCodecContext  *codec;
    AVPacket        *packet;
    AVFrame         *frame;
    int              streamIndex;     // index into format->streams
    int              framePos;        // samples of `frame` already consumed
    int              frameValid;      // `frame` holds undelivered samples
    int              drained;         // EOF sent to the decoder
    int              finished;        // decoder fully flushed
    int64_t          startPts;        // segment window in stream time_base
    int64_t          endPts;          // AV_NOPTS_VALUE = to end of stream
    // Segment report (see SPKFFmpegSegmentReport), in stream time_base.
    AVRational       timeBase;
    int64_t          firstDecodedPts; // AV_NOPTS_VALUE until the first frame
    int64_t          firstKeptPts;
    int64_t          keptEndPts;
    int              missingPts;
    int              reachedEOF;
    // Last warm-up samples per channel, oldest first.
    float           *tail;            // SPK_TAIL_CHANNELS × SPK_TAIL_LENGTH
    int              tailLength;
    // First samples per channel past the window's end (never delivered).
    float           *post;            // SPK_TAIL_CHANNELS × SPK_POST_LENGTH
    int              postLength;
    int              passedEnd;       // a frame at or past endPts was decoded
};

// MARK: - Helpers

static int isDSD(enum AVCodecID id) {
    return id == AV_CODEC_ID_DSD_LSBF || id == AV_CODEC_ID_DSD_MSBF
        || id == AV_CODEC_ID_DSD_LSBF_PLANAR || id == AV_CODEC_ID_DSD_MSBF_PLANAR;
}

/// `sampleRate` is the stream's decoded rate; libavcodec's DSD decoders
/// deliver one float per 8 bits, so DSD64 (2.8224 MHz) reaches the app as
/// 352.8 kHz. The label carries the DSD rate ("DSD64"), which is how users
/// know these files; the metadata bar's sample rate stays the decoded one
/// because that is the Nyquist limit the spectrogram is drawn to.
static const char *codecDisplayName(enum AVCodecID id, int profile, int sampleRate) {
    if (isDSD(id)) {
        switch (sampleRate * 8 / 44100) {
        case 64:  return "DSD64";
        case 128: return "DSD128";
        case 256: return "DSD256";
        case 512: return "DSD512";
        default:  return "DSD";
        }
    }
    switch (id) {
    case AV_CODEC_ID_DTS:
        switch (profile) {
        case AV_PROFILE_DTS_HD_MA:    return "DTS-HD MA";
        case AV_PROFILE_DTS_HD_MA_X:  return "DTS:X";
        case AV_PROFILE_DTS_HD_MA_X_IMAX: return "DTS:X IMAX";
        case AV_PROFILE_DTS_HD_HRA:   return "DTS-HD HRA";
        case AV_PROFILE_DTS_EXPRESS:  return "DTS Express";
        case AV_PROFILE_DTS_96_24:    return "DTS 96/24";
        case AV_PROFILE_DTS_ES:       return "DTS-ES";
        default:                      return "DTS";
        }
    case AV_CODEC_ID_TRUEHD: return "TrueHD";
    case AV_CODEC_ID_MLP:    return "MLP";
    // Display names as shown in the metadata bar.
    case AV_CODEC_ID_AAC:    return "AAC";
    case AV_CODEC_ID_AC3:    return "AC3";
    case AV_CODEC_ID_EAC3:   return "E-AC3";
    case AV_CODEC_ID_MP3:    return "MP3";
    case AV_CODEC_ID_MP2:    return "MP2";
    case AV_CODEC_ID_MP1:    return "MP1";
    case AV_CODEC_ID_FLAC:   return "FLAC";
    case AV_CODEC_ID_ALAC:   return "ALAC";
    case AV_CODEC_ID_OPUS:   return "Opus";
    case AV_CODEC_ID_VORBIS: return "Vorbis";
    case AV_CODEC_ID_WAVPACK: return "WavPack";
    case AV_CODEC_ID_TTA:    return "TTA";
    case AV_CODEC_ID_WMAV1:
    case AV_CODEC_ID_WMAV2:  return "WMA";
    case AV_CODEC_ID_WMAPRO: return "WMA Pro";
    case AV_CODEC_ID_WMALOSSLESS: return "WMA Lossless";
    case AV_CODEC_ID_ADPCM_IMA_WAV:
    case AV_CODEC_ID_ADPCM_MS: return "ADPCM";
    default: {
        if (av_get_bits_per_sample(id) > 0) return "PCM";   // any pcm_* id
        const AVCodecDescriptor *d = avcodec_descriptor_get(id);
        return d ? d->name : "Unknown";
    }
    }
}

/// Bit depth is only meaningful for lossless streams; for lossy DTS the
/// decoder's internal precision (24 or 32 bits) says nothing about the source,
/// and the metadata bar shows nothing for lossy codecs everywhere else.
static int isLossless(enum AVCodecID id, int profile) {
    // WavPack counts as lossless even in its hybrid-lossy mode: the stream
    // still carries the source depth, and libavcodec cannot tell the two
    // modes apart without decoding. DSD is shown as 1 bit.
    if (id == AV_CODEC_ID_TRUEHD || id == AV_CODEC_ID_MLP
        || id == AV_CODEC_ID_FLAC || id == AV_CODEC_ID_ALAC
        || id == AV_CODEC_ID_WAVPACK || id == AV_CODEC_ID_WMALOSSLESS
        || isDSD(id) || av_get_bits_per_sample(id) > 0) return 1;    // PCM
    if (id == AV_CODEC_ID_DTS)
        return profile == AV_PROFILE_DTS_HD_MA || profile == AV_PROFILE_DTS_HD_MA_X
            || profile == AV_PROFILE_DTS_HD_MA_X_IMAX;
    return 0;
}

/// Copy `src` into `dst` (bounded), uppercasing the first character so
/// descriptor short names like "vorbis" read as "Vorbis" in an alert.
static void appendName(char *dst, size_t cap, const char *src) {
    size_t len = strlen(dst);
    if (len > 0 && len + 2 < cap) { strlcat(dst, ", ", cap); len += 2; }
    if (len + 1 >= cap) return;
    strlcat(dst, src, cap);
    if (dst[len] >= 'a' && dst[len] <= 'z') dst[len] = (char)(dst[len] - 'a' + 'A');
}

/// Streams in `fmt` other than `st` that carry real media — attachments and
/// embedded cover art do not count. Zero means the container is nothing but
/// this audio stream, so its overall bitrate and size describe the audio.
static int otherMediaStreamCount(const AVFormatContext *fmt, const AVStream *st) {
    int others = 0;
    for (unsigned i = 0; i < fmt->nb_streams; i++)
        if (fmt->streams[i] != st
            && fmt->streams[i]->codecpar->codec_type != AVMEDIA_TYPE_ATTACHMENT
            && !(fmt->streams[i]->disposition & AV_DISPOSITION_ATTACHED_PIC))
            others++;
    return others;
}

/// Fill `info` from the container + stream without opening a decoder.
static void describeStream(AVFormatContext *fmt, AVStream *st, SPKFFmpegStreamInfo *info) {
    AVCodecParameters *par = st->codecpar;
    snprintf(info->codecName, sizeof info->codecName, "%s",
             codecDisplayName(par->codec_id, par->profile, par->sample_rate));
    info->sampleRate   = par->sample_rate;
    info->channelCount = par->ch_layout.nb_channels;
    // Bit depth: the container's BitDepth element lands in bits_per_coded_sample
    // for Matroska, FLAC/ALAC extradata in bits_per_raw_sample, and PCM carries
    // it in the codec id itself. Lossy codecs report 0 (shown as nothing).
    if (isLossless(par->codec_id, par->profile)) {
        info->bitDepth = isDSD(par->codec_id) ? 1
                       : par->bits_per_raw_sample > 0 ? par->bits_per_raw_sample
                       : par->bits_per_coded_sample > 0 ? par->bits_per_coded_sample
                       : av_get_bits_per_sample(par->codec_id);
    }

    if (st->duration > 0 && st->duration != AV_NOPTS_VALUE) {
        info->duration = st->duration * av_q2d(st->time_base);
    } else if (fmt->duration > 0 && fmt->duration != AV_NOPTS_VALUE) {
        info->duration = (double)fmt->duration / AV_TIME_BASE;
    }
    if (st->start_time != AV_NOPTS_VALUE) {
        info->startTime = st->start_time * av_q2d(st->time_base);
    } else if (fmt->start_time != AV_NOPTS_VALUE) {
        info->startTime = (double)fmt->start_time / AV_TIME_BASE;
    }

    // Lossless streams (DTS-HD MA, TrueHD) signal no bitrate in-band, so fall
    // back to the container's statistics tag. Matroska tags are language-
    // scoped and libavformat exposes them as "BPS-eng" etc.; IGNORE_SUFFIX
    // matches any of those spellings.
    info->bitRate = par->bit_rate;
    if (info->bitRate <= 0) {
        const AVDictionaryEntry *bps = av_dict_get(st->metadata, "BPS", NULL, AV_DICT_IGNORE_SUFFIX);
        if (bps) info->bitRate = strtoll(bps->value, NULL, 10);
    }
    if (info->bitRate <= 0 && otherMediaStreamCount(fmt, st) == 0) {
        // Audio-only container with a single stream (FLAC, MP3, M4A, WAV…):
        // the container's overall rate (size ÷ duration) is the audio rate.
        if (fmt->bit_rate > 0) {
            info->bitRate = fmt->bit_rate;
        } else if (info->duration > 0 && fmt->pb) {
            // Last resort for audio-only files whose demuxer computes no rate
            // (FLAC): file size ÷ duration, the same figure Audio File Services
            // reported for these files.
            int64_t size = avio_size(fmt->pb);
            if (size > 0) info->bitRate = (int64_t)(size * 8.0 / info->duration);
        }
    }
}

/// Source PCM resolution of a DTS stream, read from the PCMR field of the
/// first core frame header found in `pkt` (ETSI TS 102 114 §5.3.1). A lossy
/// DTS core has no decoded "bit depth", but this is what the encoder was fed
/// and what MediaInfo reports. Returns 0 if no 16-bit big-endian core sync is
/// found (14-bit and little-endian framings are effectively never muxed).
static int dtsSourceBitDepth(const AVPacket *pkt) {
    static const int pcmrBits[8] = { 16, 16, 20, 20, 0, 24, 24, 0 };
    const uint8_t *d = pkt->data; int n = pkt->size;
    for (int i = 0; i + 16 <= n; i++) {
        if (d[i] != 0x7F || d[i+1] != 0xFE || d[i+2] != 0x80 || d[i+3] != 0x01) continue;
        // Bit offsets after the 32-bit sync: FTYPE1 SHORT5 CPF1 NBLKS7 FSIZE14 AMODE6
        // SFREQ4 RATE5 FIXED1 DYNF1 TIMEF1 AUXF1 HDCD1 EXTID3 EXT1 ASPF1 LFF2 HFLAG1
        // [HCRC16 if CPF] FILTS1 VERNUM4 CHIST2 PCMR3  → PCMR starts at bit 95 (+16).
        const uint8_t *h = d + i;
        int cpf = (h[4] >> 1) & 1;
        int pos = 95 + (cpf ? 16 : 0);
        int v = 0;
        for (int b = 0; b < 3; b++, pos++) v = (v << 1) | ((h[pos >> 3] >> (7 - (pos & 7))) & 1);
        return pcmrBits[v & 7];
    }
    return 0;
}

/// Open the container and resolve the audio stream at `streamIndex` (0-based
/// among decodable streams, clamped). On success `*outFmt` is owned by the
/// caller and `*outStream` points at the chosen stream. Always fills `info`.
static SPKFFmpegStatus openAndSelect(const char *path, int32_t streamIndex,
                                     SPKFFmpegStreamInfo *info,
                                     AVFormatContext **outFmt, AVStream **outStream,
                                     const AVCodec **outCodec) {
    memset(info, 0, sizeof *info);
    *outFmt = NULL; *outStream = NULL; *outCodec = NULL;
    if (!path) return SPKFFmpegErrorInvalidArgument;

    // libav* would otherwise chatter on stderr (e.g. AVI duration estimates);
    // every failure this bridge cares about is reported through the status code.
    av_log_set_level(AV_LOG_QUIET);

    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, path, NULL, NULL) < 0) return SPKFFmpegErrorCannotOpen;
    if (avformat_find_stream_info(fmt, NULL) < 0) {
        avformat_close_input(&fmt);
        return SPKFFmpegErrorCannotOpen;
    }

    // Count audio streams and the subset the bundled decoders accept, keeping
    // the stream at `streamIndex` — clamped to the last decodable one, matching
    // so an out-of-range index selects the last stream rather than failing.
    int32_t total = 0, decodable = 0;
    AVStream *chosen = NULL; const AVCodec *chosenCodec = NULL;
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        AVStream *st = fmt->streams[i];
        if (st->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) continue;
        total++;
        const AVCodec *dec = avcodec_find_decoder(st->codecpar->codec_id);
        if (!dec) continue;
        if (decodable <= streamIndex) { chosen = st; chosenCodec = dec; }
        decodable++;
    }
    info->totalAudioStreamCount = total;
    info->decodableStreamCount  = decodable;

    if (total == 0) {
        avformat_close_input(&fmt);
        return SPKFFmpegErrorNoAudioTrack;
    }
    if (decodable == 0) {
        // Name what we found so the alert can say "Vorbis is not a supported stream format".
        info->codecName[0] = '\0';
        for (unsigned i = 0; i < fmt->nb_streams; i++) {
            AVStream *st = fmt->streams[i];
            if (st->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) continue;
            const char *name = codecDisplayName(st->codecpar->codec_id, st->codecpar->profile,
                                                st->codecpar->sample_rate);
            if (!strstr(info->codecName, name))
                appendName(info->codecName, sizeof info->codecName, name);
        }
        avformat_close_input(&fmt);
        return SPKFFmpegErrorNoDecoder;
    }

    describeStream(fmt, chosen, info);
    *outFmt = fmt; *outStream = chosen; *outCodec = chosenCodec;
    return SPKFFmpegOK;
}

// MARK: - Sample conversion

/// Largest float sample magnitude passed on: +120 dB over full scale, far
/// beyond any real signal, yet small enough that no FFT the app runs (up to
/// 16384 points) can overflow while summing a window of them.
#define SPK_SAMPLE_LIMIT 1.0e6f

static inline float sanitizedSample(float v) {
    if (!isfinite(v)) return 0.0f;
    return v > SPK_SAMPLE_LIMIT ? SPK_SAMPLE_LIMIT : v < -SPK_SAMPLE_LIMIT ? -SPK_SAMPLE_LIMIT : v;
}

/// Copy one channel of `frame` into `out` as Float32, starting at sample
/// `from`, at most `count` samples. Returns samples written.
static int copyChannel(const AVFrame *frame, int channel, int from, int count, float *out) {
    const enum AVSampleFormat fmtID = (enum AVSampleFormat)frame->format;
    const int channels = frame->ch_layout.nb_channels;
    if (channel >= channels) channel = channels - 1;
    if (channel < 0) channel = 0;
    const int planar = av_sample_fmt_is_planar(fmtID);
    // Planar: one buffer per channel, stride 1. Interleaved: buffer 0, stride = channels.
    const uint8_t *base = planar ? frame->extended_data[channel] : frame->extended_data[0];
    const int stride    = planar ? 1 : channels;
    const int offset    = planar ? 0 : channel;

    switch (av_get_packed_sample_fmt(fmtID)) {
    case AV_SAMPLE_FMT_U8: {
        // pcm_u8 (8-bit WAV) and pcm_s8 (8-bit AIFF) both decode to unsigned
        // 8-bit, centered on 128.
        const uint8_t *p = base + offset + (size_t)from * stride;
        for (int i = 0; i < count; i++) out[i] = ((int)p[(size_t)i * stride] - 128) * (1.0f / 128.0f);
        break;
    }
    case AV_SAMPLE_FMT_S16: {
        const int16_t *p = (const int16_t *)base + offset + (size_t)from * stride;
        for (int i = 0; i < count; i++) out[i] = p[(size_t)i * stride] * (1.0f / 32768.0f);
        break;
    }
    case AV_SAMPLE_FMT_S32: {
        const int32_t *p = (const int32_t *)base + offset + (size_t)from * stride;
        for (int i = 0; i < count; i++) out[i] = (float)(p[(size_t)i * stride] * (1.0 / 2147483648.0));
        break;
    }
    // Float formats can carry NaN or infinity (a damaged float WAV, or a lossy
    // decoder fed garbage). One such sample turns every FFT window it touches
    // into NaN, which then traps when converted to a palette index, so
    // non-finite samples become silence here, where every sample passes.
    // Huge finite values do the same: the FFT's sums overflow to ±inf and
    // inf − inf is NaN, so they are clamped to ±SPK_SAMPLE_LIMIT.
    case AV_SAMPLE_FMT_FLT: {
        const float *p = (const float *)base + offset + (size_t)from * stride;
        for (int i = 0; i < count; i++) out[i] = sanitizedSample(p[(size_t)i * stride]);
        break;
    }
    case AV_SAMPLE_FMT_DBL: {
        const double *p = (const double *)base + offset + (size_t)from * stride;
        // Out-of-range doubles become ±inf here, and then silence.
        for (int i = 0; i < count; i++) out[i] = sanitizedSample((float)p[(size_t)i * stride]);
        break;
    }
    default:
        return -1;   // nothing the bundled decoders emit (no S64, no NB planes)
    }
    return count;
}

// MARK: - Segment bookkeeping

/// Duration of `d->frame` in stream time_base, from its sample count (the
/// container's own per-packet durations are not always present).
static int64_t frameDuration(const SPKFFmpegDecoder *d) {
    int rate = d->frame->sample_rate > 0 ? d->frame->sample_rate : d->codec->sample_rate;
    if (rate <= 0) return 0;
    return av_rescale_q(d->frame->nb_samples, (AVRational){ 1, rate }, d->timeBase);
}

/// Append the warm-up frame in `d->frame` to the per-channel tail, keeping
/// only the last SPK_TAIL_LENGTH samples of each channel.
static void keepPrerollTail(SPKFFmpegDecoder *d) {
    if (!d->tail) return;
    const int n = d->frame->nb_samples;
    int channels = d->frame->ch_layout.nb_channels;
    if (channels > SPK_TAIL_CHANNELS) channels = SPK_TAIL_CHANNELS;
    if (n <= 0 || channels <= 0) return;
    const int take = n < SPK_TAIL_LENGTH ? n : SPK_TAIL_LENGTH;
    int keep = d->tailLength;
    if (keep + take > SPK_TAIL_LENGTH) keep = SPK_TAIL_LENGTH - take;
    for (int c = 0; c < channels; c++) {
        float *t = d->tail + (size_t)c * SPK_TAIL_LENGTH;
        if (keep > 0 && keep < d->tailLength)
            memmove(t, t + (d->tailLength - keep), (size_t)keep * sizeof(float));
        if (copyChannel(d->frame, c, n - take, take, t + keep) < 0) { d->tailLength = 0; return; }
    }
    d->tailLength = keep + take;
}

/// Append the frame in `d->frame` (past the window's end) to the post-roll
/// buffer. Returns 1 while more post-roll samples are wanted.
static int keepPostroll(SPKFFmpegDecoder *d) {
    if (!d->post || d->postLength >= SPK_POST_LENGTH) return 0;
    int channels = d->frame->ch_layout.nb_channels;
    if (channels > SPK_TAIL_CHANNELS) channels = SPK_TAIL_CHANNELS;
    int take = d->frame->nb_samples;
    if (take > SPK_POST_LENGTH - d->postLength) take = SPK_POST_LENGTH - d->postLength;
    if (take <= 0 || channels <= 0) return 0;
    for (int c = 0; c < channels; c++)
        if (copyChannel(d->frame, c, 0, take, d->post + (size_t)c * SPK_POST_LENGTH + d->postLength) < 0)
            return 0;
    d->postLength += take;
    return d->postLength < SPK_POST_LENGTH;
}

// MARK: - Decode loop

/// Pull the next decoded frame into `d->frame`. Returns 1 if a frame is
/// available, 0 at end of stream, <0 on error.
static int nextFrame(SPKFFmpegDecoder *d) {
    for (;;) {
        if (d->finished) return 0;

        int ret = avcodec_receive_frame(d->codec, d->frame);
        if (ret == 0) {
            // Segment window: drop pre-roll frames, stop at the next segment's
            // first frame. Frame membership is decided purely by timestamp, so
            // contiguous segments partition the frames exactly once.
            int64_t pts = d->frame->pts != AV_NOPTS_VALUE ? d->frame->pts
                                                          : d->frame->best_effort_timestamp;
            if (d->passedEnd) {
                // Already past the window: everything from here on, timestamp
                // or not, is post-roll and is never delivered.
                if (pts == AV_NOPTS_VALUE) d->missingPts = 1;
                int more = keepPostroll(d);
                av_frame_unref(d->frame);
                if (more) continue;
                d->finished = 1;
                return 0;
            }
            if (pts == AV_NOPTS_VALUE) {
                d->missingPts = 1;
            } else {
                if (d->firstDecodedPts == AV_NOPTS_VALUE) d->firstDecodedPts = pts;
                if (pts < d->startPts) {
                    keepPrerollTail(d);
                    av_frame_unref(d->frame);
                    continue;
                }
                if (d->endPts != AV_NOPTS_VALUE && pts >= d->endPts) {
                    // Past the window: decode a little further for the next
                    // segment's boundary check, but deliver none of it.
                    d->passedEnd = 1;
                    int more = keepPostroll(d);
                    av_frame_unref(d->frame);
                    if (more) continue;
                    d->finished = 1;
                    return 0;
                }
                if (d->firstKeptPts == AV_NOPTS_VALUE) d->firstKeptPts = pts;
                d->keptEndPts = pts + frameDuration(d);
            }
            d->framePos = 0;
            d->frameValid = 1;
            return 1;
        }
        if (ret == AVERROR_EOF) { d->finished = 1; d->reachedEOF = !d->passedEnd; return 0; }
        if (ret != AVERROR(EAGAIN)) {
            // A decode error in the post-roll only cuts the post-roll short.
            if (!d->passedEnd) return ret;
            d->finished = 1;
            return 0;
        }

        // Decoder needs input.
        if (d->drained) { d->finished = 1; d->reachedEOF = !d->passedEnd; return 0; }

        for (;;) {
            ret = av_read_frame(d->format, d->packet);
            if (ret < 0) {
                // EOF or read error: flush the decoder either way.
                d->drained = 1;
                avcodec_send_packet(d->codec, NULL);
                break;
            }
            if (d->packet->stream_index != d->streamIndex) {
                av_packet_unref(d->packet);
                continue;
            }
            ret = avcodec_send_packet(d->codec, d->packet);
            av_packet_unref(d->packet);
            // A corrupt packet (ret < 0, not EAGAIN) is skipped rather than
            // treated as fatal — matches what ffmpeg itself does by default.
            break;
        }
    }
}

// MARK: - Public API

SPKFFmpegStatus SPKFFmpegProbe(const char *path, int32_t streamIndex, SPKFFmpegStreamInfo *info) {
    SPKFFmpegStreamInfo local;
    if (!info) info = &local;
    AVFormatContext *fmt; AVStream *st; const AVCodec *codec;
    SPKFFmpegStatus status = openAndSelect(path, streamIndex, info, &fmt, &st, &codec);

    // DTS: the container rarely carries a BitDepth element, so read the source
    // resolution from the first audio packet's core header. Done only here —
    // the probe closes the file anyway — because packets consumed by
    // av_read_frame are not replayed to a decoder opened afterwards.
    if (status == SPKFFmpegOK && st->codecpar->codec_id == AV_CODEC_ID_DTS && info->bitDepth <= 0) {
        AVPacket *pkt = av_packet_alloc();
        if (pkt) {
            while (av_read_frame(fmt, pkt) >= 0) {
                int isOurs = pkt->stream_index == st->index;
                if (isOurs) info->bitDepth = dtsSourceBitDepth(pkt);
                av_packet_unref(pkt);
                if (isOurs) break;
            }
            av_packet_free(&pkt);
        }
    }

    if (fmt) avformat_close_input(&fmt);
    return status;
}

SPKFFmpegDecoder *SPKFFmpegOpen(const char *path, int32_t streamIndex,
                                SPKFFmpegStreamInfo *info, SPKFFmpegStatus *status) {
    return SPKFFmpegOpenSegment(path, streamIndex, 0, 0, info, status);
}

/// Seconds of audio decoded and discarded ahead of a segment start so the
/// decoder's filterbank/prediction state matches a sequential decode by the
/// time the first kept frame arrives. Half a second is generous for every
/// bundled codec but Opus (DTS/MLP need a few frames).
#define SPK_SEGMENT_PREROLL_SECONDS 0.5

/// Opus needs longer: its float decoder's inter-frame state (band-energy
/// prediction and the like) converges on a sequential decode's only gradually
/// — on a 60-minute Ogg Opus file one boundary in 109 still differed after
/// 0.5 s of warm-up and none after 1 s (2026-10-07). AudioDecoder checks
/// every boundary regardless.
#define SPK_SEGMENT_PREROLL_OPUS_SECONDS 2.0

SPKFFmpegDecoder *SPKFFmpegOpenSegment(const char *path, int32_t streamIndex,
                                       double startSeconds, double endSeconds,
                                       SPKFFmpegStreamInfo *info, SPKFFmpegStatus *status) {
    SPKFFmpegStreamInfo local;
    SPKFFmpegStatus localStatus;
    if (!info)   info   = &local;
    if (!status) status = &localStatus;

    AVFormatContext *fmt; AVStream *st; const AVCodec *codec;
    *status = openAndSelect(path, streamIndex, info, &fmt, &st, &codec);
    if (*status != SPKFFmpegOK) return NULL;

    SPKFFmpegDecoder *d = calloc(1, sizeof *d);
    if (!d) { avformat_close_input(&fmt); *status = SPKFFmpegErrorDecodeFailed; return NULL; }
    d->format      = fmt;
    d->streamIndex = st->index;
    d->timeBase    = st->time_base;
    d->firstDecodedPts = d->firstKeptPts = d->keptEndPts = AV_NOPTS_VALUE;
    if (startSeconds > 0) {
        d->tail = malloc(sizeof(float) * SPK_TAIL_CHANNELS * SPK_TAIL_LENGTH);
        if (!d->tail) { SPKFFmpegClose(d); *status = SPKFFmpegErrorDecodeFailed; return NULL; }
    }
    if (endSeconds > 0) {
        d->post = malloc(sizeof(float) * SPK_TAIL_CHANNELS * SPK_POST_LENGTH);
        if (!d->post) { SPKFFmpegClose(d); *status = SPKFFmpegErrorDecodeFailed; return NULL; }
    }
    d->startPts    = startSeconds > 0 ? av_rescale_q((int64_t)(startSeconds * AV_TIME_BASE),
                                                     AV_TIME_BASE_Q, st->time_base) : INT64_MIN;
    d->endPts      = endSeconds > 0   ? av_rescale_q((int64_t)(endSeconds * AV_TIME_BASE),
                                                     AV_TIME_BASE_Q, st->time_base) : AV_NOPTS_VALUE;

    // Seek BEFORE marking other streams discarded: av_find_default_stream_index
    // skips discarded streams, and in a movie the video stream is the one that
    // owns the Cues — seeking "on" the audio stream degrades to a linear scan.
    if (startSeconds > 0) {
        double preroll = st->codecpar->codec_id == AV_CODEC_ID_OPUS ? SPK_SEGMENT_PREROLL_OPUS_SECONDS
                                                                     : SPK_SEGMENT_PREROLL_SECONDS;
        double target = startSeconds - preroll;
        if (target < 0) target = 0;
        if (av_seek_frame(fmt, -1, (int64_t)(target * AV_TIME_BASE), AVSEEK_FLAG_BACKWARD) < 0) {
            SPKFFmpegClose(d); *status = SPKFFmpegErrorSeekFailed; return NULL;
        }
    }

    // Tell the demuxer we only want the chosen stream. With AVDISCARD_ALL the
    // Matroska/AVI demuxers seek past other streams' blocks instead of reading
    // them, so a movie's multi-gigabyte video track never touches memory —
    // decode time becomes a function of the audio track's size, not the file's.
    for (unsigned i = 0; i < fmt->nb_streams; i++)
        if ((int)i != st->index) fmt->streams[i]->discard = AVDISCARD_ALL;
    d->codec       = avcodec_alloc_context3(codec);
    d->packet      = av_packet_alloc();
    d->frame       = av_frame_alloc();
    if (!d->codec || !d->packet || !d->frame
        || avcodec_parameters_to_context(d->codec, st->codecpar) < 0) {
        SPKFFmpegClose(d); *status = SPKFFmpegErrorDecodeFailed; return NULL;
    }
    d->codec->pkt_timebase = st->time_base;
    d->codec->thread_count = 1;   // decoding already runs on a background task
    if (avcodec_open2(d->codec, codec, NULL) < 0) {
        SPKFFmpegClose(d); *status = SPKFFmpegErrorDecodeFailed; return NULL;
    }

    // Pull the first frame eagerly so the decoder can report the real channel
    // count and bit depth (the container's values for DTS-HD / TrueHD are
    // often just the core/first-substream values). Packets consumed by
    // avformat_find_stream_info are replayed by libavformat, so no seek is
    // needed to start from the first packet.
    int first = nextFrame(d);
    if (first == 0 && startSeconds > 0) {
        // A later segment with nothing in its window: hand back a decoder that
        // reads nothing; its report tells the caller whether that is a real
        // end of stream or a seek that went wrong.
        return d;
    }
    if (first <= 0) {
        SPKFFmpegClose(d); *status = SPKFFmpegErrorDecodeFailed; return NULL;
    }
    if (d->frame->sample_rate > 0)            info->sampleRate   = d->frame->sample_rate;
    if (d->frame->ch_layout.nb_channels > 0)  info->channelCount = d->frame->ch_layout.nb_channels;
    if (isLossless(d->codec->codec_id, d->codec->profile) && d->codec->bits_per_raw_sample > 0)
        info->bitDepth = d->codec->bits_per_raw_sample;
    return d;
}

int32_t SPKFFmpegRead(SPKFFmpegDecoder *d, int32_t channelIndex, float *out, int32_t capacity) {
    float *outs[1] = { out };
    return SPKFFmpegReadChannels(d, &channelIndex, 1, outs, capacity);
}

int32_t SPKFFmpegReadChannels(SPKFFmpegDecoder *d, const int32_t *channels, int32_t channelCount,
                              float *const *outs, int32_t capacity) {
    if (!d || !channels || !outs || channelCount <= 0 || capacity <= 0) return -1;
    for (int32_t c = 0; c < channelCount; c++) if (!outs[c]) return -1;
    int32_t written = 0;
    while (written < capacity) {
        if (!d->frameValid) {
            int r = nextFrame(d);
            if (r < 0) return written > 0 ? written : -1;
            if (r == 0) break;
        }
        int avail = d->frame->nb_samples - d->framePos;
        int take  = avail < (capacity - written) ? avail : (capacity - written);
        if (take > 0) {
            for (int32_t c = 0; c < channelCount; c++)
                if (copyChannel(d->frame, channels[c], d->framePos, take, outs[c] + written) < 0) return -1;
            d->framePos += take;
            written     += take;
        }
        if (d->framePos >= d->frame->nb_samples) {
            av_frame_unref(d->frame);
            d->frameValid = 0;
        }
    }
    return written;
}

void SPKFFmpegGetSegmentReport(const SPKFFmpegDecoder *d, SPKFFmpegSegmentReport *r) {
    if (!r) return;
    memset(r, 0, sizeof *r);
    r->firstDecodedTime = r->firstKeptTime = r->keptEndTime = NAN;
    if (!d) return;
    const double tb = av_q2d(d->timeBase);
    if (d->firstDecodedPts != AV_NOPTS_VALUE) r->firstDecodedTime = d->firstDecodedPts * tb;
    if (d->firstKeptPts    != AV_NOPTS_VALUE) r->firstKeptTime    = d->firstKeptPts * tb;
    if (d->keptEndPts      != AV_NOPTS_VALUE) r->keptEndTime      = d->keptEndPts * tb;
    r->timeBaseSeconds    = tb;
    r->missingTimestamps  = d->missingPts;
    r->reachedEndOfStream = d->reachedEOF;
    r->prerollTailLength  = d->tailLength;
    r->postrollLength     = d->postLength;
}

int32_t SPKFFmpegPostrollHead(const SPKFFmpegDecoder *d, int32_t channel, float *out, int32_t capacity) {
    if (!d || !out || capacity <= 0 || !d->post || d->postLength <= 0) return 0;
    if (channel < 0) return 0;
    int channels = d->codec ? d->codec->ch_layout.nb_channels : 0;
    if (channels > 0 && channel >= channels) channel = channels - 1;
    if (channel >= SPK_TAIL_CHANNELS) return 0;
    int n = d->postLength < capacity ? d->postLength : capacity;
    memcpy(out, d->post + (size_t)channel * SPK_POST_LENGTH, (size_t)n * sizeof(float));
    return n;
}

int32_t SPKFFmpegPrerollTail(const SPKFFmpegDecoder *d, int32_t channel, float *out, int32_t capacity) {
    if (!d || !out || capacity <= 0 || !d->tail || d->tailLength <= 0) return 0;
    if (channel < 0 || channel >= SPK_TAIL_CHANNELS) return 0;
    // Clamp like copyChannel does, so the tail is of the channel Read delivers.
    int channels = d->codec ? d->codec->ch_layout.nb_channels : 0;
    if (channels > 0 && channel >= channels) channel = channels - 1;
    if (channel >= SPK_TAIL_CHANNELS) return 0;
    int n = d->tailLength < capacity ? d->tailLength : capacity;
    memcpy(out, d->tail + (size_t)channel * SPK_TAIL_LENGTH + (d->tailLength - n), (size_t)n * sizeof(float));
    return n;
}

void SPKFFmpegClose(SPKFFmpegDecoder *d) {
    if (!d) return;
    free(d->tail);
    free(d->post);
    if (d->frame)  av_frame_free(&d->frame);
    if (d->packet) av_packet_free(&d->packet);
    if (d->codec)  avcodec_free_context(&d->codec);
    if (d->format) avformat_close_input(&d->format);
    free(d);
}

int32_t SPKFFmpegIsSegmentable(const char *path) {
    if (!path) return 0;
    av_log_set_level(AV_LOG_QUIET);
    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, path, NULL, NULL) < 0) return 0;
    avformat_find_stream_info(fmt, NULL);   // populates duration for MP4/MOV
    int hasDuration = fmt->duration > 0 && fmt->duration != AV_NOPTS_VALUE;
    const char *name = fmt->iformat->name;
    int isMatroska  = strstr(name, "matroska") != NULL;
    // Containers whose seeks land on exact frame timestamps (sample tables,
    // seek tables or timestamp bisection). Added 2026-10-07 beyond MOV and
    // Matroska: flac, wv, dsf, iff (DFF), ogg, mpegts — each boundary is still
    // checked by AudioDecoder, which falls back to a sequential decode if one
    // does not join up.
    int exactSeek   = strstr(name, "mov") != NULL || !strcmp(name, "flac") || !strcmp(name, "wv")
                   || !strcmp(name, "dsf") || !strcmp(name, "iff") || !strcmp(name, "ogg")
                   || !strcmp(name, "mpegts");
    avformat_close_input(&fmt);
    if (!hasDuration) return 0;
    if (exactSeek) return 1;
    if (!isMatroska) return 0;

    // libavformat does not expose whether Cues exist until the first seek, and
    // a seek without them is the very cost we must avoid. The SeekHead at the
    // front of every Matroska file lists the Cues element's ID (0x1C53BB6B)
    // when present, so a bounded scan of the header is a cheap, safe check —
    // a false negative only costs the speed-up, never correctness.
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    static const unsigned char cuesID[4] = { 0x1C, 0x53, 0xBB, 0x6B };
    // Heap, not stack: this runs on decoder worker threads and cooperative-pool
    // threads whose stacks are only 512 KB.
    const size_t cap = 256 * 1024;
    unsigned char *buf = malloc(cap);
    if (!buf) { fclose(f); return 0; }
    size_t n = fread(buf, 1, cap, f);
    fclose(f);
    int found = 0;
    for (size_t i = 0; i + 4 <= n; i++)
        if (memcmp(buf + i, cuesID, 4) == 0) { found = 1; break; }
    free(buf);
    return found;
}

const char *SPKFFmpegVersionString(void) {
    return av_version_info();
}
