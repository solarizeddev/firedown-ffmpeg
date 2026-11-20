#!/usr/bin/env python3
"""Derive the benchmark's read-strategy variants from the REAL sources.

  variants.py java <FFmpegOkhttp.java> <out.java>
      Adds a run-time switch to okhttpRead's fill loop, chosen per JVM with
      -Dfd.read=fill|first|deadline and -Dfd.deadlineMs=N:
        fill      unchanged: return once `size` bytes are read or the body ends
        first     return after the first non-empty okio read (<= one 8 KiB
                  okio segment, i.e. whatever one socket read produced)
        deadline  fill, but return as soon as some bytes are in hand and
                  N ms have passed since the call started

  variants.py c <http.c> <out.c> slots|stage
      slots  http.c as committed (clamp + address-keyed DirectByteBuffer
             table); the clamp is overridable with -DFIREDOWN_OKHTTP_MAX_READ
      stage  ONE native staging buffer of FD_STAGE_SIZE bytes per context,
             wrapped once; Java reads into it and C memcpy()s to ffmpeg's
             buffer, so the wrapper never depends on ffmpeg's dst address

Every edit is anchored on exact text and fails loudly if the source drifted,
so a stale benchmark cannot silently measure something else.
"""
import sys


def sub(text, old, new, what):
    if text.count(old) != 1:
        sys.exit("variants.py: anchor for %s found %d times" % (what, text.count(old)))
    return text.replace(old, new, 1)


def java(src, out):
    s = open(src).read()
    s = sub(s, "public class FFmpegOkhttp {\n",
            "public class FFmpegOkhttp {\n"
            "    /* okhttp-read-bench: read strategy (0 fill, 1 first, 2 deadline) */\n"
            "    private static final int FD_STRATEGY = switch (System.getProperty(\"fd.read\", \"fill\")) {\n"
            "        case \"first\" -> 1; case \"deadline\" -> 2; default -> 0; };\n"
            "    private static final long FD_DEADLINE_NS =\n"
            "            Long.getLong(\"fd.deadlineMs\", 10L) * 1_000_000L;\n",
            "class header")
    s = sub(s, "            int reconnectAttempts = 0;\n",
            "            int reconnectAttempts = 0;\n"
            "            final long fdStart = System.nanoTime();\n",
            "read start")
    s = sub(s, "                    totalRead += n;\n                }\n",
            "                    totalRead += n;\n"
            "                    if (FD_STRATEGY == 1) break;\n"
            "                    if (FD_STRATEGY == 2 && System.nanoTime() - fdStart >= FD_DEADLINE_NS) break;\n"
            "                }\n",
            "fill loop")
    open(out, "w").write(s)


def c(src, out, mode):
    s = open(src).read()
    s = sub(s, "#define FIREDOWN_OKHTTP_MAX_READ 32768\n",
            "#ifndef FIREDOWN_OKHTTP_MAX_READ\n#define FIREDOWN_OKHTTP_MAX_READ 32768\n#endif\n",
            "clamp define")
    if mode == "slots":
        open(out, "w").write(s)
        return
    if mode != "stage":
        sys.exit("variants.py: unknown C mode " + mode)

    s = sub(s, "    int buf_slot_next; /* FIFO eviction cursor once every slot is in use */\n",
            "    int buf_slot_next; /* FIFO eviction cursor once every slot is in use */\n"
            "    jobject stage_ref;        /* okhttp-read-bench: stage mode */\n"
            "    unsigned char *stage;\n",
            "struct fields")
    start = "    struct OkhttpBufSlot *slot = NULL;\n"
    call = ("    int bytes_read = (*env)->CallIntMethod(env, c->thiz, "
            "c->jfields.okhttp_read_method, slot->ref, size);\n")
    i, j = s.find(start), s.find(call)
    if i < 0 or j < 0 or s.count(start) != 1 or s.count(call) != 1 or j < i:
        sys.exit("variants.py: anchor for the slot block not found")
    stage = """    if (!c->stage_ref) {
        c->stage = av_malloc(FD_STAGE_SIZE);
        if (!c->stage)
            return AVERROR(ENOMEM);
        av_log(h, AV_LOG_VERBOSE, "okhttp_open: staging buffer %d\\n", FD_STAGE_SIZE);
        jobject local_buf = (*env)->NewDirectByteBuffer(env, c->stage, FD_STAGE_SIZE);
        if (!local_buf) {
            ff_jni_exception_check(env, 1, h);
            av_freep(&c->stage);
            return AVERROR(ENOMEM);
        }
        c->stage_ref = (*env)->NewGlobalRef(env, local_buf);
        (*env)->DeleteLocalRef(env, local_buf);
        if (!c->stage_ref) {
            ff_jni_exception_check(env, 1, h);
            av_freep(&c->stage);
            return AVERROR(ENOMEM);
        }
    }
    if (size > FD_STAGE_SIZE)
        size = FD_STAGE_SIZE;

    int bytes_read = (*env)->CallIntMethod(env, c->thiz, c->jfields.okhttp_read_method, c->stage_ref, size);
    if (bytes_read > 0)
        memcpy(buf, c->stage, bytes_read);
"""
    s = s[:i] + stage + s[j + len(call):]
    s = sub(s, "        /* [OOM FIX] Free every cached DirectByteBuffer */\n",
            "        if (c->stage_ref)\n"
            "            (*env)->DeleteGlobalRef(env, c->stage_ref);\n"
            "        c->stage_ref = NULL;\n"
            "        /* [OOM FIX] Free every cached DirectByteBuffer */\n",
            "close stage ref")
    s = sub(s, "    c->buf_slot_next = 0;\n",
            "    c->buf_slot_next = 0;\n    av_freep(&c->stage);\n",
            "close stage free")
    open(out, "w").write(s)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "java":
        java(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 5 and sys.argv[1] == "c":
        c(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        sys.exit(__doc__)
