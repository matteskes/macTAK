package mactak.render;

import com.atakmap.coremap.maps.coords.GeoPoint;
import com.atakmap.map.Globe;
import com.atakmap.map.layer.Layers;
import com.atakmap.map.layer.feature.FeatureLayer3;
import com.atakmap.map.layer.feature.geometry.Envelope;
import com.atakmap.map.layer.raster.DatasetDescriptor;
import com.atakmap.map.layer.raster.DatasetDescriptorFactory2;
import com.atakmap.map.layer.raster.PersistentRasterDataStore;
import com.atakmap.map.layer.raster.mobileimagery.MobileImageryRasterLayer2;
import com.atakmap.map.opengl.GLMapView;

import mactak.headless.LayerStore;

import java.io.BufferedOutputStream;
import java.io.DataOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.util.zip.CRC32;
import java.util.zip.DeflaterOutputStream;

/**
 * G2 M3.2: the Java half of the app shell — the hosted counterpart of
 * {@link RenderSmoke} minus its arg parsing and process exits. The Swift
 * shell (dev/g2/shell) creates the NSWindow/CAMetalLayer, starts the JVM
 * through {@code libjli}, and calls the statics below across JNI; nothing
 * here is reachable from a {@code main} method.
 *
 * <p>Thread topology (NOTES.md §M3, host model A): the caller of
 * {@link #start} is the AppKit main thread — it never touches EGL. This
 * class spawns one render thread that owns the EGL context end-to-end
 * (contexts are single-thread-bound) and runs the RenderSmoke sequence:
 * load the engine natives, EGL init + window surface on the shell's layer,
 * sentinel check, Globe/layers setup, frame loop, readback, PNG artifact.
 *
 * <p>Phases (the shell polls {@link #pollStatus} from a timer on its main
 * thread — the calls are quick and never block on the render thread):
 * <ol>
 * <li>{@link #PHASE_RENDERING} — frames under way; failure jumps straight
 * to EXITED so the shell can close the window and report the code.</li>
 * <li>{@link #PHASE_FRAME_DONE} — the first-frame gate passed: readback
 * done, PNG written, frame presented. The render thread then runs the live
 * loop (M3.3) until {@link #stop}: the window stays live, resizes and
 * follows the backing scale. On the success path only — a failed run
 * reports immediately.</li>
 * <li>{@link #PHASE_EXITED} — teardown done on the render thread (engine,
 * EGL; the shell owns the layer/window). {@link #exitCode} is final.</li>
 * </ol>
 *
 * <p>Exit codes match RenderSmoke: 0 PASS, 1 FAIL, 2 usage/environment,
 * 3 EGL init failed. The shell maps them to its own exit; nothing here
 * calls {@code System.exit} — the shell owns the process, and the JVM is
 * never destroyed ({@code DestroyJavaVM} blocks on lingering non-daemon
 * engine threads; the proven path is shell {@code System.exit}).
 *
 * <p>M3.3, the live loop: after the first frame the render thread keeps
 * rendering and presenting until {@link #stop}. It applies the size the
 * shell hands over in {@link #resize} (the shell sets the layer's
 * drawableSize first: the host's truth), pauses while the shell reports the
 * window occluded ({@link #setVisible}), renders only on
 * {@code requestRefresh} when continuous rendering is off, honours
 * {@code setFrameRate} as a clamp, and logs frame times. With
 * {@code liveMs > 0} it runs a scripted phase first, the M3.3 gate: the
 * camera pans every frame for {@code liveMs} while the shell resizes the
 * window, then the live gate checks presents, GL errors, the resizes and the
 * content at the new size (writes {@code <out>-live.png}).
 *
 * <p>M3.4, gestures: the shell forwards AppKit input through {@link #input}
 * to the {@link InputBridge}, which applies it on the render thread. With
 * {@code gestureKinds != 0} the scripted phase is driven by the gestures the
 * shell injects instead of the automatic pan, and the live gate also
 * requires each injected kind to have been applied and to have moved the
 * camera (pan: the centre; zoom: the resolution; rotate and option-drag:
 * the heading; option-drag: the tilt).
 */
public final class WindowApp {

    public static final int PHASE_RENDERING = 0;
    public static final int PHASE_FRAME_DONE = 1;
    public static final int PHASE_EXITED = 2;

    private static final String TAG = "window-app";

    // ---- shell-visible state (main thread reads, render thread writes) -----
    private static volatile int phase = PHASE_RENDERING;
    private static volatile int exitCode = -1;
    private static volatile boolean stopRequested;
    private static Thread renderThread;
    // Shell → render thread (M3.3): the latest size wins; 0 = nothing pending.
    private static int pendingW, pendingH;
    private static double pendingDpi;
    private static boolean visible = true;
    // Where the first frame put the camera: the scripted pan's anchor.
    private static double camLat = Double.NaN, camLon = Double.NaN, camRes = Double.NaN;
    /** Set once the view exists; read by the AppKit main thread in {@link #input}. */
    private static volatile InputBridge bridge;

    // Teardown bookkeeping: whatever the render body built, for the render
    // thread to release in reverse order once the shell asks for shutdown.
    private static GLMapView view;
    private static Globe globe;
    private static LayerStore store;
    private static PersistentRasterDataStore rasterStore;
    private static EglRenderContext ctx;
    /** NativeEgl.init succeeded: teardown must destroy EGL even when it
     *  failed before the render context existed (G2.5 #7). */
    private static boolean eglUp;

    private WindowApp() { }

