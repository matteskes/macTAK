package mactak.render;

import com.atakmap.coremap.maps.coords.GeoPoint;
import com.atakmap.map.Globe;
import com.atakmap.map.MapRenderer3;
import com.atakmap.map.MapSceneModel;
import com.atakmap.map.layer.Layers;
import com.atakmap.map.opengl.GLMapView;
import com.atakmap.math.PointD;

/**
 * M3.4 gesture canary (render/test/input-bridge.sh; CI's render job): the
 * Apple Maps gesture map, checked where the user sees it, on the engine's
 * own camera through an EGL pbuffer (no window, so CI runs it). Each check
 * resets the camera, applies one {@link InputBridge.Gesture} and renders
 * until the camera settles (the engine eases even an immediate move over a
 * few frames):
 *
 *   drag / scroll   the ground under the pointer moves with it
 *   wheel / pinch   resolution scales by the gesture's factor and the
 *   double-click    ground under the pointer stays under it
 *   rotate          the content turns by the gesture's angle about the
 *                   pointer (positive: counter-clockwise on screen)
 *   option-drag     up tilts toward the horizon; right turns the content
 *                   clockwise about the centre (0.25 deg per point)
 *
 * usage: InputBridgeSelfTest --lib PATH [--lib PATH ...] --egl PATH --gles PATH
 * Exit 0 = every check passed.
 */
public final class InputBridgeSelfTest {
    private static final int SIZE = 512;
    /** 2x, as on a Retina display: 72 x 2 dpi. */
    private static final double DPI = 144d;
    private static final GeoPoint HOME = new GeoPoint(37.79, -122.45);
    private static final double HOME_RES = 10d;
    /** Screen positions must land within this many pixels. */
    private static final double PX_TOLERANCE = 1.5;
    private static final double DEG_TOLERANCE = 0.25;
    private static final double RATIO_TOLERANCE = 0.01;

    private static int failures;
    private static GLMapView view;
    private static InputBridge bridge;
    private static EglRenderContext ctx;
    /** The engine eases even an immediate camera move over a few frames (3 for lookAt). */
    private static final int SETTLE_MAX_FRAMES = 30;

    private InputBridgeSelfTest() { }

    private static void check(boolean ok, String behaviour) {
        System.out.println((ok ? "PASS: " : "FAIL: ") + behaviour);
        if (!ok) failures++;
    }

