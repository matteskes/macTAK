package mactak.headless;

import java.io.File;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

import com.atakmap.map.layer.feature.FeatureCursor;
import com.atakmap.map.layer.feature.FeatureDataSourceContentFactory;
import com.atakmap.map.layer.feature.FeatureDataStore.FeatureQueryParameters;
import com.atakmap.map.layer.feature.FeatureDataStore.FeatureSetCursor;
import com.atakmap.map.layer.feature.FeatureDataStore.FeatureSetQueryParameters;
import com.atakmap.map.layer.feature.FeatureDefinition;
import com.atakmap.map.layer.feature.FeatureSet;
import com.atakmap.map.layer.feature.PersistentDataSourceFeatureDataStore2;
import com.atakmap.map.layer.feature.geometry.Envelope;
import com.atakmap.map.layer.feature.geometry.Geometry;
import com.atakmap.map.layer.feature.geometry.GeometryFactory;
import com.atakmap.map.layer.feature.ogr.OgrFeatureDataSource;

/**
 * Offline vector layer open through the engine's feature stack: the native
 * OGR provider parses the file (GeoJSON, shapefile, KML/KMZ, GPX,
 * GeoPackage — whatever the linked GDAL has drivers for) and the native
 * {@code PersistentDataSourceFeatureDataStore2} persists it under a
 * directory as feature-set databases, exactly as ATAK's overlay manager
 * does on Android. Queries come back through {@code FeatureDataStore2}
 * cursors — the G1 "offline map layer opens" criterion, minus the GL.
 */
public final class LayerStore implements AutoCloseable {

    private static boolean providerRegistered;

    private final PersistentDataSourceFeatureDataStore2 ds;

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
        ds = new PersistentDataSourceFeatureDataStore2(new File(dir));
    }

    /** Parses and persists a layer file; a file already in the store is refreshed. */
    public void add(File file) throws IOException {
        if (!file.isFile()) throw new IOException("no such file: " + file);
        final boolean ok = ds.contains(file) ? ds.update(file) : ds.add(file);
        if (!ok) throw new IOException("no feature provider accepted " + file.getName());
    }

    public int featureCount() {
        return ds.queryFeaturesCount(null);
    }

    public int featureCount(File file) {
        final FeatureQueryParameters p = new FeatureQueryParameters();
        p.featureSetIds = featureSetIds(file);
        return p.featureSetIds.isEmpty() ? 0 : ds.queryFeaturesCount(p);
    }

    private List<Long> featureSetIds(File file) {
        final List<Long> ids = new ArrayList<Long>();
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
        final List<Long> fsids = new ArrayList<Long>();
        final FeatureSetCursor sets = ds.queryFeatureSets((FeatureSetQueryParameters) null);
        try {
            while (sets.moveToNext()) {
                final FeatureSet fs = sets.get();
                fsids.add(fs.getId());
                final FeatureQueryParameters p = new FeatureQueryParameters();
                p.featureSetIds = Collections.singleton(fs.getId());
                final File src = ds.getFile(fs);
                sb.append(String.format(Locale.US, "set %-4d %-6s %-12s %-28s %5d feature(s)  %s%n",
                        fs.getId(), fs.getProvider(), fs.getType(), fs.getName(),
                        ds.queryFeaturesCount(p), src == null ? "" : src.getName()));
            }
        } finally {
            sets.close();
        }
        sb.append(String.format(Locale.US, "%d feature set(s), %d feature(s) in store%n", fsids.size(), featureCount()));

        final FeatureQueryParameters p = new FeatureQueryParameters();
        p.limit = maxFeatures;
        final FeatureCursor c = ds.queryFeatures(p);
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
