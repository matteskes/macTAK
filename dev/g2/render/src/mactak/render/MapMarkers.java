package mactak.render;

import java.util.HashMap;
import java.util.Map;

import com.atakmap.coremap.maps.coords.GeoPoint;
import com.atakmap.map.MapSceneModel;
import com.atakmap.math.PointD;

import com.atakmap.map.layer.feature.DataStoreException;
import com.atakmap.map.layer.feature.Feature;
import com.atakmap.map.layer.feature.FeatureDataStore2;
import com.atakmap.map.layer.feature.FeatureLayer3;
import com.atakmap.map.layer.feature.FeatureSet;
import com.atakmap.map.layer.feature.datastore.FeatureSetDatabase2;
import com.atakmap.map.layer.feature.geometry.Geometry;
import com.atakmap.map.layer.feature.geometry.LineString;
import com.atakmap.map.layer.feature.geometry.Point;
import com.atakmap.map.layer.feature.style.ArrowStrokeStyle;
import com.atakmap.map.layer.feature.style.BasicStrokeStyle;
import com.atakmap.map.layer.feature.style.CompositeStyle;
import com.atakmap.map.layer.feature.style.IconPointStyle;
import com.atakmap.map.layer.feature.style.LabelPointStyle;
import com.atakmap.map.layer.feature.style.Style;

/**
 * The map's markers (G3.7b): one engine feature per marker, in an in-memory
 * feature store under its own {@link FeatureLayer3}, as ATAK 5.5 draws map
 * items ({@code GLMarkerFeature.toFeature}): a point at the marker's
 * altitude (0 when unknown), an icon with its tint, size and rotation; the
 * feature's name is the label the engine draws with it (the callsign).
 *
 * <p>G3.8b adds lines beside them (a line string with a stroke, an arrow
 * head at its end if asked, and a label along it), and finds the marker
 * under a click ({@link #markerAt}).
 *
 * <p>Swift owns what the markers are; this class only writes them. Any
 * thread: the store takes its own modify lock, and the renderer picks the
 * change up from the store's content-changed event.
 */
public final class MapMarkers {

    /** A marker icon's size before scaling: 5.5's {@code Icon.Builder.setSize(32, 32)}. */
    public static final int ICON_SIZE = 32;
    /** An arrow head's length, pixels: 5.5's {@code GLArrow2} draws 16. */
    static final float ARROW_RADIUS = 16f;
    static final float LABEL_SIZE = 14f;
    static final int LABEL_BACKGROUND = 0x99000000;

    private final FeatureSetDatabase2 store = new FeatureSetDatabase2(null);
    private final long fsid;
    private final Map<String, Long> fids = new HashMap<>();
    /** Where each marker (not line) is drawn: lat, lon, height (0 when unknown). */
    private final Map<String, double[]> markerPoints = new HashMap<>();

    MapMarkers() {
        try {
            fsid = store.insertFeatureSet(new FeatureSet("mactak", "markers", "markers", Double.MAX_VALUE, 0d));
        } catch (DataStoreException e) {
            throw new IllegalStateException("can't create the marker feature set", e);
        }
    }

    /** The layer to add to the globe. */
    FeatureLayer3 layer() {
        return new FeatureLayer3("mactak-markers", store);
    }

    /**
     * Add or move the marker {@code uid}.
     *
     * @param hae      metres above the ellipsoid; NaN draws it at 0, as 5.5 does
     * @param iconUri  any URI the engine's bitmap loader takes ({@code asset://},
     *                 {@code base64://}, {@code file://})
     * @param color    ARGB tint (0xFFFFFFFF leaves the icon as drawn)
     * @param width    icon width before scaling ({@link #ICON_SIZE} for most)
     * @param height   icon height before scaling
     * @param rotation degrees clockwise from north, or NaN for none
     * @param label    the text under the icon, or null
     */
    public synchronized void put(String uid, double lat, double lon, double hae,
                                 String iconUri, int color, int width, int height, double rotation, String label) {
        final Point point = new Point(lon, lat, Double.isNaN(hae) ? 0d : hae);
        // clamped to the ground, as 5.5's markers are by default
        if (write(uid, label, point, style(iconUri, color, width, height, rotation)))
            markerPoints.put(uid, new double[] { lat, lon, point.getZ() });
    }

