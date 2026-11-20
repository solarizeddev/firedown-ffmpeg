#!/usr/bin/env python3
"""Summarize http.c's okhttp-stats lines from Android logcat captures.

  adb logcat -c
  ... run one workload in the app ...
  adb logcat -d -s ffmpeg > hls-wifi.txt
  python3 scripts/okhttp-read-bench/device-stats.py hls-wifi.txt [more.txt ...]

Each file is one capture (one workload, one build); each okhttp-stats line is
one closed connection (a whole file download, or one HLS/DASH segment, key or
playlist). Prints one summary row per file, with the same measures as the
desktop benchmark's throughput tables, so desktop and device numbers line up.
See README.md, "On a device", for the procedure.

Only lines with the "okhttp-stats:" marker are read; anything else in the
capture is ignored. A capture without any is reported, not skipped silently.
"""
import re
import statistics
import sys

FIELDS = ("partial", "reads", "bytes", "read_wall_ns", "read_cpu_ns", "copy_ns",
          "eq_hit_bytes", "eq_wraps", "rng_hit_bytes", "rng_wraps")
LINE = re.compile(r"okhttp-stats: " + " ".join(r"%s=(-?\d+)" % f for f in FIELDS)
                  + r" hist=(\S+)")
MIB = 1 << 20


def summarize(path):
    conns = []
    sizes = {}
    for line in open(path, errors="replace"):
        m = LINE.search(line)
        if not m:
            continue
        c = dict(zip(FIELDS, (int(x) for x in m.groups()[:-1])))
        conns.append(c)
        hist = m.group(len(FIELDS) + 1)
        if hist != "-":
            for item in hist.split(","):
                b, n = item.split(":")
                sizes[int(b)] = sizes.get(int(b), 0) + int(n)
    if not conns:
        return None
    tot = {f: sum(c[f] for c in conns) for f in FIELDS}
    mib = tot["bytes"] / MIB if tot["bytes"] else 0
    reads = sum(sizes.values())
    # median read size, from the floor(log2) histogram: report the bucket
    acc, median_bucket = 0, None
    for b in sorted(sizes):
        acc += sizes[b]
        if acc * 2 >= reads:
            median_bucket = b
            break
    partial = {c["partial"] for c in conns}

    def per_mib(v, div=1e6):
        return v / div / mib if mib else 0

    return {
        "file": path,
        "conns": len(conns),
        "MiB": mib,
        "partial": "/".join(str(p) for p in sorted(partial)),
        "rd_cpu": per_mib(tot["read_cpu_ns"]),
        "rd_wall": per_mib(tot["read_wall_ns"]),
        "copy_us": per_mib(tot["copy_ns"], 1e3),
        "copy_share": 100.0 * tot["copy_ns"] / tot["read_cpu_ns"] if tot["read_cpu_ns"] else 0,
        "jni": tot["reads"] / mib if mib else 0,
        "med_read": "%d-%d" % (1 << median_bucket, (2 << median_bucket) - 1) if median_bucket is not None else "-",
        "eq": 100.0 * tot["eq_hit_bytes"] / tot["bytes"] if tot["bytes"] else 0,
        "eq_wr": statistics.median(c["eq_wraps"] for c in conns),
        "eq_wr_max": max(c["eq_wraps"] for c in conns),
        "rng": 100.0 * tot["rng_hit_bytes"] / tot["bytes"] if tot["bytes"] else 0,
        "rng_wr": statistics.median(c["rng_wraps"] for c in conns),
        "rng_wr_max": max(c["rng_wraps"] for c in conns),
    }


def main(paths):
    if not paths:
        sys.exit(__doc__)
    rows, empty = [], []
    for p in paths:
        r = summarize(p)
        (rows if r else empty).append(r or p)
    hdr = ("%-24s %5s %8s %4s | %7s %7s %8s %6s | %7s %13s | %6s %9s | %7s %9s"
           % ("capture", "conns", "MiB", "prt", "rd_cpu", "rd_wall", "copy/MiB", "copy%",
              "JNI/MiB", "med read B", "eq_re%", "eq_wr/max", "rng_re%", "rng_wr/max"))
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        print("%-24s %5d %8.1f %4s | %7.2f %7.1f %6.0fus %5.1f%% | %7.1f %13s | %6.0f %5.0f/%-3d | %7.0f %5.0f/%-3d" % (
            r["file"][-24:], r["conns"], r["MiB"], r["partial"],
            r["rd_cpu"], r["rd_wall"], r["copy_us"], r["copy_share"],
            r["jni"], r["med_read"],
            r["eq"], r["eq_wr"], r["eq_wr_max"], r["rng"], r["rng_wr"], r["rng_wr_max"]))
    print()
    print("conns: connections closed (okhttp-stats lines). prt: okhttpReadPartial used")
    print("(1) or the okhttpRead fallback (0). rd_cpu / rd_wall: ms per MiB of CPU /")
    print("wall time inside okhttp_read on the calling thread (HTTP/2 also spends CPU on")
    print("OkHttp's reader thread, not counted here). copy/MiB and copy%: the staging")
    print("memcpy per MiB, and as a share of rd_cpu: CPU inside okhttp_read only, so it")
    print("overstates the copy's share of the whole download thread (use simpleperf for")
    print("that). JNI/MiB: read calls per MiB. med read B: the median read's size range.")
    print("eq / rng: two copy-free hybrids (exact-address wrapper, re-wrapped when FFmpeg")
    print("moves / range wrappers + offset). Every read in either would skip the copy, so")
    print("the cost is the wrappers created per connection (*_wr, median/max); *_re% is")
    print("the share of bytes read through a wrapper that already existed.")
    for p in empty:
        print("\nno okhttp-stats lines in %s: was debug.firedown.fflog set to 32 on a"
              " debug build before the download started?" % p)
    return 1 if empty and not rows else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
