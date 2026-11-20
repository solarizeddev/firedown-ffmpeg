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
# What the patch does to hls.c (FFmpeg 9.1 shape; 9.0.x is still accepted):
#   1. open_url(): the open_url_keepalive() branch goes, every open is a
#      plain s->io_open(). Vanilla 9.1's av_assert0(!*pb) on that path is
#      kept — see 3 for why it holds.
#   2. parse_playlist(): the c->playlist_pb keepalive reuse block goes.
#   3. is_native_http() (9.1+) returns 0. Upstream uses it to decide whether
#      a finished segment's / playlist's AVIOContext may be KEPT OPEN for a
#      follow-up request on the same connection (http_persistent, default on).
#      With 1 and 2 removed, a kept-open *pb would reach io_open() non-NULL:
#      vanilla 9.1 asserts there; a patch that merely dropped the branch (the
#      9.0 shape of this patch) would overwrite the pointer and leak the
#      URLContext — the fork's OkHttp object and its JNI global refs — once
#      per segment. Returning 0 means nothing is ever kept open: every segment
#      input is closed when read to the end, and OkHttp pools the socket.
#   4. open_url_keepalive() itself is deleted: after 1 and 2 it is an unused
#      static that references ff_http_do_new_request2(), which the fork's
#      http.c replacement does not define.
# Any of these that the source calls for but the script cannot perform is a
# hard error — a half-done patch is exactly the leak/assert described in 3.
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

if 'FIREDOWN-HLS-PATCHED' in src:
    print("ERROR: source already carries FIREDOWN-HLS-PATCHED; point this at a VANILLA tree", file=sys.stderr)
    sys.exit(2)

failed = []

# Transformation 1: replace the keepalive branch in open_url() with a direct
# s->io_open call. 9.0.x tests `*pb`, 9.1 tests `is_native_http(*pb)` and
# asserts !*pb on the plain path; the assert is re-emitted when present.
pattern1 = re.compile(
    r'    if \(is_http && c->http_persistent && (?:\*pb|is_native_http\(\*pb\))\) \{\n'
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
    r'(?P<assert>        av_assert0\(!\*pb\);\n)?'
    r'        ret = s->io_open\(s, pb, url, AVIO_FLAG_READ, &tmp\);\n'
    r'    \}\n'
)

def replacement1(m):
    out = ('    /* FIREDOWN-HLS-PATCHED: keepalive removed, all I/O via io_open.\n'
           '     * Nothing keeps a connection open across requests any more\n'
           '     * (is_native_http() is 0), so *pb is always NULL here. */\n')
    if m.group('assert'):
        out += '    av_assert0(!*pb);\n'
    out += '    ret = s->io_open(s, pb, url, AVIO_FLAG_READ, &tmp);\n'
    return out

new_src, n1 = pattern1.subn(replacement1, src)
if n1 != 1:
    failed.append(f"open_url keepalive block matched {n1} times (expected 1)")

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
if n2 != 1:
    failed.append(f"playlist_pb keepalive block matched {n2} times (expected 1)")

# Transformation 3 (FFmpeg 9.1+): is_native_http() always 0, so no finished
# input is ever kept open for reuse. Absent in 9.0.x, where it is a no-op.
pattern3 = re.compile(
    r'static int is_native_http\(AVIOContext \*pb\)\n'
    r'\{\n'
    r'#if !CONFIG_HTTP_PROTOCOL\n'
    r'    return 0;\n'
    r'#else\n'
    r'    URLContext \*uc = ffio_geturlcontext\(pb\);\n'
    r'    return uc && !strncmp\(uc->prot->name, "http", 4\);\n'
    r'#endif\n'
    r'\}\n'
)

replacement3 = (
    'static int is_native_http(AVIOContext *pb)\n'
    '{\n'
    '    /* FIREDOWN-HLS-PATCHED: never report a native-http input. Upstream\n'
    '     * uses this to keep a finished segment\'s (or playlist\'s) connection\n'
    '     * open and re-request on it (http_persistent). Firedown\'s http(s)\n'
    '     * protocol is OkHttp over JNI, which pools at the transport layer, and\n'
    '     * the keepalive paths that would consume a kept-open *pb are removed;\n'
    '     * a kept-open input would only reach io_open() non-NULL and leak the\n'
    '     * URLContext (the FFmpegOkhttp object and its JNI refs) per segment. */\n'
    '    return 0;\n'
    '}\n'
)

new_src, n3 = pattern3.subn(replacement3, new_src)
has_native_http = 'is_native_http(' in src
if has_native_http and n3 != 1:
    failed.append(f"is_native_http() body matched {n3} times (expected 1; the source uses it)")
if not has_native_http and n3 != 0:
    failed.append("is_native_http() matched although the source never calls it")

# Transformation 4: delete open_url_keepalive() — unused once 1 and 2 are
# done, and the only reference to ff_http_do_new_request2().
pattern4 = re.compile(
    r'static int open_url_keepalive\(AVFormatContext \*s, AVIOContext \*\*pb,\n'
    r'.*?\n'
    r'#endif\n'
    r'\}\n'
    r'\n',
    re.S
)

new_src, n4 = pattern4.subn('', new_src)
if n4 != 1:
    failed.append(f"open_url_keepalive() definition matched {n4} times (expected 1)")

if 'open_url_keepalive' in new_src:
    failed.append("a reference to open_url_keepalive survives")

if failed:
    for msg in failed:
        print("ERROR: " + msg, file=sys.stderr)
    print("       Upstream hls.c has changed shape; update the patterns in this script.", file=sys.stderr)
    sys.exit(2)

with open(out_path, 'w') as f:
    f.write(new_src)

print(f"Transformations: open_url={n1}, playlist={n2}, is_native_http={n3}, keepalive_fn={n4}", file=sys.stderr)
PYEOF

# Build a unified diff
TMP_DIFF="$(mktemp)"
diff -u \
    --label "a/libavformat/hls.c" \
    --label "b/libavformat/hls.c" \
    "$ORIGINAL" "$MODIFIED" > "$TMP_DIFF" || true

if [[ ! -s "$TMP_DIFF" ]]; then
    echo "ERROR: no changes produced — check the ERROR output above" >&2
    rm -f "$MODIFIED" "$TMP_DIFF"
    exit 2
fi

# Wrap with git-format-patch headers
{
cat <<'HEADER_EOF'
From 0000000000000000000000000000000000000002 Mon Sep 17 00:00:00 2001
From: solarizeddev <info@solarized.dev>
Date: Thu, 1 Jan 1970 00:00:00 +0000
Subject: [PATCH 2/2] hls: remove open_url_keepalive code paths

Firedown's HTTP backend is provided via JNI (OkHttp on the Java side).
OkHttp manages connection pooling and keepalive at the transport layer,
so FFmpeg's hls demuxer does not need its own keepalive fast-path.

This patch:
  - removes the open_url_keepalive call in open_url() and falls through
    directly to s->io_open
  - removes the playlist_pb keepalive reuse in the playlist parsing path
  - makes is_native_http() return 0 (FFmpeg 9.1+), so no finished
    segment/playlist input is kept open for reuse: with the keepalive
    paths gone, a kept-open input would reach io_open() non-NULL and
    either trip vanilla's av_assert0(!*pb) or leak the URLContext
  - deletes the now-unused open_url_keepalive(), the only reference to
    ff_http_do_new_request2(), which the OkHttp http.c does not define

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
