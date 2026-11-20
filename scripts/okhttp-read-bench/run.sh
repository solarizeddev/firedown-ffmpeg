#!/bin/sh
# okhttp read benchmark: FFmpeg's REAL avio layer + the fork's REAL http.c +
# the app's REAL FFmpegOkhttp + OkHttp, against a throttled local server.
# It measures how a read request is sized and filled across the JNI bridge,
# which FFmpeg 9.1 made matter: it grew the network AVIO buffer from 32 KiB
# to 256 KiB (512 KiB on an unknown-length stream), and FFmpegOkhttp's
# okhttpRead fills the WHOLE request before returning. See README.md here
# for the design it chose and the numbers behind it.
#
#   sh scripts/okhttp-read-bench/run.sh
#   BENCH_BASELINE_REF=<git ref> sh scripts/okhttp-read-bench/run.sh
#
# Rows (native http.c : app FFmpegOkhttp), built by variants.py:
#   current:old       this http.c with an app that has no okhttpReadPartial
#                     (falls back to okhttpRead, 32 KiB requests)
#   current:new       this http.c with the app as committed (okhttpReadPartial,
#                     256 KiB requests, 10 ms deadline): what ships
#   current:new-64k   ... with 64 KiB requests
#   current:new-2ms   ... with a 2 ms deadline
#   current:new-50ms  ... with a 50 ms deadline
#   baseline:old      http.c at BENCH_BASELINE_REF with an old app (only when
#                     BENCH_BASELINE_REF is set)
#
# Scenarios (HTTP/1.1 over loopback; HTTP/2 is not exercised):
#   live    128 kbit/s, no Content-Length (is_streamed): probe latency
#   mobile  16 Mbit/s, 8 MiB file: CPU per MiB, JNI calls, buffer wraps
#   fast    unthrottled, 256 MiB file: throughput, CPU, JNI calls
# Every byte is checked against the server's pattern; any mismatch fails.
#
# Needs: cc, make, git, curl, python3, a JDK (17+), and network the first
# time (FFmpeg source, OkHttp/okio/kotlin-stdlib jars from Maven Central).
# FFmpeg's host build and the jars are cached under
# $FIREDOWN_HARNESS_CACHE/okread (default ~/.cache/firedown-harness). The app
# repo is $FIREDOWN (default: a firedown checkout beside this repo).
# BENCH_QUICK=1 runs fewer reps and smaller transfers.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
APP=${FIREDOWN:-$ROOT/../firedown}
JSRC_APP="$APP/app/src/main/java/com/solarized/firedown"
CACHE=${FIREDOWN_HARNESS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/firedown-harness}/okread
CC=${CC:-cc}
JOBS=$(nproc 2>/dev/null || echo 4)
OUT=$(mktemp -d)
SERVER_PID=
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "${OUT:?}"
}
trap cleanup EXIT
mkdir -p "$CACHE"

