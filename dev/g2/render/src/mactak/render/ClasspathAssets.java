package mactak.render;

import android.content.Context;
import android.content.res.AssetManager;

import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;

/**
 * The Android context the render path hands the engine, serving assets from
 * the classpath: {@code getAssets().open("icons/x.png")} reads the resource
 * {@code assets/icons/x.png}, where takkernel's desktop jar packages
 * {@code src/main/assets} (as upstream's desktop build reads them).
 *
 * <p>Why: the android-port substitute's {@code Context.getAssets()} returns
 * null (it is a compile-time stand-in), so every {@code asset:} URI the
 * engine resolved through {@code GLBitmapLoader}'s asset loader failed, and
 * the engine retried on a new thread each frame (point icons such as
 * {@code asset:/icons/reference_point.png}: G2 NOTES §Asset icons). Both
 * substitute classes are concrete and non-final, so this subclasses them
 * instead of replacing them; every other {@code Context} method keeps the
 * substitute's behaviour.
 */
final class ClasspathAssets {

    private ClasspathAssets() { }

    /** The one context the render path hands out. */
    static final Context CONTEXT = new AssetContext();

    private static final class AssetContext extends Context {
        private final AssetManager assets = new ClasspathAssetManager();

        @Override public AssetManager getAssets() { return assets; }
    }

    private static final class ClasspathAssetManager extends AssetManager {
        private static final String ROOT = "assets/";

        @Override
        public InputStream open(String path) throws IOException {
            final String name = ROOT + (path.startsWith("/") ? path.substring(1) : path);
            final InputStream in = ClasspathAssets.class.getClassLoader().getResourceAsStream(name);
            if (in == null) throw new FileNotFoundException("no asset on the classpath: " + name);
            return in;
        }

        /** Listing a classpath directory is not needed by the render path; nothing is listed. */
        @Override
        public String[] list(String path) {
            return new String[0];
        }
    }
}
