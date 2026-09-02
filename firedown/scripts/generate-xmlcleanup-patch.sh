#!/usr/bin/env bash
#
# generate-xmlcleanup-patch.sh
#
# One-time helper: given a vanilla FFmpeg source tree, produces a real
# unified-diff patch at
#   firedown/patches/0006-dashdec-c-drop-xmlCleanupParser.patch
# that applies cleanly with `patch -p1`.
#
# Run this whenever you bump FFmpeg versions in the build, to regenerate the
# patch against the new upstream dashdec.c.
#
# What the patch does — the "pthread_mutex_lock called on a destroyed mutex"
# crash (Firedown 1.1.91 tombstone, SIGABRT in libavformat under
# avformat_open_input <- jni_extract_metadata):
#
#   dashdec.c's parse_manifest() ends every manifest parse with
#   xmlCleanupParser(). libxml2 documents that function as process-exit
#   teardown ("if your application is multithreaded ... calling this may
#   crash the application if another thread ... is still using libxml2"):
#   in libxml2 2.13 it runs xmlCleanupDictInternal(), a pthread_mutex_destroy
#   on the STATIC global xmlDictMutex, plus the globals/memory mutexes.
#   Firedown runs ffmpeg on several threads of one process (the capture-probe
#   pool, the downloader, the post-download metadata refresh), so two DASH
#   manifest parses can overlap: thread A finishes and destroys the mutex,
#   thread B is still inside its own parse, reaches xmlDictFree() (freeing the
#   parser context's dictionary), locks the destroyed mutex, and bionic's
#   FORTIFY aborts the whole process. Symbolized frames from the 1.1.91
#   binary: dash_read_header -> parse_manifest -> libxml2 parser teardown ->
#   xmlDictFree -> pthread_mutex_lock. A live DASH download makes the overlap
#   likelier still: refresh_manifest() re-runs parse_manifest() periodically.
#
#   Fix: drop the xmlCleanupParser() call. Nothing leaks: every per-document
#   allocation is already freed by xmlFreeDoc() (kept) and by xmlReadMemory()
#   freeing its own parser context; xmlCleanupParser() only tears down the
#   one-time library state that xmlInitParser() creates, and libxml2 2.13's
#   xmlInitParser() is written to make no allocations at all (its comment:
#   "the initialization code must not make memory allocations"). The static
#   mutexes it destroys are re-initialised by the very next parse anyway, so
#   the call was pure churn on top of being the race. The upstream call is
#   harmless only in single-threaded users like the ffmpeg CLI.
#
#   Same shape as the HLS key cache: belongs in the fork, not upstream —
#   libavformat assumes a single consumer per process; Firedown's several
#   share one. Marker: FIREDOWN-DASH-XMLCLEANUP.
#
# Usage:
#   ./generate-xmlcleanup-patch.sh <path-to-vanilla-ffmpeg-source>

set -euo pipefail

FFMPEG_DIR="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIREDOWN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCH_OUT="$FIREDOWN_DIR/patches/0006-dashdec-c-drop-xmlCleanupParser.patch"

if [[ -z "$FFMPEG_DIR" ]] || [[ ! -f "$FFMPEG_DIR/libavformat/dashdec.c" ]]; then
    echo "Usage: $0 <path-to-vanilla-ffmpeg-source>" >&2
    exit 1
fi

ORIGINAL="$FFMPEG_DIR/libavformat/dashdec.c"
MODIFIED="$(mktemp)"

# Apply the transformation using Python for reliable multi-line block matching.
python3 - "$ORIGINAL" "$MODIFIED" <<'PYEOF'
import sys

src_path, out_path = sys.argv[1], sys.argv[2]
with open(src_path, 'r') as f:
    src = f.read()