    /**
     * Spawn the render thread and return at once (called on the AppKit main
     * thread; JNI upcall from the Swift shell). {@code layerPtr} is the
     * shell's {@code CAMetalLayer*} — opaque here, dereferenced only by the
     * engine's {@code createWindowSurface}.
     *
     * @param w h       surface size in pixels (window points x backing scale)
     * @param atLat atLon camera centre; NaN means frame on content bounds
     * @param res   metres/pixel; NaN means fit content bounds
     * @param dpi   72 x the window's backing scale
     * @param liveMs scripted live phase after the first frame (0: none)
     * @param expectResizes resizes the shell will drive during that phase
     * @param frameLog CSV of the live phase's frame intervals, or null
     * @param scriptedPan pan the camera automatically during the live phase
     * @param gestureKinds bitmask (1 << InputBridge kind) of the gestures the
     *        shell injects during the live phase; the live gate checks them
     */
    public static synchronized void start(long layerPtr, int w, int h,
                                          String[] libs, String eglPath, String glesPath,
                                          String[] layers, String[] basemaps,
                                          String layerDb, String outPath,
                                          double res, double atLat, double atLon,
                                          int frames, long settleMs,
                                          double dpi, long liveMs, int expectResizes,
                                          String frameLog, boolean scriptedPan, int gestureKinds) {
        if (renderThread != null)
            throw new IllegalStateException(TAG + ": start called twice");
        if (layerPtr == 0)
            throw new IllegalArgumentException(TAG + ": null CAMetalLayer (layerPtr == 0)");
        if (w <= 0 || h <= 0)
            throw new IllegalArgumentException(TAG + ": bad surface size " + w + "x" + h);
        if (libs == null || libs.length == 0 || eglPath == null || glesPath == null)
            throw new IllegalArgumentException(TAG + ": --lib/--egl/--gles are required");
        if (frames < 1) throw new IllegalArgumentException(TAG + ": --frames must be >= 1");
        if (settleMs < 0) throw new IllegalArgumentException(TAG + ": --settle must be >= 0");
        if (!(dpi > 0)) throw new IllegalArgumentException(TAG + ": bad dpi " + dpi);
        if (liveMs < 0 || expectResizes < 0) throw new IllegalArgumentException(TAG + ": --live must be >= 0");
        final String[] layerList = (layers == null) ? new String[0] : layers;
        final String[] basemapList = (basemaps == null) ? new String[0] : basemaps;

        phase = PHASE_RENDERING;
        exitCode = -1;
        stopRequested = false;
        renderThread = new Thread(() -> render(layerPtr, w, h, libs, eglPath, glesPath,
                layerList, basemapList, layerDb, outPath, res, atLat, atLon, frames, settleMs,
                dpi, liveMs, expectResizes, frameLog, scriptedPan, gestureKinds),
                "mactak-render");
        renderThread.start();
    }

    /** Current {@code PHASE_*} — non-blocking, safe from the main thread. */
    public static synchronized int pollStatus() { return phase; }

    /** The final exit code; meaningful only once {@link #pollStatus} says EXITED. */
    public static synchronized int exitCode() { return exitCode; }

    /**
     * Ask the render thread to wind down: stops the frame loop mid-run, or
     * wakes it from the frame-done park so it tears down. Non-blocking — the
     * shell keeps polling for PHASE_EXITED instead of joining across JNI.
     */
    public static synchronized void stop() {
        stopRequested = true;
        WindowApp.class.notifyAll();   // the render thread waits on this monitor
    }

    /**
     * The window's backing changed (live resize, or a move to a display with
     * another scale): the shell has set the layer's drawableSize to
     * {@code w x h} pixels; the render thread adopts it before its next
     * frame. Latest call wins. Non-blocking, AppKit main thread.
     */
    public static synchronized void resize(int w, int h, double dpi) {
        if (w <= 0 || h <= 0 || !(dpi > 0)) return;
        pendingW = w;
        pendingH = h;
        pendingDpi = dpi;
        WindowApp.class.notifyAll();
    }

    /**
     * One AppKit input event, already in surface pixels from the upper left
     * ({@link InputBridge.Gesture}). Queued for the render thread; dropped
     * before the view exists. Non-blocking, AppKit main thread.
     */
    public static void input(int kind, float x, float y, float dx, float dy, double amount) {
        final InputBridge b = bridge;
        if (b != null) b.post(new InputBridge.Gesture(kind, x, y, dx, dy, amount));
    }

    /** The window's occlusion state; the loop pauses while it is hidden. */
    public static synchronized void setVisible(boolean isVisible) {
        visible = isVisible;
        WindowApp.class.notifyAll();
    }

    // -----------------------------------------------------------------------
    // The render thread — the RenderSmoke body, verbatim where it draws,
    // reshaped where it exits (exit code + phase instead of System.exit).
    // -----------------------------------------------------------------------

