package mactak.render;

import com.atakmap.coremap.maps.coords.GeoPoint;
import com.atakmap.map.MapRenderer3;
import com.atakmap.map.elevation.ElevationManager;
import com.atakmap.math.PointD;

import java.util.Locale;

/**
 * G2.6's two elevation checks for RenderSmoke.
 *
 * <ul>
 * <li>{@link Height} ({@code --expect-height LAT,LON,M[,msl]}): the engine's
 * height at a point ({@link ElevationManager#getElevation}, above the
 * ellipsoid) must be the expected value. With {@code msl} the expectation is
 * above mean sea level, as DTED stores it, and the engine's geoid height
 * there is added before comparing.</li>
 * <li>{@link #terrainDrawn}: the terrain renderer used the elevation. A ray
 * cast from screen points must hit the terrain mesh, at the engine's height
 * for the point it hit. Without elevation in the renderer the ray hits the
 * bare ellipsoid at height 0.</li>
 * </ul>
 */
final class ElevationChecks {

    private ElevationChecks() { }

    /** Height data: the fixtures are planes, which interpolation reproduces exactly. */
    static final double HEIGHT_TOLERANCE_M = 0.5;
    /** The terrain mesh is a level-of-detail approximation of the data. */
    static final double TERRAIN_TOLERANCE_M = 5d;

    record Height(double lat, double lon, double metres, boolean aboveSeaLevel) {

        static Height parse(String spec) {
            final String[] p = spec.split(",");
            if (p.length < 3 || p.length > 4 || (p.length == 4 && !p[3].equals("msl")))
                throw new IllegalArgumentException("want LAT,LON,METRES[,msl], got " + spec);
            return new Height(Double.parseDouble(p[0]), Double.parseDouble(p[1]), Double.parseDouble(p[2]), p.length == 4);
        }

        /** Prints the comparison; returns whether it holds. */
        boolean check() {
            final double got = ElevationManager.getElevation(lat, lon, null);
            final double want = aboveSeaLevel ? metres + ElevationManager.getGeoidHeight(lat, lon) : metres;
            final boolean ok = !Double.isNaN(got) && Math.abs(got - want) <= HEIGHT_TOLERANCE_M;
            System.out.printf(Locale.US, "render-smoke: height (%.5f, %.5f) = %.3f m, want %.3f m (%s): %s%n",
                    lat, lon, got, want, aboveSeaLevel ? "MSL + geoid" : "ellipsoid", ok ? "ok" : "FAIL");
            return ok;
        }
    }

    /**
     * Ray-cast from the centre and from points a quarter of the height above
     * and below it: each must hit the terrain mesh at the engine's height for
     * that point. Prints each; returns whether all hold.
     */
    static boolean terrainDrawn(MapRenderer3 renderer, int w, int h) {
        return terrainCheck(renderer, w, h, true);
    }

    /** {@link #terrainDrawn} without printing: the render loop polls it until the tiles land. */
    static boolean terrainUnderRays(MapRenderer3 renderer, int w, int h) {
        return terrainCheck(renderer, w, h, false);
    }

    private static boolean terrainCheck(MapRenderer3 renderer, int w, int h, boolean report) {
        boolean all = true;
        for (float fy : new float[] { 0.5f, 0.25f, 0.75f }) {
            final PointD at = new PointD(w / 2d, h * fy);
            final GeoPoint hit = GeoPoint.createMutable();
            final MapRenderer3.InverseResult result = renderer.inverse(at, hit, MapRenderer3.InverseMode.RayCast, 0,
                    MapRenderer3.DisplayOrigin.UpperLeft);
            final double ground = ElevationManager.getElevation(hit.getLatitude(), hit.getLongitude(), null);
            final boolean ok = result == MapRenderer3.InverseResult.TerrainMesh
                    && !Double.isNaN(ground) && Math.abs(hit.getAltitude() - ground) <= TERRAIN_TOLERANCE_M;
            if (report)
                System.out.printf(Locale.US, "render-smoke: terrain at pixel (%.0f, %.0f): %s, (%.5f, %.5f) at %.2f m, ground %.2f m: %s%n",
                        at.x, at.y, result, hit.getLatitude(), hit.getLongitude(), hit.getAltitude(), ground, ok ? "ok" : "FAIL");
            all &= ok;
        }
        return all;
    }
}
