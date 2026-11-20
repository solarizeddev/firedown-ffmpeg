#include <jni.h>
#include <stdint.h>
#include <string.h>
#include <inttypes.h> // PRId64 (FFmpeg 9.0 no longer pulls it in transitively)
#include "libavcodec/ffjni.h"
#include "libavcodec/jni.h"
#include "libavutil/avstring.h"
#include "libavutil/error.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/attributes.h" // Required for av_used
#include "url.h"

#include <time.h>

// Define error codes to match your Java FFmpegOkhttp class
#define OKHTTP_AVERROR_OK           0
#define OKHTTP_AVERROR_EOF         -1
#define OKHTTP_AVERROR_ENOSYS      -2
#define OKHTTP_AVERROR_EINVAL      -3
#define OKHTTP_AVERROR_BAD_REQUEST -4
#define OKHTTP_AVERROR_UNAUTHORIZED -5
#define OKHTTP_AVERROR_FORBIDDEN    -6
#define OKHTTP_AVERROR_NOT_FOUND    -7
#define OKHTTP_AVERROR_TOO_MANY_REQUESTS -8
#define OKHTTP_AVERROR_OTHER_4XX    -9
#define OKHTTP_AVERROR_SERVER_ERROR -10
#define OKHTTP_AVERROR_INTERRUPTED -11

#define SEGMENT_SIZE 8192

struct JNIOkhttpFields {
    jclass okhttp_class;
    jmethodID init_method;
    jmethodID okhttp_open_method;
    jmethodID okhttp_read_method;
    jmethodID okhttp_read_partial_method; /* optional: NULL on an older app */
    jmethodID okhttp_seek_method;
    jmethodID okhttp_close_method;
    jmethodID okhttp_get_mime_method;
    jclass hash_map_class;
    jmethodID hash_map_init_method;
    jmethodID hash_map_put_method;
    jclass bbuf_class;
    jmethodID bbuf_allocate_method;
};

/* Upper bound on ONE read request, by Java read method.
 *
 * FFmpegOkhttp.okhttpRead does not return until it has filled the request or
 * hit end of body, so for it the request size IS the read latency on a slow
 * stream: a 128 kbit/s live stream takes ~2 s to fill 32 KiB but ~33 s to fill
 * the 512 KiB FFmpeg 9.1 asks for (it grew the AVIO buffer of network
 * protocols from 32 KiB to 256 KiB, 512 KiB when is_streamed, and
 * fill_buffer() asks for all of it). 32 KiB is never more than 9.0.x asked.
 *
 * okhttpReadPartial (newer apps) stops filling at its first okio read that
 * ends 10 ms or more into the call. It can still wait for one more arrival
 * while holding bytes (see its javadoc), but never for a whole request, so it
 * can be given 9.1's full 256 KiB: a fast stream fills most of it per JNI
 * call, a slow one still returns in a fraction of a second.
 *
 * Measured by scripts/okhttp-read-bench (real avio + this file + the app's
 * FFmpegOkhttp + OkHttp): first 2 KiB of a 128 kbit/s live stream 2.0 s with
 * okhttpRead at 32 KiB vs 0.24 s with okhttpReadPartial at 256 KiB; JNI calls
 * per MiB on a fast file 32 vs 4.
 *
 * A short read is always legal: fill_buffer() takes what it gets and
 * avio_read() loops for the rest. */
#define FIREDOWN_OKHTTP_MAX_READ 32768
#define FIREDOWN_OKHTTP_PARTIAL_MAX_READ 262144

/* Per-connection read statistics, for comparing read strategies on a real
 * device (scripts/okhttp-read-bench/README.md, "On a device"). Off unless
 * av_log's level is AV_LOG_INFO or more verbose when the connection opens:
 * the app runs at AV_LOG_QUIET and only a debuggable build raises it, from
 * the debug.firedown.fflog system property. When on, the connection logs
 * ONE "okhttp-stats:" line at close; the host benchmark parses the same line.
 *
 * The shadow_* counters record what two ways of dropping the staging copy
 * WOULD have done with this connection's real read addresses — they change
 * nothing, they only count:
 *  - eq:  one DirectByteBuffer over FFmpeg's buffer, keyed by the exact
 *         address, reused when a later request starts at that address and
 *         fits; otherwise re-wrapped;
 *  - rng: up to FIREDOWN_OKHTTP_SHADOW_RANGES wrappers, each over the whole
 *         [buf, buf + requested) range FFmpeg offered, reused for any later
 *         request inside it (Java would be given an offset); FIFO otherwise.
 * hit_bytes is the data that would have skipped the copy; wraps the
 * DirectByteBuffers either would have created. */
