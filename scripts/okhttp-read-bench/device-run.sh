#!/usr/bin/env bash
# Run the okhttp read-stats comparison on a real Android device, end to end
# and unattended: put both repos on the right branches, build arm64 libraries,
# copy them into the app, install a debug build, turn the stats on, download
# each workload through the app's FFmpeg path, capture the stats, summarize,
# and put everything back.
#
#   scripts/okhttp-read-bench/device-run.sh [options] [path to the firedown app repo]
#
# The app repo defaults to $FIREDOWN, then a "firedown" checkout beside this
# repo. Downloads are started by the debug app's ReadBenchReceiver (adb
# broadcast), always through FFmpeg; a run ends --idle seconds after the last
# connection closed (or on Enter), or fails after --timeout seconds with no
# connection at all. The files land in the app's downloads as okread-*.mp4;
# delete them there afterwards.
#
# Workloads. Each has a short list of public test media; the first that
# answers from this machine is used (for aes-hls, the first whose playlist
# really uses AES-128), and a workload with none reachable is skipped with a
# warning. Override with the options below:
#   file     a large progressive video file
#   hls      an HLS VOD stream with many segments
#   aes-hls  an AES-128 encrypted HLS stream (reads arrive in 4 KiB pieces)
#
# Options:
#   --reps N          runs per workload (default 3)
#   --workloads LIST  comma-separated (default file,hls,aes-hls)
#   --file-url URL / --hls-url URL / --aes-url URL   replace a default URL
#   --idle S          end a run S seconds after the last stats line (default 20)
#   --timeout S       give up on a run with no stats line after S seconds (default 900)
#   --manual          start each download yourself in the app (any workload
#                     name; the script only captures)
#   --no-switch       leave both repos on their current branches
#   --no-build        reuse output/ from a previous build
#   --no-install      do not build/install the app (it must already be the debug build)
#   --keep-libs       leave the locally built libraries in the app afterwards
#   --out DIR         where captures go (default ~/okread-<date>-<time>)
#
# Needs: git, bash, python3, adb (one device connected, or ANDROID_SERIAL set),
# meson/ninja/nasm for the dav1d build, and the Android SDK and NDK. The build
# needs both ANDROID_SDK_HOME and ANDROID_NDK_HOME: whatever you export wins;
# otherwise the SDK is ~/Android/Sdk and the NDK the newest under its ndk/
# (e.g. ANDROID_NDK_HOME=~/Android/Sdk/ndk/30.0.16248370).
#
# Captures contain full, signed media URLs. They stay in --out; delete it once
# you have shared the summary.
set -euo pipefail

FF_BRANCH=claude/optimistic-edison-3bpmmq
APP_BRANCH=claude/okhttp-partial-read
PACKAGE=com.solarized.firedown

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FF=$(cd "$HERE/../.." && pwd)

REPS=3
WORKLOADS=file,hls,aes-hls
IDLE=20
TIMEOUT=900
MANUAL=0
# Public test media, in order of preference. Hosts move and not every network
# reaches every host, so the first candidate that answers is used;
# --file-url/--hls-url/--aes-url replace a list with one URL.
FILE_URLS="https://download.blender.org/demo/movies/BBB/bbb_sunflower_1080p_30fps_normal.mp4
https://download.blender.org/peach/bigbuckbunny_movies/big_buck_bunny_720p_h264.mov
https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_320x180.mp4
https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/1080/Big_Buck_Bunny_1080_10s_30MB.mp4"
HLS_URLS="https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8
https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8
https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8"
AES_URLS="https://cdn.theoplayer.com/video/big_buck_bunny_encrypted/stream-800/index.m3u8
https://playertest.longtailvideo.com/adaptive/oceans_aes/oceans_aes.m3u8"
FILE_URL="" HLS_URL="" AES_URL=""
SWITCH=1 BUILD=1 INSTALL=1 KEEP_LIBS=0
OUT=""
APP=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --reps) REPS=$2; shift 2 ;;
    --workloads) WORKLOADS=$2; shift 2 ;;
    --idle) IDLE=$2; shift 2 ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --manual) MANUAL=1; shift ;;
    --file-url) FILE_URL=$2; shift 2 ;;
    --hls-url) HLS_URL=$2; shift 2 ;;
    --aes-url) AES_URL=$2; shift 2 ;;
    --no-switch) SWITCH=0; shift ;;
    --no-build) BUILD=0; shift ;;
    --no-install) INSTALL=0; shift ;;
    --keep-libs) KEEP_LIBS=1; shift ;;
    --out) OUT=$2; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) APP=$1; shift ;;
  esac