    private static void render(long layerPtr, int w, int h,
                               String[] libs, String eglPath, String glesPath,
                               String[] layers, String[] basemaps,
                               String layerDb, String outPath,
                               double res, double atLat, double atLon,
                               int frames, long settleMs,
                               double dpi, long liveMs, int expectResizes, String frameLog,
                               boolean scriptedPan, int gestureKinds) {
        int code = 1;   // default when stop() arrives before the frame is done
        try {
            for (String lib : libs) System.load(lib);

            eglUp = NativeEgl.init(eglPath, glesPath, w, h);
            if (!eglUp) {
                System.err.println(TAG + ": EGL init failed: "
                        + NativeEgl.getString(NativeEgl.STR_LAST_ERROR));
                finish(3);
                return;
            }
            if (!NativeEgl.makeCurrent()) {
                System.err.println(TAG + ": eglMakeCurrent failed: "
                        + NativeEgl.getString(NativeEgl.STR_LAST_ERROR));
                finish(3);
                return;
            }
            System.out.println(TAG + ": EGL " + NativeEgl.getString(NativeEgl.STR_EGL_VERSION)
                    + " platform=" + NativeEgl.getString(NativeEgl.STR_BACKEND));
            System.out.println(TAG + ": GL_RENDERER=\"" + NativeEgl.getString(NativeEgl.STR_GL_RENDERER) + "\"");
            System.out.println(TAG + ": GL_VERSION=\"" + NativeEgl.getString(NativeEgl.STR_GL_VERSION) + "\"");

            // Swap the init pbuffer for the shell's window surface before
            // anything renders: same display, config and context (M3.1).
            if (!NativeEgl.createWindowSurface(layerPtr, w, h)) {
                System.err.println(TAG + ": window surface failed: "
                        + NativeEgl.getString(NativeEgl.STR_LAST_ERROR));
                finish(3);
                return;
            }
            System.out.println(TAG + ": window surface on the shell's CAMetalLayer (" + w + "x" + h + ")");

            ByteBuffer px = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder());

            // Sentinel: magenta. Our own GL path through the shim must work first.
            NativeEgl.fill(1f, 0f, 1f, 1f);
            NativeEgl.finish();
            if (!NativeEgl.readPixels(px) || countColour(px, w, h, 255, 0, 255) != (long) w * h) {
                System.err.println(TAG + ": FAIL: sentinel fill/readback broken (shim GL path)");
                finish(1);
                return;
            }

            ctx = new EglRenderContext(w, h, dpi);
            px = ctx.readbackBuffer();   // the context owns the readback from here on
            // Initialise the engine BEFORE any native interop: ATAKMapEngineJNI_findClass
            // holds a non-recursive mutex while FindClass runs Java <clinit>s, and
            // GLMapView.<clinit> -> EngineLibrary.initialize -> GLText.<clinit> ->
            // setTextFormatFactory re-enters findClass => self-deadlock.
            com.atakmap.map.EngineLibrary.initialize();
            // the host registers the SDK's GLLayer/GLStyle SPIs (ATAK's MapView does this)
            Layers.registerAll();
            // GdalTileReader is the org.gdal SWIG path (no bindings on macOS); it probes
            // every tile URI first and throws UnsatisfiedLinkError on the GL worker.
            com.atakmap.map.layer.raster.tilereader.TileReaderFactory.unregisterSpi(
                    com.atakmap.map.layer.raster.gdal.GdalTileReader.SPI);
            globe = new Globe();
            view = new GLMapView(ctx, globe, 0, 0, w, h);
            ctx.setGLMapView(view);
            view.start();
            bridge = new InputBridge(view, ctx);

            // --basemap: MBTiles through the raster stack (TilesetLayerInfoSpi ->
            // MBTilesTileReader -> BitmapFactory -> texture). Added first so it
            // draws beneath the vector layers.
            rasterStore = null;
            Envelope rasterBounds = null;
            if (basemaps.length > 0) {
                if (layerDb == null) layerDb = Files.createTempDirectory("mactak-render-layers").toString();
                File rasterDir = new File(layerDb, "raster");
                rasterDir.mkdirs();
                DatasetDescriptorFactory2.register(com.atakmap.android.maps.tilesets.TilesetLayerInfoSpi.INSTANCE);
                rasterStore = new PersistentRasterDataStore(new File(rasterDir, "layers.sqlite"), rasterDir);
                for (String p : basemaps) {
                    File f = new File(p);
                    if (!f.isFile()) {
                        System.err.println(TAG + ": no such basemap: " + f);
                        finish(2);
                        return;
                    }
                    if (!rasterStore.add(f)) {
                        System.err.println(TAG + ": FAIL: no raster provider accepted " + f.getName());
                        finish(1);
                        return;
                    }
                }
                com.atakmap.map.layer.raster.RasterDataStore.DatasetDescriptorCursor c = rasterStore.queryDatasets();
                try {
                    while (c.moveToNext()) {
                        DatasetDescriptor d = c.get();
                        Envelope e = d.getCoverage(null).getEnvelope();
                        System.out.printf(TAG + ": basemap %s type=%s provider=%s res [%.2f .. %.2f] m/px cov lat [%.4f, %.4f] lon [%.4f, %.4f]%n",
                                d.getName(), d.getDatasetType(), d.getProvider(), d.getMaxResolution(null), d.getMinResolution(null), e.minY, e.maxY, e.minX, e.maxX);
                        rasterBounds = rasterBounds == null ? new Envelope(e.minX, e.minY, 0, e.maxX, e.maxY, 0)
                                : union(rasterBounds, e);
                    }
                } finally {
                    c.close();
                }
                globe.addLayer(new MobileImageryRasterLayer2("mactak-basemap", rasterStore, null));
            }

            // --layer: G1.3 feature stack -> FeatureLayer -> globe; frame the camera on it.
            store = null;
            Envelope frame = rasterBounds;
            if (layers.length > 0) {
                if (layerDb == null) layerDb = Files.createTempDirectory("mactak-render-layers").toString();
                store = new LayerStore(layerDb);
                for (String p : layers) store.add(new File(p));
                Envelope b = store.bounds();
                if (b == null) {
                    System.err.println(TAG + ": FAIL: layer(s) have no geometry");
                    finish(1);
                    return;
                }
                System.out.printf(TAG + ": %d feature(s), bounds lat [%.5f, %.5f] lon [%.5f, %.5f]%n",
                        store.featureCount(), b.minY, b.maxY, b.minX, b.maxX);
                globe.addLayer(new FeatureLayer3("mactak-layer", store.dataStore()));
                frame = b;   // vector bounds win: that's what the fixture is about
            }
            if (frame != null) {
                Envelope b = frame;
                double clat = Double.isNaN(atLat) ? (b.minY + b.maxY) / 2 : atLat;
                double clon = Double.isNaN(atLon) ? (b.minX + b.maxX) / 2 : atLon;
                if (Double.isNaN(res)) {
                    // metres spanned by the bounds (+20% margin) over the surface's smaller side
                    double mPerDegLat = 111320d, mPerDegLon = 111320d * Math.cos(Math.toRadians(clat));
                    double spanM = Math.max((b.maxY - b.minY) * mPerDegLat, (b.maxX - b.minX) * mPerDegLon) * 1.2;
                    res = Math.max(spanM / Math.min(w, h), 0.5);
                }
                view.lookAt(new GeoPoint(clat, clon), res, 0d, 0d, false);
                camLat = clat;
                camLon = clon;
                camRes = res;
                System.out.printf(TAG + ": camera (%.5f, %.5f) @ %.2f m/px%n", clat, clon, res);
            }

            int glErrors = 0, presented = 0, swapFails = 0;
            long t0 = System.nanoTime();
            int rendered = 0;
            // Layers load asynchronously: keep pumping frames until settleMs has
            // elapsed (and at least `frames` frames have run). That floor alone
            // raced the layer query on a loaded hosted runner (2026-11-05: 6
            // frames at ~520 ms/frame checked out with content=0 where the same
            // commit had passed 25 minutes earlier), so with content attached the
            // readback is polled as frames run and rendering continues — up to a
            // generous cap — until content pixels have actually appeared.
            boolean hasContent = layers.length > 0 || basemaps.length > 0;
            long deadline = System.currentTimeMillis() + (hasContent ? settleMs : 0);
            long cap = System.currentTimeMillis() + (hasContent ? Math.max(settleMs * 5, 15000) : 0);
            boolean contentSeen = !hasContent;
            for (int i = 0; i < frames || System.currentTimeMillis() < deadline
                    || (!contentSeen && System.currentTimeMillis() < cap); i++) {
                if (stopRequested) break;   // shell is shutting us down mid-run
                ctx.pump();
                view.render();
                NativeEgl.finish();
                rendered++;
                int err;
                while ((err = NativeEgl.getGlError()) != 0) {
                    glErrors++;
                    if (glErrors <= 10) System.err.printf(TAG + ": frame %d GL error 0x%04x%n", i, err);
                }
                if (hasContent) {
                    if (rendered % 4 == 0)      // poll: has the async content landed?
                        contentSeen = NativeEgl.readPixels(px) && countNonClear(px, w, h)
                                >= ContentGate.requiredPixels(w, h, layers.length > 0, basemaps.length > 0);
                    try { Thread.sleep(16); } catch (InterruptedException e) { break; }
                }
                // Present last: once a frame is presented its back buffer's
                // contents are undefined, so nothing reads it past this point.
                if (NativeEgl.swap()) presented++; else swapFails++;
            }
            frames = rendered;
            double msPerFrame = (System.nanoTime() - t0) / 1e6 / Math.max(frames, 1);
            System.out.printf(TAG + ": %d frames, %.1f ms/frame (incl. glFinish), glErrors=%d%n", frames, msPerFrame, glErrors);
            System.out.printf(TAG + ": presented %d frame(s), %d failed present(s)%n", presented, swapFails);

            if (stopRequested) {
                System.err.println(TAG + ": interrupted before the frame completed (window closed early)");
                finish(1);
                return;
            }

            // A presented back buffer's contents are undefined — redraw before
            // the final readback (not counted as a frame; not presented either:
            // the on-screen frame stays whatever the loop last presented).
            view.render();
            NativeEgl.finish();
            boolean readOk = NativeEgl.readPixels(px);
            long sentinel = countColour(px, w, h, 255, 0, 255);
            long content = countNonClear(px, w, h);
            int cx = ((h / 2) * w + w / 2) * 4;
            System.out.printf(TAG + ": sentinel pixels left=%d/%d content pixels=%d centre=(%d,%d,%d,%d)%n",
                    sentinel, (long) w * h, content, px.get(cx) & 0xff, px.get(cx + 1) & 0xff, px.get(cx + 2) & 0xff, px.get(cx + 3) & 0xff);

            if (outPath != null) {
                try {
                    if (outPath.toLowerCase().endsWith(".png")) writePng(outPath, px, w, h); else writePpm(outPath, px, w, h);
                    System.out.println(TAG + ": wrote " + outPath);
                } catch (IOException e) {
                    System.err.println(TAG + ": image write failed: " + e);
                }
            }

            final long required = ContentGate.requiredPixels(w, h, layers.length > 0, basemaps.length > 0);
            boolean pass = readOk && glErrors == 0 && sentinel == 0 && presented > 0 && swapFails == 0
                    && content >= required;
            if (presented == 0) System.err.println(TAG + ": FAIL: no frame was ever presented");
            if (swapFails > 0) System.err.println(TAG + ": FAIL: " + swapFails + " of " + (presented + swapFails) + " presents failed");
            if (content < required)
                System.err.println(TAG + ": FAIL: " + ContentGate.failure(content, required, w, h, basemaps.length > 0));
            System.out.println(pass ? TAG + ": PASS" : TAG + ": FAIL");

            if (!pass) {
                finish(1);
                return;
            }
            code = 0;
        } catch (Throwable t) {
            System.err.println(TAG + ": FAIL: uncaught on the render thread");
            t.printStackTrace();
            code = 1;
        }

