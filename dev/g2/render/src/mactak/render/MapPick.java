package mactak.render;

import com.atakmap.coremap.maps.coords.GeoPoint;
import com.atakmap.coremap.maps.coords.GeoPointMetaData;
import com.atakmap.map.MapSceneModel;
import com.atakmap.map.elevation.ElevationManager;
import android.graphics.PointF;

/**
 * A click as a place on the ground (G3.8b), for the range and bearing tool
 * now and dropped points later: the pixel through the camera's scene model
 * onto the earth model, then the height from the elevation data there, as
 * 5.5 takes a tapped point's altitude ({@code ElevationManager}).
 *
 * <p>Any thread: it reads a copy of the scene model, not the renderer. The
 * earth model ignores terrain, so with the map tilted over hills the place
 * can sit a little off the one under the pointer; looking straight down it
 * is the same place.
 */
final class MapPick {

    private MapPick() { }

    /** {lat, lon, hae (NaN where no elevation data covers it)}, or null off the world. */
    static double[] ground(MapSceneModel scene, float x, float y) {
        final GeoPoint at = scene.inverse(new PointF(x, y), GeoPoint.createMutable());
        if (at == null || !at.isValid()) return null;
        final double hae = ElevationManager.getElevation(at.getLatitude(), at.getLongitude(), null);
        return new double[] { at.getLatitude(), at.getLongitude(), hae };
    }

    /**
     * Where the altitude at a place comes from, as 5.5's inverseWithElevation
     * leaves it in the point's metadata (ElevationManager's result type, "???"
     * where no elevation data covers it); sent with a placed point (G3.9d).
     */
    static String altitudeSource(double lat, double lon) {
        final GeoPointMetaData result = new GeoPointMetaData();
        ElevationManager.getElevation(lat, lon, null, result);
        final Object source = result.getMetaData(GeoPointMetaData.ALTITUDE_SOURCE);
        return source == null ? GeoPointMetaData.UNKNOWN : source.toString();
    }
}