done
APP=${APP:-${FIREDOWN:-$FF/../firedown}}
[[ -d $APP/.git && -f $APP/scripts/sync-ffmpeg.sh ]] || {
  echo "firedown app repo not found at $APP (pass its path, or set FIREDOWN)" >&2; exit 1; }
APP=$(cd "$APP" && pwd)
OUT=${OUT:-$HOME/okread-$(date +%Y%m%d-%H%M%S)}

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

for t in git python3 adb curl; do command -v "$t" >/dev/null || die "$t not found in PATH"; done

workload_url() { # the URL chosen for a workload (after the check below)
  case $1 in
    file) echo "$FILE_URL" ;;
    hls) echo "$HLS_URL" ;;
    aes-hls) echo "$AES_URL" ;;
    *) echo "" ;;
  esac
}
reachable() { # url -> 0 if a ranged GET answers 200/206
  local code
  code=$(curl -sS -L -o /dev/null -r 0-1 --max-time 20 -w '%{http_code}' "$1" 2>/dev/null || true)
  [[ $code == 200 || $code == 206 ]]
}
is_aes_hls() { # url -> 0 if the playlist (or its first variant) uses AES-128
  local body variant
  body=$(curl -sS -L --max-time 20 "$1" 2>/dev/null | head -c 200000) || return 1
  if grep -q '^#EXT-X-STREAM-INF' <<<"$body"; then
    variant=$(grep -A1 '^#EXT-X-STREAM-INF' <<<"$body" | grep -v '^#\|^--' | head -1 | tr -d '\r')
    [[ -n $variant ]] || return 1
    [[ $variant == http* ]] || variant="${1%/*}/$variant"
    body=$(curl -sS -L --max-time 20 "$variant" 2>/dev/null | head -c 200000) || return 1
  fi
  grep -q '^#EXT-X-KEY:.*METHOD=AES-128' <<<"$body"
}
pick_url() { # workload candidates... -> first usable URL, or empty
  local w=$1 url
  shift
  for url in "$@"; do
    if reachable "$url" && { [[ $w != aes-hls ]] || is_aes_hls "$url"; }; then
      echo "$url"
      return
    fi
    echo "  $w: $url not usable from here, trying the next" >&2
  done
}
IFS=, read -r -a WL <<<"$WORKLOADS"
if [[ $MANUAL = 0 ]]; then
  say "Picking test URLs that answer from this machine"
  kept=()
  for w in "${WL[@]}"; do
    case $w in
      file) cands=${FILE_URL:-$FILE_URLS} ;;
      hls) cands=${HLS_URL:-$HLS_URLS} ;;
      aes-hls) cands=${AES_URL:-$AES_URLS} ;;
      *) die "no URL for workload '$w' (use file, hls, aes-hls, or --manual)" ;;
    esac
    # shellcheck disable=SC2086
    url=$(pick_url "$w" $cands)
    if [[ -z $url ]]; then
      echo "  WARNING: skipping $w: no candidate answered (pass one with --${w%-hls}-url)" >&2
      continue
    fi
    case $w in
      file) FILE_URL=$url ;;
      hls) HLS_URL=$url ;;
      aes-hls) AES_URL=$url ;;
    esac
    echo "  $w: $url"
    kept+=("$w")
  done
  [[ ${#kept[@]} -gt 0 ]] || die "no workload has a reachable URL; pass them with --file-url / --hls-url / --aes-url"
  WL=("${kept[@]}")
fi

# --- cleanup, whatever happens from here on ---------------------------------------
LOGCAT_PID=""
PROP_SET=0 LIBS_SYNCED=0
cleanup() {
  [[ -n $LOGCAT_PID ]] && kill "$LOGCAT_PID" 2>/dev/null || true
  if [[ $PROP_SET = 1 ]]; then
    adb shell setprop debug.firedown.fflog '""' >/dev/null 2>&1 || true
    echo "stats turned off on the device"
  fi
  if [[ $LIBS_SYNCED = 1 && $KEEP_LIBS = 0 ]]; then
    echo "restoring the app's pinned FFmpeg release (--keep-libs to skip)"
    (cd "$APP" && scripts/fetch-prebuilts.sh ffmpeg --force) || \
      echo "WARNING: could not restore; run: cd $APP && scripts/fetch-prebuilts.sh ffmpeg --force" >&2
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- 1. branches -----------------------------------------------------------------
switch_branch() { # repo branch
  local repo=$1 branch=$2
  if [[ $(git -C "$repo" rev-parse --abbrev-ref HEAD) == "$branch" ]]; then
    git -C "$repo" pull -q --ff-only origin "$branch" || die "could not update $repo"
    return
  fi
  [[ -z $(git -C "$repo" status --porcelain --untracked-files=no) ]] || \
    die "$repo has uncommitted changes; commit or stash them, or use --no-switch"
  git -C "$repo" fetch -q origin "$branch"
  git -C "$repo" switch -q "$branch" 2>/dev/null || \
    git -C "$repo" switch -q -c "$branch" --track "origin/$branch"
  git -C "$repo" pull -q --ff-only origin "$branch"
}
if [[ $SWITCH = 1 ]]; then
  say "Switching firedown-ffmpeg to $FF_BRANCH and the app to $APP_BRANCH"
  switch_branch "$FF" "$FF_BRANCH"
  switch_branch "$APP" "$APP_BRANCH"
fi
grep -q 'okhttp-stats:' "$FF/firedown/replacements/libavformat/http.c" || \
  die "this firedown-ffmpeg checkout has no okhttp-stats in http.c (wrong branch?)"
grep -q 'utils_ffmpeg_log_level' "$APP/app/src/main/cpp/ffmpegutils/utils.c" || \
  die "this app checkout has no utils_ffmpeg_log_level (wrong branch?)"

# --- 2. device -------------------------------------------------------------------
say "Checking the device"
if [[ -z ${ANDROID_SERIAL:-} ]]; then
  n=$(adb devices | awk 'NR > 1 && $2 == "device"' | wc -l)
  [[ $n -eq 1 ]] || die "need exactly one device in 'adb devices' (found $n); or set ANDROID_SERIAL"
fi
adb get-state >/dev/null || die "device not ready"
echo "device: $(adb shell getprop ro.product.model | tr -d '\r') (Android $(adb shell getprop ro.build.version.release | tr -d '\r'))"

# --- 3. build ----------------------------------------------------------------------
if [[ $BUILD = 1 ]]; then
  export ANDROID_SDK_HOME=${ANDROID_SDK_HOME:-$HOME/Android/Sdk}
  if [[ ! -d ${ANDROID_NDK_HOME:-/nonexistent}/toolchains/llvm ]]; then
    ndk=$(ls -d "$ANDROID_SDK_HOME"/ndk/*/ 2>/dev/null | sort -V | tail -1)
    [[ -n $ndk && -d $ndk/toolchains/llvm ]] || \
      die "no NDK found; set ANDROID_NDK_HOME to e.g. $ANDROID_SDK_HOME/ndk/<version>"
    export ANDROID_NDK_HOME=${ndk%/}
  fi
  say "Building FFmpeg for arm64-v8a"
  echo "ANDROID_SDK_HOME=$ANDROID_SDK_HOME"
  echo "ANDROID_NDK_HOME=$ANDROID_NDK_HOME   (export it yourself to pick another NDK)"
  # A dav1d build directory left behind by a failed meson setup blocks the next one.
  for d in "$FF"/sources/libdav1d/*/build/*; do
    [[ -d $d && ! -f $d/build.ninja ]] && { echo "removing stale $d"; rm -rf "$d"; }
  done
  (cd "$FF" && ./ffmpeg-android-maker.sh -dav1d -abis=arm64-v8a)
fi
ls "$FF"/output/lib/arm64-v8a/*.so >/dev/null 2>&1 || die "no libraries in $FF/output/lib/arm64-v8a"

# --- 4. app ------------------------------------------------------------------------
say "Copying the libraries into the app"
(cd "$APP/scripts" && ./sync-ffmpeg.sh "$FF")
LIBS_SYNCED=1
if [[ $INSTALL = 1 ]]; then
  say "Building and installing the debug app"
  (cd "$APP" && ./gradlew installDebug)
fi

# --- 5. stats on -------------------------------------------------------------------
say "Turning the stats on"
adb shell setprop debug.firedown.fflog 32
PROP_SET=1
[[ $(adb shell getprop debug.firedown.fflog | tr -d '\r') == 32 ]] || die "could not set debug.firedown.fflog"
adb logcat -G 16M >/dev/null 2>&1 || echo "note: could not enlarge the log buffer"
adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
mkdir -p "$OUT"
echo "captures go to $OUT"

# --- 6. workloads ------------------------------------------------------------------
describe() {
  case $1 in
    file)    echo "download a LARGE direct video file (100 MB or more) over Wi-Fi" ;;
    hls)     echo "download an HLS video with many segments" ;;
    aes-hls) echo "download an AES-128 encrypted HLS video (for example Niconico)" ;;
    *)       echo "run the '$1' workload" ;;
  esac
}
start_download() { # workload run; queues the download through ReadBenchReceiver
  local url answer
  url=$(workload_url "$1")
  [[ $url != *"'"* ]] || { echo "  URL contains a single quote: $url" >&2; return 1; }
  # The download service only starts for an app in the foreground (Android 8+).
  adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  adb shell am start -W -n "$PACKAGE/.phone.BrowserActivity" >/dev/null 2>&1 || true
  sleep 2
  answer=$(adb shell am broadcast -n "$PACKAGE/.readbench.ReadBenchReceiver" \
    -a com.solarized.firedown.readbench.DOWNLOAD \
    --es url "'$url'" --es name "okread-$1-$2.mp4" | tr -d '\r')
  if [[ $answer != *"result=1"* ]]; then
    echo "  the app refused the download: $answer" >&2
    return 1
  fi
  echo "  queued okread-$1-$2.mp4"
}
CAPTURED=0
capture() { # file [workload run]; sets CAPTURED to the number of okhttp-stats lines
  local file=$1 last_count=0 last_change start now count
  adb logcat -c
  adb logcat -s ffmpeg >"$file" 2>/dev/null &
  LOGCAT_PID=$!
  if [[ $# -gt 1 ]] && ! start_download "$2" "$3"; then
    kill "$LOGCAT_PID" 2>/dev/null || true
    wait "$LOGCAT_PID" 2>/dev/null || true
    LOGCAT_PID="" CAPTURED=0
    return
  fi
  start=$(date +%s) last_change=$start
  while :; do
    if read -r -t 2 _; then break; fi
    count=$(grep -c 'okhttp-stats:' "$file" 2>/dev/null || true)
    now=$(date +%s)
    if [[ $count != "$last_count" ]]; then
      last_count=$count last_change=$now
      printf '\r  %d connection(s) logged so far ' "$count"
    elif [[ $IDLE -gt 0 && $count -gt 0 && $((now - last_change)) -ge $IDLE ]]; then
      printf '\n  no new stats for %ss, run done\n' "$IDLE"
      break
    elif [[ $MANUAL = 0 && $count -eq 0 && $((now - start)) -ge $TIMEOUT ]]; then
      printf '\n  nothing logged in %ss, giving up on this run\n' "$TIMEOUT"
      break
    fi
  done
  kill "$LOGCAT_PID" 2>/dev/null || true
  wait "$LOGCAT_PID" 2>/dev/null || true
  LOGCAT_PID=""
  CAPTURED=$(grep -c 'okhttp-stats:' "$file" || true)
}
for w in "${WL[@]}"; do
  for ((i = 1; i <= REPS; i++)); do
    while :; do
      file="$OUT/$w-$i.txt"
      say "$w, run $i of $REPS"
      if [[ $MANUAL = 1 ]]; then
        echo "In the app: $(describe "$w")."
        echo "Capturing now. Press Enter when it has finished$([[ $IDLE -gt 0 ]] && echo ", or wait: it stops ${IDLE}s after the last connection closes")."
        capture "$file"
      else
        echo "Downloading $(workload_url "$w") through the app (Enter ends the run early)."
        capture "$file" "$w" "$i"
      fi
      if [[ $CAPTURED -gt 0 ]]; then
        echo "  saved $file ($CAPTURED connections)"
        break
      fi
      read -r -p "  no okhttp-stats lines were captured. [r]etry, [s]kip? " ans
      [[ $ans == s* ]] && { rm -f "$file"; break; }
    done
  done
done

# --- 7. summary --------------------------------------------------------------------
say "Summary"
shopt -s nullglob
captures=("$OUT"/*.txt)
[[ ${#captures[@]} -gt 0 ]] || die "nothing was captured"
python3 "$HERE/device-stats.py" "${captures[@]}" | tee "$OUT/summary.txt"
echo
echo "summary saved to $OUT/summary.txt (the captures beside it contain signed URLs)"
