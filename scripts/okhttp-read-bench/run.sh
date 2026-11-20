#!/bin/sh
# okhttp read-strategy benchmark: FFmpeg's REAL avio layer + the fork's REAL
# http.c + the app's REAL FFmpegOkhttp + OkHttp, against a throttled local
# server. Compares how a read request is sized and filled across the JNI
# bridge, which FFmpeg 9.1 made matter: it grew the network AVIO buffer from
# 32 KiB to 256 KiB (512 KiB on an unknown-length stream), and
# FFmpegOkhttp.okhttpRead fills the WHOLE request before returning.
#
#   sh scripts/okhttp-read-bench/run.sh
#
# Native variants (built from firedown/replacements/libavformat/http.c by
# variants.py), Java strategies (FFmpegOkhttp.okhttpRead's fill loop, chosen
# per JVM):
#   slots-32k   http.c as committed: 32 KiB clamp, address-keyed buffer table
#   slots-none  the same without the clamp (what 9.1 does to an unclamped fork)
#   stage-32k   one staging buffer per context, 32 KiB, memcpy to ffmpeg
#   stage-256k  the same, 256 KiB
#   fill        okhttpRead as shipped: fill `size` or end of body
#   first       return after the first non-empty okio read (<= 8 KiB)
#   deadline    fill, but return once some bytes are in and 10 ms passed
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

# --- Java: the app's real classes + stubs + the strategy switch ----------------
J="$OUT/java"
mkdir -p "$J/com/solarized/firedown/ffmpegutils" "$J/com/solarized/firedown/okhttp"
cp -R "$HERE/java/." "$J/"
python3 -I "$HERE/variants.py" java "$JSRC_APP/ffmpegutils/FFmpegOkhttp.java" \
  "$J/com/solarized/firedown/ffmpegutils/FFmpegOkhttp.java"
cp "$JSRC_APP/ffmpegutils/FFmpegConstants.java" "$J/com/solarized/firedown/ffmpegutils/"
cp "$JSRC_APP/okhttp/SafeHeaders.java" "$J/com/solarized/firedown/okhttp/"
mkdir -p "$OUT/classes"
find "$J" -name '*.java' >"$OUT/sources.txt"
"$JAVA_HOME/bin/javac" -nowarn -d "$OUT/classes" -cp "$CP" @"$OUT/sources.txt"

# --- native variants -------------------------------------------------------------
CFLAGS_FF="-O2 -fPIC -std=c17 -DHAVE_AV_CONFIG_H -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -I$INC1 -I$FFDIR/build -I$FFDIR/src -I$FFDIR/src/libavformat -I$JAVA_HOME/include -I$JAVA_HOME/include/linux"
LIBS_FF="$FFDIR/build/libavformat/libavformat.a $FFDIR/build/libavcodec/libavcodec.a $FFDIR/build/libavutil/libavutil.a -lm -lpthread"
build_variant() { # name mode extra-cflags
  python3 -I "$HERE/variants.py" c "$ROOT/firedown/replacements/libavformat/http.c" "$OUT/http-$1.c" "$2"
  # shellcheck disable=SC2086
  $CC $CFLAGS_FF $3 -w -shared -o "$OUT/lib$1.so" "$HERE/bench_jni.c" "$OUT/http-$1.c" \
    "$FFDIR/src/libavcodec/ffjni.c" "$FFDIR/src/libavcodec/jni.c" $LIBS_FF -Wl,-Bsymbolic
}
build_variant slots-32k  slots ""
build_variant slots-none slots "-DFIREDOWN_OKHTTP_MAX_READ=0x7fffffff"
build_variant stage-32k  stage "-DFIREDOWN_OKHTTP_MAX_READ=0x7fffffff -DFD_STAGE_SIZE=32768"
build_variant stage-256k stage "-DFIREDOWN_OKHTTP_MAX_READ=0x7fffffff -DFD_STAGE_SIZE=262144"

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
COMBOS="slots-32k:fill slots-none:fill slots-none:first slots-none:deadline slots-32k:first slots-32k:deadline stage-32k:fill stage-256k:first stage-256k:deadline"
RES="$OUT/results.txt"
: >"$RES"
for combo in $COMBOS; do
  lib=${combo%%:*} strat=${combo#*:}
  echo "okread: $combo"
  for sc in live mobile fast; do
    case $sc in
      live)   url="$BASE/live?rate=16000"; chunk=4096; max=65536; lim=120000; reps=$REPS_LIVE ;;
      mobile) url="$BASE/file?size=$MOBILE_SIZE&rate=2000000"; chunk=16384; max=$MOBILE_SIZE; lim=600000; reps=$REPS_MOBILE ;;
      fast)   url="$BASE/file?size=$FAST_SIZE&rate=0"; chunk=16384; max=$FAST_SIZE; lim=600000; reps=$REPS_FAST ;;
    esac
    # one extra rep, dropped in the summary: JIT warm-up
    "$JAVA_HOME/bin/java" -Xmx512m -Dfd.read="$strat" -Dfd.deadlineMs=10 \
      -cp "$OUT/classes:$CP" Bench "$OUT/lib$lib.so" "$combo $sc" "$url" "$chunk" "$max" "$lim" $((reps + 1)) \
      2>"$OUT/err.txt" >>"$RES" || { cat "$OUT/err.txt" >&2; exit 1; }
  done
done
python3 -I "$HERE/summarize.py" "$RES" "$MOBILE_SIZE" "$FAST_SIZE"
