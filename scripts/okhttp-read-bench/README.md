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
  connection whatever FFmpeg does. Its copy did not show up in throughput.
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

## Limits

- HTTP/1.1 over loopback only. HTTP/2 delivers data through OkHttp's reader
  thread, so arrival patterns differ; check a live stream on a device.
- A desktop JVM, not ART. JNI and `DirectByteBuffer` costs differ on a phone,
  but the call and allocation counts carry over.
