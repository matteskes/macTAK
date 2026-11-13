package com.atakmap.map;

import android.content.Context;
import com.atakmap.map.opengl.GLRenderGlobals;
import com.atakmap.util.ConfigOptions;
import gov.tak.api.commons.graphics.DisplaySettings;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.JarURLConnection;
import java.net.URL;
import java.nio.file.Files;
import java.util.Enumeration;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;

/**
 * macOS host bootstrap for the engine — shadows upstream's
 * {@code engine/src/jre/.../EngineLibrary} (the desktop-JOGL host), which the
 * published {@code java}-target jar carries and {@code Globe}, {@code GLMapView},
 * {@code ConfigOptions}, {@code Unsafe}, {@code GdalLibrary} invoke from their
 * static initialisers. Upstream's version cannot run here: it unpacks natives
 * from jar resources through the android-port {@code Context} (throws), and its
 * last statement registers a JOGL hook whose anonymous class references
 * {@code javax.media.opengl.GL} (NoClassDefFoundError without JOGL jars).
 *
 * <p>This class must precede the engine jar on the classpath. Spike-grade
 * mechanism: the proper fix is an engine jar built for a {@code macos} host
 * source set instead of {@code jre}. What it keeps from upstream is the
 * platform {@link ConfigOptions} defaults and the GL globals' context; natives
 * are loaded by the host ({@code System.load} in the launcher), not here.
 */
public final class EngineLibrary {

    private static final AtomicBoolean initialized = new AtomicBoolean(false);
    private static Context runtimeContext;

    private EngineLibrary() { }

    public static void initialize() {
        if (initialized.getAndSet(true))
            return;

        // same defaults as upstream's jre host
        ConfigOptions.setOption("glmapview.tilt-skew-offset", 1.0);
        ConfigOptions.setOption("glmapview.tilt-skew-mult", 2.5);
        ConfigOptions.setOption("terrain.constrain-query-res", 1);
        ConfigOptions.setOption("terrain.fill-with-hi-res", 0);
        ConfigOptions.setOption("terrain.legacy-elevation-api", 0);
        ConfigOptions.setOption("terrain.resadj", 1.0);
        ConfigOptions.setOption("gltext.use-font-bins", 0);
        // Android's default, not the desktop one (G2 exit run, trap #76):
        // screen-to-ground ray casts (MapRenderer.inverse, every gesture
        // event) intersect the terrain meshes on the CPU. The desktop default
        // (1) picks terrain tiles on the GPU and reads them back, which
        // waits for all queued GPU work in the middle of a frame. The option
        // gates only that choice (GLGlobe, GLMapView2).
        ConfigOptions.setOption("glmapview.surface-rendering-v2", 0);

        // GLSLUtil resolves shader sources from Android raw resources; the jar
        // carries them at resources/raw/*. Unpack once and hand GLSLUtil the
        // directory instead (its Context path would hit the stub Resources).
        try {
            ConfigOptions.setOption("glslutil.additional-shader-source-paths", unpackShaders().getAbsolutePath());
        } catch (IOException e) {
            System.err.println("EngineLibrary: shader unpack failed: " + e);
        }

        // android-port compile stub: a bare object, enough for the null checks
        runtimeContext = new Context();
        GLRenderGlobals.appContext = runtimeContext;

        // force GLText's static init: installs the default TextFormatFactory
        // (native GLText2 dereferences it — SIGSEGV in getTextFormat() without)
        com.atakmap.opengl.GLText.localize(null);

        DisplaySettings.setDpi(300f);

        Runtime.getRuntime().addShutdownHook(new Thread(new Runnable() {
            @Override public void run() { shutdown(); }
        }));
    }

    public static void shutdown() {
        shutdownImpl();
    }

    private static final String SHADER_PREFIX = "resources/raw/";

    /** Copies {@code resources/raw/*} out of the jar that holds {@code GLSLUtil}'s shaders. */
    private static File unpackShaders() throws IOException {
        URL probe = EngineLibrary.class.getResource("/" + SHADER_PREFIX + "gl20fp_vector2d_vsh");
        if (probe == null) throw new IOException("no " + SHADER_PREFIX + " on the classpath");
        File dir = Files.createTempDirectory("mactak-shaders").toFile();
        dir.deleteOnExit();
        if (!"jar".equals(probe.getProtocol())) {
            return new File(probe.getPath()).getParentFile();   // exploded classes dir
        }
        JarFile jar = ((JarURLConnection) probe.openConnection()).getJarFile();
        for (Enumeration<JarEntry> e = jar.entries(); e.hasMoreElements();) {
            JarEntry entry = e.nextElement();
            if (entry.isDirectory() || !entry.getName().startsWith(SHADER_PREFIX)) continue;
            File out = new File(dir, entry.getName().substring(SHADER_PREFIX.length()));
            out.deleteOnExit();
            try (InputStream in = jar.getInputStream(entry); OutputStream os = new FileOutputStream(out)) {
                byte[] buf = new byte[8192];
                for (int n; (n = in.read(buf)) > 0;) os.write(buf, 0, n);
            }
        }
        return dir;
    }

    // JNI exports in libtakenginejni keyed by this class name (jenginelibrary.cpp)
    static native void shutdownImpl();

    static native void initJOGL();
}