[ -f "$JSRC_APP/ffmpegutils/FFmpegOkhttp.java" ] || {
  echo "FFmpegOkhttp.java not found under $JSRC_APP (set FIREDOWN to the app repo)" >&2
  exit 1
}
FFV=$(sed -n 's/^SOURCE_VALUE=//p' "$ROOT/scripts/parse-arguments.sh")
OKHTTP_V=$(sed -n "s/.*com\.squareup\.okhttp3:okhttp:\([0-9.]*\).*/\1/p" "$APP/app/build.gradle" | head -1)
[ -n "$OKHTTP_V" ] || { echo "cannot read the OkHttp version from $APP/app/build.gradle" >&2; exit 1; }
JAVA_HOME=${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")}
echo "okread: FFmpeg $FFV, OkHttp $OKHTTP_V, app at $APP"

# --- FFmpeg host libs (cached) ------------------------------------------------
# Host configure refuses --enable-jni off Android, so JNI is forced afterwards:
# ffjni.c and jni.c are compiled per variant against a config.h with
# CONFIG_JNI 1, and the archive members built without it (http.o, jni.o) are
# dropped so the variant's objects are the only definitions.
FFDIR="$CACHE/ffmpeg-$FFV"
if [ ! -f "$FFDIR/.ready" ]; then
  rm -rf "$FFDIR"
  mkdir -p "$FFDIR/build"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "n$FFV" https://github.com/FFmpeg/FFmpeg "$FFDIR/src"
  echo "okread: building FFmpeg $FFV for the host (once)"
  (cd "$FFDIR/build" && "$FFDIR/src/configure" --disable-everything --enable-protocol=http \
      --disable-programs --disable-doc --disable-autodetect --disable-x86asm \
      --enable-pic --disable-debug >"$FFDIR/configure.log" 2>&1 \
    && make -j"$JOBS" libavformat/libavformat.a libavcodec/libavcodec.a \
      libavutil/libavutil.a >"$FFDIR/make.log" 2>&1) \
    || { echo "FFmpeg host build failed; see $FFDIR/*.log" >&2; exit 1; }
  ar d "$FFDIR/build/libavformat/libavformat.a" http.o
  ar d "$FFDIR/build/libavcodec/libavcodec.a" jni.o
  touch "$FFDIR/.ready"
fi
INC1="$OUT/inc"
mkdir -p "$INC1"
sed 's/^#define CONFIG_JNI 0$/#define CONFIG_JNI 1/' "$FFDIR/build/config.h" >"$INC1/config.h"
grep -q '^#define CONFIG_JNI 1$' "$INC1/config.h" || { echo "could not force CONFIG_JNI" >&2; exit 1; }

# --- jars (cached) ------------------------------------------------------------
M=https://repo1.maven.org/maven2
fetch() { # url dest
  [ -s "$2" ] && return 0
  n=0
  until curl -fsS -o "$2.part" "$1"; do
    n=$((n + 1)); [ $n -ge 6 ] && { echo "download failed: $1" >&2; exit 1; }
    sleep $((n * 5))
  done
  mv "$2.part" "$2"
}
JARS="$CACHE/jars-$OKHTTP_V"
mkdir -p "$JARS"
fetch "$M/com/squareup/okhttp3/okhttp-jvm/$OKHTTP_V/okhttp-jvm-$OKHTTP_V.pom" "$JARS/okhttp.pom"
OKIO_V=$(grep -A1 '<artifactId>okio-jvm</artifactId>' "$JARS/okhttp.pom" | sed -n 's/.*<version>\(.*\)<\/version>.*/\1/p')
KOTLIN_V=$(grep -A1 '<artifactId>kotlin-stdlib</artifactId>' "$JARS/okhttp.pom" | sed -n 's/.*<version>\(.*\)<\/version>.*/\1/p')
fetch "$M/com/squareup/okhttp3/okhttp-jvm/$OKHTTP_V/okhttp-jvm-$OKHTTP_V.jar" "$JARS/okhttp.jar"
fetch "$M/com/squareup/okio/okio-jvm/$OKIO_V/okio-jvm-$OKIO_V.jar" "$JARS/okio.jar"
fetch "$M/org/jetbrains/kotlin/kotlin-stdlib/$KOTLIN_V/kotlin-stdlib-$KOTLIN_V.jar" "$JARS/kotlin-stdlib.jar"
CP="$JARS/okhttp.jar:$JARS/okio.jar:$JARS/kotlin-stdlib.jar"

# --- Java: the app's real classes + stubs, old and new app ---------------------
for mode in old new; do
  J="$OUT/java-$mode"
  mkdir -p "$J/com/solarized/firedown/ffmpegutils" "$J/com/solarized/firedown/okhttp" "$OUT/classes-$mode"
  cp -R "$HERE/java/." "$J/"
  python3 -I "$HERE/variants.py" java "$JSRC_APP/ffmpegutils/FFmpegOkhttp.java" \
    "$J/com/solarized/firedown/ffmpegutils/FFmpegOkhttp.java" "$mode"
  cp "$JSRC_APP/ffmpegutils/FFmpegConstants.java" "$J/com/solarized/firedown/ffmpegutils/"
  cp "$JSRC_APP/okhttp/SafeHeaders.java" "$J/com/solarized/firedown/okhttp/"
  find "$J" -name '*.java' >"$OUT/sources-$mode.txt"
  "$JAVA_HOME/bin/javac" -nowarn -d "$OUT/classes-$mode" -cp "$CP" @"$OUT/sources-$mode.txt"
done

# --- native variants -------------------------------------------------------------
CFLAGS_FF="-O2 -fPIC -std=c17 -DHAVE_AV_CONFIG_H -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -I$INC1 -I$FFDIR/build -I$FFDIR/src -I$FFDIR/src/libavformat -I$JAVA_HOME/include -I$JAVA_HOME/include/linux"
LIBS_FF="$FFDIR/build/libavformat/libavformat.a $FFDIR/build/libavcodec/libavcodec.a $FFDIR/build/libavutil/libavutil.a -lm -lpthread"
build_lib() { # name http.c extra-cflags
  # shellcheck disable=SC2086
  $CC $CFLAGS_FF $3 -w -shared -o "$OUT/lib$1.so" "$HERE/bench_jni.c" "$2" \
    "$FFDIR/src/libavcodec/ffjni.c" "$FFDIR/src/libavcodec/jni.c" $LIBS_FF -Wl,-Bsymbolic
}
python3 -I "$HERE/variants.py" c "$ROOT/firedown/replacements/libavformat/http.c" "$OUT/http-current.c"
build_lib current "$OUT/http-current.c" ""
build_lib current-64k "$OUT/http-current.c" "-DFIREDOWN_OKHTTP_PARTIAL_MAX_READ=65536"
ROWS="current:old:current:10 current:new:current:10 current:new-64k:current-64k:10 current:new-2ms:current:2 current:new-50ms:current:50"
if [ -n "${BENCH_BASELINE_REF:-}" ]; then
  git -C "$ROOT" show "$BENCH_BASELINE_REF:firedown/replacements/libavformat/http.c" >"$OUT/http-baseline.c"
  build_lib baseline "$OUT/http-baseline.c" ""
  ROWS="baseline:old:baseline:10 $ROWS"
fi

# --- server ---------------------------------------------------------------------
python3 -I "$HERE/server.py" "$OUT/port" &
SERVER_PID=$!
n=0
until [ -s "$OUT/port" ]; do n=$((n + 1)); [ $n -gt 50 ] && { echo "server did not start" >&2; exit 1; }; sleep 0.1; done
BASE="http://127.0.0.1:$(cat "$OUT/port")"

# --- matrix ---------------------------------------------------------------------
if [ "${BENCH_QUICK:-0}" = 1 ]; then
  REPS_LIVE=2 REPS_MOBILE=2 REPS_FAST=3 MOBILE_SIZE=2097152 FAST_SIZE=67108864
else
  REPS_LIVE=3 REPS_MOBILE=3 REPS_FAST=6 MOBILE_SIZE=8388608 FAST_SIZE=268435456
fi
RES="$OUT/results.txt"
: >"$RES"
for row in $ROWS; do
  # row = <label native>:<label app>:<lib>:<deadline ms>
  lab_n=${row%%:*}; rest=${row#*:}
  lab_a=${rest%%:*}; rest=${rest#*:}
  lib=${rest%%:*}; ms=${rest#*:}
  mode=${lab_a%%-*}
  label="$lab_n:$lab_a"
  echo "okread: $label"
  for sc in live mobile fast; do
    case $sc in
      live)   url="$BASE/live?rate=16000"; chunk=4096; max=65536; lim=120000; reps=$REPS_LIVE ;;
      mobile) url="$BASE/file?size=$MOBILE_SIZE&rate=2000000"; chunk=16384; max=$MOBILE_SIZE; lim=600000; reps=$REPS_MOBILE ;;
      fast)   url="$BASE/file?size=$FAST_SIZE&rate=0"; chunk=16384; max=$FAST_SIZE; lim=600000; reps=$REPS_FAST ;;
    esac
    # one extra rep, dropped in the summary: JIT warm-up
    "$JAVA_HOME/bin/java" -Xmx512m -Dfd.deadlineMs="$ms" \
      -cp "$OUT/classes-$mode:$CP" Bench "$OUT/lib$lib.so" "$label $sc" "$url" "$chunk" "$max" "$lim" $((reps + 1)) \
      2>"$OUT/err.txt" >>"$RES" || { cat "$OUT/err.txt" >&2; exit 1; }
  done
done
# shellcheck disable=SC2046
python3 -I "$HERE/summarize.py" "$RES" "$MOBILE_SIZE" "$FAST_SIZE" \
  "$((REPS_LIVE + 1))" "$((REPS_MOBILE + 1))" "$((REPS_FAST + 1))" $(for r in $ROWS; do echo "$r" | cut -d: -f1,2; done)
