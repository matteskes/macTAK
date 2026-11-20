package mactak.render;

import java.util.Locale;

import com.atakmap.coremap.maps.coords.GeoPoint;
import com.atakmap.map.MapSceneModel;
import com.atakmap.math.PointD;

/**
 * G3.8b's click checks, for RenderSmoke:
 *
 * <ul>
 *   <li>{@code --expect-ground LAT,LON}: the point goes to its pixel through
 *       the scene model ({@code forward}), and a click there must come back
 *       ({@link MapPick#ground}, the model's {@code inverse}) within a pixel's
 *       worth of ground</li>
 *   <li>{@code --expect-marker LAT,LON,UID}: a click a few pixels off that
 *       point must pick the marker {@code UID} ({@link MapMarkers#markerAt});
 *       {@code UID} "none" wants no marker there.</li>
 * </ul>
 */
record PickExpectation(double lat, double lon, String uid) {

    /** How far off the point the marker click lands, pixels each way. */
    static final float CLICK_OFFSET = 6f;
    /** The hit radius the app uses: half a 32-point icon at 2x. */
    static final float RADIUS = 32f;

    static PickExpectation parseGround(String spec) {
        final String[] p = spec.split(",");
        if (p.length != 2) throw new IllegalArgumentException("want LAT,LON, got " + spec);
        return new PickExpectation(Double.parseDouble(p[0]), Double.parseDouble(p[1]), null);
    }

    static PickExpectation parseMarker(String spec) {
        final String[] p = spec.split(",");
        if (p.length != 3 || p[2].isEmpty()) throw new IllegalArgumentException("want LAT,LON,UID, got " + spec);
        return new PickExpectation(Double.parseDouble(p[0]), Double.parseDouble(p[1]), p[2]);
    }

    /** Check against the scene the frame drew with; prints the comparison. */
    boolean check(MapSceneModel scene, MapMarkers markers) {
        final PointD at = new PointD(0d, 0d);
        scene.forward(new GeoPoint(lat, lon), at);
        return uid == null ? checkGround(scene, at) : checkMarker(scene, markers, at);
    }

    private boolean checkGround(MapSceneModel scene, PointD at) {
        final double[] got = MapPick.ground(scene, (float) at.x, (float) at.y);
        final double off = got == null ? Double.NaN : metres(lat, lon, got[0], got[1]);
        final boolean ok = got != null && off <= scene.gsd;
        System.out.printf(Locale.US, "render-smoke: pick (%.5f, %.5f) -> pixel (%.1f, %.1f) -> %s, %.2f m off (gsd %.2f): %s%n",
                lat, lon, at.x, at.y, got == null ? "nothing" : String.format(Locale.US, "(%.5f, %.5f)", got[0], got[1]),
                off, scene.gsd, ok ? "ok" : "FAIL");
        return ok;
    }

    private boolean checkMarker(MapSceneModel scene, MapMarkers markers, PointD at) {
        final String got = markers == null ? null
                : markers.markerAt(scene, (float) at.x + CLICK_OFFSET, (float) at.y + CLICK_OFFSET, RADIUS);
        final boolean ok = uid.equals("none") ? got == null : uid.equals(got);
        System.out.printf(Locale.US, "render-smoke: click near (%.5f, %.5f) picks %s, want %s: %s%n",
                lat, lon, got == null ? "none" : got, uid, ok ? "ok" : "FAIL");
        return ok;
    }

    /** Equirectangular: exact enough over a pixel. */
    private static double metres(double lat1, double lon1, double lat2, double lon2) {
        final double k = 111_320d;
        final double dy = (lat2 - lat1) * k, dx = (lon2 - lon1) * k * Math.cos(Math.toRadians(lat1));
        return Math.hypot(dx, dy);
    }
}
