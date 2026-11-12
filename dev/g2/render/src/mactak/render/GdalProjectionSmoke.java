package mactak.render;

import com.atakmap.coremap.maps.coords.GeoPoint;
import com.atakmap.map.gdal.GdalLibrary;
import com.atakmap.map.layer.raster.gdal.GdalDatasetProjection2;
import com.atakmap.math.PointD;

import org.gdal.gdal.Dataset;
import org.gdal.gdal.Driver;
import org.gdal.gdal.gdal;
import org.gdal.gdalconst.gdalconstConstants;
import org.gdal.osr.SpatialReference;
import org.gdal.osr.osrConstants;

import java.io.File;

/**
 * G2.4 b.2 smoke: the engine's own GDAL georeferencing path, on GDAL 3, with
 * the trap #48 patch (dev/g1/patches/gdal3-axis-order-traditional-gis.patch,
 * shadowed under engine-shadows/). Compiled by render/env.sh so the shadowed
 * {@code GdalLibrary}/{@code GdalDatasetProjection2} are the ones under test.
 *
 * Proves: (1) {@code GdalLibrary.init()} — the real engine init, natives
 * loaded, the {@code /vsitakio/} handler installed — returns true and leaves
 * {@code EPSG_4326} in traditional GIS order; (2)
 * {@code GdalDatasetProjection2.getInstance(dataset)} on a 64×64 EPSG:4326
 * GeoTIFF maps pixel (0,0) to its georeferenced corner and back. Without the
 * patch (2) yields Infinity/NaN ("PROJ: Invalid latitude"); (3) the same
 * GeoTIFF opens through the Java-backed VSI handler ({@code /vsitakio/}
 * prefix → {@code VSIFileFileSystemHandler} → {@code FileChannel}) with the
 * same geotransform — the b.1a port of {@code vsi_jfile.cpp} to GDAL 3's
 * VSI interface (trap #50).
 *
 * Exit 0 = PASS; exit 1 with the first failing line otherwise.
 */
public final class GdalProjectionSmoke {
    private GdalProjectionSmoke() {}

    private static void fail(String why) {
        System.out.println("gdal-projection-smoke: FAIL: " + why);
        System.exit(1);
    }

    private static void check(boolean ok, String why) {
        if (!ok) fail(why);
    }

