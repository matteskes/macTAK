package android.net;

/**
 * Issue 161 (missing-member mode, dev/g1/jni-tests/run.sh): an
 * {@code android.net.Uri} without the static {@code parse(String)} the engine
 * looks up. It goes ahead of the kernel jars, so the class loads but a class
 * init that looks up {@code Uri.parse} fails with NoSuchMethodError, the case
 * a healthy JVM never shows.
 */
public final class Uri
{
    private Uri() {}
}
