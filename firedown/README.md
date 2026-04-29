# firedown/

This directory contains everything Firedown adds on top of upstream `ffmpeg-android-maker`. Nothing in this directory exists in `Javernaut/ffmpeg-android-maker` — it's all Firedown-specific. Keeping it isolated here means upstream merges won't conflict with our changes.

## Contents

```
firedown/
├── apply-firedown-patches.sh    # Invoked by the patched ffmpeg-android-maker.sh
│                                # during build. Applies replacements + patches
│                                # to the FFmpeg source tree.
│
├── replacements/                # Files that replace vanilla FFmpeg sources
│   └── libavformat/
│       └── http.c               # OkHttp JNI backend (replaces FFmpeg's HTTP)
│
├── patches/                     # In-place patches to vanilla FFmpeg sources
│   ├── 0001-ffmpeg-android-maker-add-firedown-hook.patch
│   │                            # The diff documenting how the main
│   │                            # ffmpeg-android-maker.sh is modified. This
│   │                            # patch is already applied in this fork — it
│   │                            # exists for reference and re-application
│   │                            # against future upstream versions.
│   │
│   └── 0002-hls-c-remove-keepalive-branches.patch
│                                # Removes open_url_keepalive code paths in
│                                # libavformat/hls.c. Generated against your
│                                # specific FFmpeg version (see below).
│
└── scripts/
    ├── install-firedown-hook.sh # One-time: re-applies the modification to
    │                            # ffmpeg-android-maker.sh against a fresh
    │                            # upstream pull. Idempotent.
    │
    └── generate-hls-patch.sh    # Generates patches/0002 from a vanilla
                                 # FFmpeg source tree. Run when bumping
                                 # FFmpeg version.
```

## How it fits together

The patched `ffmpeg-android-maker.sh` at the repo root (modified by `0001`) calls `firedown/apply-firedown-patches.sh` after FFmpeg source is downloaded but before any build runs. That script:

1. Copies `firedown/replacements/libavformat/http.c` over the upstream `http.c`
2. Edits `configure` via `awk` to add `http_protocol_deps="jni"` and `https_protocol_deps="jni"`
3. Applies `firedown/patches/0002-hls-c-remove-keepalive-branches.patch` via `patch -p1`

All three operations are idempotent — running twice on the same source tree is safe.

## Initial setup

If you've just forked this repo or pulled fresh from upstream, you may need to:

1. **Re-apply the main script hook** (if upstream's `ffmpeg-android-maker.sh` was overwritten by a merge):
   ```bash
   ./firedown/scripts/install-firedown-hook.sh
   ```

2. **Generate the hls.c patch** against your target FFmpeg version:
   ```bash
   wget https://ffmpeg.org/releases/ffmpeg-8.1.tar.xz
   tar -xf ffmpeg-8.1.tar.xz
   ./firedown/scripts/generate-hls-patch.sh ./ffmpeg-8.1
   ```

After that, normal builds via `./ffmpeg-android-maker.sh` will pick up Firedown's modifications automatically.

## When upstream changes

If `Javernaut/ffmpeg-android-maker` releases a new version and you want to merge:

1. Pull upstream into your fork
2. If `ffmpeg-android-maker.sh` was modified upstream, re-run `install-firedown-hook.sh` to put the hook back
3. If FFmpeg version was bumped, regenerate the hls.c patch with `generate-hls-patch.sh`
4. Test build end-to-end before tagging a new release

## When the hls.c regex stops matching

If `generate-hls-patch.sh` warns "block not found", upstream FFmpeg has rewritten the affected regions of `libavformat/hls.c`. Open the script and update the regex patterns to match the new code. The patterns are documented inline.
