package mactak.render;

import com.atakmap.coremap.maps.coords.GeoPoint;
import com.atakmap.map.CameraController;
import com.atakmap.map.MapRenderer3;
import com.atakmap.map.MapSceneModel;
import com.atakmap.math.PointD;

/**
 * G2 M3.4: the map's gestures, interpreted JVM-side (NOTES §M3,
 * "Architecture (committed)"): the Swift shell forwards each AppKit event as
 * a {@link Gesture} record in surface pixels, upper-left origin; this class
 * maps it onto the engine's own gesture entry points
 * ({@link CameraController.Interactive}) on the render thread, the way
 * upstream's Android {@code AtakMapController} does.
 *
 * <p>The map follows Apple Maps (decided 2026-11-12, NOTES "Gesture map"):
 * <pre>
 *   drag, two-finger scroll   pan: the content follows the pointer
 *   mouse wheel, pinch        zoom about the point under the pointer
 *   two-finger rotate         rotate about the point under the pointer
 *   option-drag               up: tilt toward the horizon; right: turn clockwise
 *                             (about the centre, 0.25 degrees per point)
 *   double-click              zoom in 2x about the point under the pointer
 * </pre>
 * Motion is immediate ({@code animate = false}): direct manipulation tracks
 * the fingers frame by frame.
 */
final class InputBridge {

    /** Gesture kinds; the shell sends these numbers across JNI. */
    static final int DRAG = 0, SCROLL = 1, WHEEL = 2, MAGNIFY = 3, ROTATE = 4, OPTION_DRAG = 5, DOUBLE_CLICK = 6;
    static final int KINDS = 7;
    static final String[] NAMES = { "drag", "scroll", "wheel", "magnify", "rotate", "option-drag", "double-click" };

    /** Zoom per wheel line (a notch). */
    static final double WHEEL_ZOOM_PER_LINE = 1.1;
    /** Degrees of tilt or rotation per point of option-drag. */
    static final double OPTION_DRAG_DEGREES_PER_POINT = 0.25;
    static final double DOUBLE_CLICK_ZOOM = 2d;

    /**
     * One input event. {@code x, y}: the pointer, in surface pixels from the
     * upper left. {@code dx, dy}: how far the content should move, pixels
     * (drag, scroll, option-drag). {@code amount}: wheel lines (positive zooms
     * in), magnification (0.1 = 10% larger), or rotation in degrees
     * (positive is counter-clockwise, as AppKit reports it).
     */
    record Gesture(int kind, float x, float y, float dx, float dy, double amount) { }

    private final MapRenderer3 renderer;
    private final EglRenderContext ctx;
    private final int[] applied = new int[KINDS];

    InputBridge(MapRenderer3 renderer, EglRenderContext ctx) {
        this.renderer = renderer;
        this.ctx = ctx;
    }

    /** Any thread: queue the gesture for the render thread and ask for a frame. */
    void post(Gesture g) {
        if (g.kind() < 0 || g.kind() >= KINDS) return;
        ctx.queueEvent(() -> apply(g));
        ctx.requestRefresh();
    }

    /** How many gestures of {@code kind} have been applied. Render thread. */
    int applied(int kind) { return applied[kind]; }

    /** Apply one gesture to the camera. Render thread only. */
    void apply(Gesture g) {
        switch (g.kind()) {
            case DRAG, SCROLL -> pan(g.dx(), g.dy());
            case WHEEL -> zoomAt(g.x(), g.y(), Math.pow(WHEEL_ZOOM_PER_LINE, g.amount()));
            case MAGNIFY -> zoomAt(g.x(), g.y(), Math.max(1d + g.amount(), 0.1d));
            case ROTATE -> rotateAt(g.x(), g.y(), g.amount());
            case OPTION_DRAG -> {
                final double perPixel = OPTION_DRAG_DEGREES_PER_POINT / backingScale();
                final float cx = ctx.getWidth() / 2f, cy = ctx.getHeight() / 2f;
                if (g.dy() != 0f) tiltAt(cx, cy, -g.dy() * perPixel);    // drag up: tilt toward the horizon
                if (g.dx() != 0f) rotateAt(cx, cy, -g.dx() * perPixel);  // drag right: turn clockwise, like a dial
            }
            case DOUBLE_CLICK -> zoomAt(g.x(), g.y(), DOUBLE_CLICK_ZOOM);
            default -> { return; }
        }
        applied[g.kind()]++;
    }

    /** The content moves by (dx, dy): the camera moves the other way (upstream's panBy convention). */
    private void pan(float dx, float dy) {
        CameraController.Interactive.panBy(renderer, -dx, -dy, MapRenderer3.CameraCollision.AdjustFocus, false);
    }

    private void zoomAt(float x, float y, double factor) {
        final MapRenderer3.CameraCollision collide =
                factor > 1d ? MapRenderer3.CameraCollision.Abort : MapRenderer3.CameraCollision.AdjustFocus;
        final GeoPoint focus = groundAt(x, y);
        if (focus != null)
            CameraController.Interactive.zoomBy(renderer, factor, focus, x, y, collide, false);
        else
            CameraController.Interactive.zoomBy(renderer, factor, collide, false);
    }

    private void rotateAt(float x, float y, double degrees) {
        final MapSceneModel sm = renderer.getMapSceneModel(false, MapRenderer3.DisplayOrigin.UpperLeft);
        final GeoPoint focus = groundAt(x, y);
        if (focus != null)
            CameraController.Interactive.rotateTo(renderer, sm.camera.azimuth + degrees, focus, x, y,
                    MapRenderer3.CameraCollision.AdjustFocus, false);
        else
            CameraController.Programmatic.rotateTo(renderer, sm.camera.azimuth + degrees, false);
    }

    private void tiltAt(float x, float y, double degrees) {
        final MapSceneModel sm = renderer.getMapSceneModel(false, MapRenderer3.DisplayOrigin.UpperLeft);
        final GeoPoint focus = groundAt(x, y);
        if (focus != null)
            CameraController.Interactive.tiltBy(renderer, degrees, focus, x, y,
                    MapRenderer3.CameraCollision.AdjustFocus, false);
        else
            CameraController.Programmatic.tiltTo(renderer, degrees + 90d + sm.camera.elevation, false);
    }

    /** The ground under a surface pixel (upper-left origin), or null off the world. */
    GeoPoint groundAt(float x, float y) {
        final GeoPoint result = GeoPoint.createMutable();
        return renderer.inverse(new PointD(x, y), result, MapRenderer3.InverseMode.RayCast, 0,
                MapRenderer3.DisplayOrigin.UpperLeft) != MapRenderer3.InverseResult.None ? result : null;
    }

    /** Pixels per point: dpi / 72 (the shell sets dpi = 72 x backing scale). */
    private double backingScale() {
        return Math.max(ctx.getDpi() / 72d, 1d);
    }
}
