#!/usr/bin/env bash
#
# apply-firedown-patches.sh
#
# Applies Firedown's modifications to a vanilla FFmpeg source tree.
# Invoked from ffmpeg-android-maker.sh after FFmpeg source is downloaded
# and before any per-ABI builds run.
#
# Usage:
#   ./apply-firedown-patches.sh <path-to-ffmpeg-source-dir>
#
# Idempotent — running twice on the same tree is safe.

set -euo pipefail

FFMPEG_DIR="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIREDOWN_DIR="$SCRIPT_DIR"

if [[ -z "$FFMPEG_DIR" ]]; then
    echo "ERROR: missing FFmpeg source directory argument" >&2
    echo "Usage: $0 <path-to-ffmpeg-source-dir>" >&2
    exit 1
fi

if [[ ! -d "$FFMPEG_DIR" ]] || [[ ! -f "$FFMPEG_DIR/configure" ]]; then
    echo "ERROR: $FFMPEG_DIR does not look like an FFmpeg source tree" >&2
    exit 1
fi

echo "[firedown] Applying patches to: $FFMPEG_DIR"

# ----------------------------------------------------------------------
# Step 1: File replacements
# ----------------------------------------------------------------------
# Full-file replacements live in firedown/replacements/. Each file is
# copied verbatim over the upstream version.

REPLACEMENTS_DIR="$FIREDOWN_DIR/replacements"

if [[ -d "$REPLACEMENTS_DIR" ]]; then
    echo "[firedown] Copying file replacements..."

    if [[ -f "$REPLACEMENTS_DIR/libavformat/http.c" ]]; then
        echo "  - libavformat/http.c (OkHttp JNI backend)"
        cp "$REPLACEMENTS_DIR/libavformat/http.c" "$FFMPEG_DIR/libavformat/http.c"
    fi
fi

# ----------------------------------------------------------------------
# Step 2: hls.c — remove keepalive code paths
# ----------------------------------------------------------------------
# Note: there was previously a step here that edited FFmpeg's configure
# to add http_protocol_deps="jni" / https_protocol_deps="jni". That edit
# was removed because:
#   - scripts/ffmpeg/build.sh always passes --enable-jni, so JNI is
#     available when http/https protocols are built.
#   - If JNI is disabled, the replacement http.c fails at compile time
#     with clear "ff_jni_* undeclared" errors — same outcome, simpler path.
#   - configure is large and version-sensitive; anchor-based edits are
#     fragile across FFmpeg versions.

HLS_FILE="$FFMPEG_DIR/libavformat/hls.c"
HLS_PATCH="$FIREDOWN_DIR/patches/0002-hls-c-remove-keepalive-branches.patch"

if [[ ! -f "$HLS_FILE" ]]; then
    echo "ERROR: $HLS_FILE not found" >&2
    exit 4
fi

# Idempotency: the patch adds a marker comment we can grep for
if grep -q "FIREDOWN-HLS-PATCHED" "$HLS_FILE"; then
    echo "[firedown] hls.c already patched, skipping"
elif [[ -f "$HLS_PATCH" ]] && head -1 "$HLS_PATCH" | grep -q '^From '; then
    # Real generated patch (starts with "From <hash>")
    echo "[firedown] Applying hls.c patch..."
    if ! patch -p1 --forward --reject-file=- -d "$FFMPEG_DIR" < "$HLS_PATCH"; then
        echo "ERROR: hls.c patch failed to apply" >&2
        echo "       FFmpeg source may have changed; regenerate the patch with:" >&2
        echo "       ./firedown/scripts/generate-hls-patch.sh $FFMPEG_DIR" >&2
        exit 5
    fi
else
    echo "WARNING: $HLS_PATCH is missing or a placeholder" >&2
    echo "         Generate it with: ./firedown/scripts/generate-hls-patch.sh $FFMPEG_DIR" >&2
    echo "         Continuing without hls.c patch — connection keepalive still active." >&2
fi

echo "[firedown] Done."
