package mactak.engine;

/**
 * What the map window starts with (G3.0): the engine's natives, ANGLE, the
 * data to show and the camera, plus the G2 gates' scripted live phase. The
 * Swift side ({@code app/Sources/MacTAKCore/EngineBridge.swift}) builds one
 * with the no-argument constructor and sets the fields by name over JNI,
 * then hands it to {@link EngineBridge#start}. It replaces the 22
 * positional arguments {@code WindowApp.start} took through G2.
 *
 * <p>A plain data holder on purpose: public fields keep the JNI side to one
 * {@code SetXField} per value, with no setter signatures to keep in step.
 * Nulls mean "none" for every array and the optional paths.
 */
public final class MapConfig {

    // ---- the engine and ANGLE (required) ----------------------------------
    /** Native libraries to {@code System.load}, in order (libtakengine, libtakenginejni). */
    public String[] libs;
    /** ANGLE's {@code libEGL.dylib}. */
    public String egl;
    /** ANGLE's {@code libGLESv2.dylib}. */
    public String gles;

    // ---- data -------------------------------------------------------------
    /** Vector layers (GeoJSON, GPKG, KML, SHP). */
    public String[] layers;
    /** Raster basemaps (MBTiles or a GDAL raster such as GeoTIFF). */
    public String[] basemaps;
    /** Elevation: a GeoTIFF DEM file or a DTED directory. */
    public String[] elevations;
    /** The feature store's directory; null for a temp directory. */
    public String layerDb;

    // ---- camera -----------------------------------------------------------
    /** Metres per pixel; NaN fits the content bounds. */
    public double res = Double.NaN;
    /** Camera centre; NaN frames on the content bounds. */
    public double atLat = Double.NaN;
    public double atLon = Double.NaN;

    // ---- the first-frame gate ---------------------------------------------
    /** Frames to render before the first-frame gate (plus the settle tail). */
    public int frames = 5;
    /** Minimum wall time to keep rendering while layers load. */
    public long settleMs = 3000;
    /** The readback artifact (.png, else binary PPM); null writes none. */
    public String out;
    /**
     * The first frame must show the attached layers and basemaps (the render
     * gates). The app sets false: its data may keep loading after the first
     * frame, which then only has to present without a GL error.
     */
    public boolean contentGate = true;

    // ---- the scripted live phase (G2 gates; 0 for the app) ----------------
    /** Length of the scripted live phase after the first frame; 0 for none. */
    public long liveMs;
    /** Resizes the host will drive during the live phase. */
    public int expectResizes;
    /** CSV of the live phase's frame times; null for none. */
    public String frameLog;
    /** Pan the camera automatically during the live phase. */
    public boolean scriptedPan = true;
    /** Bitmask (1 &lt;&lt; InputBridge kind) of gestures the host injects during the live phase. */
    public int gestureKinds;

    public MapConfig() { }
}
