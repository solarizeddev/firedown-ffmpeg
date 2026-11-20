# okhttp read benchmark

Measures how one FFmpeg read is sized and filled across the JNI bridge
between the fork's `http.c` and the app's `FFmpegOkhttp`. It runs the real
pieces: FFmpeg's avio layer (a host build of the pinned version, JNI forced
on), the fork's `http.c`, the app's `FFmpegOkhttp` with OkHttp, and a local
throttled server. Every byte read is checked.

```
sh scripts/okhttp-read-bench/run.sh                          # needs the app repo
BENCH_BASELINE_REF=<git ref> sh scripts/okhttp-read-bench/run.sh
BENCH_QUICK=1 sh scripts/okhttp-read-bench/run.sh            # smaller, noisier
```

Run it after changing either side of the read path, and on every FFmpeg bump.

## Why it exists

FFmpeg 9.1 grew the AVIO buffer of network protocols from 32 KiB to 256 KiB
(512 KiB when the length is unknown), for a few percent of throughput on
native sockets (upstream commit `63d53fa`). `fill_buffer()` asks the protocol
for the whole free buffer. A socket returns whatever has arrived, but
`okhttpRead` filled the whole request before returning. Unchanged, a probe of
a 128 kbit/s live stream would wait about 33 seconds for its first read.

## What was compared

Native side, how a request is capped and where Java writes:

- **slots-32k**: 32 KiB cap, a 16-entry table of `DirectByteBuffer`s keyed by
  FFmpeg's buffer address (the 9.1 bump's first fix).
- **slots-none**: the same without the cap.
- **stage-32k / stage-256k**: one staging buffer per connection, wrapped
  once; C copies from it into FFmpeg's buffer.

Java side, when `okhttpRead` returns:

- **fill**: when the request is full or the body ends (the shipped behaviour).
- **first**: after the first non-empty okio read, at most 8 KiB.
- **deadline**: once it holds some bytes and 10 ms have passed.

## Results

Full run on the 9.1 host build, HTTP/1.1 over loopback. Medians, first
repetition dropped as JIT warm-up. Every byte verified in every repetition.

| Variant | Live: first 2 KiB | Live: longest gap | Fast: MiB/s | Fast: JNI calls/MiB | Fast: buffers created |
|---|---|---|---|---|---|
| slots-32k + fill | 2.04 s | 2.04 s | 405 | 32 | 8 |
| slots-none + fill | 32.76 s | 0.00 s | 416 | 4 | 1 |
| slots-none + first | 0.24 s | 0.26 s | 360 | 128 | 32,769 |
| slots-none + deadline | 0.24 s | 0.26 s | 382 | 4 | 1 |
| slots-32k + first | 0.24 s | 0.26 s | 286 | 128 | 32,768 |
| slots-32k + deadline | 0.24 s | 0.26 s | 418 | 32 | 8 |
| stage-32k + fill | 2.04 s | 2.04 s | 359 | 32 | 1 |
| stage-256k + first | 0.24 s | 0.26 s | 370 | 128 | 1 |
| **stage-256k + deadline** | **0.24 s** | **0.26 s** | **367** | **4** | **1** |

Throughput differences of about ±8% are run-to-run noise on this machine. The
16 Mbit/s scenario showed the same ordering for JNI calls (13 per MiB with the
deadline, 32 with the 32 KiB cap, 131 for first) and no CPU difference
outside noise.

## What was chosen, and why

**Staging buffer, `okhttpReadPartial` with a 10 ms deadline, 256 KiB requests.**

- Returning early is the only thing that fixes slow streams: 0.24 s instead
  of 2 s (32 KiB fill) or 33 s (unclamped fill) to a probe's first 2 KiB.
- Returning after the first chunk costs 128 JNI calls per MiB. The deadline
  lets a fast stream fill most of the request: 4 calls per MiB.
- Any early return makes FFmpeg's read address move unpredictably, so a
  wrapper cached by address misses on nearly every read: 32,768 new
  `DirectByteBuffer`s for 256 MiB. That is the per-read allocation the
  `[OOM FIX]` in `http.c` removed. A staging buffer is wrapped once per
  connection whatever FFmpeg does. Its copy cost about 0.3 ms of CPU per
  MiB at loopback speed in the exploration run and nothing measurable in the
  run of the committed code, both within this machine's spread and far below
  anything a real network shows.
