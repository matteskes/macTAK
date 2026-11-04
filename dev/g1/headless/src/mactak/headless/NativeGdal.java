package mactak.headless;

/**
 * GDAL driver registration for the headless host. Android does this through
 * the org.gdal SWIG bindings ({@code gdal.AllRegister()}); on macOS the
 * binding is {@code dev/g1/jni-extra/mactak_gdal.cpp} inside
 * {@code libtakenginejni.dylib}, which calls the engine's native
 * {@code GdalLibrary::init}. Must run before any feature/raster provider
 * touches GDAL — otherwise OGR answers "ERROR 4: No driver registered".
 */
final class NativeGdal {

    private NativeGdal() { }

    /** @param gdalDataDir GDAL_DATA directory (Homebrew: {@code $(gdal-config --datadir)}) */
    static native boolean init(String gdalDataDir);

    static native boolean isInitialized();
}
