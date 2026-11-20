package android.util;

/** Stub: only errors are printed, so logging never skews a timing. */
public final class Log {
    public static int d(String tag, String msg) { return 0; }
    public static int i(String tag, String msg) { return 0; }
    public static int w(String tag, String msg) { return 0; }
    public static int w(String tag, String msg, Throwable t) { return 0; }
    public static int e(String tag, String msg) {
        System.err.println("E/" + tag + ": " + msg);
        return 0;
    }
    public static int e(String tag, String msg, Throwable t) {
        System.err.println("E/" + tag + ": " + msg + ": " + t);
        return 0;
    }
}
