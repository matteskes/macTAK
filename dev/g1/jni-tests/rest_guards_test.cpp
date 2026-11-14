/*
 * Issue 142, batch 5 (wave 7, the rest): the quantized-mesh source layer,
 * the geometry model, the bitmap loader's protocol handler, the
 * IOProviderFactory proxy and the projection SPI when their class init
 * fails, and the projection SPI when its Java side throws.
 *
 * Guards mode (empty classpath, every lookup fails):
 *  - ManagedQMESourceLayer's and ManagedGeometryModel's consumers bail
 *    (TE_Err, false) over a String, leaving the JNIEnv clean;
 *  - GLBitmapLoader.registerProtocolHandler (the JNI entry) survives its
 *    handler's class init, which checked nothing and went into GetMethodID
 *    on a NULL class;
 *  - the IOProviderFactory proxy, installed as the engine's filesystem the
 *    way Java's IOProviderFactory.installFactory does, answers TE_Err for
 *    every filesystem call, then uninstalls.
 * The protocol handler's handleURI needs AsyncBitmapLoader2 to drive it,
 * and the projection SPI would stay registered in this process if pinned
 * here, so both are guarded but not pinned in this mode.
 *
 * Kernel mode (the takkernel jars): a Java ProjectionSpi whose create
 * throws, registered through ProjectionFactory.registerSpiImpl, leaves the
 * JNIEnv clean after ProjectionFactory3_create asks it (upstream returned
 * with the exception pending).
 *
 * Patches under test: wave7-rest-consumer-guards.patch and
 * wave7-rest-projectionspi-exception.patch.
 */
#include <jni.h>

#include <core/ProjectionFactory3.h>
#include <math/Ray2.h>
#include <port/STLVectorAdapter.h>
#include <util/IO2.h>

#include <gtest/gtest.h>

#include <string>
#include <vector>

#include "jni_test_env.hpp"
#include "interop/formats/quantizedmesh/ManagedQMESourceLayer.h"
#include "interop/math/ManagedGeometryModel.h"

extern "C" {
    JNIEXPORT jlong JNICALL Java_com_atakmap_android_maps_graphics_GLBitmapLoader_registerProtocolHandler
        (JNIEnv *env, jclass clazz, jstring mscheme, jobject mloaderSpi, jstring mqueueHint);
    JNIEXPORT void JNICALL Java_com_atakmap_android_maps_graphics_GLBitmapLoader_unregisterProtocolHandler
        (JNIEnv *env, jclass clazz, jlong ptr);
    JNIEXPORT jlong JNICALL Java_com_atakmap_coremap_io_IOProviderFactory_installFactory
        (JNIEnv *env, jclass clazz);
    JNIEXPORT void JNICALL Java_com_atakmap_coremap_io_IOProviderFactory_uninstallFactory
        (JNIEnv *env, jclass clazz, jlong ptr);
    JNIEXPORT jobject JNICALL Java_com_atakmap_map_projection_ProjectionFactory_registerSpiImpl
        (JNIEnv *env, jclass clazz, jobject mspi, jint priority);
    JNIEXPORT void JNICALL Java_com_atakmap_map_projection_ProjectionFactory_unregisterSpiImpl
        (JNIEnv *env, jclass clazz, jobject mpointer);
}

namespace
{
    using TAK::Engine::Util::TE_Err;
    using TAK::Engine::Util::TE_InvalidArg;
    using TAK::Engine::Util::TE_Ok;
    using TAKEngineJNI::Interop::Formats::QuantizedMesh::ManagedQMESourceLayer;
    using TAKEngineJNI::Interop::Math::ManagedGeometryModel;

    /* an SRID no SDK projection answers, so ProjectionFactory3 asks every
     * registered SPI */
    constexpr int kUnknownSrid = 990001;

    class JniGuardsRest : public JniGuardsTest
    {
    protected:
        /* a live Java object that is none of the classes these wrap */
        jobject javaObject(JNIEnv &env)
        {
            return env.NewStringUTF("not a quantized-mesh, geometry or loader class");
        }
    };

    class JniKernelRest : public JniKernelTest
    {
    protected:
        jclass recorder(JNIEnv &env)
        {
            return env.FindClass("JniTestsMain$ThrowingProjectionSpi");
        }
        jobject newThrowingSpi(JNIEnv &env)
        {
            jclass c = recorder(env);
            if(!c)
                return nullptr;
            return env.CallStaticObjectMethod(c, env.GetStaticMethodID(c, "create", "()Ljava/lang/Object;"));
        }
        void clearCalls(JNIEnv &env)
        {
            jclass c = recorder(env);
            env.CallStaticVoidMethod(c, env.GetStaticMethodID(c, "clear", "()V"));
        }
        std::string calls(JNIEnv &env)
        {
            jclass c = recorder(env);
            jstring s = (jstring)env.CallStaticObjectMethod(c, env.GetStaticMethodID(c, "calls", "()Ljava/lang/String;"));
            if(!s)
                return std::string();
            const char *utf = env.GetStringUTFChars(s, nullptr);
            std::string out(utf ? utf : "");
            if(utf)
                env.ReleaseStringUTFChars(s, utf);
            return out;
        }
    };
}