    public static void main(String[] args) {
        // usage: --lib PATH [--lib PATH ...] --scratch DIR
        File scratch = null;
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--lib": System.load(args[++i]); break;
                case "--scratch": scratch = new File(args[++i]); break;
                default: fail("unknown arg " + args[i]);
            }
        }
        check(scratch != null && scratch.isDirectory(), "--scratch DIR required");

        // 1. the engine's init, for real: AllRegister, config, EPSG_4326,
        //    registerProjectionSpi (JNI), the /vsitakio/ VSI handler (JNI,
        //    vsi_jfile.cpp — b.1a). Anything short of true is a FAIL.
        final boolean inited = GdalLibrary.init();
        System.out.println("gdal-projection-smoke: GdalLibrary.init() = " + inited);
        check(inited, "GdalLibrary.init() returned false");
        check(GdalLibrary.EPSG_4326 != null, "GdalLibrary.EPSG_4326 not constructed");
        final int strategy = GdalLibrary.EPSG_4326.GetAxisMappingStrategy();
        System.out.println("gdal-projection-smoke: GdalLibrary.EPSG_4326 axis mapping strategy=" + strategy
                + " (OAMS_TRADITIONAL_GIS_ORDER=" + osrConstants.OAMS_TRADITIONAL_GIS_ORDER + ")");
        check(strategy == osrConstants.OAMS_TRADITIONAL_GIS_ORDER,
                "EPSG_4326 is not in traditional GIS order — patch not in effect");

        // 2. a GeoTIFF with a known geotransform, through the engine's
        //    projection factory.
        final int w = 64, h = 64;
        final double west = -122.5, north = 37.8, dx = 0.1 / w, dy = 0.1 / h;
        final File tif = new File(scratch, "proj-smoke.tif");
        {
            final Driver gtiff = gdal.GetDriverByName("GTiff");
            check(gtiff != null, "GTiff driver missing (AllRegister not run?)");
            final Dataset ds = gtiff.Create(tif.getPath(), w, h, 1, gdalconstConstants.GDT_Byte);
            check(ds != null, "GTiff Create failed: " + gdal.GetLastErrorMsg());
            ds.SetGeoTransform(new double[] {west, dx, 0, north, 0, -dy});
            final SpatialReference wgs84 = new SpatialReference();
            wgs84.ImportFromEPSG(4326);
            check(ds.SetProjection(wgs84.ExportToWkt()) == 0, "SetProjection failed");
            ds.delete();
        }
        final Dataset ds = gdal.Open(tif.getPath(), gdalconstConstants.GA_ReadOnly);
        check(ds != null, "reopen failed: " + gdal.GetLastErrorMsg());
        final GdalDatasetProjection2 proj = GdalDatasetProjection2.getInstance(ds);
        check(proj != null, "GdalDatasetProjection2.getInstance returned null");
        System.out.println("gdal-projection-smoke: projection " + proj.getClass().getSimpleName()
                + " srid=" + proj.getNativeSpatialReferenceID());
        check(proj.getNativeSpatialReferenceID() == 4326, "srid != 4326");

        // pixel (0,0) → NW corner; the centre and SE corner below
        final GeoPoint g = GeoPoint.createMutable();
        check(proj.imageToGround(new PointD(0, 0), g), "imageToGround(0,0) returned false");
        System.out.println(String.format("gdal-projection-smoke: image(0,0) → lat %.6f lon %.6f", g.getLatitude(), g.getLongitude()));
        check(Math.abs(g.getLatitude() - north) < 1e-9 && Math.abs(g.getLongitude() - west) < 1e-9,
                "image(0,0) != (" + north + ", " + west + ")");

        // ground(centre) → the midpoint of image(0,0) and ground(SE corner)'s
        // image. Where the SE corner lands is upstream's pixel convention:
        // 4.6 maps the extent to [0, w] (centre 32), 5.5 to the addressable
        // [0, w-1] (GdalDatasetProjection2.GeoTransform's pixelScale, centre
        // 31.5). Either way it lies in [w-1, w] on both axes; an axis swap or
        // a non-linear mapping fails here or at image(0,0) above.
        final PointD se = new PointD(0, 0);
        check(proj.groundToImage(new GeoPoint(north - h * dy, west + w * dx), se), "groundToImage(SE) returned false");
        System.out.println(String.format("gdal-projection-smoke: ground(SE corner) → image(%.6f, %.6f)", se.x, se.y));
        check(se.x >= w - 1 - 1e-6 && se.x <= w + 1e-6 && se.y >= h - 1 - 1e-6 && se.y <= h + 1e-6,
                "ground(SE corner) outside image [" + (w - 1) + ", " + w + "]");

        final PointD p = new PointD(0, 0);
        check(proj.groundToImage(new GeoPoint(north - 32 * dy, west + 32 * dx), p), "groundToImage returned false");
        System.out.println(String.format("gdal-projection-smoke: ground(centre) → image(%.6f, %.6f)", p.x, p.y));
        check(Math.abs(p.x - se.x / 2) < 1e-6 && Math.abs(p.y - se.y / 2) < 1e-6,
                "ground(centre) != half of image(SE corner)");

        ds.delete();

        // 3. the same file through the Java-backed VSI handler: GDAL calls
        //    VSIJFileFilesystemHandler::Open/Stat and VSIJFileHandle::Seek/
        //    Read/Tell/Eof (the ported overrides) against a FileChannel.
        final String vsiPath = com.atakmap.map.gdal.VSIFileFileSystemHandler.PREFIX + tif.getPath();
        final Dataset vds = gdal.Open(vsiPath, gdalconstConstants.GA_ReadOnly);
        check(vds != null, "open via " + com.atakmap.map.gdal.VSIFileFileSystemHandler.PREFIX + " failed: " + gdal.GetLastErrorMsg());
        final double[] vgt = vds.GetGeoTransform();
        System.out.println(String.format("gdal-projection-smoke: %s open OK %dx%d gt[0]=%.4f gt[3]=%.4f driver=%s",
                com.atakmap.map.gdal.VSIFileFileSystemHandler.PREFIX, vds.getRasterXSize(), vds.getRasterYSize(),
                vgt[0], vgt[3], vds.GetDriver().getShortName()));
        check(vds.getRasterXSize() == w && vds.getRasterYSize() == h, "vsi size mismatch");
        check(Math.abs(vgt[0] - west) < 1e-9 && Math.abs(vgt[3] - north) < 1e-9, "vsi geotransform mismatch");
        final byte[] vpx = new byte[w * h];
        check(vds.GetRasterBand(1).ReadRaster(0, 0, w, h, gdalconstConstants.GDT_Byte, vpx) == 0,
                "vsi ReadRaster failed: " + gdal.GetLastErrorMsg());
        vds.delete();
        System.out.println("gdal-projection-smoke: PASS");
    }
}