    /**
     * Add or move the line {@code uid} (G3.8b), clamped to the ground.
     *
     * @param latLons  lat, lon pairs, two or more points
     * @param color    ARGB stroke colour
     * @param width    stroke width, pixels
     * @param arrow    draw an arrow head at the last point
     * @param label    text drawn along the line, or null
     */
    public synchronized void putLine(String uid, double[] latLons, int color, float width, boolean arrow, String label) {
        if (latLons == null || latLons.length < 4 || latLons.length % 2 != 0) {
            System.err.println("MapMarkers: line " + uid + " wants two or more lat, lon pairs");
            return;
        }
        final LineString line = new LineString(2);
        for (int i = 0; i < latLons.length; i += 2) line.addPoint(latLons[i + 1], latLons[i]);
        if (write(uid, label, line, lineStyle(color, width, arrow, label))) markerPoints.remove(uid);
    }

    /** Insert or update one feature; whether it is in the store. */
    private boolean write(String uid, String name, Geometry geometry, Style style) {
        try {
            final Long fid = fids.get(uid);
            if (fid == null) {
                final Feature f = new Feature(fsid, FeatureDataStore2.FEATURE_ID_NONE, name, geometry, style, null,
                        FeatureDataStore2.TIMESTAMP_NONE, 1L);
                fids.put(uid, store.insertFeature(f));
            } else {
                store.updateFeature(fid,
                        FeatureDataStore2.PROPERTY_FEATURE_NAME | FeatureDataStore2.PROPERTY_FEATURE_GEOMETRY
                                | FeatureDataStore2.PROPERTY_FEATURE_STYLE,
                        name, geometry, style, null, FeatureDataStore2.UPDATE_ATTRIBUTES_SET);
            }
            return true;
        } catch (DataStoreException e) {
            System.err.println("MapMarkers: " + uid + " not drawn: " + e);
            return false;
        }
    }

    /** Take the marker or line {@code uid} off the map; nothing when there is none. */
    public synchronized void remove(String uid) {
        markerPoints.remove(uid);
        final Long fid = fids.remove(uid);
        if (fid == null) return;
        try {
            store.deleteFeature(fid);
        } catch (DataStoreException e) {
            System.err.println("MapMarkers: " + uid + " not removed: " + e);
        }
    }

    /**
     * The marker drawn nearest the surface pixel ({@code x, y}, upper-left
     * origin) and within {@code radius} pixels of it, or null. Each marker's
     * point goes through the scene model, as {@code PixelExpectation} does;
     * the radius stands in for the icon's box (5.5 hit-tests the icon).
     */
    public synchronized String markerAt(MapSceneModel scene, float x, float y, float radius) {
        final PointD at = new PointD(0d, 0d);
        final GeoPoint geo = GeoPoint.createMutable();
        String best = null;
        double bestSq = (double) radius * radius;
        for (Map.Entry<String, double[]> e : markerPoints.entrySet()) {
            final double[] p = e.getValue();
            geo.set(p[0], p[1], p[2]);
            scene.forward(geo, at);
            final double dx = at.x - x, dy = at.y - y, sq = dx * dx + dy * dy;
            if (sq <= bestSq) {
                bestSq = sq;
                best = e.getKey();
            }
        }
        return best;
    }

    /** How many markers and lines there are. */
    public synchronized int count() {
        return fids.size();
    }

    /** A line's style: a stroke (with an arrow head when asked) and its label. */
    static Style lineStyle(int color, float width, boolean arrow, String label) {
        final Style stroke = arrow
                ? new ArrowStrokeStyle(ARROW_RADIUS, 1, (short) 0xFFFF, color, width, BasicStrokeStyle.EXTRUDE_NONE)
                : new BasicStrokeStyle(color, width, BasicStrokeStyle.EXTRUDE_NONE);
        if (label == null) return stroke;
        // drawn at every resolution, white on a translucent black box; the
        // engine lays it along the line and hides it when it doesn't fit, as
        // 5.5's GLArrow2 label (a GLLabelManager label on the line) does
        final Style text = new LabelPointStyle(label, 0xFFFFFFFF, LABEL_BACKGROUND, LabelPointStyle.ScrollMode.OFF,
                LABEL_SIZE, 0, 0, 0f, false, Double.MAX_VALUE);
        return new CompositeStyle(new Style[] { stroke, text });
    }

    /** 5.5's icon style: centred, sized, turned when there's a heading. */
    static Style style(String iconUri, int color, int width, int height, double rotation) {
        final boolean turned = !Double.isNaN(rotation);
        return new IconPointStyle(color, iconUri, width, height, 0, 0,
                turned ? (float) -rotation : 0f, turned);
    }
}
