#!/usr/bin/env python3
"""Summarize okhttp-read-bench results, medians over the reps after the first
(JIT warm-up).

  summarize.py <results> "<scenario>:<bytes>:<reps> ..." <row label>...

Exits 1, so a run can never pass by measuring nothing or the wrong thing, if:
  - a result line is malformed, or names a row or scenario not expected;
  - an expected row x scenario is missing or has fewer reps than requested;
  - a rep read a wrong byte, failed to open, or came up short;
  - a row ran a different Java read method than its label says: "<x>:new*"
    rows must have used okhttpReadPartial, "<x>:old" rows must not;
  - a "current:*" row has no okhttp-stats line, an unparsable one, or one
    counting fewer bytes than the reader got (a baseline http.c that predates
    the stats line reports none, which is fine).

Input lines: "<row> <scenario> <stats...>" with stats in bench_jni.c order.
"""
import statistics
import sys
from collections import OrderedDict

(BYTES, NS_TOTAL, NS_2K, NS_32K, CPU_NS, CALLS, WRAPS, BAD, GAP, OPEN_ERR,
 PARTIAL, S_BYTES, S_COPY_NS, S_READ_CPU_NS, S_EQ_HIT, S_EQ_WRAPS, S_RNG_HIT,
 S_RNG_WRAPS) = range(18)
N_STATS = 18
MIB = 1 << 20

DESCR = {
    "live": "128 kbit/s live, no Content-Length",
    "mobile": "16 Mbit/s file",
    "m50": "50 Mbit/s file",
    "m100": "100 Mbit/s file",
    "m150": "150 Mbit/s file",
    "fast": "unthrottled file (loopback)",
    "chunked": "unthrottled, no Content-Length (512 KiB AVIO buffer)",
    "crypto": "unthrottled, protocol reads as crypto.c makes them (4 KiB, moving)",
}


