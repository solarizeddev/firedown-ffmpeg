/*
 * Native side of the okhttp read benchmark: FFmpeg's REAL avio layer (host
 * libavformat 9.x) over the fork's REAL http.c variant, driven from a JVM so
 * FFmpegOkhttp (the app's real class) and OkHttp run exactly as on Android,
 * minus ART.
 *
 * Bench.run(url, chunk, maxBytes, timeLimitMs) opens url with avio_open2(),
 * avio_read()s it chunk bytes at a time until maxBytes, EOF or the time limit,
 * checks every byte against the server's pattern (byte p == p % 251), and
 * returns the stats below. okhttp_read calls and DirectByteBuffer wraps are
 * counted from http.c's own av_log lines, matched on the FORMAT string in the
 * log callback (nothing is formatted, so counting costs a strcmp per line).
 */
#include <jni.h>
#include <stdarg.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

#include "libavcodec/jni.h"
#include "libavformat/avio.h"
#include "libavutil/log.h"
#include "libavutil/mem.h"

enum {
    ST_BYTES, ST_NS_TOTAL, ST_NS_FIRST_2K, ST_NS_FIRST_32K, ST_CPU_NS,
    ST_READ_CALLS, ST_DBB_WRAPS, ST_BAD_BYTES, ST_MAX_GAP_NS, ST_OPEN_ERR,
    ST_PARTIAL, /* http.c's partial flag from its staging log line; -1: none */
    ST_N
};

static _Thread_local int64_t read_calls, dbb_wraps, partial_flag;

static void log_cb(void *avcl, int level, const char *fmt, va_list vl)
{
    if (!fmt)
        return;
    if (!strncmp(fmt, "okhttp_read: size=", 18))
        read_calls++;
    else if (!strncmp(fmt, "okhttp_read: creating", 21)) {
        dbb_wraps++;
        /* "...staging DirectByteBuffer size=%d partial=%d": which Java read
         * method http.c chose, so a row can't silently measure the fallback. */
        if (strstr(fmt, "partial=%d")) {
            va_list ap;
            va_copy(ap, vl);
            (void)va_arg(ap, int);
            partial_flag = va_arg(ap, int);
            va_end(ap);
        }
    }
    else if (level <= AV_LOG_ERROR)
        av_log_default_callback(avcl, level, fmt, vl);
}

static int64_t now_ns(clockid_t clk)
{
    struct timespec ts;
    clock_gettime(clk, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved)
{
    av_jni_set_java_vm(vm, NULL);
    av_log_set_level(AV_LOG_TRACE);
    av_log_set_callback(log_cb);
    return JNI_VERSION_1_6;
}

JNIEXPORT jlongArray JNICALL Java_Bench_run(JNIEnv *env, jclass cls, jstring jurl,
                                            jint chunk, jlong max_bytes, jlong time_limit_ms)
{
    int64_t st[ST_N] = { 0 };
    const char *url = (*env)->GetStringUTFChars(env, jurl, NULL);
    AVIOContext *pb = NULL;
    uint8_t *buf = av_malloc(chunk);
    int64_t t0, cpu0, last, deadline, got = 0, bad = 0;

    read_calls = dbb_wraps = 0;
    partial_flag = -1;
    st[ST_NS_FIRST_2K] = st[ST_NS_FIRST_32K] = -1;
    t0 = now_ns(CLOCK_MONOTONIC);
    cpu0 = now_ns(CLOCK_THREAD_CPUTIME_ID);
    deadline = t0 + time_limit_ms * 1000000;

    int ret = avio_open2(&pb, url, AVIO_FLAG_READ, NULL, NULL);
    if (ret < 0 || !buf) {
        st[ST_OPEN_ERR] = ret < 0 ? ret : -1;
        goto end;
    }
    last = now_ns(CLOCK_MONOTONIC);
    while (got < max_bytes) {
        int want = (int)FFMIN((int64_t)chunk, max_bytes - got);
        int n = avio_read(pb, buf, want);
        int64_t t = now_ns(CLOCK_MONOTONIC);
        if (n <= 0)
            break;
        for (int i = 0; i < n; i++)
            bad += buf[i] != (uint8_t)((got + i) % 251);
        got += n;
        if (t - last > st[ST_MAX_GAP_NS] && got > n)  /* gaps after the first read */
            st[ST_MAX_GAP_NS] = t - last;
        last = t;
        if (st[ST_NS_FIRST_2K] < 0 && got >= 2048)
            st[ST_NS_FIRST_2K] = t - t0;
        if (st[ST_NS_FIRST_32K] < 0 && got >= 32768)
            st[ST_NS_FIRST_32K] = t - t0;
        if (t > deadline)
            break;
    }

end:
    st[ST_NS_TOTAL] = now_ns(CLOCK_MONOTONIC) - t0;
    st[ST_CPU_NS] = now_ns(CLOCK_THREAD_CPUTIME_ID) - cpu0;
    st[ST_BYTES] = got;
    st[ST_BAD_BYTES] = bad;
    st[ST_READ_CALLS] = read_calls;
    st[ST_DBB_WRAPS] = dbb_wraps;
    st[ST_PARTIAL] = partial_flag;
    avio_closep(&pb);
    av_free(buf);
    (*env)->ReleaseStringUTFChars(env, jurl, url);

    jlongArray out = (*env)->NewLongArray(env, ST_N);
    (*env)->SetLongArrayRegion(env, out, 0, ST_N, (const jlong *)st);
    return out;
}
