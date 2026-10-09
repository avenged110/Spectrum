#!/bin/zsh
# build-ffmpeg.sh — Copyright © 2026 avenged110.
# SPDX-License-Identifier: GPL-3.0-only
#
# Reproduces the minimal FFmpeg build vendored in this folder (lib/ and include/).
# FFmpeg is Spectrum's only demux/decode path, so only what the app's supported
# formats need is compiled in:
#
#   demuxers  : matroska (MKV/MKA/WebM), avi, mov (MP4/M4A/M4V/MOV), flac, ogg
#               (Opus/Vorbis), wav, aiff, caf, mp3, aac (ADTS), ac3, eac3,
#               dts, mlp, truehd (raw elementary streams), asf (WMV/WMA),
#               wv (WavPack), mpegts (TS/M2TS/MTS), dsf and iff (DSD: DSF/DFF)
#   decoders  : dca (DTS, DTS-HD HRA/MA, DTS:X), mlp, truehd, aac, ac3, eac3,
#               mp1/mp2/mp3, flac, alac, opus, vorbis, wavpack,
#               wmav1/wmav2/wmapro/wmalossless, dsd_lsbf/dsd_msbf (+ planar), and
#               integer/float/A-law/µ-law/ADPCM PCM as found in WAV/AIFF/CAF/AVI
#   parsers   : dca, mlp, aac, ac3, mpegaudio, flac, vorbis (frame-boundary
#               recovery for chunked containers and raw-stream probing)
#   protocol  : file
#   libraries : libavformat, libavcodec, libavutil, libswresample (the Opus
#               decoder requires it; nothing else uses it — no swscale/avfilter)
#
# Everything else — programs, docs, network, hardware acceleration, external
# libraries, every other codec/format — is disabled. The result is an arm64-only
# set of static archives (with NEON assembly), LGPL-2.1+ licensed (no
# --enable-gpl). The app target is arm64-only too (ARCHS = arm64); an x86_64
# slice was dropped 2026-09-12 — it had to be built without assembly and was
# never benchmarked or tested, and macOS 26 is the last Intel release.
#
# Usage:  ./build-ffmpeg.sh [version]        (default: the version below)
# Needs only Xcode's command line tools. No Homebrew, nasm, or pkg-config.

set -euo pipefail

VERSION="${1:-9.0.2}"
MIN_MACOS="15.6"                            # keep in sync with MACOSX_DEPLOYMENT_TARGET
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d /tmp/ffmpeg-build.XXXXXX)"
SRC="$WORK/ffmpeg-$VERSION"
JOBS="$(sysctl -n hw.ncpu)"

echo "→ Downloading ffmpeg-$VERSION to $WORK"
curl -fsSL "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" | tar -xJ -C "$WORK"

COMMON=(
  --disable-all --disable-autodetect --disable-programs --disable-doc --disable-debug
  --disable-shared --enable-static --enable-pic
  # No --enable-small: -Oz costs ~34% decode speed on DTS-HD MA and ~20% on AC-3
  # (measured on 90-minute tracks) for about 300 KB of binary. Decoding is the
  # pipeline's bottleneck for these codecs, so speed wins here.
  --enable-avutil --enable-avcodec --enable-avformat --enable-swresample
  --enable-demuxer=matroska,avi,mov,flac,ogg,wav,aiff,caf,mp3,aac,ac3,eac3,dts,mlp,truehd,asf
  --enable-demuxer=wv,mpegts,dsf,iff
  --enable-decoder=mlp,truehd,dca,aac,ac3,eac3,mp1,mp2,mp3,flac,alac,opus,vorbis,wavpack
  --enable-decoder=wmav1,wmav2,wmapro,wmalossless
  --enable-decoder=dsd_lsbf,dsd_msbf,dsd_lsbf_planar,dsd_msbf_planar
  --enable-decoder=pcm_u8,pcm_s8,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le
  --enable-decoder=pcm_s16be,pcm_s24be,pcm_s32be,pcm_f32be,pcm_f64be
  --enable-decoder=pcm_alaw,pcm_mulaw,adpcm_ima_wav,adpcm_ms
  --enable-parser=mlp,dca,aac,ac3,mpegaudio,flac,vorbis
  --enable-protocol=file
  --cc=clang --target-os=darwin
)

build_arch() {
  local arch="$1"; shift
  local out="$WORK/out-$arch"
  local bld="$WORK/build-$arch"
  mkdir -p "$bld"
  echo "→ Configuring $arch"
  ( cd "$bld" && "$SRC/configure" --prefix="$out" --arch="$arch" \
      --extra-cflags="-arch $arch -mmacosx-version-min=$MIN_MACOS" \
      --extra-ldflags="-arch $arch -mmacosx-version-min=$MIN_MACOS" \
      "${COMMON[@]}" "$@" > "$bld/configure.log" )
  echo "→ Building $arch"
  ( cd "$bld" && make -j"$JOBS" > "$bld/make.log" 2>&1 && make install > /dev/null )
}

build_arch arm64

echo "→ Installing arm64 archives into $HERE"
rm -rf "$HERE/lib" "$HERE/include"
mkdir -p "$HERE/lib"
for lib in avformat avcodec swresample avutil; do
  cp "$WORK/out-arm64/lib/lib$lib.a" "$HERE/lib/lib$lib.a"
done
cp -R "$WORK/out-arm64/include" "$HERE/include"
cp "$SRC/LICENSE.md" "$SRC/COPYING.LGPLv2.1" "$HERE/"

rm -rf "$WORK"
echo "→ Done:"
lipo -info "$HERE"/lib/*.a
