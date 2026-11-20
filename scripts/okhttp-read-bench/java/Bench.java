import com.solarized.firedown.data.di.NetworkModule;

import java.util.concurrent.TimeUnit;

import okhttp3.OkHttpClient;

/**
 * okhttp-read-bench driver. One JVM per (native variant, Java strategy).
 *
 *   java [-Dfd.deadlineMs=N] Bench <libpath> <label> <url> <chunk> <maxBytes> <timeLimitMs> <reps>
 *
 * Prints one line per rep: label, then the native stats (see bench_jni.c).
 */
public final class Bench {
    static native long[] run(String url, int chunk, long maxBytes, long timeLimitMs);

    public static void main(String[] a) {
        System.load(a[0]);
        // Same timeouts as the app's NetworkModule client.
        NetworkModule.globalClient = new OkHttpClient.Builder()
                .connectTimeout(15, TimeUnit.SECONDS)
                .readTimeout(30, TimeUnit.SECONDS)
                .writeTimeout(30, TimeUnit.SECONDS)
                .callTimeout(0, TimeUnit.MILLISECONDS)
                .build();
        String label = a[1], url = a[2];
        int chunk = Integer.parseInt(a[3]);
        long maxBytes = Long.parseLong(a[4]), limit = Long.parseLong(a[5]);
        int reps = Integer.parseInt(a[6]);
        for (int r = 0; r < reps; r++) {
            long[] s = run(url, chunk, maxBytes, limit);
            StringBuilder sb = new StringBuilder(label);
            for (long v : s) sb.append(' ').append(v);
            System.out.println(sb);
        }
        System.out.flush();
        System.exit(0); // OkHttp's pool threads would otherwise keep the JVM up
    }
}
