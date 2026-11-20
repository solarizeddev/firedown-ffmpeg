package com.solarized.firedown.utils;

public final class BrowserHeaders {
    public static final String RANGES = "Range";
    public static final String ACCEPT_RANGES = "Accept-Ranges";

    public static String getDefaultUserAgentString() {
        return "okhttp-read-bench";
    }
}
