package com.solarized.firedown.ffmpegutils;

import java.util.HashMap;
import java.util.Map;

/**
 * Stub: the real FFmpegUtils pulls in Guava and half the app. FFmpegOkhttp
 * only calls stringToMap, copied verbatim (with its SEPARATOR) from
 * app/src/main/java/com/solarized/firedown/ffmpegutils/FFmpegUtils.java.
 */
public final class FFmpegUtils {
    private static final String SEPARATOR = "\r\n";

    public static Map<String, String> stringToMap(String headers) {
        Map<String, String> headersMap = new HashMap<>();
        if (headers != null) {
            String[] headersRaw = headers.split(SEPARATOR);
            for (String s : headersRaw) {
                String[] array = s.split("=", 2);
                if (array.length >= 2) {
                    headersMap.put(array[0], array[1]);
                }
            }
        }
        return headersMap;
    }
}
