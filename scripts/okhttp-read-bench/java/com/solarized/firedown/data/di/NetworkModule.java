package com.solarized.firedown.data.di;

import okhttp3.OkHttpClient;

/** Stub: Bench installs a client configured like the app's (timeouts). */
public final class NetworkModule {
    public static volatile OkHttpClient globalClient;

    public static void evictIdleConnections() {
        OkHttpClient c = globalClient;
        if (c != null) c.connectionPool().evictAll();
    }
}
