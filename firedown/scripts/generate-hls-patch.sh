#!/usr/bin/env bash
#
# generate-hls-patch.sh
#
# One-time helper: given a vanilla FFmpeg source tree, produces a real
# unified-diff patch at firedown/patches/0002-hls-c-remove-keepalive-branches.patch
# that applies cleanly with `patch -p1`.
#
# Run this whenever you bump FFmpeg versions in the build, to regenerate
# the patch against the new upstream hls.c.
#
# Usage:
#   ./generate-hls-patch.sh <path-to-vanilla-ffmpeg-source>

set -euo pipefail

FFMPEG_DIR="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIREDOWN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCH_OUT="$FIREDOWN_DIR/patches/0002-hls-c-remove-keepalive-branches.patch"

if [[ -z "$FFMPEG_DIR" ]] || [[ ! -f "$FFMPEG_DIR/libavformat/hls.c" ]]; then
    echo "Usage: $0 <path-to-vanilla-ffmpeg-source>" >&2
    exit 1
fi

ORIGINAL="$FFMPEG_DIR/libavformat/hls.c"
MODIFIED="$(mktemp)"

# Apply transformations using Python for reliable multi-line block matching
python3 - "$ORIGINAL" "$MODIFIED" <<'PYEOF'
import sys, re

src_path, out_path = sys.argv[1], sys.argv[2]
with open(src_path, 'r') as f:
    src = f.read()

# Transformation 1: replace the keepalive branch in open_url() with
# a direct s->io_open call.
pattern1 = re.compile(
    r'    if \(is_http && c->http_persistent && \*pb\) \{\n'
    r'        ret = open_url_keepalive\(c->ctx, pb, url, &tmp\);\n'
    r'        if \(ret == AVERROR_EXIT\) \{\n'
    r'            av_dict_free\(&tmp\);\n'
    r'            return ret;\n'
    r'        \} else if \(ret < 0\) \{\n'
    r'            if \(ret != AVERROR_EOF\)\n'
    r'                av_log\(s, AV_LOG_WARNING,\n'
    r'                    "keepalive request failed for \'%s\' with error: \'%s\' when opening url, retrying with new connection\\n",\n'
    r'                    url, av_err2str\(ret\)\);\n'
    r'            av_dict_copy\(&tmp, \*opts, 0\);\n'
    r'            av_dict_copy\(&tmp, opts2, 0\);\n'
    r'            ret = s->io_open\(s, pb, url, AVIO_FLAG_READ, &tmp\);\n'
    r'        \}\n'
    r'    \} else \{\n'
    r'        ret = s->io_open\(s, pb, url, AVIO_FLAG_READ, &tmp\);\n'
    r'    \}\n'
)

replacement1 = (
    '    /* FIREDOWN-HLS-PATCHED: keepalive removed, all I/O via io_open */\n'
    '    ret = s->io_open(s, pb, url, AVIO_FLAG_READ, &tmp);\n'
)

new_src, n1 = pattern1.subn(replacement1, src)
if n1 == 0:
    print("WARNING: open_url keepalive block not matched", file=sys.stderr)
elif n1 > 1:
    print(f"WARNING: open_url keepalive block matched {n1} times (expected 1)", file=sys.stderr)

# Transformation 2: remove the playlist_pb keepalive block entirely.
pattern2 = re.compile(
    r'    if \(is_http && !in && c->http_persistent && c->playlist_pb\) \{\n'
    r'        in = c->playlist_pb;\n'
    r'        ret = open_url_keepalive\(c->ctx, &c->playlist_pb, url, NULL\);\n'
    r'        if \(ret == AVERROR_EXIT\) \{\n'
    r'            return ret;\n'
    r'        \} else if \(ret < 0\) \{\n'
    r'            if \(ret != AVERROR_EOF\)\n'
    r'                av_log\(c->ctx, AV_LOG_WARNING,\n'
    r'                    "keepalive request failed for \'%s\' with error: \'%s\' when parsing playlist\\n",\n'
    r'                    url, av_err2str\(ret\)\);\n'
    r'            in = NULL;\n'
    r'        \}\n'
    r'    \}\n'
)

new_src, n2 = pattern2.subn('', new_src)
if n2 == 0:
    print("WARNING: playlist_pb keepalive block not matched", file=sys.stderr)
elif n2 > 1:
    print(f"WARNING: playlist_pb keepalive block matched {n2} times (expected 1)", file=sys.stderr)

with open(out_path, 'w') as f:
    f.write(new_src)

print(f"Transformations: open_url={n1}, playlist={n2}", file=sys.stderr)
PYEOF

# Build a unified diff
TMP_DIFF="$(mktemp)"
diff -u \
    --label "a/libavformat/hls.c" \
    --label "b/libavformat/hls.c" \
    "$ORIGINAL" "$MODIFIED" > "$TMP_DIFF" || true

if [[ ! -s "$TMP_DIFF" ]]; then
    echo "ERROR: no changes produced — check the WARNING output above" >&2
    rm -f "$MODIFIED" "$TMP_DIFF"
    exit 2
fi

# Wrap with git-format-patch headers
{
cat <<'HEADER_EOF'
From 0000000000000000000000000000000000000002 Mon Sep 17 00:00:00 2001
From: solarizeddev <solarizeddev@solarized.dev>
Date: Thu, 1 Jan 1970 00:00:00 +0000
Subject: [PATCH 2/2] hls: remove open_url_keepalive code paths

Firedown's HTTP backend is provided via JNI (OkHttp on the Java side).
OkHttp manages connection pooling and keepalive at the transport layer,
so FFmpeg's hls demuxer does not need its own keepalive fast-path.

This patch:
  - removes the open_url_keepalive call in open_url() and falls through
    directly to s->io_open
  - removes the playlist_pb keepalive reuse in the playlist parsing path

Adds a FIREDOWN-HLS-PATCHED marker comment so apply-firedown-patches.sh
can detect when the patch is already applied.
HEADER_EOF

echo "---"
echo " libavformat/hls.c | varies"
echo ""
cat "$TMP_DIFF"
echo "-- "
echo "2.40.0"
} > "$PATCH_OUT"

rm -f "$MODIFIED" "$TMP_DIFF"

echo "[firedown] Generated: $PATCH_OUT"
echo "[firedown] Review with: less $PATCH_OUT"