#define FIREDOWN_OKHTTP_SHADOW_RANGES 3
#define FIREDOWN_OKHTTP_HIST_BUCKETS 20 /* floor(log2(bytes)), 1 B .. 512 KiB */
struct OkhttpStats {
    int enabled;
    int64_t reads, bytes, read_wall_ns, read_cpu_ns, copy_ns;
    int64_t hist[FIREDOWN_OKHTTP_HIST_BUCKETS];
    const unsigned char *eq_ptr;
    int eq_size;
    int64_t eq_hit_bytes, eq_wraps;
    const unsigned char *rng_ptr[FIREDOWN_OKHTTP_SHADOW_RANGES];
    int rng_size[FIREDOWN_OKHTTP_SHADOW_RANGES];
    int rng_used, rng_next;
    int64_t rng_hit_bytes, rng_wraps;
};

static int64_t okhttp_clock_ns(clockid_t clk)
{
    struct timespec ts;
    if (clock_gettime(clk, &ts) < 0)
        return 0;
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

/* Shadow decisions for one read request; returns a bit mask: 1 eq hit,
 * 2 rng hit. `requested` is what FFmpeg offered (before the clamp), `size`
 * what is actually asked of Java. */
static int okhttp_stats_shadow(struct OkhttpStats *st, const unsigned char *buf,
                               int requested, int size)
{
    int hits = 0;

    if (st->eq_ptr == buf && st->eq_size >= size) {
        hits |= 1;
    } else {
        st->eq_ptr = buf;
        st->eq_size = size;
        st->eq_wraps++;
    }

    for (int i = 0; i < st->rng_used; i++) {
        /* Integer arithmetic: the pointers may belong to unrelated allocations. */
        uintptr_t base = (uintptr_t)st->rng_ptr[i], at = (uintptr_t)buf;
        if (at >= base && at - base <= (uintptr_t)st->rng_size[i] &&
            (uintptr_t)size <= (uintptr_t)st->rng_size[i] - (at - base)) {
            hits |= 2;
            break;
        }
    }
    if (!(hits & 2)) {
        int slot;
        if (st->rng_used < FIREDOWN_OKHTTP_SHADOW_RANGES) {
            slot = st->rng_used++;
        } else {
            slot = st->rng_next;
            st->rng_next = (st->rng_next + 1) % FIREDOWN_OKHTTP_SHADOW_RANGES;
        }
        st->rng_ptr[slot] = buf;
        st->rng_size[slot] = requested;
        st->rng_wraps++;
    }
    return hits;
}

static void okhttp_stats_log(URLContext *h, const struct OkhttpStats *st, int partial)
{
    char hist[FIREDOWN_OKHTTP_HIST_BUCKETS * 24] = "";
    size_t len = 0;

    for (int i = 0; i < FIREDOWN_OKHTTP_HIST_BUCKETS && len < sizeof(hist); i++) {
        if (st->hist[i])
            len += snprintf(hist + len, sizeof(hist) - len, "%s%d:%"PRId64,
                            len ? "," : "", i, st->hist[i]);
    }
    av_log(h, AV_LOG_INFO,
           "okhttp-stats: partial=%d reads=%"PRId64" bytes=%"PRId64
           " read_wall_ns=%"PRId64" read_cpu_ns=%"PRId64" copy_ns=%"PRId64
           " eq_hit_bytes=%"PRId64" eq_wraps=%"PRId64
           " rng_hit_bytes=%"PRId64" rng_wraps=%"PRId64" hist=%s\n",
           partial, st->reads, st->bytes, st->read_wall_ns, st->read_cpu_ns, st->copy_ns,
           st->eq_hit_bytes, st->eq_wraps, st->rng_hit_bytes, st->rng_wraps,
           len ? hist : "-");
}

typedef struct {
    const AVClass *class;
    char *headers;
    char *mime_type;
    struct JNIOkhttpFields jfields;
    jobject thiz;

    /* [OOM FIX] ONE staging buffer per context, wrapped in a DirectByteBuffer
     * ONCE, on the first read: Java reads into it, okhttp_read memcpy()s the
     * bytes to ffmpeg's buffer. Allocating a wrapper per read call created
     * thousands of DirectByteBuffers per HLS download and overwhelmed the
     * GC's Cleaner thread (OOM under concurrent downloads).
     *
     * Why a staging buffer and not a wrapper around ffmpeg's own buffer: the
     * address ffmpeg reads into is not stable. fill_buffer() (aviobuf.c)
     * appends at buf_end while 32 KiB still fits in 9.1's 256/512 KiB
     * buffer, so dst moves with every short read — and a partial read
     * returns a different size each time, so dst lands anywhere. avio_read()'s
     * direct path hands over the CALLER's buffer, advancing it per call. A
     * cache keyed by address therefore misses (the 9.1 bench measured one
     * new wrapper per read for partial reads), and a cached wrapper can
     * outlive the allocation it wrapped. The staging buffer is memory this
     * context owns, sized for the largest request it will make, so the
     * wrapper is created once and is always valid.
     *
     * Cost: one memcpy per read — at loopback speed about 0.3 ms of CPU per
     * MiB in one bench run and nothing measurable in another, nothing a real
     * network shows — and the staging bytes of native memory per open context —
     * FIREDOWN_OKHTTP_MAX_READ (32 KiB) for an older app,
     * FIREDOWN_OKHTTP_PARTIAL_MAX_READ (256 KiB) with okhttpReadPartial —
     * freed by okhttp_close. The open failure path never holds one: it is
     * only created by a read.
     *
     * FFmpegOkhttp still bounds every write by its `size` argument, never by
     * byteBuffer.capacity(); keep it that way on both sides of the bridge. */
    jobject stage_ref;
    unsigned char *stage;

    struct OkhttpStats stats;
} OkhttpContext;

#define OFFSET(x) offsetof(struct JNIOkhttpFields, x)
static const struct FFJniField jfields_okhttp_mapping[] = {
    { "com/solarized/firedown/ffmpegutils/FFmpegOkhttp", NULL, NULL, FF_JNI_CLASS, OFFSET(okhttp_class), 1 },
    { "com/solarized/firedown/ffmpegutils/FFmpegOkhttp", "<init>", "(Ljava/lang/String;Ljava/lang/String;)V", FF_JNI_METHOD, OFFSET(init_method), 1 },
    { "com/solarized/firedown/ffmpegutils/FFmpegOkhttp", "okhttpOpen", "(Ljava/util/Map;)I", FF_JNI_METHOD, OFFSET(okhttp_open_method), 1 },
    { "com/solarized/firedown/ffmpegutils/FFmpegOkhttp", "okhttpRead", "(Ljava/nio/ByteBuffer;I)I", FF_JNI_METHOD, OFFSET(okhttp_read_method), 1 },
    /* Optional (mandatory 0): absent on apps built before it existed, and then
     * NULL, with the NoSuchMethodError cleared and init still returning 0. */
    { "com/solarized/firedown/ffmpegutils/FFmpegOkhttp", "okhttpReadPartial", "(Ljava/nio/ByteBuffer;I)I", FF_JNI_METHOD, OFFSET(okhttp_read_partial_method), 0 },
    { "com/solarized/firedown/ffmpegutils/FFmpegOkhttp", "okhttpSeek", "(JI)J", FF_JNI_METHOD, OFFSET(okhttp_seek_method), 1 },
    { "com/solarized/firedown/ffmpegutils/FFmpegOkhttp", "okhttpClose", "()V", FF_JNI_METHOD, OFFSET(okhttp_close_method), 1 },
    { "com/solarized/firedown/ffmpegutils/FFmpegOkhttp", "okhttpGetMime", "()Ljava/lang/String;", FF_JNI_METHOD, OFFSET(okhttp_get_mime_method), 1 },
    { "java/util/HashMap", NULL, NULL, FF_JNI_CLASS, OFFSET(hash_map_class), 1 },
    { "java/util/HashMap", "<init>", "()V", FF_JNI_METHOD, OFFSET(hash_map_init_method), 1 },
    { "java/util/HashMap", "put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;", FF_JNI_METHOD, OFFSET(hash_map_put_method), 1 },
    { "java/nio/ByteBuffer", NULL, NULL, FF_JNI_CLASS, OFFSET(bbuf_class), 1 },
    { "java/nio/ByteBuffer", "allocateDirect", "(I)Ljava/nio/ByteBuffer;", FF_JNI_STATIC_METHOD, OFFSET(bbuf_allocate_method), 1 },
    { NULL }
};
#undef OFFSET

#define OFFSET(x) offsetof(OkhttpContext, x)
#define D AV_OPT_FLAG_DECODING_PARAM
#define E AV_OPT_FLAG_ENCODING_PARAM
static const AVOption options[] = {
    { "headers", "set custom HTTP headers", OFFSET(headers), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, D | E },
    { "mime_type", "export the MIME type", OFFSET(mime_type), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, AV_OPT_FLAG_EXPORT | AV_OPT_FLAG_READONLY },
    { NULL }
};
#undef OFFSET

static jobject okhttp_get_options(OkhttpContext *c, JNIEnv *env, AVDictionary **options)
{
    jobject meta_map = (*env)->NewObject(env, c->jfields.hash_map_class, c->jfields.hash_map_init_method);
    AVDictionaryEntry *t = NULL;

    if ((*env)->ExceptionCheck(env) || !meta_map) {
        /* Two things must happen before returning, and the old code did
         * neither:
         *
         * 1. CLEAR the pending exception. The caller issues further JNI
         *    calls immediately (CallIntMethod on okhttpOpen), and CheckJNI
         *    aborts the whole process on any JNI call made with an exception
         *    pending ("JNI CallIntMethod called with pending exception").
         * 2. RELEASE the local ref when the object was in fact created (the
         *    ExceptionCheck can be true with a non-NULL meta_map). These
         *    calls arrive on long-lived attached native download threads,
         *    where local refs are NOT reclaimed per call the way they are
         *    when returning to a Java frame — they accumulate until ART's
         *    local reference table (512 entries) overflows and aborts.
         *
         * ff_jni_exception_check does the clearing as well as the logging. */
        ff_jni_exception_check(env, 1, c);
        if (meta_map) {
            (*env)->DeleteLocalRef(env, meta_map);
        }
        return NULL;
    }

    while ((t = av_dict_iterate(*options, t))) {
        jstring key = ff_jni_utf_chars_to_jstring(env, t->key, c);
        jstring value = ff_jni_utf_chars_to_jstring(env, t->value, c);
        if(key && value) {
            jobject prev = (*env)->CallObjectMethod(env, meta_map, c->jfields.hash_map_put_method, key, value);
            if (ff_jni_exception_check(env, 1, c) < 0) {
                if (prev)
                    (*env)->DeleteLocalRef(env, prev);
                if (key)
                    (*env)->DeleteLocalRef(env, key);
                if (value)
                    (*env)->DeleteLocalRef(env, value);
                (*env)->DeleteLocalRef(env, meta_map);
                return NULL;
            }
            if (prev)
                (*env)->DeleteLocalRef(env, prev);
        }
        if(key)
            (*env)->DeleteLocalRef(env, key);
        if(value)
            (*env)->DeleteLocalRef(env, value);
    }
    return meta_map;
}

static int okhttp_close(URLContext *h)
{
    OkhttpContext *c = h->priv_data;
    JNIEnv *env = ff_jni_get_env(h);

    if (c->stats.enabled)
        okhttp_stats_log(h, &c->stats, c->jfields.okhttp_read_partial_method != NULL);

    av_log(h, AV_LOG_DEBUG, "okhttp_close\n");

    /* The early return this used to take on (!env || !c->thiz) skipped
     * EVERYTHING below — the cached DirectByteBuffer global ref, the thiz
     * global ref and the jfields class refs all leaked, plus the mime_type
     * string. That is the same leak class as issue #300, just reached by a
     * rarer door, so it gets the same treatment: release whatever is
     * releasable rather than bailing wholesale.
     *
     * Only the JNI work genuinely needs an env; the native free never did. */
    if (env) {
        if (c->thiz) {
            (*env)->CallVoidMethod(env, c->thiz, c->jfields.okhttp_close_method);
            ff_jni_exception_check(env, 1, h);
            (*env)->DeleteGlobalRef(env, c->thiz);
        }

        /* [OOM FIX] Free the staging buffer's DirectByteBuffer */
        if (c->stage_ref) {
            (*env)->DeleteGlobalRef(env, c->stage_ref);
            av_log(h, AV_LOG_TRACE, "okhttp_close: freed staging DirectByteBuffer\n");
        }

        ff_jni_reset_jfields(env, &c->jfields, jfields_okhttp_mapping, 1, h);
    } else {
        /* Nothing can be released without an env — the global refs are
         * unreachable from here. Log it honestly rather than silently: a
         * URLContext closing on a thread ff_jni_get_env could not attach is
         * itself the anomaly worth seeing. */
        av_log(h, AV_LOG_WARNING,
               "okhttp_close: no JNIEnv — JNI global refs cannot be released\n");
    }

    c->thiz = NULL;
    c->stage_ref = NULL;
    av_freep(&c->stage);

    // FIX #3: free mime_type string
    av_freep(&c->mime_type);

    av_log(h, AV_LOG_DEBUG, "okhttp_close finished\n");
    return 0;
}

static int64_t okhttp_seek(URLContext *h, int64_t off, int whence)
{
    OkhttpContext *c = h->priv_data;
    JNIEnv *env = ff_jni_get_env(h);

    av_log(h, AV_LOG_DEBUG, "okhttp_seek: off=%"PRId64" whence=%d\n", off, whence);

    if (!env) {
        av_log(h, AV_LOG_ERROR, "okhttp_seek: no JNIEnv\n");
        return AVERROR(EINVAL);
    }

    int64_t result = (*env)->CallLongMethod(env, c->thiz, c->jfields.okhttp_seek_method, off, whence);

    /* log_ctx must be a struct whose FIRST member is an AVClass* (av_log
     * dereferences it as one) — h, or c. It must NEVER be c->thiz: a jobject
     * is an opaque JNI handle, and av_log would read a class_name and an
     * item_name FUNCTION POINTER out of whatever that indirection lands on.
     *
     * This matters most in exactly the situation it was hiding: the check
     * only reaches av_log when a Java exception is pending, and okhttpSeek
     * on the Java side has no try/catch at all, so a heap-exhaustion
     * OutOfMemoryError arrives here as a pending exception. The app would
     * then jump through a garbage function pointer — turning a diagnosable
     * java.lang.OutOfMemoryError (issue #300) into a native SIGSEGV. Same
     * fix applied in okhttp_read and okhttp_close. */
    if (ff_jni_exception_check(env, 1, h) < 0) {
        av_log(h, AV_LOG_ERROR, "okhttp_seek: Java exception\n");
        return AVERROR_EXIT;
    }

    if (result == OKHTTP_AVERROR_EOF) {
        av_log(h, AV_LOG_VERBOSE, "okhttp_seek: EOF\n");
        return AVERROR_EOF;
    } else if (result == OKHTTP_AVERROR_INTERRUPTED) {
        av_log(h, AV_LOG_INFO, "okhttp_seek: interrupted\n");
        return AVERROR_EXIT;
    } else if (result == OKHTTP_AVERROR_ENOSYS) {
        av_log(h, AV_LOG_VERBOSE, "okhttp_seek: ENOSYS\n");
        return AVERROR(ENOSYS);
    } else if (result == OKHTTP_AVERROR_EINVAL) {
        av_log(h, AV_LOG_WARNING, "okhttp_seek: EINVAL\n");
        return AVERROR(EINVAL);
    }

    av_log(h, AV_LOG_DEBUG, "okhttp_seek: result=%"PRId64"\n", result);
    return result;
}

static int okhttp_open(URLContext *h, const char *uri, int flags, AVDictionary **options)
{
    OkhttpContext *c = h->priv_data;
    JNIEnv *env = ff_jni_get_env(h);
    jobject object = NULL, url = NULL, headers = NULL, meta_map = NULL, mime_type = NULL;
    int ret = 0;

    memset(&c->stats, 0, sizeof(c->stats));
    c->stats.enabled = av_log_get_level() >= AV_LOG_INFO;

    av_log(h, AV_LOG_DEBUG, "okhttp_open: %s\n", uri);

    if (!env) {
        av_log(h, AV_LOG_ERROR, "okhttp_open: no JNIEnv\n");
        return AVERROR(EINVAL);
    }

    ret = ff_jni_init_jfields(env, &c->jfields, jfields_okhttp_mapping, 1, h);

    if (ret < 0) {
        av_log(h, AV_LOG_ERROR, "okhttp_open: jfields init failed: %d\n", ret);
        return ret;
    }

    url     = ff_jni_utf_chars_to_jstring(env, uri, c);
    headers = ff_jni_utf_chars_to_jstring(env, c->headers ? c->headers : "", c); // FIX #1

    object = (*env)->NewObject(env, c->jfields.okhttp_class, c->jfields.init_method, url, headers);

    if (ff_jni_exception_check(env, 1, h) < 0 || !object) {
        av_log(h, AV_LOG_ERROR, "okhttp_open: NewObject failed\n");
        ret = AVERROR_EXIT;
        goto done;
    }
    c->thiz = (*env)->NewGlobalRef(env, object);

    meta_map = okhttp_get_options(c, env, options);
    ret = (*env)->CallIntMethod(env, c->thiz, c->jfields.okhttp_open_method, meta_map);

    /* Java side may have thrown (e.g. InterruptedException when the worker
     * thread is cancelled mid-open). Clear before any further JNI call so
     * CheckJNI doesn't abort the process on the next callback. */
    if (ff_jni_exception_check(env, 1, h) < 0) {
        av_log(h, AV_LOG_ERROR, "okhttp_open: Java exception from okhttpOpen\n");
        ret = AVERROR_EXIT;
        goto done;
    }

    if (ret < 0) {
        av_log(h, AV_LOG_WARNING, "okhttp_open: Java okhttpOpen returned %d\n", ret);
        switch(ret) {
            case OKHTTP_AVERROR_EOF:           ret = AVERROR_EOF; break;
            case OKHTTP_AVERROR_UNAUTHORIZED:  ret = AVERROR_HTTP_UNAUTHORIZED; break;
            case OKHTTP_AVERROR_FORBIDDEN:     ret = AVERROR_HTTP_FORBIDDEN; break;
            case OKHTTP_AVERROR_NOT_FOUND:     ret = AVERROR_HTTP_NOT_FOUND; break;
            case OKHTTP_AVERROR_INTERRUPTED:   ret = AVERROR_EXIT; break;
            default:                           ret = AVERROR(EIO); break;
        }
        goto done;
    }

    mime_type = (*env)->CallObjectMethod(env, c->thiz, c->jfields.okhttp_get_mime_method);

    if (ff_jni_exception_check(env, 1, h) < 0) {
        av_log(h, AV_LOG_ERROR, "okhttp_open: Java exception from okhttpGetMime\n");
        ret = AVERROR_EXIT;
        goto done;
    }

    if (mime_type) {
        const char *m = (*env)->GetStringUTFChars(env, mime_type, NULL);
        if (m) {
            c->mime_type = av_strdup(m);
            av_log(h, AV_LOG_VERBOSE, "okhttp_open: mime=%s\n", m);
            (*env)->ReleaseStringUTFChars(env, mime_type, m);
        }
    }

    /* Advertise seekability honestly (native http.c does this; this port did
     * not). The protocol always exposes url_seek, so without this the
     * URLContext defaults to seekable even for a chunked segment whose total
     * length we never learned. A "seekable but unknown-size" stream defeats the
     * mov demuxer's read_header early-out ("stop after moov+first mdat" only
     * fires for non-seekable input, or when an atom ends exactly at avio_size),
     * so mov walks every moof/mdat to EOF and downloads the whole fragmented
     * HLS track during avformat_open_input. okhttp_seek(AVSEEK_SIZE) returns the
     * total size, or <0 when unknown. */
    {
        int64_t total = okhttp_seek(h, 0, AVSEEK_SIZE);
        h->is_streamed = (total <= 0);
        av_log(h, AV_LOG_VERBOSE, "okhttp_open: total=%"PRId64" is_streamed=%d\n",
               total, h->is_streamed);
    }

    av_log(h, AV_LOG_DEBUG, "okhttp_open: success\n");

done:

    if (meta_map)
        (*env)->DeleteLocalRef(env, meta_map);
    if (object)
        (*env)->DeleteLocalRef(env, object);
    if (mime_type)
        (*env)->DeleteLocalRef(env, mime_type);
    if (url)
        (*env)->DeleteLocalRef(env, url);
    if (headers)
        (*env)->DeleteLocalRef(env, headers);

    /* [OOM FIX — issue #300] On failure, release everything okhttp_close would.
     *
     * ffmpeg calls url_close (okhttp_close) ONLY for a URLContext that connected
     * successfully: ffurl_closep() gates the close on h->is_connected, which
     * ffurl_connect() sets to 1 only AFTER url_open2 returns 0. When okhttp_open
     * returns an error, ffmpeg just av_freep()s priv_data — okhttp_close never
     * runs — so any JNI global ref created above leaks for the whole process:
     *   - c->thiz pins the FFmpegOkhttp Java object (holding its mUrl/mHeaders
     *     strings — headers can be several KB of cookies), a Java-heap leak;
     *   - the jfields class refs leak entries in the JNI global-ref table.
     * HLS/DASH opens a fresh http URLContext per segment / key / playlist and a
     * meaningful fraction of opens fail (403/404/EOF, cancelled capture probes,
     * live-edge reload storms), so these accumulate until the Java heap is
     * exhausted — the OOM this fixes (victim on an OkHttp TaskRunner thread,
     * heap 254/256 MB). Do the close-equivalent cleanup here, gated on failure
     * so a successful open leaves thiz/jfields intact for read/seek/close. */
    if (ret < 0) {
        if (c->thiz) {
            /* Release the socket deterministically for the rare path where the
             * Java open succeeded but a later JNI step here failed (the object
             * still holds a live Response); harmless when Java okhttpOpen
             * already closed itself on its own error return. Any pending
             * exception was cleared by ff_jni_exception_check above, so these
             * JNI calls are safe. */
            (*env)->CallVoidMethod(env, c->thiz, c->jfields.okhttp_close_method);
            ff_jni_exception_check(env, 1, h);
            (*env)->DeleteGlobalRef(env, c->thiz);
            c->thiz = NULL;
        }
        av_freep(&c->mime_type);
        ff_jni_reset_jfields(env, &c->jfields, jfields_okhttp_mapping, 1, h);
    }

    return ret;
}

static int okhttp_read(URLContext *h, unsigned char *buf, int size)
{
    OkhttpContext *c = h->priv_data;
    JNIEnv *env = ff_jni_get_env(h);
#ifdef PROFILING
    struct timespec start, end;

    // Start timer
    clock_gettime(CLOCK_MONOTONIC, &start);
#endif

    av_log(h, AV_LOG_TRACE, "okhttp_read: size=%d\n", size);

    if (!env) {
        av_log(h, AV_LOG_ERROR, "okhttp_read: no JNIEnv\n");
        return AVERROR(EIO);
    }

    /* Which Java read to call, and how much to ask of it: see
     * FIREDOWN_OKHTTP_MAX_READ. Fixed for the context's lifetime (the method
     * is looked up once, at open), so the staging buffer's size is too. */
    const int partial = c->jfields.okhttp_read_partial_method != NULL;
    const int max_read = partial ? FIREDOWN_OKHTTP_PARTIAL_MAX_READ : FIREDOWN_OKHTTP_MAX_READ;
    const int requested = size;
    if (size > max_read)
        size = max_read;

    if (!c->stage_ref) {
        c->stage = av_malloc(max_read);
        if (!c->stage) {
            av_log(h, AV_LOG_ERROR, "okhttp_read: staging buffer allocation failed\n");
            return AVERROR(ENOMEM);
        }
        av_log(h, AV_LOG_VERBOSE, "okhttp_read: creating staging DirectByteBuffer size=%d partial=%d\n",
               max_read, partial);

        jobject local_buf = (*env)->NewDirectByteBuffer(env, c->stage, max_read);
        if (!local_buf) {
            av_log(h, AV_LOG_ERROR, "okhttp_read: NewDirectByteBuffer failed\n");
            ff_jni_exception_check(env, 1, h);
            av_freep(&c->stage);
            return AVERROR(ENOMEM);
        }
        c->stage_ref = (*env)->NewGlobalRef(env, local_buf);
        (*env)->DeleteLocalRef(env, local_buf);

        if (!c->stage_ref) {
            av_log(h, AV_LOG_ERROR, "okhttp_read: NewGlobalRef failed\n");
            ff_jni_exception_check(env, 1, h);
            av_freep(&c->stage);
            return AVERROR(ENOMEM);
        }
    }

    int shadow_hits = 0;
    int64_t t_wall = 0, t_cpu = 0;
    if (c->stats.enabled) {
        shadow_hits = okhttp_stats_shadow(&c->stats, buf, requested, size);
        t_wall = okhttp_clock_ns(CLOCK_MONOTONIC);
        t_cpu = okhttp_clock_ns(CLOCK_THREAD_CPUTIME_ID);
    }

    int bytes_read = (*env)->CallIntMethod(env, c->thiz,
                                           partial ? c->jfields.okhttp_read_partial_method
                                                   : c->jfields.okhttp_read_method,
                                           c->stage_ref, size);

#ifdef PROFILING
    // End timer
    clock_gettime(CLOCK_MONOTONIC, &end);

    // Calculate nanoseconds
    long diff_ns = (end.tv_sec - start.tv_sec) * 1000000000L + (end.tv_nsec - start.tv_nsec);

    // Log occasionally (e.g., every 100 reads) to avoid log spamming
    static int read_count = 0;
    if (++read_count % 100 == 0) {
        av_log(c, AV_LOG_ERROR, "Read %d bytes | JNI Latency: %ld ns", bytes_read, diff_ns);
    }
#endif

    /* On a pending exception (e.g. InterruptedException from Thread.interrupt
     * during cancel), return AVERROR_EXIT rather than EIO so the demuxer
     * unwinds cleanly instead of retrying into the same trap. */
    /* h, never c->thiz — see the log_ctx note in okhttp_seek. */
    if (ff_jni_exception_check(env, 1, h) < 0) {
        av_log(h, AV_LOG_ERROR, "okhttp_read: Java exception\n");
        return AVERROR_EXIT;
    }

    if (bytes_read > size) {
        /* Java bounds its write by `size`; more means a broken contract and
         * bytes past the request in the staging buffer. Refuse, never copy. */
        av_log(h, AV_LOG_ERROR, "okhttp_read: %d bytes for a %d-byte request\n", bytes_read, size);
        return AVERROR(EIO);
    }
    if (bytes_read > 0) {
        if (c->stats.enabled) {
            struct OkhttpStats *st = &c->stats;
            int64_t t_copy = okhttp_clock_ns(CLOCK_MONOTONIC);
            memcpy(buf, c->stage, bytes_read);
            int64_t t_end = okhttp_clock_ns(CLOCK_MONOTONIC);
            int bucket = 0;
            while (bucket < FIREDOWN_OKHTTP_HIST_BUCKETS - 1 && (bytes_read >> (bucket + 1)))
                bucket++;
            st->reads++;
            st->bytes += bytes_read;
            st->hist[bucket]++;
            st->copy_ns += t_end - t_copy;
            st->read_wall_ns += t_end - t_wall;
            st->read_cpu_ns += okhttp_clock_ns(CLOCK_THREAD_CPUTIME_ID) - t_cpu;
            if (shadow_hits & 1)
                st->eq_hit_bytes += bytes_read;
            if (shadow_hits & 2)
                st->rng_hit_bytes += bytes_read;
        } else {
            memcpy(buf, c->stage, bytes_read);
        }
        av_log(h, AV_LOG_TRACE, "okhttp_read: %d bytes\n", bytes_read);
        return bytes_read;
    }
    if (bytes_read == 0) {
        av_log(h, AV_LOG_DEBUG, "okhttp_read: EAGAIN\n");
        return AVERROR(EAGAIN);
    }
    if (bytes_read == OKHTTP_AVERROR_INTERRUPTED) {
        av_log(h, AV_LOG_INFO, "okhttp_read: interrupted\n");
        return AVERROR_EXIT;
    }

    av_log(h, AV_LOG_VERBOSE, "okhttp_read: EOF\n");
    return AVERROR_EOF;
}


#define HTTP_CLASS(flavor)                          \
static const AVClass flavor ## _context_class = {   \
    .class_name = # flavor,                         \
    .item_name  = av_default_item_name,             \
    .option     = options,                          \
    .version    = LIBAVUTIL_VERSION_INT,            \
}


HTTP_CLASS(http);
const URLProtocol ff_http_protocol = {
    .name                = "http",
    .url_open2           = okhttp_open,
    .url_read            = okhttp_read,
    .url_seek            = okhttp_seek,
    .url_close           = okhttp_close,
    .priv_data_size      = sizeof(OkhttpContext),
    .priv_data_class     = &http_context_class,
    .flags               = URL_PROTOCOL_FLAG_NETWORK,
    .default_whitelist   = "http,https,tls,tcp,udp,crypto,data"
};



HTTP_CLASS(https);
const URLProtocol ff_https_protocol = {
    .name                = "https",
    .url_open2           = okhttp_open,
    .url_read            = okhttp_read,
    .url_seek            = okhttp_seek,
    .url_close           = okhttp_close,
    .priv_data_size      = sizeof(OkhttpContext),
    .priv_data_class     = &https_context_class,
    .flags               = URL_PROTOCOL_FLAG_NETWORK,
    .default_whitelist   = "http,https,tls,tcp,udp,crypto,data"
};
