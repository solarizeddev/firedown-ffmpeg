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
# Idempotent — running twice on the same tree is safe. Each edit is checked
# independently so partial states from prior failed runs are recoverable.

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
# Step 1: File replacements (http.c → OkHttp JNI backend)
# ----------------------------------------------------------------------

REPLACEMENTS_DIR="$FIREDOWN_DIR/replacements"

if [[ -d "$REPLACEMENTS_DIR" ]]; then
    echo "[firedown] Copying file replacements..."

    if [[ -f "$REPLACEMENTS_DIR/libavformat/http.c" ]]; then
        echo "  - libavformat/http.c (OkHttp JNI backend)"
        cp "$REPLACEMENTS_DIR/libavformat/http.c" "$FFMPEG_DIR/libavformat/http.c"
    fi

    if [[ -f "$REPLACEMENTS_DIR/libavcodec/webp.c" ]]; then
        echo "  - libavcodec/webp.c (animated WebP decoder, FFmpeg PR #22975)"
        cp "$REPLACEMENTS_DIR/libavcodec/webp.c" "$FFMPEG_DIR/libavcodec/webp.c"
    fi

    if [[ -f "$REPLACEMENTS_DIR/libavformat/webp_anim_dec.c" ]]; then
        echo "  - libavformat/webp_anim_dec.c (animated WebP demuxer, FFmpeg PR #22975)"
        cp "$REPLACEMENTS_DIR/libavformat/webp_anim_dec.c" "$FFMPEG_DIR/libavformat/webp_anim_dec.c"
    fi
fi

# ----------------------------------------------------------------------
# Step 2: configure — patch protocol declarations
# ----------------------------------------------------------------------
# Two independent edits, matching the working Firedown build:
#
#  (a) DELETE the line  https_protocol_select="tls_protocol"
#      Decouples https_protocol from tls_protocol so https builds without
#      a TLS backend. Our replacement http.c handles HTTPS at the OkHttp
#      layer in Java.
#
#  (b) ADD the line  http_protocol_deps="jni"
#      Marks http_protocol as JNI-dependent (matches what the replacement
#      http.c actually uses). Inserted just before the
#      "# external library protocols" comment.
#
# Each edit is checked independently — if a prior run did (a) but failed
# before (b), re-running this script will complete (b).

echo "[firedown] Patching configure..."

python3 - "$FFMPEG_DIR/configure" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    text = f.read()

orig = text
changes = []

# (a) Delete https_protocol_select="tls_protocol", replace with marker.
old_a = 'https_protocol_select="tls_protocol"'
marker_a = '# FIREDOWN-PATCH-A: https_protocol_select removed (was tls_protocol)'
if marker_a in text:
    pass  # already done
elif old_a in text:
    text = text.replace(old_a, marker_a, 1)
    changes.append('(a) deleted https_protocol_select line')
else:
    print('ERROR: anchor for edit (a) not found: ' + old_a, file=sys.stderr)
    print('       Upstream FFmpeg may have changed; update this script.', file=sys.stderr)
    sys.exit(2)

# (b) Inject http_protocol_deps="jni" before "# external library protocols".
inject_b = 'http_protocol_deps="jni"'
anchor_b = '# external library protocols'
if inject_b in text:
    pass  # already done
elif anchor_b in text:
    text = text.replace(anchor_b, inject_b + '\n\n' + anchor_b, 1)
    changes.append('(b) inserted http_protocol_deps="jni"')
else:
    print('ERROR: anchor for edit (b) not found: ' + anchor_b, file=sys.stderr)
    sys.exit(2)

if text != orig:
    with open(path, 'w') as f:
        f.write(text)
    for c in changes:
        print('[firedown] ' + c)
else:
    print('[firedown] configure already fully patched')
PYEOF

# Independent post-patch verification
if ! grep -q '# FIREDOWN-PATCH-A' "$FFMPEG_DIR/configure"; then
    echo "ERROR: edit (a) verification failed (https_protocol_select not removed)" >&2
    exit 3
fi
if ! grep -q '^http_protocol_deps="jni"$' "$FFMPEG_DIR/configure"; then
    echo "ERROR: edit (b) verification failed (http_protocol_deps=jni not present)" >&2
    exit 3
fi

chmod +x "$FFMPEG_DIR/configure"

# ----------------------------------------------------------------------
# Step 3: hls.c — remove keepalive code paths
# ----------------------------------------------------------------------

HLS_FILE="$FFMPEG_DIR/libavformat/hls.c"
HLS_PATCH="$FIREDOWN_DIR/patches/0002-hls-c-remove-keepalive-branches.patch"

if [[ ! -f "$HLS_FILE" ]]; then
    echo "ERROR: $HLS_FILE not found" >&2
    exit 4
fi

if grep -q "FIREDOWN-HLS-PATCHED" "$HLS_FILE"; then
    echo "[firedown] hls.c already patched, skipping"
elif [[ -f "$HLS_PATCH" ]] && head -1 "$HLS_PATCH" | grep -q '^From '; then
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

