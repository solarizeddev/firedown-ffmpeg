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

# libavcodec/codec_id.h — add AV_CODEC_ID_WEBP_ANIM at the END of the video
# section, immediately before the blank line + PCM-comment block that
# precedes AV_CODEC_ID_FIRST_AUDIO. Matches Ramiro's placement in PR #22975.
#
# Inserting mid-enum (e.g. right after AV_CODEC_ID_WEBP) shifts every
# subsequent codec ID up by 1, breaking the static_assert in
# libavcodec/version.c that pins specific IDs (AV_CODEC_ID_PRORES_RAW == 274)
# to fixed numeric values.
codec_id_path = os.path.join(ff, 'libavcodec/codec_id.h')
with open(codec_id_path) as f:
    codec_id_text = f.read()
if 'AV_CODEC_ID_WEBP_ANIM' in codec_id_text:
    pass  # already present
else:
    # Anchor on the blank line + PCM-section comment that precedes FIRST_AUDIO.
    # This is more stable than naming the last-video codec, which changes
    # between ffmpeg versions.
    pcm_anchor = '\n\n    /* various PCM "codecs" */'
    if pcm_anchor not in codec_id_text:
        sys.stderr.write("ERROR: codec_id.h — PCM-section anchor not found\n")
        sys.exit(16)
    codec_id_text = codec_id_text.replace(
        pcm_anchor,
        '\n    AV_CODEC_ID_WEBP_ANIM,' + pcm_anchor,
        1,
    )
    with open(codec_id_path, 'w') as f:
        f.write(codec_id_text)
    did.append('codec_id.h: AV_CODEC_ID_WEBP_ANIM (end of video section)')

# libavcodec/codec_desc.c — add descriptor entry at the END of the video
# section. CRITICAL: the codec_descriptors[] array is binary-searched by
# avcodec_descriptor_get() (bsearch on .id), so the array MUST stay sorted
# by codec ID. Our codec_id.h patch places AV_CODEC_ID_WEBP_ANIM at the
# end of the video enum block (highest video ID), so the matching
# descriptor entry must be the last video entry, right before the
# "/* various PCM "codecs" */" delimiter. Inserting it after the WEBP
# descriptor breaks the sort order, causes bsearch to return NULL, and
# crashes ff_decode_preinit on `avctx->codec_descriptor->props`.
desc_path = os.path.join(ff, 'libavcodec/codec_desc.c')
with open(desc_path) as f:
    desc_text = f.read()
if 'AV_CODEC_ID_WEBP_ANIM' in desc_text:
    pass  # descriptor entry already present
else:
    pcm_anchor = '\n    /* various PCM "codecs" */\n'
    if pcm_anchor not in desc_text:
        sys.stderr.write("ERROR: codec_desc.c — PCM-section anchor not found\n")
        sys.exit(11)
    insertion = (
        '    {\n'
        '        .id        = AV_CODEC_ID_WEBP_ANIM,\n'
        '        .type      = AVMEDIA_TYPE_VIDEO,\n'
        '        .name      = "webp_anim",\n'
        '        .long_name = NULL_IF_CONFIG_SMALL("Animated WebP"),\n'
        '        .props     = AV_CODEC_PROP_LOSSY | AV_CODEC_PROP_LOSSLESS,\n'
        '        .mime_types= MT("image/webp"),\n'
        '    },\n'
    )
    desc_text = desc_text.replace(pcm_anchor, '\n' + insertion + pcm_anchor, 1)
    with open(desc_path, 'w') as f:
        f.write(desc_text)
    did.append('codec_desc.c: webp_anim descriptor (end of video section)')

# libavcodec/allcodecs.c — extern declaration for ff_webp_anim_decoder.
# IMPORTANT: do NOT add a trailing /* ... */ comment to the extern line.
# ffmpeg's configure auto-discovers codecs by awk-parsing this file, and
# extra tokens after the symbol name bleed into the discovered codec name,
# yielding a `FIREDOWN-...=yes` shell-eval that explodes with "command not
# found" since hyphens aren't valid identifier chars.
if edit('libavcodec/allcodecs.c',
        marker='ff_webp_anim_decoder',
        find='extern const FFCodec ff_webp_decoder;\n',
        replacement='extern const FFCodec ff_webp_anim_decoder;\n'):
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
                anchor + 'extern const FFInputFormat  ff_webp_anim_demuxer;\n',
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
# Idempotency check is on the canonical CONFIG_ flag, not our marker.
makef_cd_path = os.path.join(ff, 'libavcodec/Makefile')
with open(makef_cd_path) as f:
    makef_cd_text = f.read()
if 'CONFIG_WEBP_ANIM_DECODER' in makef_cd_text:
    pass  # already present (by us or by upstream)