# ---------------------------------------------------------------------------
# The one transformation: in parse_manifest()'s cleanup block, drop the
# xmlCleanupParser() call between xmlFreeDoc() and xmlFreeNode(). Matched
# against the exact upstream block so an upstream change is loud.
# ---------------------------------------------------------------------------
old_cleanup = (
    'cleanup:\n'
    '        /*free the document */\n'
    '        xmlFreeDoc(doc);\n'
    '        xmlCleanupParser();\n'
    '        xmlFreeNode(mpd_baseurl_node);\n'
)
new_cleanup = (
    'cleanup:\n'
    '        /*free the document */\n'
    '        xmlFreeDoc(doc);\n'
    '        /* FIREDOWN-DASH-XMLCLEANUP: vanilla calls xmlCleanupParser() here.\n'
    '         * That is libxml2\'s process-exit teardown, documented as unsafe\n'
    '         * while any other thread uses the library: it destroys the static\n'
    '         * global mutexes (xmlDictMutex among them), so a second DASH\n'
    '         * manifest being parsed concurrently on another thread of this\n'
    '         * process (the capture-probe pool, the downloader, a live\n'
    '         * refresh_manifest) locks a destroyed mutex in xmlDictFree() and\n'
    '         * bionic aborts the process ("pthread_mutex_lock called on a\n'
    '         * destroyed mutex"). Nothing leaks without it: xmlFreeDoc() above\n'
    '         * frees the document and xmlReadMemory() its parser context, and\n'
    '         * xmlInitParser() allocates nothing that the next parse would not\n'
    '         * simply re-create. */\n'
    '        xmlFreeNode(mpd_baseurl_node);\n'
)
if 'FIREDOWN-DASH-XMLCLEANUP' in src:
    pass  # already present
elif old_cleanup in src:
    src = src.replace(old_cleanup, new_cleanup, 1)
else:
    print("ERROR: parse_manifest cleanup block (xmlFreeDoc / xmlCleanupParser / xmlFreeNode) not matched", file=sys.stderr)
    sys.exit(2)

if 'xmlCleanupParser();' in src:
    print("ERROR: another xmlCleanupParser() call remains in dashdec.c — extend this generator", file=sys.stderr)
    sys.exit(2)

with open(out_path, 'w') as f:
    f.write(src)
PYEOF

# Produce the diff hunks rooted at a/libavformat/dashdec.c b/libavformat/dashdec.c.
DIFF_TMP="$(mktemp)"
diff -u "$ORIGINAL" "$MODIFIED" \
    | sed -e "1s|^--- .*|--- a/libavformat/dashdec.c|" \
          -e "2s|^+++ .*|+++ b/libavformat/dashdec.c|" \
    > "$DIFF_TMP" || true

if [[ ! -s "$DIFF_TMP" ]]; then
    echo "ERROR: no diff produced — transformation matched nothing or source already patched" >&2
    rm -f "$MODIFIED" "$DIFF_TMP"
    exit 1
fi

# Wrap in a git-format-patch-style envelope to match the other firedown patches
# (apply-firedown-patches.sh guards on a leading `From ` line).
{
    echo "From 0000000000000000000000000000000000000006 Mon Sep 17 00:00:00 2001"
    echo "From: solarizeddev <info@solarized.dev>"
    echo "Date: Thu, 1 Jan 1970 00:00:00 +0000"
    echo "Subject: [PATCH 6/6] dashdec: drop xmlCleanupParser() after each manifest parse"
    echo ""
    echo "parse_manifest() ended every DASH manifest parse with xmlCleanupParser(),"
    echo "libxml2's process-exit teardown, which the library documents as unsafe"
    echo "while any other thread is using it: in libxml2 2.13 it pthread_mutex_destroys"
    echo "the static global xmlDictMutex (and the globals/memory mutexes). Firedown"
    echo "runs ffmpeg on several threads of one process, so two overlapping DASH"
    echo "manifest parses raced: one finished and destroyed the mutex, the other"
    echo "locked it from xmlDictFree() while tearing down its parser context, and"
    echo "bionic's FORTIFY aborted the app (\"pthread_mutex_lock called on a destroyed"
    echo "mutex\", 1.1.91 tombstone under avformat_open_input <- jni_extract_metadata)."
    echo ""
    echo "Drop the call. Nothing leaks: xmlFreeDoc() and xmlReadMemory() already free"
    echo "every per-document allocation, and xmlInitParser() allocates nothing that the"
    echo "next parse would not re-create. Marker: FIREDOWN-DASH-XMLCLEANUP."
    echo "---"
    echo " libavformat/dashdec.c | varies"
    echo ""
    cat "$DIFF_TMP"
} > "$PATCH_OUT"

rm -f "$MODIFIED" "$DIFF_TMP"
echo "[firedown] wrote $PATCH_OUT"
