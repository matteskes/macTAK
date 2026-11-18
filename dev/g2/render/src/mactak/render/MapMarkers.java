package mactak.render;

import java.util.HashMap;
import java.util.Map;

import com.atakmap.map.layer.feature.DataStoreException;
import com.atakmap.map.layer.feature.Feature;
import com.atakmap.map.layer.feature.FeatureDataStore2;
import com.atakmap.map.layer.feature.FeatureLayer3;
import com.atakmap.map.layer.feature.FeatureSet;
import com.atakmap.map.layer.feature.datastore.FeatureSetDatabase2;
import com.atakmap.map.layer.feature.geometry.Point;
import com.atakmap.map.layer.feature.style.IconPointStyle;
import com.atakmap.map.layer.feature.style.Style;

/**
 * The map's markers (G3.7b): one engine feature per marker, in an in-memory
 * feature store under its own {@link FeatureLayer3}, as ATAK 5.5 draws map
 * items ({@code GLMarkerFeature.toFeature}): a point at the marker's
 * altitude (0 when unknown), an icon with its tint, size and rotation; the
 * feature's name is the label the engine draws with it (the callsign).
 *
 * <p>Swift owns what the markers are; this class only writes them. Any
 * thread: the store takes its own modify lock, and the renderer picks the
 * change up from the store's content-changed event.
 */
public final class MapMarkers {

    /** A marker icon's size before scaling: 5.5's {@code Icon.Builder.setSize(32, 32)}. */
    public static final int ICON_SIZE = 32;

    private final FeatureSetDatabase2 store = new FeatureSetDatabase2(null);
    private final long fsid;
    private final Map<String, Long> fids = new HashMap<>();

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
        final Style style = style(iconUri, color, width, height, rotation);
        try {
            final Long fid = fids.get(uid);
            if (fid == null) {
                // clamped to the ground, as 5.5's markers are by default
                final Feature f = new Feature(fsid, FeatureDataStore2.FEATURE_ID_NONE, label, point, style, null,
                        FeatureDataStore2.TIMESTAMP_NONE, 1L);
                fids.put(uid, store.insertFeature(f));
            } else {
                store.updateFeature(fid,
                        FeatureDataStore2.PROPERTY_FEATURE_NAME | FeatureDataStore2.PROPERTY_FEATURE_GEOMETRY
                                | FeatureDataStore2.PROPERTY_FEATURE_STYLE,
                        label, point, style, null, FeatureDataStore2.UPDATE_ATTRIBUTES_SET);
            }
        } catch (DataStoreException e) {
            System.err.println("MapMarkers: " + uid + " not drawn: " + e);
        }
    }

    /** Take the marker {@code uid} off the map; nothing when there is none. */
    public synchronized void remove(String uid) {
        final Long fid = fids.remove(uid);
        if (fid == null) return;
        try {
            store.deleteFeature(fid);
        } catch (DataStoreException e) {
            System.err.println("MapMarkers: " + uid + " not removed: " + e);
        }
    }

    /** How many markers there are. */
    public synchronized int count() {
        return fids.size();
    }

    /** 5.5's icon style: centred, sized, turned when there's a heading. */
    static Style style(String iconUri, int color, int width, int height, double rotation) {
        final boolean turned = !Double.isNaN(rotation);
        return new IconPointStyle(color, iconUri, width, height, 0, 0,
                turned ? (float) -rotation : 0f, turned);
    }
}
