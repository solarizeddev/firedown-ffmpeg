#!/usr/bin/env python3
"""Derive the benchmark's variants from the REAL sources.

  variants.py java <FFmpegOkhttp.java> <out.java> old|new
      old  okhttpReadPartial removed: what an app built before it existed
           looks like to http.c (which then falls back to okhttpRead with
           32 KiB requests)
      new  as committed, except that PARTIAL_READ_DEADLINE_NS is read from
           -Dfd.deadlineMs (default 10, the committed value) so one build
           can sweep it

  variants.py c <http.c> <out.c>
      as committed, except that FIREDOWN_OKHTTP_MAX_READ and
      FIREDOWN_OKHTTP_PARTIAL_MAX_READ become overridable with -D

Every edit is anchored on exact text and fails loudly if the source drifted,
so a stale benchmark cannot silently measure something else.
"""
import re
import sys


def sub(text, old, new, what):
    if text.count(old) != 1:
        sys.exit("variants.py: anchor for %s found %d times" % (what, text.count(old)))
    return text.replace(old, new, 1)


def java(src, out, mode):
    s = open(src).read()
    if mode == "old":
        # The method, its javadoc and @Keep: from the javadoc opener that
        # precedes it to the end of its body.
        m = re.search(r"\n    /\*\*\n(?:     \*[^\n]*\n)*?     \*/\n    @Keep\n"
                      r"    public int okhttpReadPartial\(ByteBuffer byteBuffer, int size\) \{\n"
                      r"        return read\(byteBuffer, size, true\);\n    \}\n", s)
        if not m:
            sys.exit("variants.py: okhttpReadPartial not found (old mode)")
        s = s[:m.start()] + "\n" + s[m.end():]
        if "okhttpReadPartial(" in s.replace("{@link #okhttpReadPartial}", ""):
            sys.exit("variants.py: okhttpReadPartial still referenced after removal")
    elif mode == "new":
        s = sub(s, "    private static final long PARTIAL_READ_DEADLINE_NS = 10_000_000L;\n",
                "    private static final long PARTIAL_READ_DEADLINE_NS =\n"
                "            Long.getLong(\"fd.deadlineMs\", 10L) * 1_000_000L; // okhttp-read-bench\n",
                "deadline constant")
    else:
        sys.exit("variants.py: unknown java mode " + mode)
    open(out, "w").write(s)


def c(src, out):
    s = open(src).read()
    s = sub(s, "#define FIREDOWN_OKHTTP_MAX_READ 32768\n#define FIREDOWN_OKHTTP_PARTIAL_MAX_READ 262144\n",
            "#ifndef FIREDOWN_OKHTTP_MAX_READ\n#define FIREDOWN_OKHTTP_MAX_READ 32768\n#endif\n"
            "#ifndef FIREDOWN_OKHTTP_PARTIAL_MAX_READ\n#define FIREDOWN_OKHTTP_PARTIAL_MAX_READ 262144\n#endif\n",
            "read-size defines")
    open(out, "w").write(s)


if __name__ == "__main__":
    a = sys.argv
    if len(a) == 5 and a[1] == "java":
        java(a[2], a[3], a[4])
    elif len(a) == 4 and a[1] == "c":
        c(a[2], a[3])
    else:
        sys.exit(__doc__)