- The new Java method is optional. `http.c` looks it up by name and falls
  back to `okhttpRead` with 32 KiB requests on an older app, and an older
  `.so` keeps calling `okhttpRead`. The app and the `.so` can ship in either
  order.

The current run measures this design: `current:new` is what ships,
`current:old` is the new `.so` with an older app, and `new-64k`, `new-2ms`
and `new-50ms` are its neighbours. With `BENCH_BASELINE_REF=origin/master`
at the time (the slot-table design):

| Row | Live: first 2 KiB | Live: longest gap | Mobile: JNI calls/MiB | Fast: MiB/s | Fast: JNI calls/MiB | Buffers created |
|---|---|---|---|---|---|---|
| baseline, older app | 2.04 s | 2.04 s | 32.0 | 369 | 32 | 8 |
| current, older app | 2.04 s | 2.04 s | 32.0 | 376 | 32 | 1 |
| **current, new app (ships)** | **0.24 s** | **0.26 s** | **13.2** | **400** | **4** | **1** |
| current, new app, 64 KiB requests | 0.24 s | 0.26 s | 26.2 | 346 | 16 | 1 |
| current, new app, 2 ms deadline | 0.24 s | 0.26 s | 13.2 | 417 | 4 | 1 |
| current, new app, 50 ms deadline | 0.24 s | 0.30 s | 8.8 | 389 | 4 | 1 |

The deadline sits in a flat region: 2 ms gains nothing measurable, 50 ms
makes fewer calls on a medium-speed stream at the price of slightly longer
gaps. 64 KiB requests double the calls for no gain.

## Is the staging copy worth removing?

The staging buffer adds one copy per read: Java fills it, C copies it into
FFmpeg's buffer. Two copy-free alternatives were considered:

- **eq**: wrap FFmpeg's buffer at the exact address it reads into, reuse the
  wrapper while FFmpeg keeps reading there, and re-wrap when it moves.
- **rng**: wrap the whole range FFmpeg offers (three kept), and give Java an
  offset for later reads inside one. That needs a third Java read method.

In both, every read would skip the copy, so what each costs is the
`DirectByteBuffer`s it would create, and the per-read allocation those bring
back is what the `[OOM FIX]` in `http.c` removed. Rather than build either,
`http.c` counts what each WOULD have done with the real read addresses (shadow
counters; nothing is read differently): wrappers created per connection
(`*_wr`) and the share of bytes read through one that already existed
(`*_re%`), next to the time the copy actually takes.

The decision rule, from the design review: keep staging unless, on a real
phone with a TLS workload, the copy exceeds about **1 ms of CPU per MiB**
(`copy/MiB`), or about 3-5% of the download thread's whole CPU. `copy%` is its
share of the CPU inside `okhttp_read` only, which overstates that; check the
whole-thread share with simpleperf (below). If the rule trips, build **rng**,
and only if its counters show at most three wrappers per connection.

### Desktop result

Full run, plain HTTP over loopback, the shipped configuration (`current:new`).
"Share" is the copy's time against the reader thread's whole CPU. Without TLS
that denominator is far smaller than on a phone, so the share runs high here.
Wrappers are per connection; each scenario is one 8-256 MiB connection.

| Scenario | Copy per MiB | Share | JNI calls per MiB | eq wrappers | rng wrappers |
|---|---|---|---|---|---|
| 16 Mbit/s file | 149 µs | 3.2% | 13.2 | 106 | 1 |
| 50 Mbit/s file | 137 µs | 4.3% | 8.4 | 135 | 1 |
| 100 Mbit/s file | 83 µs | 3.2% | 4.2 | 1 | 1 |
| 150 Mbit/s file | 66 µs | 2.4% | 6.3 | 145 | 1 |
| Unthrottled file | 33 µs | 1.4% | 4.0 | 1 | 1 |
| Unthrottled, no length | 40 µs | 1.7% | 4.0 | 1,024 | 1 |
| crypto.c reads | 22 µs | 0.7% | 256 | 2 | 1 |

- The copy costs 0.02-0.15 ms per MiB, a tenth of the 1 ms threshold or less.
- **eq** would bring back a wrapper per read whenever reads are short (16, 50
  and 150 Mbit/s) and on every unknown-length stream, where FFmpeg alternates
  between two addresses. It only works when 256 KiB arrives within the
  deadline. It is ruled out.
- **rng** needs one wrapper per connection everywhere. It is the variant to
  build if a phone ever shows the copy to matter.