        if (code == 0) {
            // Frame on screen, artifact written: publish FRAME_DONE (the
            // shell's linger timer starts on it), then keep the window live
            // until the shell stops us; teardown stays on this thread (the
            // EGL context never leaves it).
            synchronized (WindowApp.class) { phase = PHASE_FRAME_DONE; }
            try {
                code = live(outPath, layers.length > 0, basemaps.length > 0,
                        liveMs, expectResizes, frameLog, scriptedPan, gestureKinds);
            } catch (Throwable t) {
                System.err.println(TAG + ": FAIL: uncaught in the live loop");
                t.printStackTrace();
                code = 1;
            }
        }
        teardown();
        synchronized (WindowApp.class) {
            exitCode = code;
            phase = PHASE_EXITED;
            WindowApp.class.notifyAll();
        }
    }

    // -----------------------------------------------------------------------
    // M3.3: the live loop
    // -----------------------------------------------------------------------

    /** Scripted pan: a full east-west sweep every PAN_PERIOD_S seconds. */
    private static final double PAN_PERIOD_S = 4d;
    /** Pan amplitude as a fraction of the surface width. */
    private static final double PAN_SWING = 0.25;
    private static final long PAUSE_POLL_MS = 16;
    private static final java.lang.management.ThreadMXBean CPU =
            java.lang.management.ManagementFactory.getThreadMXBean();

    /**
     * Render and present until {@link #stop}; render thread only. With
     * {@code liveMs > 0} the first {@code liveMs} are the scripted gate
     * (camera pans every frame; the shell resizes the window meanwhile) and
     * its verdict is the exit code; without a script the window simply stays
     * live and the exit code stays 0. Returns the exit code.
     */
    private static int live(String outPath, boolean hasLayers, boolean hasBasemaps,
                            long liveMs, int expectResizes, String frameLog,
                            boolean scriptedPan, int gestureKinds) throws IOException {
        final Camera before = Camera.now();
        final FrameTimes times = new FrameTimes();
        final long t0 = System.nanoTime();
        final boolean scripted = liveMs > 0;
        boolean scriptDone = !scripted;
        int glErrors = 0, presented = 0, swapFails = 0, resizes = 0;
        long lastPresent = 0;

        while (true) {
            int rw, rh;
            double rdpi;
            boolean show;
            synchronized (WindowApp.class) {
                if (stopRequested) break;
                rw = pendingW;
                rh = pendingH;
                rdpi = pendingDpi;
                pendingW = pendingH = 0;
                show = visible;
                if (rw == 0 && !show) {
                    // occluded: no frames until the shell says we are seen,
                    // resized or stopped (all three notify this monitor)
                    try { WindowApp.class.wait(); } catch (InterruptedException e) { break; }
                    lastPresent = 0;   // a pause is not a frame interval
                    continue;
                }
            }
            if (rw > 0) {
                ctx.setDpi(rdpi);
                if (!ctx.resize(rw, rh)) {
                    System.err.println(TAG + ": FAIL: resize to " + rw + "x" + rh + ": "
                            + NativeEgl.getString(NativeEgl.STR_LAST_ERROR));
                    return 1;
                }
                resizes++;
                ctx.requestRefresh();
                System.out.printf(TAG + ": live: surface now %dx%d px, dpi %.0f%n", rw, rh, rdpi);
                if (!show) continue;
            }
            final boolean scriptRunning = !scriptDone;
            if (!scriptRunning && !ctx.isContinuousRenderEnabled() && !ctx.takeRefreshRequest()) {
                synchronized (WindowApp.class) {
                    try { WindowApp.class.wait(PAUSE_POLL_MS); } catch (InterruptedException e) { break; }
                }
                continue;
            }

            // CPU from here: the queued work (gestures included) and the render
            final long renderCpuStart = CPU.getCurrentThreadCpuTime();
            ctx.pump();
            final long now = System.nanoTime();
            if (scriptRunning && scriptedPan) panStep((now - t0) / 1e9);
            view.render();
            int err;
            while ((err = NativeEgl.getGlError()) != 0) {
                glErrors++;
                if (glErrors <= 10) System.err.printf(TAG + ": live frame GL error 0x%04x%n", err);
            }
            // The engine's cost: CPU time, not wall time. ANGLE's Metal backend
            // takes the next drawable lazily at the first draw, so the wait
            // for the display happens inside render(); blocking is not CPU.
            final long renderNs = CPU.getCurrentThreadCpuTime() - renderCpuStart;
            if (NativeEgl.swap()) presented++; else swapFails++;
            final long presentedAt = System.nanoTime();
            times.add(lastPresent == 0 ? -1 : presentedAt - lastPresent, renderNs);
            lastPresent = presentedAt;
            clampFrameRate(presentedAt);

            if (scriptRunning && presentedAt - t0 >= liveMs * 1_000_000L) {
                scriptDone = true;
                times.report(TAG + ": live", frameLog);
                int verdict = liveGate(outPath, hasLayers, hasBasemaps, glErrors, presented,
                        swapFails, resizes, expectResizes);
                if (gestureKinds != 0 && gestureGate(gestureKinds, before, Camera.now()) != 0) verdict = 1;
                if (verdict != 0) return verdict;
            }
        }
        if (scripted && !scriptDone) {
            System.err.println(TAG + ": FAIL: stopped before the live script finished");
            return 1;
        }
        if (!scripted) times.report(TAG + ": live", frameLog);
        return 0;
    }

    /** The camera, as the gesture gate compares it. Render thread. */
    private record Camera(GeoPoint centre, double gsd, double azimuth, double tilt) {
        static Camera now() {
            final com.atakmap.map.MapSceneModel sm =
                    view.getMapSceneModel(false, com.atakmap.map.MapRenderer3.DisplayOrigin.UpperLeft);
            final InputBridge b = bridge;
            final GeoPoint c = b == null ? null : b.groundAt(ctx.getWidth() / 2f, ctx.getHeight() / 2f);
            return new Camera(c, sm.gsd, sm.camera.azimuth, 90d + sm.camera.elevation);
        }
    }

    /** Equirectangular distance: exact enough for "did the centre move" at map scales. */
    private static double groundMetres(GeoPoint a, GeoPoint b) {
        final double mPerDeg = 111320d;
        final double dy = (b.getLatitude() - a.getLatitude()) * mPerDeg;
        final double dx = (b.getLongitude() - a.getLongitude()) * mPerDeg * Math.cos(Math.toRadians(a.getLatitude()));
        return Math.hypot(dx, dy);
    }

    /** Smallest camera change the gesture gate counts as "moved". */
    private static final double GATE_MIN_DEGREES = 1d, GATE_MIN_ZOOM = 0.05, GATE_MIN_PAN_PX = 5d;

    /**
     * M3.4: every gesture kind the shell injected reached the camera
     * through AppKit, the JNI hop and the render thread, and moved it.
     * Returns 0 or 1.
     */
    private static int gestureGate(int kinds, Camera before, Camera after) {
        final InputBridge b = bridge;
        boolean pass = b != null;
        final StringBuilder counts = new StringBuilder();
        for (int k = 0; k < InputBridge.KINDS; k++) {
            if ((kinds & (1 << k)) == 0) continue;
            final int n = b == null ? 0 : b.applied(k);
            counts.append(' ').append(InputBridge.NAMES[k]).append('=').append(n);
            if (n == 0) {
                System.err.println(TAG + ": FAIL: no " + InputBridge.NAMES[k] + " gesture reached the camera");
                pass = false;
            }
        }
        final double panPx = before.centre() == null || after.centre() == null ? 0d
                : groundMetres(before.centre(), after.centre()) / before.gsd();
        final double zoom = before.gsd() / after.gsd();
        final double turn = Math.abs(((after.azimuth() - before.azimuth()) % 360d + 540d) % 360d - 180d);
        final double tilt = after.tilt() - before.tilt();
        System.out.printf(TAG + ": gestures:%s; camera: centre moved %.0f px, zoom %.2fx, heading %.1f deg, tilt %+.1f deg%n",
                counts, panPx, zoom, turn, tilt);
        final int pan = (1 << InputBridge.DRAG) | (1 << InputBridge.SCROLL);
        final int zooms = (1 << InputBridge.WHEEL) | (1 << InputBridge.MAGNIFY) | (1 << InputBridge.DOUBLE_CLICK);
        final int turns = (1 << InputBridge.ROTATE) | (1 << InputBridge.OPTION_DRAG);
        if ((kinds & pan) != 0 && panPx < GATE_MIN_PAN_PX) { System.err.println(TAG + ": FAIL: the pan gestures did not move the centre"); pass = false; }
        if ((kinds & zooms) != 0 && Math.abs(zoom - 1d) < GATE_MIN_ZOOM) { System.err.println(TAG + ": FAIL: the zoom gestures did not change the resolution"); pass = false; }
        if ((kinds & turns) != 0 && turn < GATE_MIN_DEGREES) { System.err.println(TAG + ": FAIL: the rotate gestures did not turn the heading"); pass = false; }
        if ((kinds & (1 << InputBridge.OPTION_DRAG)) != 0 && Math.abs(tilt) < GATE_MIN_DEGREES) {
            System.err.println(TAG + ": FAIL: option-drag did not tilt the camera");
            pass = false;
        }
        System.out.println(pass ? TAG + ": gestures: PASS" : TAG + ": gestures: FAIL");
        return pass ? 0 : 1;
    }

    /** One step of the scripted pan: the camera swings east and west of where the first frame put it. */
    private static void panStep(double seconds) {
        if (Double.isNaN(camLat)) return;   // no content framed: nothing to pan over
        final double mPerDegLon = 111320d * Math.cos(Math.toRadians(camLat));
        final double swingDeg = PAN_SWING * ctx.getWidth() * camRes / mPerDegLon;
        final double lon = camLon + swingDeg * Math.sin(2 * Math.PI * seconds / PAN_PERIOD_S);
        view.lookAt(new GeoPoint(camLat, lon), camRes, 0d, 0d, false);
    }

    /** {@code setFrameRate} as a clamp: sleep out the rest of the frame's slot. */
    private static void clampFrameRate(long presentedAt) {
        final float rate = ctx.getFrameRate();
        if (rate <= 0f) return;
        final long slotEnd = presentedAt + (long) (1e9 / rate);
        final long sleepNs = slotEnd - System.nanoTime();
        if (sleepNs > 0) {
            try { Thread.sleep(sleepNs / 1_000_000L, (int) (sleepNs % 1_000_000L)); }
            catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        }
    }

    /**
     * The M3.3 gate, after the scripted phase: every present succeeded, no GL
     * error, the shell's resizes all landed, and the content gate holds at
     * the surface's current (resized) size. Writes {@code <out>-live.png}.
     */
    private static int liveGate(String outPath, boolean hasLayers, boolean hasBasemaps,
                                int glErrors, int presented, int swapFails,
                                int resizes, int expectResizes) throws IOException {
        final int w = ctx.getWidth(), h = ctx.getHeight();
        // the back buffer is undefined after a present: draw once more, unpresented
        view.render();
        NativeEgl.finish();
        final ByteBuffer px = ctx.readbackBuffer();
        final boolean readOk = NativeEgl.readPixels(px);
        final long content = countNonClear(px, w, h);
        final long required = ContentGate.requiredPixels(w, h, hasLayers, hasBasemaps);
        System.out.printf(TAG + ": live: %d presented, %d failed, glErrors=%d, resizes=%d (expected %d), "
                + "surface %dx%d, content pixels=%d (need %d)%n",
                presented, swapFails, glErrors, resizes, expectResizes, w, h, content, required);
        if (outPath != null) {
            final String livePath = outPath.replaceFirst("(\\.[A-Za-z]+)?$", "-live$1");
            if (livePath.toLowerCase().endsWith(".png")) writePng(livePath, px, w, h); else writePpm(livePath, px, w, h);
            System.out.println(TAG + ": wrote " + livePath);
        }
        boolean pass = true;
        if (!readOk) { System.err.println(TAG + ": FAIL: live readback failed"); pass = false; }
        if (presented == 0) { System.err.println(TAG + ": FAIL: live phase presented nothing"); pass = false; }
        if (swapFails > 0) { System.err.println(TAG + ": FAIL: " + swapFails + " live present(s) failed"); pass = false; }
        if (glErrors > 0) { System.err.println(TAG + ": FAIL: " + glErrors + " GL error(s) in the live phase"); pass = false; }
        if (resizes < expectResizes) {
            System.err.println(TAG + ": FAIL: " + resizes + " of " + expectResizes + " expected resize(s) reached the surface");
            pass = false;
        }
        if (content < required) {
            System.err.println(TAG + ": FAIL: " + ContentGate.failure(content, required, w, h, hasBasemaps));
            pass = false;
        }
        System.out.println(pass ? TAG + ": live: PASS" : TAG + ": live: FAIL");
        return pass ? 0 : 1;
    }

    /**
     * Frame times of the live loop: the interval between presents (what a
     * viewer sees; the display paces it) and the render thread's CPU time in
     * the queued work (gestures), {@code view.render()} and the GL error
     * drain (what the engine costs on
     * the CPU; GPU time and the wait for a drawable are not in it).
     * {@link #report} prints mean/p50/p95/max and the dropped frames
     * (intervals past {@link #DROPPED_NS}) and, given a path, writes CSV.
     */
    private static final class FrameTimes {
        /** A dropped frame at 60 Hz: an interval past 1.5 refreshes (G2's exit gate, NOTES §M3.3). */
        static final long DROPPED_NS = 25_000_000L;
        private long[] interval = new long[1024];
        private long[] work = new long[1024];
        private int n;

        /** @param intervalNs -1 for the first frame after a start or pause */
        void add(long intervalNs, long workNs) {
            if (n == interval.length) {
                interval = java.util.Arrays.copyOf(interval, n * 2);
                work = java.util.Arrays.copyOf(work, n * 2);
            }
            interval[n] = intervalNs;
            work[n] = workNs;
            n++;
        }

        void report(String tag, String csvPath) throws IOException {
            final long[] iv = java.util.Arrays.stream(interval, 0, n).filter(v -> v >= 0).sorted().toArray();
            final long[] wk = java.util.Arrays.copyOf(work, n);
            java.util.Arrays.sort(wk);
            if (iv.length == 0) {
                System.out.println(tag + ": no frame intervals recorded");
            } else {
                final long dropped = java.util.Arrays.stream(iv).filter(v -> v > DROPPED_NS).count();
                System.out.printf("%s: %d frames; interval ms mean %.2f p50 %.2f p95 %.2f max %.2f (%.1f fps); "
                        + "dropped (>%.0f ms) %d; render CPU ms p50 %.2f p95 %.2f max %.2f%n",
                        tag, n, mean(iv) / 1e6, pct(iv, 50) / 1e6, pct(iv, 95) / 1e6, iv[iv.length - 1] / 1e6,
                        1e9 / mean(iv), DROPPED_NS / 1e6, dropped, pct(wk, 50) / 1e6, pct(wk, 95) / 1e6, wk[wk.length - 1] / 1e6);
            }
            if (csvPath != null) {
                try (java.io.PrintWriter out = new java.io.PrintWriter(new FileOutputStream(csvPath))) {
                    out.println("frame,interval_ms,render_cpu_ms");
                    for (int i = 0; i < n; i++)
                        out.printf("%d,%s,%.3f%n", i, interval[i] < 0 ? "" : String.format("%.3f", interval[i] / 1e6), work[i] / 1e6);
                }
                System.out.println(tag + ": frame log " + csvPath);
            }
        }

        private static double mean(long[] v) {
            double sum = 0;
            for (long x : v) sum += x;
            return sum / v.length;
        }

        /** Nearest-rank percentile of a sorted array. */
        private static long pct(long[] sorted, int p) {
            final int rank = (int) Math.ceil(p / 100d * sorted.length);
            return sorted[Math.max(0, Math.min(sorted.length - 1, rank - 1))];
        }
    }

    /** Record a failure and end the render thread without the live loop. */
    private static void finish(int code) {
        teardown();
        synchronized (WindowApp.class) {
            exitCode = code;
            phase = PHASE_EXITED;
            WindowApp.class.notifyAll();
        }
    }

    /** Release what the render body built, in reverse order — render thread only. */
    private static void teardown() {
        bridge = null;   // no more input once the view goes
        if (view != null) {
            view.stop();
            view.release();
            view = null;
        }
        if (globe != null) {
            globe.dispose();
            globe = null;
        }
        if (store != null) {
            store.close();
            store = null;
        }
        if (rasterStore != null) {
            rasterStore.dispose();
            rasterStore = null;
        }
        ctx = null;
        if (eglUp) {
            NativeEgl.release();
            NativeEgl.destroy();
            eglUp = false;
        }
        // The layer/window stay with the shell — that is its half of the split.
    }

    // -----------------------------------------------------------------------
    // Helpers lifted verbatim from RenderSmoke (its copies are private; the
    // smoke itself stays untouched — fold the duplication away when M3.3
    // makes the app absorb the smoke's roles).
    // -----------------------------------------------------------------------

    private static Envelope union(Envelope a, Envelope b) {
        return new Envelope(Math.min(a.minX, b.minX), Math.min(a.minY, b.minY), 0, Math.max(a.maxX, b.maxX), Math.max(a.maxY, b.maxY), 0);
    }

    /** Pixels that are neither the sentinel nor the engine's black clear. */
    private static long countNonClear(ByteBuffer px, int w, int h) {
        long n = 0;
        for (int i = 0; i < w * h * 4; i += 4) {
            int r = px.get(i) & 0xff, g = px.get(i + 1) & 0xff, b = px.get(i + 2) & 0xff;
            boolean black = r < 8 && g < 8 && b < 8;
            boolean magenta = r == 255 && g == 0 && b == 255;
            if (!black && !magenta) n++;
        }
        return n;
    }

    private static long countColour(ByteBuffer px, int w, int h, int r, int g, int b) {
        long n = 0;
        for (int i = 0; i < w * h * 4; i += 4) {
            if ((px.get(i) & 0xff) == r && (px.get(i + 1) & 0xff) == g && (px.get(i + 2) & 0xff) == b) n++;
        }
        return n;
    }

    /** Minimal PNG writer — RGB8, filter 0 rows, zlib IDAT. Deliberately
     *  AWT-free: BufferedImage/ImageIO drag AWT up inside the shell's process,
     *  where AWT fights our own NSApplication for the AppKit main thread
     *  (JRSAppKitAWT markAppIsDaemon) and the terminate handshake wedges.
     *  RenderSmoke keeps ImageIO — it runs in a standalone JVM, where AWT
     *  owns no thread the shell needs. */
    private static void writePng(String path, ByteBuffer px, int w, int h) throws IOException {
        CRC32 crc = new CRC32();
        try (DataOutputStream d = new DataOutputStream(
                new BufferedOutputStream(new FileOutputStream(path)))) {
            d.write(new byte[]{(byte) 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A});

            byte[] ihdr = new byte[13];
            putU32(ihdr, 0, w);
            putU32(ihdr, 4, h);
            ihdr[8] = 8;    // bit depth
            ihdr[9] = 2;    // colour type: truecolour RGB
            chunk(d, crc, "IHDR", ihdr);

            // The zlib stream is the IDAT chunk's data: deflate into memory,
            // then frame it (length, type, CRC). Writing it straight into the
            // file left a PNG no decoder reads (G2 trap #59).
            java.io.ByteArrayOutputStream idat = new java.io.ByteArrayOutputStream();
            try (DeflaterOutputStream z = new DeflaterOutputStream(idat)) {
                byte[] row = new byte[1 + w * 3];   // filter byte 0 + RGB8
                for (int y = h - 1; y >= 0; y--) {  // GL rows are bottom-up
                    row[0] = 0;
                    for (int x = 0; x < w; x++) {
                        int i = (y * w + x) * 4;
                        row[1 + x * 3]     = px.get(i);
                        row[1 + x * 3 + 1] = px.get(i + 1);
                        row[1 + x * 3 + 2] = px.get(i + 2);
                    }
                    z.write(row);
                }
            }
            chunk(d, crc, "IDAT", idat.toByteArray());
            chunk(d, crc, "IEND", new byte[0]);
        }
    }

    private static void chunk(DataOutputStream d, CRC32 crc, String type, byte[] data) throws IOException {
        byte[] t = type.getBytes("US-ASCII");
        d.writeInt(data.length);
        d.write(t);
        d.write(data);
        crc.reset();
        crc.update(t);
        crc.update(data);
        d.writeInt((int) crc.getValue());
    }

    private static void putU32(byte[] b, int off, int v) {
        b[off]     = (byte) (v >>> 24);
        b[off + 1] = (byte) (v >>> 16);
        b[off + 2] = (byte) (v >>> 8);
        b[off + 3] = (byte) v;
    }

    private static void writePpm(String path, ByteBuffer px, int w, int h) throws IOException {
        try (OutputStream os = new FileOutputStream(path)) {
            os.write(("P6\n" + w + " " + h + "\n255\n").getBytes("US-ASCII"));
            byte[] row = new byte[w * 3];
            for (int y = h - 1; y >= 0; y--) {            // GL rows are bottom-up
                for (int x = 0; x < w; x++) {
                    int i = (y * w + x) * 4;
                    row[x * 3] = px.get(i); row[x * 3 + 1] = px.get(i + 1); row[x * 3 + 2] = px.get(i + 2);
                }
                os.write(row);
            }
        }
    }
}