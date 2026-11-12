package mactak.render;

import com.atakmap.map.elevation.ElevationChunk;
import com.atakmap.map.elevation.ElevationSource;
import com.atakmap.map.elevation.ElevationSourceBuilder;
import com.atakmap.map.elevation.ElevationSourceManager;
import com.atakmap.map.formats.dted.DtedElevationSource;
import com.atakmap.map.gdal.GdalElevationChunk;
import com.atakmap.map.layer.feature.geometry.Envelope;
import com.atakmap.map.layer.feature.geometry.Geometry;

import java.io.File;
import java.util.Collections;

/**
 * G2.6: elevation for the render harnesses, attached to the engine's
 * {@link ElevationSourceManager}, which feeds both height queries and the
 * terrain renderer.
 *
 * <ul>
 * <li>A directory is a DTED tree ({@code w123/n37.dt1}):
 * {@link DtedElevationSource}. DTED heights are above mean sea level; the
 * engine reports them above the ellipsoid (adds the geoid height).</li>
 * <li>A file is a GDAL raster (GeoTIFF DEM): one {@link GdalElevationChunk}
 * ({@code autoDetectMsl}: a file that declares a sea-level vertical datum,
 * as USGS 3DEP does, is corrected like DTED; one that declares none is taken
 * as ellipsoid heights).</li>
 * </ul>
 *
 * <p>The GDAL chunk is lent, not handed over: every reader of a query
 * disposes the chunk it got, and {@code ElevationSourceBuilder.build} hands
 * every query the same chunk, so the second height query read a closed GDAL
 * dataset (NullPointerException in {@code ReadRaster_Direct}; G2 trap #71).
 * {@link LendingSource} gives each reader its own
 * {@link ElevationChunk.Factory#makeShared} reference instead, as upstream's
 * {@code SrtmElevationSource} does, and keeps one itself.
 */
final class ElevationSources {

    private ElevationSources() { }

    /** The terrain model flag (bare earth): {@code ElevationData.MODEL_TERRAIN}'s
     *  bit, which ElevationChunk's flags carry. ElevationData itself is
     *  deprecated in 5.5, and our compile is -Werror. */
    private static final int MODEL_TERRAIN = 0x01;

    /** Attach the elevation at {@code path}; returns the source, for {@link #detach}. */
    static ElevationSource attach(File path) {
        final ElevationSource source = path.isDirectory()
                ? DtedElevationSource.create(path.getAbsolutePath())
                : gdalSource(path);
        if (source == null)
            throw new IllegalArgumentException("no elevation source for " + path);
        ElevationSourceManager.attach(source);
        return source;
    }

    /**
     * Detach before the process exits: a Java-backed source (the GeoTIFF's)
     * still attached at exit is destroyed in C++ static teardown, after the
     * JVM is gone, and its native wrapper's destructor crashes the process
     * (exit 134 and an hs_err file; G2 trap #73).
     */
    static void detach(ElevationSource source) {
        ElevationSourceManager.detach(source);
    }

    private static ElevationSource gdalSource(File file) {
        final ElevationChunk chunk = GdalElevationChunk.create(file.getAbsolutePath(), null, Double.NaN,
                MODEL_TERRAIN, true);
        if (chunk == null) return null;
        final ElevationChunk master = ElevationChunk.Factory.makeShared(chunk);   // our reference, never released
        return new LendingSource(ElevationSourceBuilder.build(file.getName(), Collections.singleton(master)));
    }

    /** A source whose cursors lend each reader its own reference to the chunk. */
    private static final class LendingSource extends ElevationSource {
        private final ElevationSource impl;

        LendingSource(ElevationSource impl) { this.impl = impl; }

        @Override public String getName() { return impl.getName(); }
        @Override public Cursor query(QueryParameters params) { return new LendingCursor(impl.query(params)); }
        @Override public Envelope getBounds() { return impl.getBounds(); }
        @Override public void addOnContentChangedListener(OnContentChangedListener l) { impl.addOnContentChangedListener(l); }
        @Override public void removeOnContentChangedListener(OnContentChangedListener l) { impl.removeOnContentChangedListener(l); }
    }

    private static final class LendingCursor implements ElevationSource.Cursor {
        private final ElevationSource.Cursor impl;

        LendingCursor(ElevationSource.Cursor impl) { this.impl = impl; }

        /** A new reference per reader: its dispose releases only that one. */
        @Override public ElevationChunk get() { return ElevationChunk.Factory.makeShared(impl.get()); }

        @Override public boolean moveToNext() { return impl.moveToNext(); }
        @Override public void close() { impl.close(); }
        @Override public boolean isClosed() { return impl.isClosed(); }
        @Override public double getResolution() { return impl.getResolution(); }
        @Override public boolean isAuthoritative() { return impl.isAuthoritative(); }
        @Override public double getCE() { return impl.getCE(); }
        @Override public double getLE() { return impl.getLE(); }
        @Override public String getUri() { return impl.getUri(); }
        @Override public String getType() { return impl.getType(); }
        @Override public Geometry getBounds() { return impl.getBounds(); }
        @Override public int getFlags() { return impl.getFlags(); }
    }
}