# ----------------------------------------------------------------------
# Step 4: Wire animated WebP decoder + demuxer into upstream files
# ----------------------------------------------------------------------
# The replacement libavcodec/webp.c adds a second decoder (ff_webp_anim_decoder)
# alongside the existing still-WebP decoder. The new libavformat/webp_anim_dec.c
# adds the matching demuxer (ff_webp_anim_demuxer). For configure to recognise
# both, and for the link to find their symbols, we have to touch:
#
#   - libavcodec/codec_id.h     : add AV_CODEC_ID_WEBP_ANIM enum value
#   - libavcodec/codec_desc.c   : add codec descriptor entry
#   - libavcodec/allcodecs.c    : extern declaration for ff_webp_anim_decoder
#   - libavformat/allformats.c  : extern declaration for ff_webp_anim_demuxer
#   - libavcodec/Makefile       : link webp.o when WEBP_ANIM_DECODER is enabled
#   - libavformat/Makefile      : compile webp_anim_dec.o
#   - configure                 : register webp_anim in DECODER_LIST/DEMUXER_LIST
#
# Each edit uses a FIREDOWN-WEBP-ANIM-* marker so re-runs are idempotent.

echo "[firedown] Wiring animated WebP decoder + demuxer into upstream files..."

python3 - "$FFMPEG_DIR" <<'PYEOF'
import sys, os

ff = sys.argv[1]

def edit(path, marker, find, replacement, where='after'):
    """Insert `replacement` relative to anchor `find` in `path`, idempotent on `marker`."""
    full = os.path.join(ff, path)
    with open(full) as f:
        text = f.read()
    if marker in text:
        return False  # already applied
    if find not in text:
        sys.stderr.write(f"ERROR: anchor not found in {path}\n  looking for: {find!r}\n")
        sys.exit(10)
    if where == 'after':
        new_text = text.replace(find, find + replacement, 1)
    else:
        new_text = text.replace(find, replacement + find, 1)
    with open(full, 'w') as f:
        f.write(new_text)
    return True

did = []

# libavcodec/codec_id.h — add AV_CODEC_ID_WEBP_ANIM after AV_CODEC_ID_WEBP
if edit('libavcodec/codec_id.h',
        marker='AV_CODEC_ID_WEBP_ANIM',
        find='    AV_CODEC_ID_WEBP,\n',
        replacement='    AV_CODEC_ID_WEBP_ANIM, /* FIREDOWN-WEBP-ANIM-CODEC-ID */\n'):
    did.append('codec_id.h: AV_CODEC_ID_WEBP_ANIM')

# libavcodec/codec_desc.c — add descriptor entry. Anchor on the closing `},` of
# the existing AV_CODEC_ID_WEBP descriptor block.
desc_anchor = '''        .id        = AV_CODEC_ID_WEBP,'''
desc_path = os.path.join(ff, 'libavcodec/codec_desc.c')
with open(desc_path) as f:
    desc_text = f.read()
if 'FIREDOWN-WEBP-ANIM-DESC' in desc_text:
    pass
else:
    idx = desc_text.find(desc_anchor)
    if idx < 0:
        sys.stderr.write("ERROR: codec_desc.c — AV_CODEC_ID_WEBP descriptor not found\n")
        sys.exit(11)
    # Find the end of this block: scan forward to the next "    },\n"
    end = desc_text.find('\n    },\n', idx)
    if end < 0:
        sys.stderr.write("ERROR: codec_desc.c — end of WEBP descriptor block not found\n")
        sys.exit(11)
    end += len('\n    },\n')
    insertion = (
        '    /* FIREDOWN-WEBP-ANIM-DESC */\n'
        '    {\n'
        '        .id        = AV_CODEC_ID_WEBP_ANIM,\n'
        '        .type      = AVMEDIA_TYPE_VIDEO,\n'
        '        .name      = "webp_anim",\n'
        '        .long_name = NULL_IF_CONFIG_SMALL("Animated WebP image"),\n'
        '        .props     = AV_CODEC_PROP_LOSSY | AV_CODEC_PROP_LOSSLESS,\n'
        '        .mime_types= MT("image/webp"),\n'
        '    },\n'
    )
    with open(desc_path, 'w') as f:
        f.write(desc_text[:end] + insertion + desc_text[end:])
    did.append('codec_desc.c: webp_anim descriptor')

# libavcodec/allcodecs.c — extern declaration for ff_webp_anim_decoder
if edit('libavcodec/allcodecs.c',
        marker='ff_webp_anim_decoder',
        find='extern const FFCodec ff_webp_decoder;\n',
        replacement='extern const FFCodec ff_webp_anim_decoder; /* FIREDOWN-WEBP-ANIM-DECODER-EXTERN */\n'):
    did.append('allcodecs.c: ff_webp_anim_decoder extern')

