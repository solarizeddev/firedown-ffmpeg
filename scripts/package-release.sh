#!/usr/bin/env bash
# scripts/package-release.sh — bundle the build output into ONE release asset.
#
#   scripts/package-release.sh <tag>          e.g.  scripts/package-release.sh v9.0.2-1
#
# Produces  dist/firedown-ffmpeg-<tag>-android.tar.gz  (+ a .sha256 beside it)
# whose contents mirror exactly what the app's external/ffmpeg/ holds:
#
#   lib/<abi>/*.so     one dir per ABI in output/lib/ (arm64-v8a, x86_64, …)
#   include/           the headers, taken from arm64-v8a as the canonical copy —
#                      the SAME convention the app's scripts/sync-ffmpeg.sh has
#                      always used (the app's CMake points at one include/ dir)
#   version.txt        tag + git describe + FFmpeg source version, for humans and
#                      for the app's fetch gate
#
# Why a tarball on GitHub Releases, not git: the .so set is ~tens of MB and
# changes only when this repo is rebuilt, so git/LFS would carry every revision
# forever (and LFS bandwidth on a private repo is metered); a Release asset is
# free, unmetered, up to 2 GB, and addressed by a tag the app can pin. The app
# side (firedown scripts/fetch-prebuilts.sh) downloads this asset by tag.
#
# The tag names the FFmpeg source version it was built from plus a Firedown
# iteration counter: v<ffmpeg-version>-<n>. The <ffmpeg-version> half MUST match
# SOURCE_VALUE in scripts/parse-arguments.sh (the script refuses otherwise) so
# the tag can never claim a source the build didn't use.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-}"

if [[ -z "$TAG" ]]; then
  echo "usage: $0 <tag>   (format v<ffmpeg-version>-<n>, e.g. v9.0.2-1)" >&2
  exit 2
fi
if [[ ! "$TAG" =~ ^v([0-9]+\.[0-9]+(\.[0-9]+)?)-([0-9]+)$ ]]; then
  echo "ERROR: tag '$TAG' is not of the form v<ffmpeg-version>-<n> (e.g. v9.0.2-1)" >&2
  exit 2
fi
TAG_FFMPEG="${BASH_REMATCH[1]}"

# The source version this tree builds (scripts/parse-arguments.sh SOURCE_VALUE).
SRC_FFMPEG="$(sed -n 's/^SOURCE_VALUE=\(.*\)$/\1/p' "$ROOT/scripts/parse-arguments.sh" | head -1)"
if [[ -z "$SRC_FFMPEG" ]]; then
  echo "ERROR: could not read SOURCE_VALUE from scripts/parse-arguments.sh" >&2
  exit 1
fi
if [[ "$TAG_FFMPEG" != "$SRC_FFMPEG" ]]; then
  echo "ERROR: tag says FFmpeg $TAG_FFMPEG but scripts/parse-arguments.sh builds $SRC_FFMPEG" >&2
  echo "       (tag v${SRC_FFMPEG}-<n> instead, or bump SOURCE_VALUE first)" >&2
  exit 1
fi

OUT="$ROOT/output"
if [[ ! -d "$OUT/lib" ]]; then
  echo "ERROR: $OUT/lib not found — build first: ./ffmpeg-android-maker.sh -dav1d -abis=arm64-v8a,x86_64" >&2
  exit 1
fi

# Every ABI dir must carry the six libraries the app's CMake imports
# (app/src/main/cpp/ffmpegutils/CMakeLists.txt). A partial build (one ABI's
# compile died, or a library got dropped from the allow-list) must not ship.
NEEDED=(libavutil.so libavcodec.so libavformat.so libavfilter.so libswresample.so libswscale.so)
ABIS=()
for d in "$OUT"/lib/*/; do
  abi="$(basename "$d")"
  for lib in "${NEEDED[@]}"; do
    if [[ ! -f "$d/$lib" ]]; then
      echo "ERROR: output/lib/$abi/$lib is missing — incomplete build, not packaging" >&2
      exit 1
    fi
  done
  ABIS+=("$abi")
done
if [[ ${#ABIS[@]} -eq 0 ]]; then
  echo "ERROR: no ABI directories under $OUT/lib" >&2
  exit 1
fi
if [[ ! -d "$OUT/include/arm64-v8a" ]]; then
  echo "ERROR: $OUT/include/arm64-v8a missing (headers are taken from arm64-v8a)" >&2
  exit 1
fi

DESCRIBE="$(cd "$ROOT" && git describe --always --dirty 2>/dev/null || echo unknown)"
DIST="$ROOT/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/lib"
for abi in "${ABIS[@]}"; do
  mkdir -p "$STAGE/lib/$abi"
  cp "$OUT/lib/$abi"/*.so "$STAGE/lib/$abi/"
done
cp -r "$OUT/include/arm64-v8a" "$STAGE/include"
{
  echo "firedown-ffmpeg release $TAG ($DESCRIBE)"
  echo "ffmpeg: $SRC_FFMPEG"
  echo "abis: ${ABIS[*]}"
  echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$STAGE/version.txt"

mkdir -p "$DIST"
ASSET="$DIST/firedown-ffmpeg-$TAG-android.tar.gz"
# Fixed owner/mtime/ordering so re-packaging the same output is byte-identical
# (a re-run after a failed upload yields the same sha256).
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='2000-01-01 00:00Z' \
    -C "$STAGE" -czf "$ASSET" lib include version.txt
( cd "$DIST" && sha256sum "$(basename "$ASSET")" > "$(basename "$ASSET").sha256" )

echo "[ok] $ASSET"
echo "     $(cat "$ASSET.sha256")"
echo "     abis: ${ABIS[*]}   ffmpeg: $SRC_FFMPEG   tree: $DESCRIBE"
