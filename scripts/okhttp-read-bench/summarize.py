#!/usr/bin/env python3
"""Summarize okhttp-read-bench results: one table, medians over the reps
after the first (JIT warm-up).

  summarize.py <results> <mobile_size> <fast_size> <reps_live> <reps_mobile>
               <reps_fast> <row label>...

Exits 1, so a run can never pass by measuring nothing or the wrong thing, if:
  - a result line is malformed;
  - an expected row x scenario is missing or has fewer reps than requested;
  - a rep read a wrong byte, failed to open, or came up short;
  - a row ran a different Java read method than its label says: "<x>:new*"
    rows must have used okhttpReadPartial, "current:old" must have fallen
    back to okhttpRead (a baseline http.c predating the flag reports none).

Input lines: "<row> <scenario> <stats...>" with stats in bench_jni.c order.
"""
import statistics
import sys
from collections import OrderedDict

(BYTES, NS_TOTAL, NS_2K, NS_32K, CPU_NS, CALLS, WRAPS, BAD, GAP, OPEN_ERR,
 PARTIAL) = range(11)
N_STATS = 11
MIB = 1 << 20
SCENARIOS = ("live", "mobile", "fast")


def main(argv):
    path = argv[1]
    want_bytes = {"live": 65536, "mobile": int(argv[2]), "fast": int(argv[3])}
    want_reps = dict(zip(SCENARIOS, (int(argv[4]), int(argv[5]), int(argv[6]))))
    rows = argv[7:]

    failed = []
    runs = OrderedDict()
    for n, line in enumerate(open(path), 1):
        f = line.split()
        if not f:
            continue
        if len(f) != 2 + N_STATS or f[1] not in SCENARIOS:
            failed.append("malformed result line %d: %r" % (n, line.rstrip()))
            continue
        try:
            runs.setdefault((f[0], f[1]), []).append([int(x) for x in f[2:]])
        except ValueError:
            failed.append("malformed result line %d: %r" % (n, line.rstrip()))

    for row in rows:
        app = row.split(":", 1)[1]
        for sc in SCENARIOS:
            reps = runs.get((row, sc), [])
            if len(reps) < want_reps[sc]:
                failed.append("%s %s: %d of %d reps" % (row, sc, len(reps), want_reps[sc]))
            for r in reps:
                if r[BAD] or r[OPEN_ERR] or r[BYTES] < want_bytes[sc]:
                    failed.append("%s %s: bytes=%d bad=%d open_err=%d"
                                  % (row, sc, r[BYTES], r[BAD], r[OPEN_ERR]))
                if app.startswith("new") and r[PARTIAL] != 1:
                    failed.append("%s %s: expected okhttpReadPartial, got partial=%d"
                                  % (row, sc, r[PARTIAL]))
                if app.startswith("old") and r[PARTIAL] == 1:
                    failed.append("%s %s: an old app cannot use okhttpReadPartial"
                                  % (row, sc))
    for key in runs:
        if key[0] not in rows:
            failed.append("unexpected row in results: %s %s" % key)

    def med(row, sc, fn):
        reps = runs.get((row, sc), [])
        reps = reps[1:] or reps
        vals = [fn(r) for r in reps]
        return statistics.median(vals) if vals else float("nan")

    hdr = ("%-20s | %8s %8s %8s | %7s %8s %6s | %8s %7s %8s %6s"
           % ("native:app", "2KB s", "32KB s", "gap s",
              "cpu/MiB", "reads/MiB", "wraps",
              "MiB/s", "cpu/MiB", "reads/MiB", "wraps"))
    print()
    print("%-20s | %-26s | %-24s | %s" % ("", "live 128 kbit/s (probe)",
                                           "mobile 16 Mbit/s", "fast (loopback)"))
    print(hdr)
    print("-" * len(hdr))
    for c in rows:
        print("%-20s | %8.2f %8.2f %8.2f | %7.2f %8.1f %6.0f | %8.0f %7.2f %8.1f %6.0f" % (
            c,
            med(c, "live", lambda r: r[NS_2K] / 1e9),
            med(c, "live", lambda r: r[NS_32K] / 1e9),
            med(c, "live", lambda r: r[GAP] / 1e9),
            med(c, "mobile", lambda r: r[CPU_NS] / 1e6 / (r[BYTES] / MIB)),
            med(c, "mobile", lambda r: r[CALLS] / (r[BYTES] / MIB)),
            med(c, "mobile", lambda r: r[WRAPS]),
            med(c, "fast", lambda r: (r[BYTES] / MIB) / (r[NS_TOTAL] / 1e9)),
            med(c, "fast", lambda r: r[CPU_NS] / 1e6 / (r[BYTES] / MIB)),
            med(c, "fast", lambda r: r[CALLS] / (r[BYTES] / MIB)),
            med(c, "fast", lambda r: r[WRAPS])))
    print()
    print("2KB s / 32KB s: time from open until the reader has 2 KiB (a probe's first")
    print("read) / 32 KiB. gap s: longest wait between two reads after the first.")
    print("cpu/MiB: reader-thread CPU ms per MiB: JNI, the Java read path, avio, and")
    print("the bench's own per-byte check (the same in every row).")
    print("reads/MiB: okhttp_read JNI calls per MiB. wraps: DirectByteBuffers created.")
    if failed:
        print("\nFAILED:")
        for f in failed:
            print("  " + f)
        return 1
    print("\nall rows and reps present, every byte verified, read method as labelled")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
