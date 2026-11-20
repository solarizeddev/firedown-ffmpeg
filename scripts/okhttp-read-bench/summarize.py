#!/usr/bin/env python3
"""Summarize okhttp-read-bench results: one table, medians over the reps
after the first (JIT warm-up). Exits 1 if any rep read a wrong byte, failed
to open, or came up short.

Input lines: "<combo> <scenario> <stats...>" with stats in bench_jni.c order.
"""
import statistics
import sys
from collections import OrderedDict

BYTES, NS_TOTAL, NS_2K, NS_32K, CPU_NS, CALLS, WRAPS, BAD, GAP, OPEN_ERR = range(10)
MIB = 1 << 20


def main(path, mobile_size, fast_size):
    want = {"live": 65536, "mobile": mobile_size, "fast": fast_size}
    runs = OrderedDict()
    for line in open(path):
        f = line.split()
        if len(f) != 12:
            continue
        runs.setdefault((f[0], f[1]), []).append([int(x) for x in f[2:]])

    failed = []
    for (combo, sc), reps in runs.items():
        for r in reps:
            if r[BAD] or r[OPEN_ERR] or r[BYTES] < want[sc]:
                failed.append("%s %s: bytes=%d bad=%d open_err=%d"
                              % (combo, sc, r[BYTES], r[BAD], r[OPEN_ERR]))

    def med(combo, sc, fn):
        reps = runs.get((combo, sc), [])[1:] or runs.get((combo, sc), [])
        vals = [fn(r) for r in reps]
        return statistics.median(vals) if vals else float("nan")

    combos = list(OrderedDict.fromkeys(c for c, _ in runs))
    hdr = ("%-20s | %8s %8s %8s | %7s %8s %6s | %8s %7s %8s %6s"
           % ("variant:strategy", "2KB s", "32KB s", "gap s",
              "cpu/MiB", "reads/MiB", "wraps",
              "MiB/s", "cpu/MiB", "reads/MiB", "wraps"))
    print()
    print("%-20s | %-26s | %-24s | %s" % ("", "live 128 kbit/s (probe)",
                                           "mobile 16 Mbit/s", "fast (loopback)"))
    print(hdr)
    print("-" * len(hdr))
    for c in combos:
        print("%-20s | %8.2f %8.2f %8.2f | %7.2f %8.1f %6d | %8.0f %7.2f %8.1f %6d" % (
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
    print("cpu/MiB: reader-thread CPU ms per MiB (JNI + Java read path + avio).")
    print("reads/MiB: okhttp_read JNI calls per MiB. wraps: DirectByteBuffers created.")
    if failed:
        print("\nFAILED:")
        for f in failed:
            print("  " + f)
        return 1
    print("\nall reps: every byte verified, no open errors")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], int(sys.argv[2]), int(sys.argv[3])))
