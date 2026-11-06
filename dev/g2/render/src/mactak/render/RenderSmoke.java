package mactak.render;

import com.atakmap.coremap.maps.coords.GeoPoint;
import com.atakmap.map.Globe;
import com.atakmap.map.layer.Layers;
import com.atakmap.map.layer.feature.Adapters;
import com.atakmap.map.layer.feature.FeatureLayer3;
import com.atakmap.map.layer.feature.geometry.Envelope;
import com.atakmap.map.layer.raster.DatasetDescriptor;
import com.atakmap.map.layer.raster.DatasetDescriptorFactory2;
import com.atakmap.map.layer.raster.PersistentRasterDataStore;
import com.atakmap.map.layer.raster.mobileimagery.MobileImageryRasterLayer2;
import com.atakmap.map.opengl.GLMapView;

import mactak.headless.LayerStore;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;

/**
 * G2.1 spike: the engine's native renderer ({@code GLGlobe} behind
 * {@link GLMapView}) draws into an EGL pbuffer on ANGLE/Metal from a JVM.
 *
 * <p>Pass criterion: the pbuffer is pre-filled with a sentinel colour, then
 * {@code GLMapView.render()} runs N frames; the engine's own clear must have
 * replaced the sentinel everywhere (the G0 stub would leave it untouched),
 * with zero GL errors. With no layers attached, the frame is the engine's
 * clear colour — this proves the GL path, not map content.
 *
 * <p>With {@code --layer FILE} (G2.2) the file is opened through the G1.3
 * feature stack, wrapped in a {@code FeatureLayer}, added to the globe, and
 * the camera framed on its bounds; PASS additionally requires non-clear
 * pixels in the frame — the first map content on macOS.
 *
 * <p>With {@code --window WxH} (M3.1) the EGL surface is a CAMetalLayer
 * window surface from the WindowHost harness instead of the pbuffer — the
 * first real caller of the window path. Frames are presented with
 * {@code NativeEgl.swap()}; PASS additionally requires at least one
 * successful present, no failed ones, and a mid-run {@code --resize} to
 * have gone through the host's layer (drawableSize truth) before
 * {@code ctx.resize()} proves EGL tracks the layer.
 *
 * <p>Exit: 0 PASS, 1 FAIL, 2 usage/environment, 3 EGL init failed.
 */
public final class RenderSmoke {

    private static final String USAGE =
        "usage: RenderSmoke --lib PATH [--lib PATH ...] --egl PATH --gles PATH\n"
      + "                   [--size WxH] [--resize WxH] [--frames N] [--out FILE.ppm]\n"
      + "                   [--layer FILE ...] [--layer-db DIR] [--res M_PER_PX] [--settle MS]\n"
      + "  --lib PATH    native library to System.load (repeatable, in order)\n"
      + "  --egl PATH    ANGLE libEGL.dylib (must sit beside the libGLESv2 the engine links)\n"
      + "  --gles PATH   ANGLE libGLESv2.dylib\n"
      + "  --size WxH    pbuffer size (default 512x512)\n"
      + "  --resize WxH  resize the surface mid-run (before the 2nd frame), the\n"
      + "                M3.1 dynamic-size exercise; PASS requires the resize to\n"
      + "                have gone through and the size-change listener to fire\n"
      + "  --window WxH  render into a CAMetalLayer window surface instead of the pbuffer\n"
      + "                (needs a GUI session; --resize then goes through the host's layer)\n"
      + "  --window-host PATH  the WindowHost dylib (build-window-host.sh); required with --window\n"
      + "  --frames N    frames to render (default 5)\n"
      + "  --out FILE    write the last frame (.png via ImageIO, else binary PPM)\n"
      + "  --layer FILE  vector file to render (GeoJSON/GPKG/KML/SHP; repeatable)\n"
      + "  --basemap F   raster basemap (MBTiles) rendered under the layers (repeatable)\n"
      + "  --layer-db    feature store dir (default: temp)\n"
      + "  --res M       camera resolution, metres/pixel (default: fit layer bounds)\n"
      + "  --at LAT,LON  camera centre (default: layer bounds centre)\n"
      + "  --settle MS   min wall time to keep rendering while layers load (default 3000);\n"
      + "                with content attached, rendering continues (up to 5x that, min 15 s)\n"
      + "                until content pixels have appeared, so a slow runner can't race it\n";

