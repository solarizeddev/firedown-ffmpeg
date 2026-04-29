#!/usr/bin/env bash
#
# install-firedown-hook.sh
#
# One-time setup: modifies the upstream ffmpeg-android-maker.sh to call
# firedown/apply-firedown-patches.sh between the download loop and the
# build loop.
#
# This is an alternative to applying patches/0001-ffmpeg-android-maker-add-firedown-hook.patch
# directly. The .patch file is line-number-sensitive; this script uses
# content-based matching and is more robust to upstream drift.
#
# Run once after forking ffmpeg-android-maker. It is idempotent — running
# twice on the same file is safe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/ffmpeg-android-maker.sh"

if [[ ! -f "$TARGET" ]]; then
    echo "ERROR: $TARGET not found" >&2
    echo "       Run this from a forked clone of ffmpeg-android-maker." >&2
    exit 1
fi

# Idempotency check
if grep -q '=== Firedown: apply project-specific patches' "$TARGET"; then
    echo "[firedown] Hook already installed, skipping."
    exit 0
fi

# Anchor: the line "# Main build loop" appears once in upstream and is
# the boundary between "all components downloaded" and "start per-ABI builds".
# We insert our hook block immediately before it.

if ! grep -q '^# Main build loop$' "$TARGET"; then
    echo "ERROR: anchor '# Main build loop' not found in $TARGET" >&2
    echo "       Upstream may have changed; update this script's anchor." >&2
    exit 2
fi

TMP="$(mktemp)"
awk '
    /^# Main build loop$/ && !done {
        print "# === Firedown: apply project-specific patches to FFmpeg source ==="
        print "# After all components have been downloaded but before any builds start,"
        print "# apply Firedown'\''s modifications to the FFmpeg source tree. This runs once"
        print "# and benefits all subsequent per-ABI builds."
        print "if [[ -x \"${BASE_DIR}/firedown/apply-firedown-patches.sh\" ]]; then"
        print "  echo \"Applying Firedown patches to FFmpeg source...\""
        print "  \"${BASE_DIR}/firedown/apply-firedown-patches.sh\" \"${SOURCES_DIR_ffmpeg}\" || exit 1"
        print "fi"
        print "# === End Firedown patches ==="
        print ""
        done = 1
    }
    { print }
' "$TARGET" > "$TMP"

mv "$TMP" "$TARGET"
chmod +x "$TARGET"

echo "[firedown] Hook installed in $TARGET"
echo "[firedown] Verify with: grep -A 10 'Firedown' $TARGET"
