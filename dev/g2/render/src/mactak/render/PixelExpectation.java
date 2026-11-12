package mactak.render;

import com.atakmap.coremap.maps.coords.GeoPoint;
import com.atakmap.map.MapRenderer3;
import com.atakmap.map.MapSceneModel;
import com.atakmap.math.PointD;

import java.nio.ByteBuffer;
import java.util.Locale;

/**
 * {@code RenderSmoke --expect LAT,LON,RRGGBB}: the frame's pixel over a
 * ground point must be a given colour. It checks georeferencing, not just
 * coverage: a raster drawn in the wrong place (axis order, the wrong
 * projection) still fills the frame and passes the content gate, but puts
 * the wrong colour over a known point. The point goes through the camera's
 * own scene model (GLMapView.forward is an upstream stub: G2 trap #64).
 */
record PixelExpectation(double lat, double lon, int rgb) {

    /** Per-channel slack: texture filtering and the reprojection blur edges. */
    static final int TOLERANCE = 12;

    static PixelExpectation parse(String spec) {
        final String[] p = spec.split(",");
        if (p.length != 3 || p[2].length() != 6)
            throw new IllegalArgumentException("want LAT,LON,RRGGBB, got " + spec);
        return new PixelExpectation(Double.parseDouble(p[0]), Double.parseDouble(p[1]), Integer.parseInt(p[2], 16));
    }

    /**
     * Check against a GL readback (RGBA8, rows bottom-up, {@code w x h}).
     * Prints the comparison; returns whether it holds.
     */
    boolean check(MapRenderer3 renderer, ByteBuffer px, int w, int h) {
        final MapSceneModel sm = renderer.getMapSceneModel(false, MapRenderer3.DisplayOrigin.UpperLeft);
        final PointD at = new PointD(0d, 0d);
        sm.forward(new GeoPoint(lat, lon), at);
        final int x = (int) Math.round(at.x), y = (int) Math.round(at.y);
        final boolean onScreen = x >= 0 && x < w && y >= 0 && y < h;
        int got = -1;
        if (onScreen) {
            final int i = ((h - 1 - y) * w + x) * 4;   // GL rows are bottom-up
            got = ((px.get(i) & 0xff) << 16) | ((px.get(i + 1) & 0xff) << 8) | (px.get(i + 2) & 0xff);
        }
        final boolean ok = onScreen && near(got, rgb);
        System.out.printf(Locale.US, "render-smoke: expect (%.5f, %.5f) -> pixel (%d, %d) = %s, want #%06x: %s%n",
                lat, lon, x, y, onScreen ? String.format("#%06x", got) : "off-frame", rgb, ok ? "ok" : "FAIL");
        return ok;
    }

    private static boolean near(int a, int b) {
        for (int shift = 0; shift <= 16; shift += 8)
            if (Math.abs(((a >> shift) & 0xff) - ((b >> shift) & 0xff)) > TOLERANCE) return false;
        return true;
    }
}