    public static void main(String[] args) {
        String egl = null, gles = null;
        final java.util.List<String> libs = new java.util.ArrayList<>();
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--lib" -> libs.add(args[++i]);
                case "--egl" -> egl = args[++i];
                case "--gles" -> gles = args[++i];
                default -> { System.err.println("input-bridge: unknown option " + args[i]); System.exit(2); }
            }
        }
        if (libs.isEmpty() || egl == null || gles == null) {
            System.err.println("usage: InputBridgeSelfTest --lib PATH [--lib PATH ...] --egl PATH --gles PATH");
            System.exit(2);
        }
        for (String lib : libs) System.load(lib);
        if (!NativeEgl.init(egl, gles, SIZE, SIZE) || !NativeEgl.makeCurrent()) {
            System.err.println("input-bridge: EGL init failed: " + NativeEgl.getString(NativeEgl.STR_LAST_ERROR));
            System.exit(3);
        }
        ctx = new EglRenderContext(SIZE, SIZE, DPI);
        com.atakmap.map.EngineLibrary.initialize();   // before any native interop (WindowApp explains)
        Layers.registerAll();
        final Globe globe = new Globe();
        view = new GLMapView(ctx, globe, 0, 0, SIZE, SIZE);
        ctx.setGLMapView(view);
        view.start();
        bridge = new InputBridge(view, ctx);
        dragFollowsPointer(InputBridge.DRAG, 80f, 30f);
        dragFollowsPointer(InputBridge.SCROLL, -40f, 60f);
        zoomAboutPointer(InputBridge.WHEEL, 3d, Math.pow(InputBridge.WHEEL_ZOOM_PER_LINE, 3), 300f, 200f);
        zoomAboutPointer(InputBridge.MAGNIFY, 0.5d, 1.5d, 150f, 350f);
        zoomAboutPointer(InputBridge.DOUBLE_CLICK, 0d, InputBridge.DOUBLE_CLICK_ZOOM, 256f, 256f);
        rotateAboutPointer();
        optionDragTilts();
        optionDragTurns();

        view.stop();
        view.release();
        globe.dispose();
        NativeEgl.release();
        NativeEgl.destroy();
        System.out.println("input-bridge: " + (failures == 0 ? "PASS" : "FAIL (" + failures + ")"));
        System.exit(failures == 0 ? 0 : 1);
    }

    // ---- checks ------------------------------------------------------------

    private static void dragFollowsPointer(int kind, float dx, float dy) {
        reset();
        final float x = 200f, y = 250f;
        final GeoPoint under = bridge.groundAt(x, y);
        apply(new InputBridge.Gesture(kind, x + dx, y + dy, dx, dy, 0d));
        final PointD now = screenOf(under);
        check(near(now, x + dx, y + dy), String.format("%s by (%.0f, %.0f) px keeps the ground under the pointer "
                + "(lands at (%.1f, %.1f), want (%.1f, %.1f))", InputBridge.NAMES[kind], dx, dy, now.x, now.y, x + dx, y + dy));
    }

    private static void zoomAboutPointer(int kind, double amount, double factor, float x, float y) {
        reset();
        final double gsd0 = scene().gsd;
        final GeoPoint under = bridge.groundAt(x, y);
        apply(new InputBridge.Gesture(kind, x, y, 0f, 0f, amount));
        final double ratio = gsd0 / scene().gsd;
        final PointD now = screenOf(under);
        check(Math.abs(ratio / factor - 1d) <= RATIO_TOLERANCE,
                String.format("%s zooms in %.3fx (want %.3fx)", InputBridge.NAMES[kind], ratio, factor));
        check(near(now, x, y), String.format("%s keeps the ground under the pointer (at (%.1f, %.1f), want (%.0f, %.0f))",
                InputBridge.NAMES[kind], now.x, now.y, x, y));
    }

    private static void rotateAboutPointer() {
        reset();
        final float px = 256f, py = 256f;
        final double degrees = 30d;
        // a ground point 100 px east of the pivot must swing counter-clockwise by 30 degrees
        final GeoPoint east = bridge.groundAt(px + 100f, py);
        apply(new InputBridge.Gesture(InputBridge.ROTATE, px, py, 0f, 0f, degrees));
        final double r = Math.toRadians(degrees);
        final double wantX = px + 100d * Math.cos(r), wantY = py - 100d * Math.sin(r);   // y grows downward
        final PointD now = screenOf(east);
        check(near(now, wantX, wantY), String.format("rotate +%.0f deg turns the content counter-clockwise about the pointer "
                + "(east point at (%.1f, %.1f), want (%.1f, %.1f))", degrees, now.x, now.y, wantX, wantY));
    }

    private static void optionDragTilts() {
        reset();
        final double tilt0 = tilt();
        final float dyPx = -40f;   // 20 points up at 2x
        final double want = -dyPx / (DPI / 72d) * InputBridge.OPTION_DRAG_DEGREES_PER_POINT;
        apply(new InputBridge.Gesture(InputBridge.OPTION_DRAG, 256f, 216f, 0f, dyPx, 0d));
        final double got = tilt() - tilt0;
        check(Math.abs(got - want) <= DEG_TOLERANCE,
                String.format("option-drag up %.0f px tilts toward the horizon by %.2f deg (want %.2f)", -dyPx, got, want));
    }

    private static void optionDragTurns() {
        reset();
        final float c = SIZE / 2f;
        final float dxPx = 40f;    // 20 points right at 2x
        final double degrees = dxPx / (DPI / 72d) * InputBridge.OPTION_DRAG_DEGREES_PER_POINT;
        final GeoPoint east = bridge.groundAt(c + 100f, c);
        apply(new InputBridge.Gesture(InputBridge.OPTION_DRAG, c + dxPx, c, dxPx, 0f, 0d));
        final double r = Math.toRadians(degrees);
        final double wantX = c + 100d * Math.cos(r), wantY = c + 100d * Math.sin(r);   // clockwise: east point dips
        final PointD now = screenOf(east);
        check(near(now, wantX, wantY), String.format("option-drag right %.0f px turns the content clockwise by %.1f deg "
                + "(east point at (%.1f, %.1f), want (%.1f, %.1f))", dxPx, degrees, now.x, now.y, wantX, wantY));
    }

    // ---- helpers -----------------------------------------------------------

    private static void reset() {
        view.lookAt(HOME, HOME_RES, 0d, 0d, false);
        settle();
    }

    private static void apply(InputBridge.Gesture g) {
        bridge.apply(g);
        settle();
    }

    /** Render until the camera stops moving: the centre and resolution repeat. */
    private static void settle() {
        GeoPoint last = null;
        double lastGsd = Double.NaN;
        for (int i = 0; i < SETTLE_MAX_FRAMES; i++) {
            ctx.pump();
            view.render();
            NativeEgl.finish();
            while (NativeEgl.getGlError() != 0) { /* the render gates own GL errors */ }
            final GeoPoint c = bridge.groundAt(SIZE / 2f, SIZE / 2f);
            final double gsd = scene().gsd;
            if (last != null && c != null && gsd == lastGsd
                    && Math.abs(c.getLatitude() - last.getLatitude()) < 1e-9
                    && Math.abs(c.getLongitude() - last.getLongitude()) < 1e-9) return;
            last = c;
            lastGsd = gsd;
        }
        System.err.println("input-bridge: the camera did not settle within " + SETTLE_MAX_FRAMES + " frames");
    }

    private static MapSceneModel scene() {
        return view.getMapSceneModel(false, MapRenderer3.DisplayOrigin.UpperLeft);
    }

    /** 0 looking straight down; grows toward the horizon (upstream: 90 + elevation). */
    private static double tilt() {
        return 90d + scene().camera.elevation;
    }

    private static PointD screenOf(GeoPoint g) {
        final PointD p = new PointD(0d, 0d);
        scene().forward(g, p);   // the camera's own projection, upper-left origin
        return p;
    }

    private static boolean near(PointD p, double x, double y) {
        return Math.hypot(p.x - x, p.y - y) <= PX_TOLERANCE;
    }
}