else:
    import re
    # Look for the existing CONFIG_WEBP_DECODER line. The whitespace between
    # the variable and `+= webp.o` varies between ffmpeg versions, so use a
    # loose regex rather than a fixed-string anchor.
    m = re.search(r'^OBJS-\$\(CONFIG_WEBP_DECODER\)[ \t]*\+=[^\n]+$',
                  makef_cd_text, flags=re.M)
    if not m:
        sys.stderr.write("ERROR: libavcodec/Makefile — CONFIG_WEBP_DECODER anchor not found\n")
        sys.exit(14)
    insertion = '\nOBJS-$(CONFIG_WEBP_ANIM_DECODER)       += webp.o'
    new_text = makef_cd_text[:m.end()] + insertion + makef_cd_text[m.end():]
    with open(makef_cd_path, 'w') as f:
        f.write(new_text)
    did.append('libavcodec/Makefile: WEBP_ANIM_DECODER += webp.o')

# libavformat/Makefile — compile webp_anim_dec.o when WEBP_ANIM_DEMUXER enabled.
# Idempotency check is on the canonical content (CONFIG_WEBP_ANIM_DEMUXER as a
# Makefile var), not on our marker — some upstream trees already ship this line.
# Anchors allow multi-file OBJS values (e.g. `+= img2dec.o img2.o`), unlike the
# previous regex.
makef_path = os.path.join(ff, 'libavformat/Makefile')
with open(makef_path) as f:
    makef_text = f.read()
if 'CONFIG_WEBP_ANIM_DEMUXER' in makef_text:
    pass  # already present (by us or by upstream)
else:
    import re
    anchors = [
        r'^OBJS-\$\(CONFIG_WEBM_CHUNK_MUXER\)[ \t]*\+=[^\n]+$',
        r'^OBJS-\$\(CONFIG_WEBP_MUXER\)[ \t]*\+=[^\n]+$',
        r'^OBJS-\$\(CONFIG_WEBVTT_DEMUXER\)[ \t]*\+=[^\n]+$',
        r'^OBJS-\$\(CONFIG_IMAGE_WEBP_PIPE_DEMUXER\)[ \t]*\+=[^\n]+$',
        r'^OBJS-\$\(CONFIG_IMAGE2_DEMUXER\)[ \t]*\+=[^\n]+$',
        r'^OBJS-\$\(CONFIG_MOV_DEMUXER\)[ \t]*\+=[^\n]+$',
    ]
    m = None
    for a in anchors:
        m = re.search(a, makef_text, flags=re.M)
        if m:
            break
    if not m:
        sys.stderr.write("ERROR: libavformat/Makefile — no usable anchor found\n")
        sys.exit(13)
    insertion = '\nOBJS-$(CONFIG_WEBP_ANIM_DEMUXER)         += webp_anim_dec.o'
    new_text = makef_text[:m.end()] + insertion + makef_text[m.end():]
    with open(makef_path, 'w') as f:
        f.write(new_text)
    did.append('libavformat/Makefile: WEBP_ANIM_DEMUXER += webp_anim_dec.o')

# configure — three edits, each independently idempotent:
#   (1) DECODER_LIST: add `webp_anim` after the `webp` entry
#   (2) DEMUXER_LIST: add `webp_anim` after the `webp_pipe` entry
#   (3) Dependency rule: webp_anim_decoder_select="vp8_decoder" — added
#       after the existing webp_decoder_select line. WITHOUT this, configure's
#       dep walker can't resolve webp_anim_decoder and enters an infinite loop
#       during `check_deps`. This was the root cause of the build hang.
cfg_path = os.path.join(ff, 'configure')
with open(cfg_path) as f:
    cfg_text = f.read()
import re

# (1) and (2): list entries
orig_cfg = cfg_text
if re.search(r'^    webp_anim$', cfg_text, flags=re.M) is None:
    cfg_text = re.sub(r'(\n    webp)(\n)', r'\1\n    webp_anim\2', cfg_text, count=1)
    cfg_text = re.sub(r'(\n    webp_pipe)(\n)', r'\1\n    webp_anim\2', cfg_text, count=1)
    if cfg_text != orig_cfg:
        did.append('configure: webp_anim added to DECODER_LIST / DEMUXER_LIST')

# (3) dependency select rule
if 'webp_anim_decoder_select' not in cfg_text:
    select_anchor = 'webp_decoder_select="vp8_decoder"'
    if select_anchor in cfg_text:
        cfg_text = cfg_text.replace(
            select_anchor,
            select_anchor + '\nwebp_anim_decoder_select="vp8_decoder"',
            1,
        )
        did.append('configure: webp_anim_decoder_select="vp8_decoder"')
    else:
        sys.stderr.write(
            "ERROR: configure — webp_decoder_select anchor not found; "
            "cannot wire webp_anim_decoder_select\n")
        sys.exit(15)

if cfg_text != orig_cfg:
    with open(cfg_path, 'w') as f:
        f.write(cfg_text)

for line in did:
    print(f'[firedown]   {line}')
if not did:
    print('[firedown]   (all webp_anim edits already applied)')
PYEOF

echo "[firedown] Done."