    private RenderSmoke() { }

    public static void main(String[] args) throws IOException {
        List<String> libs = new ArrayList<>();
        List<File> layers = new ArrayList<>();
        List<File> basemaps = new ArrayList<>();
        String egl = null, gles = null, out = null, layerDb = null;
        int w = 512, h = 512, frames = 5;
        int resizeW = 0, resizeH = 0;
        boolean windowMode = false;
        String windowHostLib = null;
        long layerPtr = 0;
        int presented = 0, swapFails = 0;
        boolean hostTruthOk = true;
        long settleMs = 3000;
        double res = Double.NaN;
        double atLat = Double.NaN, atLon = Double.NaN;
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--lib": libs.add(args[++i]); break;
                case "--egl": egl = args[++i]; break;
                case "--gles": gles = args[++i]; break;
                case "--out": out = args[++i]; break;
                case "--frames": frames = Integer.parseInt(args[++i]); break;
                case "--layer": layers.add(new File(args[++i])); break;
                case "--basemap": basemaps.add(new File(args[++i])); break;
                case "--layer-db": layerDb = args[++i]; break;
                case "--res": res = Double.parseDouble(args[++i]); break;
                case "--at": {
                    String[] ll = args[++i].split(",");
                    atLat = Double.parseDouble(ll[0]); atLon = Double.parseDouble(ll[1]);
                    break;
                }
                case "--settle": settleMs = Long.parseLong(args[++i]); break;
                case "--size": {
                    String[] wh = args[++i].split("x");
                    w = Integer.parseInt(wh[0]); h = Integer.parseInt(wh[1]);
                    break;
                }
                case "--resize": {
                    String[] wh = args[++i].split("x");
                    resizeW = Integer.parseInt(wh[0]); resizeH = Integer.parseInt(wh[1]);
                    if (resizeW <= 0 || resizeH <= 0) { System.err.print(USAGE); System.exit(2); }
                    break;
                }
                case "--window-host": windowHostLib = args[++i]; break;
                case "--window": {
                    String[] wh = args[++i].split("x");
                    w = Integer.parseInt(wh[0]); h = Integer.parseInt(wh[1]);
                    if (w <= 0 || h <= 0) { System.err.print(USAGE); System.exit(2); }
                    windowMode = true;
                    break;
                }
                default: System.err.print(USAGE); System.exit(2);
            }
        }
        if (libs.isEmpty() || egl == null || gles == null) { System.err.print(USAGE); System.exit(2); }
        if (windowMode && windowHostLib == null) { System.err.print(USAGE); System.exit(2); }

        for (String lib : libs) System.load(lib);

        if (!NativeEgl.init(egl, gles, w, h)) {
            System.err.println("render-smoke: EGL init failed: " + NativeEgl.getString(NativeEgl.STR_LAST_ERROR));
            System.exit(3);
        }
        if (!NativeEgl.makeCurrent()) {
            System.err.println("render-smoke: eglMakeCurrent failed: " + NativeEgl.getString(NativeEgl.STR_LAST_ERROR));
            System.exit(3);
        }
        System.out.println("render-smoke: EGL " + NativeEgl.getString(NativeEgl.STR_EGL_VERSION)
                + " platform=" + NativeEgl.getString(NativeEgl.STR_BACKEND));
        System.out.println("render-smoke: GL_RENDERER=\"" + NativeEgl.getString(NativeEgl.STR_GL_RENDERER) + "\"");
        System.out.println("render-smoke: GL_VERSION=\"" + NativeEgl.getString(NativeEgl.STR_GL_VERSION) + "\"");

        if (windowMode) {
            // Swap the init pbuffer for the harness's window surface before
            // anything renders: same display, config and context (M3.1).
            WindowHost.load(windowHostLib);
            layerPtr = WindowHost.open(w, h);
            if (layerPtr == 0) {
                System.err.println("render-smoke: window host failed: " + WindowHost.getError());
                System.exit(3);
            }
            if (!NativeEgl.createWindowSurface(layerPtr, w, h)) {
                System.err.println("render-smoke: window surface failed: "
                        + NativeEgl.getString(NativeEgl.STR_LAST_ERROR));
                System.exit(3);
            }
            System.out.println("render-smoke: window surface on the harness CAMetalLayer (" + w + "x" + h + ")");
        }

        ByteBuffer px = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder());

        // Sentinel: magenta. Our own GL path through the shim must work first.
        NativeEgl.fill(1f, 0f, 1f, 1f);
        NativeEgl.finish();
        if (!NativeEgl.readPixels(px) || countColour(px, w, h, 255, 0, 255) != (long) w * h) {
            System.err.println("render-smoke: FAIL: sentinel fill/readback broken (shim GL path)");
            System.exit(1);
        }

        EglRenderContext ctx = new EglRenderContext(w, h, 128d);
        // Watch the event the engine itself consumes: GLMapView registers as
        // the surface's OnSizeChangedListener host-side, so PASS can require
        // the resize to have reached the engine, not just the EGL surface.
        final int[] seenSize = { -1, -1 };
        ctx.addOnSizeChangedListener((surface, nw, nh) -> { seenSize[0] = nw; seenSize[1] = nh; });
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
        Globe globe = new Globe();
        GLMapView view = new GLMapView(ctx, globe, 0, 0, w, h);
        ctx.setGLMapView(view);
        view.start();

        // --basemap: MBTiles through the raster stack (TilesetLayerInfoSpi -> MBTilesTileReader ->
        // BitmapFactory -> texture). Added first so it draws beneath the vector layers.
        PersistentRasterDataStore rasterStore = null;
        Envelope rasterBounds = null;
        if (!basemaps.isEmpty()) {
            if (layerDb == null) layerDb = Files.createTempDirectory("mactak-render-layers").toString();
            File rasterDir = new File(layerDb, "raster");
            rasterDir.mkdirs();
            DatasetDescriptorFactory2.register(com.atakmap.android.maps.tilesets.TilesetLayerInfoSpi.INSTANCE);
            rasterStore = new PersistentRasterDataStore(new File(rasterDir, "layers.sqlite"), rasterDir);
            for (File f : basemaps) {
                if (!f.isFile()) { System.err.println("render-smoke: no such basemap: " + f); System.exit(2); }
                if (!rasterStore.add(f)) { System.err.println("render-smoke: FAIL: no raster provider accepted " + f.getName()); System.exit(1); }
            }
            com.atakmap.map.layer.raster.RasterDataStore.DatasetDescriptorCursor c = rasterStore.queryDatasets();
            try {
                while (c.moveToNext()) {
                    DatasetDescriptor d = c.get();
                    Envelope e = d.getCoverage(null).getEnvelope();
                    System.out.printf("render-smoke: basemap %s type=%s provider=%s res [%.2f .. %.2f] m/px cov lat [%.4f, %.4f] lon [%.4f, %.4f]%n",
                            d.getName(), d.getDatasetType(), d.getProvider(), d.getMaxResolution(null), d.getMinResolution(null), e.minY, e.maxY, e.minX, e.maxX);
                    rasterBounds = rasterBounds == null ? new Envelope(e.minX, e.minY, 0, e.maxX, e.maxY, 0) : union(rasterBounds, e);
                }
            } finally {
                c.close();
            }
            globe.addLayer(new MobileImageryRasterLayer2("mactak-basemap", rasterStore, null));
        }

        // --layer: G1.3 feature stack -> FeatureLayer -> globe; frame the camera on it.
        LayerStore store = null;
        Envelope frame = rasterBounds;
        if (!layers.isEmpty()) {
            if (layerDb == null) layerDb = Files.createTempDirectory("mactak-render-layers").toString();
            store = new LayerStore(layerDb);
            for (File f : layers) store.add(f);
            Envelope b = store.bounds();
            if (b == null) { System.err.println("render-smoke: FAIL: layer(s) have no geometry"); System.exit(1); }
            System.out.printf("render-smoke: %d feature(s), bounds lat [%.5f, %.5f] lon [%.5f, %.5f]%n",
                    store.featureCount(), b.minY, b.maxY, b.minX, b.maxX);
            globe.addLayer(new FeatureLayer3("mactak-layer", Adapters.adapt(store.dataStore())));
            frame = b;   // vector bounds win: that's what the fixture is about
        }
        if (frame != null) {
            Envelope b = frame;
            double clat = Double.isNaN(atLat) ? (b.minY + b.maxY) / 2 : atLat;
            double clon = Double.isNaN(atLon) ? (b.minX + b.maxX) / 2 : atLon;
            if (Double.isNaN(res)) {
                // metres spanned by the bounds (+20% margin) over the pbuffer's smaller side
                double mPerDegLat = 111320d, mPerDegLon = 111320d * Math.cos(Math.toRadians(clat));
                double spanM = Math.max((b.maxY - b.minY) * mPerDegLat, (b.maxX - b.minX) * mPerDegLon) * 1.2;
                res = Math.max(spanM / Math.min(w, h), 0.5);
            }
            view.lookAt(new GeoPoint(clat, clon), res, 0d, 0d, false);
            System.out.printf("render-smoke: camera (%.5f, %.5f) @ %.2f m/px%n", clat, clon, res);
        }

        int glErrors = 0;
        long t0 = System.nanoTime();
        int rendered = 0;
        // Layers load asynchronously: keep pumping frames until settleMs has
        // elapsed (and at least `frames` frames have run). That floor alone
        // raced the layer query on a loaded hosted runner (2026-11-05: 6
        // frames at ~520 ms/frame checked out with content=0 where the same
        // commit had passed 25 minutes earlier), so with content attached the
        // readback is polled as frames run and rendering continues — up to a
        // generous cap — until content pixels have actually appeared.
        boolean hasContent = !layers.isEmpty() || !basemaps.isEmpty();
        long deadline = System.currentTimeMillis() + (hasContent ? settleMs : 0);
        long cap = System.currentTimeMillis() + (hasContent ? Math.max(settleMs * 5, 15000) : 0);
        boolean contentSeen = !hasContent;
        for (int i = 0; i < frames || System.currentTimeMillis() < deadline
                || (!contentSeen && System.currentTimeMillis() < cap); i++) {
            ctx.pump();
            if (resizeW > 0 && rendered == 1) {       // mid-run resize (M3.1)
                if (windowMode) {
                    // The host resizes its layer first, the way a user drag
                    // would; the drawableSize read-back is the host's truth,
                    // and ctx.resize() below proves EGL tracks the layer.
                    if (!WindowHost.resizeWindow(layerPtr, resizeW, resizeH)) {
                        System.err.println("render-smoke: FAIL: host resize refused: " + WindowHost.getError());
                        System.exit(1);
                    }
                    final long truth = WindowHost.drawableSize(layerPtr);
                    hostTruthOk = WindowHost.widthOf(truth) == resizeW && WindowHost.heightOf(truth) == resizeH;
                    if (!hostTruthOk) {
                        System.err.println("render-smoke: FAIL: host layer drawableSize is "
                                + WindowHost.widthOf(truth) + "x" + WindowHost.heightOf(truth)
                                + ", expected " + resizeW + "x" + resizeH);
                        System.exit(1);
                    }
                }
                if (!ctx.resize(resizeW, resizeH)) {
                    System.err.println("render-smoke: FAIL: resize refused: "
                            + NativeEgl.getString(NativeEgl.STR_LAST_ERROR));
                    System.exit(1);
                }
                px = ctx.readbackBuffer();            // re-ask: new size, new buffer
                w = ctx.getWidth(); h = ctx.getHeight();
                System.out.printf("render-smoke: resized to %dx%d, listener saw %dx%d%n",
                        w, h, seenSize[0], seenSize[1]);
                if (windowMode)
                    System.out.println("render-smoke: host layer drawableSize matches the resize");
            }
            view.render();
            NativeEgl.finish();
            rendered++;
            int err;
            while ((err = NativeEgl.getGlError()) != 0) {
                glErrors++;
                if (glErrors <= 10) System.err.printf("render-smoke: frame %d GL error 0x%04x%n", i, err);
            }
            if (hasContent) {
                if (rendered % 4 == 0)      // poll: has the async layer landed?
                    contentSeen = NativeEgl.readPixels(px) && countNonClear(px, w, h) > 0;
                try { Thread.sleep(16); } catch (InterruptedException e) { break; }
            }
            if (windowMode) {
                // Present after the poll read: once a frame is presented its
                // back buffer's contents are undefined, so nothing reads it
                // past this point.
                if (NativeEgl.swap()) presented++; else swapFails++;
            }
        }
        frames = rendered;
        double msPerFrame = (System.nanoTime() - t0) / 1e6 / frames;

        // A presented back buffer's contents are undefined — redraw before
        // the final readback (not counted as a frame; nothing is presented).
        if (windowMode) { view.render(); NativeEgl.finish(); }
        boolean readOk = NativeEgl.readPixels(px);
        long sentinel = countColour(px, w, h, 255, 0, 255);
        long content = countNonClear(px, w, h);
        int cx = ((h / 2) * w + w / 2) * 4;
        System.out.printf("render-smoke: %d frames, %.1f ms/frame (incl. glFinish), glErrors=%d%n", frames, msPerFrame, glErrors);
        if (windowMode)
            System.out.printf("render-smoke: presented %d frame(s), %d failed present(s)%n", presented, swapFails);
        System.out.printf("render-smoke: sentinel pixels left=%d/%d content pixels=%d centre=(%d,%d,%d,%d)%n",
                sentinel, (long) w * h, content, px.get(cx) & 0xff, px.get(cx + 1) & 0xff, px.get(cx + 2) & 0xff, px.get(cx + 3) & 0xff);

        if (out != null) {
            try {
                if (out.toLowerCase().endsWith(".png")) writePng(out, px, w, h); else writePpm(out, px, w, h);
                System.out.println("render-smoke: wrote " + out);
            } catch (IOException e) { System.err.println("render-smoke: image write failed: " + e); }
        }

        view.stop();
        view.release();
        globe.dispose();
        if (store != null) store.close();
        if (rasterStore != null) rasterStore.dispose();
        NativeEgl.release();
        NativeEgl.destroy();
        if (windowMode && layerPtr != 0) WindowHost.close(layerPtr);

        boolean resizeSeen = resizeW <= 0 || (seenSize[0] == resizeW && seenSize[1] == resizeH);
        if (!resizeSeen)
            System.err.println("render-smoke: FAIL: resize listener saw " + seenSize[0] + "x" + seenSize[1]
                    + ", expected " + resizeW + "x" + resizeH);
        boolean windowOk = !windowMode || (hostTruthOk && presented > 0 && swapFails == 0);
        if (windowMode && presented == 0)
            System.err.println("render-smoke: FAIL: no frame was ever presented");
        if (windowMode && swapFails > 0)
            System.err.println("render-smoke: FAIL: " + swapFails + " of " + (presented + swapFails) + " presents failed");
        boolean pass = readOk && glErrors == 0 && sentinel == 0 && resizeSeen
                && (!hasContent || content > 0) && windowOk;
        if (hasContent && content == 0) System.err.println("render-smoke: FAIL: layer attached but frame has no content pixels");
        System.out.println(pass ? "render-smoke: PASS" : "render-smoke: FAIL");
        System.exit(pass ? 0 : 1);
    }

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

    private static void writePng(String path, ByteBuffer px, int w, int h) throws IOException {
        java.awt.image.BufferedImage img = new java.awt.image.BufferedImage(w, h, java.awt.image.BufferedImage.TYPE_INT_RGB);
        for (int y = 0; y < h; y++) {                      // GL rows are bottom-up
            for (int x = 0; x < w; x++) {
                int i = ((h - 1 - y) * w + x) * 4;
                img.setRGB(x, y, ((px.get(i) & 0xff) << 16) | ((px.get(i + 1) & 0xff) << 8) | (px.get(i + 2) & 0xff));
            }
        }
        if (!javax.imageio.ImageIO.write(img, "png", new File(path))) throw new IOException("no PNG writer");
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