def main(argv):
    path = argv[1]
    spec = OrderedDict()
    for item in argv[2].split():
        name, nbytes, reps = item.split(":")
        spec[name] = (int(nbytes), int(reps))
    rows = argv[3:]

    failed = []
    runs = OrderedDict()
    for n, line in enumerate(open(path), 1):
        f = line.split()
        if not f:
            continue
        if len(f) != 2 + N_STATS or f[1] not in spec or f[0] not in rows:
            failed.append("malformed or unexpected result line %d: %r" % (n, line.rstrip()))
            continue
        try:
            runs.setdefault((f[0], f[1]), []).append([int(x) for x in f[2:]])
        except ValueError:
            failed.append("malformed result line %d: %r" % (n, line.rstrip()))

    for row in rows:
        native, app = row.split(":", 1)
        for sc, (want_bytes, want_reps) in spec.items():
            reps = runs.get((row, sc), [])
            if len(reps) < want_reps:
                failed.append("%s %s: %d of %d reps" % (row, sc, len(reps), want_reps))
            for r in reps:
                if r[BAD] or r[OPEN_ERR] or r[BYTES] < want_bytes:
                    failed.append("%s %s: bytes=%d bad=%d open_err=%d"
                                  % (row, sc, r[BYTES], r[BAD], r[OPEN_ERR]))
                if app.startswith("new") and r[PARTIAL] != 1:
                    failed.append("%s %s: expected okhttpReadPartial, got partial=%d"
                                  % (row, sc, r[PARTIAL]))
                if app.startswith("old") and r[PARTIAL] == 1:
                    failed.append("%s %s: an old app cannot use okhttpReadPartial" % (row, sc))
                if r[S_BYTES] == -2:
                    failed.append("%s %s: unparsable okhttp-stats line" % (row, sc))
                elif native == "current" and r[S_BYTES] < r[BYTES]:
                    failed.append("%s %s: okhttp-stats bytes=%d, reader got %d"
                                  % (row, sc, r[S_BYTES], r[BYTES]))

    def med(row, sc, fn):
        reps = runs.get((row, sc), [])
        reps = reps[1:] or reps
        vals = [v for v in (fn(r) for r in reps) if v is not None]
        return statistics.median(vals) if vals else None

    def fmt(v, spec_):
        return "-" if v is None else spec_ % v

    def per_mib(r, ns):
        return ns / 1e6 / (r[BYTES] / MIB) if r[BYTES] else None

    def stat(r, i, fn):
        return None if r[S_BYTES] < 0 else fn(r, r[i])

    print()
    if "live" in spec:
        print("live: %s" % DESCR["live"])
        hdr = "%-18s | %9s %9s %9s" % ("native:app", "2KB s", "32KB s", "gap s")
        print(hdr)
        print("-" * len(hdr))
        for c in rows:
            print("%-18s | %9s %9s %9s" % (
                c,
                fmt(med(c, "live", lambda r: r[NS_2K] / 1e9), "%.2f"),
                fmt(med(c, "live", lambda r: r[NS_32K] / 1e9), "%.2f"),
                fmt(med(c, "live", lambda r: r[GAP] / 1e9), "%.2f")))
        print()

    for sc in spec:
        if sc == "live":
            continue
        print("%s: %s" % (sc, DESCR.get(sc, sc)))
        hdr = ("%-18s | %7s %7s %7s %8s | %7s %5s | %6s %6s | %6s %6s"
               % ("native:app", "MiB/s", "cpu/MiB", "rd/MiB", "copy/MiB",
                  "JNI/MiB", "wraps", "eq_re%", "eq_wr", "rng_re%", "rng_wr"))
        print(hdr)
        print("-" * len(hdr))
        for c in rows:
            print("%-18s | %7s %7s %7s %8s | %7s %5s | %6s %6s | %6s %6s" % (
                c,
                fmt(med(c, sc, lambda r: (r[BYTES] / MIB) / (r[NS_TOTAL] / 1e9)), "%.0f"),
                fmt(med(c, sc, lambda r: per_mib(r, r[CPU_NS])), "%.2f"),
                fmt(med(c, sc, lambda r: stat(r, S_READ_CPU_NS, lambda r, v: v / 1e6 / (r[S_BYTES] / MIB) if r[S_BYTES] else None)), "%.2f"),
                fmt(med(c, sc, lambda r: stat(r, S_COPY_NS, lambda r, v: v / 1e3 / (r[S_BYTES] / MIB))), "%.0fus"),
                fmt(med(c, sc, lambda r: r[CALLS] / (r[BYTES] / MIB)), "%.1f"),
                fmt(med(c, sc, lambda r: r[WRAPS]), "%.0f"),
                fmt(med(c, sc, lambda r: stat(r, S_EQ_HIT, lambda r, v: 100.0 * v / r[S_BYTES] if r[S_BYTES] else 0)), "%.0f"),
                fmt(med(c, sc, lambda r: stat(r, S_EQ_WRAPS, lambda r, v: v)), "%.0f"),
                fmt(med(c, sc, lambda r: stat(r, S_RNG_HIT, lambda r, v: 100.0 * v / r[S_BYTES] if r[S_BYTES] else 0)), "%.0f"),
                fmt(med(c, sc, lambda r: stat(r, S_RNG_WRAPS, lambda r, v: v)), "%.0f")))
        print()

    print("2KB s / 32KB s: time from open until the reader has 2 KiB (a probe's first")
    print("read) / 32 KiB. gap s: longest wait between two reads after the first.")
    print("MiB/s: reader throughput. cpu/MiB: reader-thread CPU ms per MiB, all of it")
    print("(JNI, Java read path, avio, and the bench's own per-byte check, equal in every")
    print("row). rd/MiB: CPU ms per MiB inside okhttp_read only (http.c's stats line).")
    print("copy/MiB: time in the staging memcpy per MiB. JNI/MiB: okhttp_read calls per")
    print("MiB. wraps: staging DirectByteBuffers created (1 per connection by design).")
    print("eq_* / rng_*: two copy-free hybrids, from http.c's shadow counters (nothing is")
    print("read differently): eq wraps FFmpeg's buffer at the exact address and re-wraps")
    print("when FFmpeg reads elsewhere; rng wraps whole buffer ranges (3 kept) and passes")
    print("an offset. Every read in either would skip the copy, so the cost is *_wr, the")
    print("wrappers created per connection; *_re% is the share of bytes read through one")
    print("that already existed. '-': this row's http.c has no stats line.")
    if failed:
        print("\nFAILED:")
        for f in failed:
            print("  " + f)
        return 1
    print("\nall rows and reps present, every byte verified, read method as labelled,")
    print("stats lines present and consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
