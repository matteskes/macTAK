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
 * <li>{@link #PHASE_FRAME_DONE} — PASS candidate: readback done, PNG
 * written, last frame presented. The render thread parks (the window stays
 * up, frame on screen) until {@link #stop} or the shell's linger expires.
 * On the success path only — a failed run reports immediately.</li>
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
 * <p>Not in this gate (M3.3): live resize, real dpi (the surface is built
 * with RenderSmoke's 128 m/px placeholder), Retina calibration.
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

    // Teardown bookkeeping: whatever the render body built, for the render
    // thread to release in reverse order once the shell asks for shutdown.
    private static GLMapView view;
    private static Globe globe;
    private static LayerStore store;
    private static PersistentRasterDataStore rasterStore;
    private static EglRenderContext ctx;

    private WindowApp() { }

    /**
     * Spawn the render thread and return at once (called on the AppKit main
     * thread; JNI upcall from the Swift shell). {@code layerPtr} is the
     * shell's {@code CAMetalLayer*} — opaque here, dereferenced only by the
     * engine's {@code createWindowSurface}.
     *
     * @param atLat atLon camera centre; NaN means frame on content bounds
     * @param res   metres/pixel; NaN means fit content bounds
     */
    public static synchronized void start(long layerPtr, int w, int h,
                                          String[] libs, String eglPath, String glesPath,
                                          String[] layers, String[] basemaps,
                                          String layerDb, String outPath,
                                          double res, double atLat, double atLon,
                                          int frames, long settleMs) {
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
        final String[] layerList = (layers == null) ? new String[0] : layers;
        final String[] basemapList = (basemaps == null) ? new String[0] : basemaps;

        phase = PHASE_RENDERING;
        exitCode = -1;
        stopRequested = false;
        renderThread = new Thread(() -> render(layerPtr, w, h, libs, eglPath, glesPath,
                layerList, basemapList, layerDb, outPath, res, atLat, atLon, frames, settleMs),
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
        WindowApp.class.notifyAll();   // the render thread parks on this monitor
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
                               int frames, long settleMs) {
        int code = 1;   // default when stop() arrives before the frame is done
        try {
            for (String lib : libs) System.load(lib);

            if (!NativeEgl.init(eglPath, glesPath, w, h)) {
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

            ctx = new EglRenderContext(w, h, 128d);
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
            // shell's linger timer starts on it), then hold the window up
            // for the shell's linger / until the user closes it, then tear
            // down on this thread (the EGL context never leaves it).
            synchronized (WindowApp.class) {
                phase = PHASE_FRAME_DONE;
                while (!stopRequested) {
                    try {
                        WindowApp.class.wait();
                    } catch (InterruptedException e) {
                        break;
                    }
                }
            }
        }
        teardown();
        synchronized (WindowApp.class) {
            exitCode = code;
            phase = PHASE_EXITED;
            WindowApp.class.notifyAll();
        }
    }

    /** Record a failure and end the render thread without parking. */
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
        if (ctx != null) {
            NativeEgl.release();
            NativeEgl.destroy();
            ctx = null;
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

            DeflaterOutputStream z = new DeflaterOutputStream(d);
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
            z.finish();                          // flushes the zlib stream; d stays open
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