TEST_F(JniGuardsRest, QMESourceLayerBailsOut)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    {
        ManagedQMESourceLayer layer(env, javaObject(*env));
        int i = -1;
        EXPECT_EQ(layer.getMinZoom(&i), TE_Err);
        EXPECT_EQ(layer.getMaxZoom(&i), TE_Err);
        EXPECT_EQ(layer.getClosestLevel(&i, 1.0), TE_Err);
        EXPECT_EQ(layer.getMaxLevel(&i), TE_Err);
        bool b = false;
        EXPECT_EQ(layer.isLocalDirectoryValid(&b), TE_Err);
        EXPECT_EQ(layer.isValid(&b), TE_Err);
        EXPECT_EQ(layer.isEnabled(&b), TE_Err);
        EXPECT_EQ(layer.hasTile(&b, 0, 0, 0), TE_Err);
        TAK::Engine::Port::String name;
        EXPECT_EQ(layer.getDirectory(&name), TE_Err);
        EXPECT_EQ(layer.getLevelDirName(&name, 0), TE_Err);
        EXPECT_EQ(layer.getTileFilename(&name, 0, 0, 0), TE_Err);
        std::vector<TAK::Engine::Formats::QuantizedMesh::TileExtents> extents;
        TAK::Engine::Port::STLVectorAdapter<TAK::Engine::Formats::QuantizedMesh::TileExtents> extents_w(extents);
        EXPECT_EQ(layer.getAvailableExtents(&extents_w, 0), TE_Err);
        EXPECT_EQ(layer.startDataRequest(0, 0, 0), TE_Err);
    }
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniGuardsRest, GeometryModelBailsOut)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    {
        ManagedGeometryModel model(*env, javaObject(*env));
        TAK::Engine::Math::Point2<double> hit(0, 0, 0);
        const TAK::Engine::Math::Ray2<double> ray(TAK::Engine::Math::Point2<double>(0, 0, 10),
                                                  TAK::Engine::Math::Vector4<double>(0, 0, -1));
        EXPECT_FALSE(model.intersect(&hit, ray));
    }
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniGuardsRest, BitmapLoaderHandlerSurvivesItsInit)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    jstring scheme = env->NewStringUTF("takjni-guards");
    jstring hint = env->NewStringUTF("takjni-guards");
    const jlong handler = Java_com_atakmap_android_maps_graphics_GLBitmapLoader_registerProtocolHandler(
        env, nullptr, scheme, javaObject(*env), hint);
    ASSERT_NE(handler, 0);
    Java_com_atakmap_android_maps_graphics_GLBitmapLoader_unregisterProtocolHandler(env, nullptr, handler);
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniGuardsRest, IOProviderFactoryProxyBailsOut)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    const jlong proxy = Java_com_atakmap_coremap_io_IOProviderFactory_installFactory(env, nullptr);
    ASSERT_NE(proxy, 0);
    bool b = true;
    EXPECT_EQ(TAK::Engine::Util::IO_exists(&b, "/tmp"), TE_Err);
    EXPECT_EQ(TAK::Engine::Util::IO_isDirectory(&b, "/tmp"), TE_Err);
    int64_t len = -1;
    EXPECT_EQ(TAK::Engine::Util::IO_length(&len, "/tmp"), TE_Err);
    EXPECT_EQ(TAK::Engine::Util::IO_mkdirs("/tmp/takjni-guards-never-made"), TE_Err);
    Java_com_atakmap_coremap_io_IOProviderFactory_uninstallFactory(env, nullptr, proxy);

    // uninstalled: the default filesystem answers again
    EXPECT_EQ(TAK::Engine::Util::IO_exists(&b, "/tmp"), TE_Ok);
    EXPECT_TRUE(b);
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniKernelRest, ThrowingProjectionSpiLeavesTheEnvClean)
{
    JNIEnv *env = jnitest::launcher_env();
    ASSERT_NE(env, nullptr);
    jobject spi = newThrowingSpi(*env);
    ASSERT_NE(spi, nullptr) << "JniTestsMain$ThrowingProjectionSpi did not load";

    jobject registered = Java_com_atakmap_map_projection_ProjectionFactory_registerSpiImpl(env, nullptr, spi, 0);
    ASSERT_NE(registered, nullptr);
    ASSERT_FALSE(env->ExceptionCheck());
    clearCalls(*env);

    TAK::Engine::Core::Projection2Ptr projection(nullptr, nullptr);
    const auto code = TAK::Engine::Core::ProjectionFactory3_create(projection, kUnknownSrid);
    const bool pending = env->ExceptionCheck();
    env->ExceptionClear(); // so the rest of the pin can talk to Java either way
    EXPECT_EQ(code, TE_InvalidArg);
    EXPECT_FALSE(pending) << "the SPI's exception was left pending";
    EXPECT_EQ(calls(*env), "create");

    Java_com_atakmap_map_projection_ProjectionFactory_unregisterSpiImpl(env, nullptr, registered);
    EXPECT_FALSE(env->ExceptionCheck());
}
