package mactak.render;

import com.atakmap.coremap.maps.coords.GeoPoint;
import com.atakmap.map.MapRenderer3;
import com.atakmap.map.MapSceneModel;
import com.atakmap.math.PointD;

import java.nio.ByteBuffer;
import java.util.Locale;

/**
 * {@code RenderSmoke --expect-run LAT,LON,LAT,LON,RRGGBB,MIN,MAX[,TOL]}
 * (G3.10b): of the frame's pixels on the straight run between two ground
 * points' pixels, between MIN and MAX percent must be a given colour,
 * within TOL per channel ({@link PixelExpectation#TOLERANCE} by default).
 * One pixel can't tell a dashed line from a solid one, or an outlined line
 * from a plain one; the share of a run can: along a dashed line some
 * pixels are the gaps, and across an outlined line over a light ground
 * some are its dark edge. A thin line falls between pixel rows, so its
 * pixels are never quite its colour, and its edge is a blend: TOL says how
 * near counts. Each point goes through the camera's own scene model, as
 * {@link PixelExpectation} does.
 */
record RunExpectation(double lat0, double lon0, double lat1, double lon1, int rgb, double minPercent,
                      double maxPercent, int tolerance) {

    static RunExpectation parse(String spec) {
        final String[] p = spec.split(",");
        if ((p.length != 7 && p.length != 8) || p[4].length() != 6)
            throw new IllegalArgumentException("want LAT,LON,LAT,LON,RRGGBB,MIN,MAX[,TOL], got " + spec);
        final double min = Double.parseDouble(p[5]), max = Double.parseDouble(p[6]);
        if (min < 0 || max > 100 || min > max)
            throw new IllegalArgumentException("want 0 <= MIN <= MAX <= 100, got " + spec);
        final int tolerance = p.length == 8 ? Integer.parseInt(p[7]) : PixelExpectation.TOLERANCE;
        return new RunExpectation(Double.parseDouble(p[0]), Double.parseDouble(p[1]), Double.parseDouble(p[2]),
                Double.parseDouble(p[3]), Integer.parseInt(p[4], 16), min, max, tolerance);
    }

    /**
     * Check against a GL readback (RGBA8, rows bottom-up, {@code w x h}).
     * Prints the share found; returns whether it holds. A run that leaves
     * the frame fails.
     */
    boolean check(MapRenderer3 renderer, ByteBuffer px, int w, int h) {
        final MapSceneModel sm = renderer.getMapSceneModel(false, MapRenderer3.DisplayOrigin.UpperLeft);
        final PointD a = new PointD(0d, 0d), b = new PointD(0d, 0d);
        sm.forward(new GeoPoint(lat0, lon0), a);
        sm.forward(new GeoPoint(lat1, lon1), b);
        final int steps = (int) Math.ceil(Math.max(Math.abs(b.x - a.x), Math.abs(b.y - a.y)));
        int pixels = 0, matching = 0;
        boolean onScreen = steps > 0;
        for (int s = 0; s <= steps && onScreen; s++) {
            final double t = steps == 0 ? 0 : (double) s / steps;
            final int x = (int) Math.round(a.x + (b.x - a.x) * t), y = (int) Math.round(a.y + (b.y - a.y) * t);
            onScreen = x >= 0 && x < w && y >= 0 && y < h;
            if (!onScreen) break;
            final int i = ((h - 1 - y) * w + x) * 4;   // GL rows are bottom-up
            final int got = ((px.get(i) & 0xff) << 16) | ((px.get(i + 1) & 0xff) << 8) | (px.get(i + 2) & 0xff);
            pixels++;
            if (PixelExpectation.near(got, rgb, tolerance)) matching++;
        }
        final double percent = pixels == 0 ? 0 : 100.0 * matching / pixels;
        final boolean ok = onScreen && percent >= minPercent && percent <= maxPercent;
        System.out.printf(Locale.US,
                "render-smoke: expect-run (%.5f, %.5f)-(%.5f, %.5f) -> (%d, %d)-(%d, %d): %s #%06x +/-%d, want %.0f-%.0f%%: %s%n",
                lat0, lon0, lat1, lon1, Math.round(a.x), Math.round(a.y), Math.round(b.x), Math.round(b.y),
                onScreen ? String.format(Locale.US, "%.0f%% (%d of %d)", percent, matching, pixels) : "off-frame",
                rgb, tolerance, minPercent, maxPercent, ok ? "ok" : "FAIL");
        return ok;
    }
}
