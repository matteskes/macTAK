package mactak.render;

import com.atakmap.map.Globe;
import com.atakmap.map.layer.raster.DatasetRasterLayer2;
import com.atakmap.map.layer.raster.RasterDataStore;
import com.atakmap.map.layer.raster.mobileimagery.MobileImageryRasterLayer2;

import java.util.Collections;

/**
 * The raster layers over the render harnesses' basemap store (RenderSmoke,
 * WindowApp), chosen the way ATAK chooses them: tilesets (MBTiles) through
 * {@link MobileImageryRasterLayer2}, and GDAL datasets ("native" imagery
 * such as GeoTIFF) through {@link DatasetRasterLayer2}.
 *
 * <p>Why both: {@code MobileImageryRasterLayer2} filters its store to its
 * default dataset types, the tileset kinds, so a GeoTIFF added to the same
 * store was accepted (provider gdal, type native) and then never drawn, with
 * no error (G2.4 b.1, G2 trap #67).
 *
 * <p>{@code DatasetRasterLayer2} is marked deprecated for removal at 5.5 but
 * is present and draws at the pin; 5.5's {@code NativeImageryRasterLayer2}
 * (a mosaic over the datasets) drew nothing for the same GeoTIFF and is not
 * chased here (G2 NOTES §G2.4 b.1, open items).
 */
final class BasemapLayers {

    private BasemapLayers() { }

    /** The provider name GdalLayerInfo gives its datasets. */
    static final String GDAL_PROVIDER = "gdal";
    /** Native datasets drawn at once; the fixtures add one. */
    private static final int DATASET_LIMIT = 4;
    static void addTo(Globe globe, RasterDataStore store) {
        globe.addLayer(new MobileImageryRasterLayer2("mactak-basemap", store, null));
        final RasterDataStore.DatasetQueryParameters gdal = new RasterDataStore.DatasetQueryParameters();
        gdal.providers = Collections.singleton(GDAL_PROVIDER);
        if (store.queryDatasetsCount(gdal) == 0) return;
        final RasterDataStore.DatasetDescriptorCursor c = store.queryDatasets(gdal);
        try {
            while (c.moveToNext()) GdalImagery.readerFor(c.get().getDatasetType());
        } finally {
            c.close();
        }
        globe.addLayer(new DatasetRasterLayer2("mactak-imagery", store, gdal, DATASET_LIMIT));
    }
}