# libavformat/allformats.c — extern declaration for ff_webp_anim_demuxer.
# Anchor on the still-WebP demuxer extern. In ffmpeg 8.x the *_pipe image
# demuxers are namespaced with `image_` at the C-symbol level (the configure
# flag is still just `webp_pipe`), so the symbol is ff_image_webp_pipe_demuxer.
# Try both spellings to remain compatible with older trees.
allf_path = os.path.join(ff, 'libavformat/allformats.c')
with open(allf_path) as f:
    allf_text = f.read()
if 'ff_webp_anim_demuxer' in allf_text:
    pass
else:
    for anchor in (
        'extern const FFInputFormat  ff_image_webp_pipe_demuxer;\n',
        'extern const FFInputFormat ff_image_webp_pipe_demuxer;\n',
        'extern const FFInputFormat  ff_webp_pipe_demuxer;\n',
        'extern const FFInputFormat ff_webp_pipe_demuxer;\n',
    ):
        if anchor in allf_text:
            new_text = allf_text.replace(
                anchor,
                anchor + 'extern const FFInputFormat  ff_webp_anim_demuxer; /* FIREDOWN-WEBP-ANIM-DEMUXER-EXTERN */\n',
                1,
            )
            with open(allf_path, 'w') as f:
                f.write(new_text)
            did.append('allformats.c: ff_webp_anim_demuxer extern')
            break
    else:
        sys.stderr.write("ERROR: allformats.c — webp_pipe demuxer extern not found\n")
        sys.exit(12)

# libavcodec/Makefile — link webp.o when WEBP_ANIM_DECODER enabled.
# (webp.o is already pulled in for CONFIG_WEBP_DECODER; this just adds it for
# the new flag so the link works even if someone disables the still decoder.)
if edit('libavcodec/Makefile',
        marker='FIREDOWN-WEBP-ANIM-DECODER-OBJ',
        find='OBJS-$(CONFIG_WEBP_DECODER)            += webp.o',
        replacement='\nOBJS-$(CONFIG_WEBP_ANIM_DECODER)       += webp.o # FIREDOWN-WEBP-ANIM-DECODER-OBJ'):
    did.append('libavcodec/Makefile: WEBP_ANIM_DECODER += webp.o')

# libavformat/Makefile — compile webp_anim_dec.o when WEBP_ANIM_DEMUXER enabled.
# Anchor on an existing webp-related line.
makef_path = os.path.join(ff, 'libavformat/Makefile')
with open(makef_path) as f:
    makef_text = f.read()
if 'FIREDOWN-WEBP-ANIM-DEMUXER-OBJ' in makef_text:
    pass
else:
    # Look for any line referencing webp in libavformat/Makefile and append after it.
    import re
    m = re.search(r'^OBJS-\$\(CONFIG_WEBP_PIPE_DEMUXER\)[ \t]*\+=[ \t]*[A-Za-z0-9_./]+$',
                  makef_text, flags=re.M)
    if not m:
        # Try a looser anchor — img2dec is usually nearby
        m = re.search(r'^OBJS-\$\(CONFIG_IMAGE2_DEMUXER\)[ \t]*\+=[ \t]*[A-Za-z0-9_./]+$',
                      makef_text, flags=re.M)
    if not m:
        sys.stderr.write("ERROR: libavformat/Makefile — anchor (WEBP_PIPE_DEMUXER or IMAGE2_DEMUXER) not found\n")
        sys.exit(13)
    insertion = '\nOBJS-$(CONFIG_WEBP_ANIM_DEMUXER)         += webp_anim_dec.o # FIREDOWN-WEBP-ANIM-DEMUXER-OBJ'
    new_text = makef_text[:m.end()] + insertion + makef_text[m.end():]
    with open(makef_path, 'w') as f:
        f.write(new_text)
    did.append('libavformat/Makefile: WEBP_ANIM_DEMUXER += webp_anim_dec.o')

# configure — register webp_anim in DECODER_LIST and DEMUXER_LIST.
cfg_path = os.path.join(ff, 'configure')
with open(cfg_path) as f:
    cfg_text = f.read()
changed_cfg = False
if 'webp_anim' not in cfg_text:
    # DECODER_LIST entry — insert after the `webp` decoder line.
    import re
    new_text, n = re.subn(r'(\n    webp)(\n)', r'\1\n    webp_anim\2', cfg_text, count=2)
    # subn with count=2 covers DECODER_LIST + (optionally) DEMUXER_LIST if both
    # have `webp` followed by a different next entry. But the DEMUXER_LIST entry
    # is `webp_pipe`, not `webp`, so the second `webp` line we want to hit may
    # not exist. We need a separate insert for the DEMUXER_LIST `webp_pipe` line.
    new_text = re.sub(r'(\n    webp_pipe)(\n)', r'\1\n    webp_anim\2', new_text, count=1)
    if new_text != cfg_text:
        with open(cfg_path, 'w') as f:
            f.write(new_text)
        did.append('configure: webp_anim added to DECODER_LIST / DEMUXER_LIST')
        changed_cfg = True

for line in did:
    print(f'[firedown]   {line}')
if not did:
    print('[firedown]   (all webp_anim edits already applied)')
PYEOF

echo "[firedown] Done."