- AES-128 HLS reads cost 256 JNI calls per MiB whatever the buffer design,
  because `crypto.c` reads 4 KiB at a time. If anything on the read path is
  worth optimising, it is that, not the copy.

## On a device

The same stats line the benchmark parses is printed to logcat by a debug build
of the app, one line per closed connection (a whole file download, or one
HLS/DASH segment, key or playlist).

**The short way:** one script does all of the steps below except tapping the
downloads, which it prompts for, and then restores the device and the app's
libraries:

```
scripts/okhttp-read-bench/device-run.sh ~/path/to/firedown
```

It switches both repos to the measurement branches (refusing if either has
uncommitted changes), builds arm64 libraries, copies them into the app,
installs the debug build, turns the stats on, and captures each workload
(wifi-file, hls, aes-hls, radio; three runs each). A capture stops when you
press Enter, or 45 s after the last connection closed. Then it prints the
summary and saves it with the captures in `~/okread-<date>-<time>`. Run it
with `--help` for options (`--reps`, `--workloads`, `--no-build`,
`--no-install`, `--keep-libs`). The build needs `ANDROID_SDK_HOME` and
`ANDROID_NDK_HOME`; the script uses yours if exported, else `~/Android/Sdk`
and its newest NDK.

The manual steps, for reference or for running a part by hand:

1. Build this repo's libraries and copy them into the app for a local test
   (not a release). The sync script must run from the app's `scripts/`
   directory, because it writes to `../external/ffmpeg`:
   ```
   ./ffmpeg-android-maker.sh -dav1d -abis=arm64-v8a
   cd <firedown>/scripts && ./sync-ffmpeg.sh <path to this repo>
   ```
   Then install a **debug** build of the app (`./gradlew installDebug`) from a
   commit that has `utils_ffmpeg_log_level()` (the app's
   `claude/okhttp-partial-read` branch, or `main` once merged): only debug
   builds honour the property below, and older apps ignore it silently.
2. Turn the stats on. FFmpeg's log level is read at the start of each
   operation, so this applies from the next download:
   ```
   adb shell setprop debug.firedown.fflog 32      # AV_LOG_INFO
   ```
3. For each workload, capture the log live while it runs. At INFO, FFmpeg
   also logs every segment URL it opens, so dumping the ring buffer
   afterwards can lose the first stats lines of a long HLS download; enlarge
   it as well:
   ```
   adb logcat -G 16M
   adb logcat -c
   adb logcat -s ffmpeg > wifi-file.txt     # Ctrl-C once the workload is done
   ```
   These captures contain full, signed media URLs: keep them private.
   Workloads, each at least three times, phone cool and on a fixed charging
   state:
   - a large HTTPS file over Wi-Fi (HTTP/2 from a CDN if possible);
   - an HLS VOD download with many segments;
   - an AES-128 HLS download (reads arrive in 4112-byte pieces through
     FFmpeg's crypto layer);
   - a live radio or ICY stream for about 30 seconds.
4. Summarize, with the same measures as the desktop tables:
   ```
   python3 scripts/okhttp-read-bench/device-stats.py wifi-file.txt hls.txt aes-hls.txt
   ```
5. Turn the stats off again: `adb shell setprop debug.firedown.fflog '""'`.

No A/B build is needed: the copy's cost is measured directly (`copy/MiB`),
and the shadow counters show what each hybrid would have cost on the same
reads. Caveats on the numbers: the read-path CPU (`rd_cpu`) counts only the
thread that calls FFmpeg, and with HTTP/2 OkHttp's reader thread does the
socket and TLS work elsewhere; the timers include their own clock reads (one
thread-CPU clock syscall per read), which shows on AES-128 HLS, where reads
are about 4 KiB.

For a whole-download CPU picture, profile one download of a debug build with
the NDK's simpleperf and look at `memcpy` under `okhttp_read` against BoringSSL,
ART and the demuxer:

```
python3 $ANDROID_NDK_HOME/simpleperf/app_profiler.py -p com.solarized.firedown \
    -r "-g --duration 30"
python3 $ANDROID_NDK_HOME/simpleperf/report_html.py
```

## Limits

- HTTP/1.1 over loopback only. HTTP/2 delivers data through OkHttp's reader
  thread, so arrival patterns differ; check a live stream on a device.
- A desktop JVM, not ART. JNI and `DirectByteBuffer` costs differ on a phone,
  but the call and allocation counts carry over.
