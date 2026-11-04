// macTAK addition to the JNI glue (built into libtakenginejni.dylib by
// dev/g1/build-native.sh). On Android the engine's GDAL drivers are
// registered from Java via the org.gdal SWIG bindings (GdalLibrary.init ->
// gdal.AllRegister()); those bindings do not exist on macOS, so expose the
// engine's own native GdalLibrary::init instead (GDALAllRegister + GDAL_DATA
// + EPSG:4326 spatial reference).
#include <jni.h>

#include <raster/gdal/GdalLibrary.h>

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
    return ok ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL Java_mactak_headless_NativeGdal_isInitialized
  (JNIEnv *, jclass)
{
    return atakmap::raster::gdal::GdalLibrary::isInitialized() ? JNI_TRUE : JNI_FALSE;
}
