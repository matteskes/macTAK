package mactak.render;

import com.atakmap.map.gdal.GdalLibrary;
import com.atakmap.map.layer.raster.DatasetDescriptorFactory2;
import com.atakmap.map.layer.raster.gdal.GdalLayerInfo;
import com.atakmap.map.layer.raster.gdal.GdalTileReader;
import com.atakmap.map.layer.raster.tilereader.TileReader;
import com.atakmap.map.layer.raster.tilereader.TileReaderFactory;
import com.atakmap.map.layer.raster.tilereader.TileReaderSpi2;

import java.io.File;
import java.net.URI;

/**
 * G2.4 b.1: GDAL imagery (GeoTIFF and every other raster GDAL reads) for the
 * render harnesses, wired the way ATAK's app layer wires it.
 *
 * <ol>
 * <li>{@link GdalLibrary#init()}: the org.gdal bindings exist since b.0
 * (make gdal-java) and init completes since b.1a.</li>
 * <li>{@link GdalLayerInfo} describes GDAL datasets for the raster store
 * (provider "gdal", type "native").</li>
 * <li>{@link #readerFor}: a tile reader for each GDAL dataset type the store
 * holds. On Android, ATAK's app-layer {@code GLGdalMapLayer2} renders
 * native datasets; it is not in takkernel, so with the engine alone they
 * reach {@code GLTiledMapLayer2}, which asks {@code TileReaderFactory} for
 * a reader with two things {@link GdalTileReader} refuses, both silently
 * (G2 trap #68): the dataset's {@code file://} URI ({@code GdalTileReader}
 * takes only a plain path: its {@code create} and {@code isSupported}
 * return nothing unless the URI starts with '/'), and the dataset type
 * ("native") as the preferred reader, which the factory treats as a
 * strategy name: only a reader registered under that name qualifies. The
 * adapter registers under the type, turns the URI into the path and hands
 * over to {@code GdalTileReader}.</li>
 * </ol>
 *
 * Without GDAL, {@link GdalTileReader#SPI} is unregistered as before: it
 * probes every tile URI first and would throw UnsatisfiedLinkError on the
 * GL worker.
 */
final class GdalImagery {

    private GdalImagery() { }

    /** Ahead of the engine's own readers (priority 0), so it sees file:// URIs first. */
    private static final int PRIORITY = 1;

    private static boolean enabled;
    private static final java.util.Map<String, TileReaderSpi2> READERS = new java.util.HashMap<>();

    /** GdalTileReader for a {@code file:} URI, registered under one dataset type. */
    private static final class FileUriReader implements TileReaderSpi2 {
        private final String datasetType;

        FileUriReader(String datasetType) { this.datasetType = datasetType; }

        @Override public String getName() { return datasetType; }

        @Override public int getPriority() { return PRIORITY; }

        @Override
        public TileReader create(String uri, TileReaderFactory.Options options) {
            final String path = localPath(uri);
            return path == null ? null : GdalTileReader.SPI.create(path, options);
        }

        @Override
        public boolean isSupported(String uri) {
            final String path = localPath(uri);
            return path != null && GdalTileReader.SPI.isSupported(path);
        }
    }

    /**
     * Enable GDAL imagery; returns false (and keeps GdalTileReader out of the
     * tile readers) when the GDAL bindings are not there.
     */
    static boolean enable(String tag) {
        if (!GdalLibrary.init()) {
            System.err.println(tag + ": GDAL unavailable (GdalLibrary.init() = false): GeoTIFF imagery disabled");
            TileReaderFactory.unregisterSpi(GdalTileReader.SPI);
            return false;
        }
        DatasetDescriptorFactory2.register(GdalLayerInfo.INSTANCE);
        synchronized (GdalImagery.class) { enabled = true; }
        return true;
    }

    /** Register the file-URI reader under a GDAL dataset type (once per type). */
    static synchronized void readerFor(String datasetType) {
        if (!enabled || datasetType == null || READERS.containsKey(datasetType)) return;
        final TileReaderSpi2 reader = new FileUriReader(datasetType);
        READERS.put(datasetType, reader);
        TileReaderFactory.registerSpi(reader);
    }

    /** The local path of a {@code file:} URI, or null for anything else. */
    static String localPath(String uri) {
        if (uri == null || !uri.startsWith("file:")) return null;
        try {
            return new File(URI.create(uri)).getAbsolutePath();
        } catch (IllegalArgumentException e) {
            return null;
        }
    }
}
