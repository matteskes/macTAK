package mactak.headless;

import java.io.File;
import java.io.IOException;
import java.util.Collections;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;

import com.atakmap.map.layer.feature.Adapters;
import com.atakmap.map.layer.feature.DataStoreException;
import com.atakmap.map.layer.feature.FeatureCursor;
import com.atakmap.map.layer.feature.FeatureDataSourceContentFactory;
import com.atakmap.map.layer.feature.FeatureDataStore2.FeatureQueryParameters;
import com.atakmap.map.layer.feature.FeatureDataStore2.FeatureSetQueryParameters;
import com.atakmap.map.layer.feature.FeatureDataStore4;
import com.atakmap.map.layer.feature.FeatureDefinition;
import com.atakmap.map.layer.feature.FeatureSet;
import com.atakmap.map.layer.feature.FeatureSetCursor;
import com.atakmap.map.layer.feature.PersistentDataSourceFeatureDataStore3;
import com.atakmap.map.layer.feature.geometry.Envelope;
import com.atakmap.map.layer.feature.geometry.Geometry;
import com.atakmap.map.layer.feature.geometry.GeometryFactory;
import com.atakmap.map.layer.feature.ogr.OgrFeatureDataSource;

/**
 * Offline vector layer open through the engine's feature stack: the native
 * OGR provider parses the file (GeoJSON, shapefile, KML/KMZ, GPX,
 * GeoPackage — whatever the linked GDAL has drivers for) and the native
 * {@code PersistentDataSourceFeatureDataStore3} persists it under a
 * directory as feature-set databases, exactly as ATAK's overlay manager
 * does on Android. Queries come back through {@code FeatureDataStore2}
 * cursors — the G1 "offline map layer opens" criterion, minus the GL.
 *
 * <p>Store3 is 5.5's wrapper over the same native store as the deprecated
 * Store2 (removed at 5.6). Its queries throw the checked
 * {@link DataStoreException}; this class rethrows it unchecked, since a
 * failed query on a local store is a bug, not a condition callers handle.</p>
 */
public final class LayerStore implements AutoCloseable {

    private static boolean providerRegistered;

    private final PersistentDataSourceFeatureDataStore3 ds;
    private final FeatureDataStore4 view;

    public LayerStore(String dir) {
        synchronized (LayerStore.class) {
            if (!providerRegistered) {
                final String gdalData = System.getProperty("mactak.gdal.data");
                if (gdalData == null) throw new IllegalStateException("-Dmactak.gdal.data=<GDAL_DATA dir> not set");
                if (!NativeGdal.init(gdalData)) throw new IllegalStateException("GdalLibrary::init failed for " + gdalData);
                // registers the native OGR source + KML/GPX/SHP driver definitions
                FeatureDataSourceContentFactory.register(new OgrFeatureDataSource());
                providerRegistered = true;
            }
        }
        ds = new PersistentDataSourceFeatureDataStore3(new File(dir));
        view = Adapters.adapt(ds);
    }

    /** Parses and persists a layer file; a file already in the store is refreshed. */
    public void add(File file) throws IOException {
        if (!file.isFile()) throw new IOException("no such file: " + file);
        final boolean ok = ds.contains(file) ? ds.update(file) : ds.add(file);
        if (!ok) throw new IOException("no feature provider accepted " + file.getName());
    }

    public int featureCount() {
        return count(null);
    }

    /** The store as a {@code FeatureDataStore4}, e.g. to wrap in a {@code FeatureLayer3} for rendering (G2). */
    public FeatureDataStore4 dataStore() {
        return view;
    }

    /** Union envelope of every feature geometry in the store, or null if empty. */
    public Envelope bounds() {
        Envelope out = null;
        final FeatureCursor c = features(null);
        try {
            while (c.moveToNext()) {
                final Geometry g = geometryOf(c);
                if (g == null) continue;
                final Envelope e = g.getEnvelope();
                if (out == null) out = new Envelope(e.minX, e.minY, e.minZ, e.maxX, e.maxY, e.maxZ);
                else {
                    out.minX = Math.min(out.minX, e.minX); out.minY = Math.min(out.minY, e.minY);
                    out.minZ = Math.min(out.minZ, e.minZ);
                    out.maxX = Math.max(out.maxX, e.maxX); out.maxY = Math.max(out.maxY, e.maxY);
                    out.maxZ = Math.max(out.maxZ, e.maxZ);
                }
            }
        } finally {
            c.close();
        }
        return out;
    }

