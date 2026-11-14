// macTAK addition to the JNI glue (built into libtakenginejni.dylib by
// dev/g1/build-native.sh). On Android the engine's GDAL drivers are
// registered from Java via the org.gdal SWIG bindings (GdalLibrary.init ->
// gdal.AllRegister()); those bindings do not exist on macOS, so expose the
// engine's own native GdalLibrary::init instead (GDALAllRegister + GDAL_DATA
// + EPSG:4326 spatial reference).
//
// It also keeps GDAL offline (issue 155, dev/g1/NOTES.md §G1.26): both
// inits, this native one and the Java one (patches/gdal-offline-only.patch),
// call keepOffline() right after registering the drivers.
#include <jni.h>

#include <cstring>
#include <string>

#include <cpl_conv.h>
#include <gdal.h>
#include <gdal_priv.h>

#include <raster/gdal/GdalLibrary.h>

namespace {

// The only GDAL drivers the process keeps, raster and vector alike. Each was
// probed for files that make it reach the network or open other files
// (§G1.19 for the vector ones, §G1.26 for the raster ones):
//   imagery and elevation, as the engine's ImageryFileType names them:
//     GTiff, NITF (also CADRG/CIB frames), DTED, SRTMHGT, JP2OpenJPEG
//   images inside KMZ overlays and GeoPackage tiles: PNG, JPEG, GIF
//   the engine's own in-memory rasters (BitmapFactory2, GriddedCoverage): MEM
//   layer files, matching patches/ogr-open-driver-allowlist.patch:
//     GeoJSON, GPKG, KML, LIBKML, ESRI Shapefile, GPX, FlatGeobuf, OGDI
const char *const kAllowedDrivers[] = {
    "GTiff", "NITF", "DTED", "SRTMHGT", "JP2OpenJPEG",
    "PNG", "JPEG", "GIF",
    "MEM",
    "GeoJSON", "GPKG", "KML", "LIBKML", "ESRI Shapefile", "GPX", "FlatGeobuf", "OGDI",
};

// CPL_VSIL_CURL_ALLOWED_FILENAME admits exactly one path, compared with the
// whole /vsicurl/... name, so a value that is no such path refuses them all.
// (CPL_VSIL_CURL_ALLOWED_EXTENSIONS would not do: a URL can end in any
// extension.)
const char kNoCurlPath[] = "none";

bool isAllowed(const char *name)
{
    for (const char *allowed : kAllowedDrivers)
        if (std::strcmp(name, allowed) == 0)
            return true;
    return false;
}

// Two layers, because each misses what the other catches (§G1.26):
//  - GDAL_SKIP: every registered driver outside the allowlist, after what the
//    option already holds (GdalLibrary.java skips MBTiles and GPKG). Every
//    later GDALAllRegister honours it, including the other init's, so the
//    drivers can't come back. A driver list in each open call wouldn't do:
//    GDAL opens a raster's .ovr sidecar with every driver. Comma-separated,
//    because some driver names contain spaces.
//  - the curl file systems (/vsicurl, /vsis3, /vsiaz, ...) refuse every path,
//    which stops an allowed driver reading a remote source.
void keepOffline()
{
    std::string skip;
    if (const char *existing = CPLGetConfigOption("GDAL_SKIP", nullptr))
        skip = existing;
    for (int i = 0; i < GDALGetDriverCount(); i++) {
        const char *name = GDALGetDriverShortName(GDALGetDriver(i));
        if (!name || isAllowed(name))
            continue;
        if (!skip.empty())
            skip += ',';
        skip += name;
    }
    CPLSetConfigOption("GDAL_SKIP", skip.c_str());
    GetGDALDriverManager()->AutoSkipDrivers();
    CPLSetConfigOption("CPL_VSIL_CURL_ALLOWED_FILENAME", kNoCurlPath);
}

}  // namespace

extern "C" JNIEXPORT jboolean JNICALL Java_mactak_headless_NativeGdal_init
  (JNIEnv *env, jclass, jstring jdataDir)
{
    if (!jdataDir)
        return JNI_FALSE;
    const char *dataDir = env->GetStringUTFChars(jdataDir, nullptr);
    if (!dataDir)
        return JNI_FALSE;
    const bool ok = atakmap::raster::gdal::GdalLibrary::init(dataDir);
    env->ReleaseStringUTFChars(jdataDir, dataDir);
    if (ok)
        keepOffline();
    return ok ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL Java_mactak_headless_NativeGdal_isInitialized
  (JNIEnv *, jclass)
{
    return atakmap::raster::gdal::GdalLibrary::isInitialized() ? JNI_TRUE : JNI_FALSE;
}

// com.atakmap.map.gdal.GdalLibrary.keepOffline(), declared by
// patches/gdal-offline-only.patch and called from its initImpl.
extern "C" JNIEXPORT void JNICALL Java_com_atakmap_map_gdal_GdalLibrary_keepOffline
  (JNIEnv *, jclass)
{
    keepOffline();
}