    public int featureCount(File file) {
        final Set<Long> ids = featureSetIds(file);
        return ids.isEmpty() ? 0 : count(inFeatureSets(ids));
    }

    private Set<Long> featureSetIds(File file) {
        final Set<Long> ids = new HashSet<Long>();
        final FeatureSetCursor c = ds.queryFeatureSets(file);
        try {
            while (c.moveToNext()) ids.add(c.get().getId());
        } finally {
            c.close();
        }
        return ids;
    }

    /** One line per feature set (provider/type/name/count), then up to {@code maxFeatures} features. */
    public String summary(int maxFeatures) {
        final StringBuilder sb = new StringBuilder();
        int setCount = 0;
        final FeatureSetCursor sets = featureSets(null);
        try {
            while (sets.moveToNext()) {
                final FeatureSet fs = sets.get();
                setCount++;
                final File src = ds.getFile(fs);
                sb.append(String.format(Locale.US, "set %-4d %-6s %-12s %-28s %5d feature(s)  %s%n",
                        fs.getId(), fs.getProvider(), fs.getType(), fs.getName(),
                        count(inFeatureSets(Collections.singleton(fs.getId()))),
                        src == null ? "" : src.getName()));
            }
        } finally {
            sets.close();
        }
        sb.append(String.format(Locale.US, "%d feature set(s), %d feature(s) in store%n", setCount, featureCount()));

        final FeatureQueryParameters p = new FeatureQueryParameters();
        p.limit = maxFeatures;
        final FeatureCursor c = features(p);
        try {
            // Read through the cursor's FeatureDefinition view: FeatureCursor.get()
            // materializes a Feature whose style parse touches android.util.LruCache
            // (a "Stub!" in the android-port transplant) — the headless host never
            // needs styles.
            while (c.moveToNext()) {
                sb.append(String.format(Locale.US, "  fid %-12d set %-3d %-28s %s%n",
                        c.getId(), c.getFsid(), c.getName(), describe(geometryOf(c))));
            }
        } finally {
            c.close();
        }
        return sb.toString();
    }

    private static FeatureQueryParameters inFeatureSets(Set<Long> fsids) {
        final FeatureQueryParameters p = new FeatureQueryParameters();
        p.featureSetFilter = new FeatureSetQueryParameters();
        p.featureSetFilter.ids = fsids;
        return p;
    }

    private int count(FeatureQueryParameters p) {
        try {
            return ds.queryFeaturesCount(p);
        } catch (DataStoreException e) {
            throw new IllegalStateException("feature count query failed", e);
        }
    }

    private FeatureCursor features(FeatureQueryParameters p) {
        try {
            return ds.queryFeatures(p);
        } catch (DataStoreException e) {
            throw new IllegalStateException("feature query failed", e);
        }
    }

    private FeatureSetCursor featureSets(FeatureSetQueryParameters p) {
        try {
            return ds.queryFeatureSets(p);
        } catch (DataStoreException e) {
            throw new IllegalStateException("feature set query failed", e);
        }
    }

    private static Geometry geometryOf(FeatureCursor c) {
        final Object raw = c.getRawGeometry();
        switch (c.getGeomCoding()) {
            case FeatureDefinition.GEOM_ATAK_GEOMETRY: return (Geometry) raw;
            case FeatureDefinition.GEOM_WKB:            return GeometryFactory.parseWkb((byte[]) raw);
            case FeatureDefinition.GEOM_SPATIALITE_BLOB: return GeometryFactory.parseSpatiaLiteBlob((byte[]) raw);
            default:                                    return null;
        }
    }

    private static String describe(Geometry g) {
        if (g == null) return "(no geometry)";
        final Envelope e = g.getEnvelope();
        return String.format(Locale.US, "%-18s [%.5f %.5f .. %.5f %.5f]",
                g.getClass().getSimpleName(), e.minY, e.minX, e.maxY, e.maxX);
    }

    @Override
    public void close() {
        ds.dispose();
    }
}
