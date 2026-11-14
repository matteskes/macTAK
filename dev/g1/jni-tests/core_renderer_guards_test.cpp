/*
 * Issue 142, batch 4 (wave 7, core and renderer area): the Java-backed
 * core and GL wrappers when their class init fails, and three upstream
 * bugs when it doesn't.
 *
 * Guards mode (empty classpath, every lookup fails). Each wrapper wraps a
 * real Java object that is none of the classes it expects (a String, as
 * feature_guards_test.cpp does), and every consumer must bail (TE_Err, or
 * NaN, false, 0 or the documented default for the getters that return
 * plain values) instead of calling through a NULL ID, leaving the JNIEnv
 * clean; constructors that call through the IDs (ManagedLayer's getName,
 * ManagedGLLayer2's getSubject, ManagedRenderSurface's IsInstanceOf) must
 * not. The GL draw paths and ManagedGLLayerSpi2::create need a GL view,
 * so they are guarded but not pinned here.
 *
 * Kernel mode (the takkernel jars), over JniTestsMain.RecordingCoreRenderer:
 *  - MapRenderer3_init succeeds on a real JVM (14 of its 19 lookups named
 *    members 5.5 doesn't have; F-1, issue 141), so isAnimating reaches Java;
 *  - getDisplayMode and getDisplayOrigin return Java's answer (upstream
 *    tested Interop_marshal's TE_Ok as false, returning the default);
 *  - each ManagedRenderSurface remembers whether it wraps a RenderSurface2
 *    (upstream kept one flag for every surface, set by the newest).
 *
 * Patches under test: wave7-core-renderer-consumer-guards.patch and
 * wave7-core-renderer-wrong-members.patch.
 */
#include <jni.h>

#include <core/MapRenderer.h>

#include <gtest/gtest.h>

#include <cmath>
#include <string>

#include "jni_test_env.hpp"
#include "interop/core/ManagedLayer.h"
#include "interop/core/ManagedMapRenderer2.h"
#include "interop/core/ManagedProjection.h"
#include "interop/core/ManagedRenderSurface.h"
#include "interop/core/ManagedVisibilityListener.h"
#include "interop/renderer/core/ManagedGLLayer2.h"
#include "interop/renderer/core/ManagedGLMapRenderable2.h"

namespace
{
    using TAK::Engine::Core::MapRenderer;
    using TAK::Engine::Util::TE_Err;
    using TAK::Engine::Util::TE_Ok;
    using TAKEngineJNI::Interop::Core::ManagedLayer;
    using TAKEngineJNI::Interop::Core::ManagedMapRenderer3;
    using TAKEngineJNI::Interop::Core::ManagedProjection;
    using TAKEngineJNI::Interop::Core::ManagedRenderSurface;
    using TAKEngineJNI::Interop::Core::ManagedVisibilityListener;
    using TAKEngineJNI::Interop::Renderer::Core::ManagedGLLayer2;
    using TAKEngineJNI::Interop::Renderer::Core::ManagedGLMapRenderable2;

    class CountingVisibilityListener : public atakmap::core::Layer::VisibilityListener
    {
    public:
        void visibilityChanged(atakmap::core::Layer &) override
        {
            ++changes;
        }
        int changes = 0;
    };

    class CountingSizeListener : public TAK::Engine::Core::RenderSurface::OnSizeChangedListener
    {
    public:
        void onSizeChanged(const TAK::Engine::Core::RenderSurface &, const std::size_t, const std::size_t) NOTHROWS override
        {
            ++changes;
        }
        int changes = 0;
    };

    class JniGuardsCoreRenderer : public JniGuardsTest
    {
    protected:
        /* a live Java object that is none of the core or renderer classes */
        jobject javaObject(JNIEnv &env)
        {
            return env.NewStringUTF("not a core or renderer class");
        }
    };

    class JniKernelCoreRenderer : public JniKernelTest
    {
    protected:
        jclass recorder(JNIEnv &env)
        {
            return env.FindClass("JniTestsMain$RecordingCoreRenderer");
        }
        jobject make(JNIEnv &env, const char *factory)
        {
            jclass c = recorder(env);
            if(!c)
                return nullptr;
            return env.CallStaticObjectMethod(c, env.GetStaticMethodID(c, factory, "()Ljava/lang/Object;"));
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

TEST_F(JniGuardsCoreRenderer, LayerAndVisibilityListenerBailOut)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    CountingVisibilityListener listener;
    {
        ManagedLayer layer(*env, javaObject(*env));
        EXPECT_EQ(layer.getName(), nullptr);
        EXPECT_FALSE(layer.isVisible());
        layer.setVisible(true);
        layer.addVisibilityListener(&listener);
        layer.removeVisibilityListener(&listener);

        ManagedVisibilityListener mlistener(*env, javaObject(*env));
        mlistener.visibilityChanged(layer);
    } // the layer's destructor has no listener to unbind
    EXPECT_EQ(listener.changes, 0);
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniGuardsCoreRenderer, ProjectionBailsOut)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    {
        ManagedProjection projection(*env, javaObject(*env));
        TAK::Engine::Math::Point2<double> proj(0, 0, 0);
        EXPECT_EQ(projection.forward(&proj, TAK::Engine::Core::GeoPoint2(37.77, -122.47)), TE_Err);
        TAK::Engine::Core::GeoPoint2 geo;
        EXPECT_EQ(projection.inverse(&geo, proj), TE_Err);
        EXPECT_EQ(projection.getSpatialReferenceID(), 0);
        EXPECT_TRUE(std::isnan(projection.getMinLatitude()));
        EXPECT_FALSE(projection.is3D());
    }
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniGuardsCoreRenderer, RenderSurfaceBailsOut)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    CountingSizeListener listener;
    jobject impl = javaObject(*env);
    {
        ManagedRenderSurface surface(*env, impl);
        EXPECT_TRUE(std::isnan(surface.getDpi()));
        EXPECT_EQ(surface.getWidth(), 0u);
        EXPECT_EQ(surface.getHeight(), 0u);
        surface.addOnSizeChangedListener(&listener);
        surface.removeOnSizeChangedListener(listener);
    } // the destructor has no listener to unbind
    EXPECT_EQ(listener.changes, 0);
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniGuardsCoreRenderer, MapRendererBailsOut)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    {
        ManagedMapRenderer3 renderer(*env, javaObject(*env));
        EXPECT_FALSE(renderer.isAnimating());
        EXPECT_EQ(renderer.setDisplayMode(MapRenderer::DisplayMode::Flat), TE_Err);
        EXPECT_EQ(renderer.getDisplayMode(), MapRenderer::DisplayMode::Globe);
        EXPECT_EQ(renderer.getDisplayOrigin(), MapRenderer::DisplayOrigin::LowerLeft);
    }
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniGuardsCoreRenderer, GLWrappersBailOut)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    {
        ManagedGLMapRenderable2 renderable(*env, javaObject(*env), true);
        renderable.release();
        EXPECT_EQ(renderable.getRenderPass(), 0);

        ManagedGLLayer2 layer(*env, javaObject(*env));
        layer.start();
        layer.stop();
        layer.release();
    }
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniKernelCoreRenderer, MapRendererInitSucceedsAndReachesJava)
{
    JNIEnv *env = jnitest::launcher_env();
    ASSERT_NE(env, nullptr);
    jobject impl = make(*env, "mapRenderer");
    ASSERT_NE(impl, nullptr) << "JniTestsMain$RecordingCoreRenderer did not load";

    ManagedMapRenderer3 renderer(*env, impl);
    EXPECT_FALSE(env->ExceptionCheck()) << "MapRenderer3_init left an exception pending";
    env->ExceptionClear();
    clearCalls(*env);
    EXPECT_TRUE(renderer.isAnimating());
    EXPECT_EQ(calls(*env), "isAnimating");
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniKernelCoreRenderer, DisplayModeAndOriginComeFromJava)
{
    JNIEnv *env = jnitest::launcher_env();
    ASSERT_NE(env, nullptr);
    jobject impl = make(*env, "mapRenderer");
    ASSERT_NE(impl, nullptr) << "JniTestsMain$RecordingCoreRenderer did not load";

    ManagedMapRenderer3 renderer(*env, impl);
    env->ExceptionClear();
    clearCalls(*env);
    EXPECT_EQ(renderer.getDisplayMode(), MapRenderer::DisplayMode::Flat);
    EXPECT_EQ(renderer.getDisplayOrigin(), MapRenderer::DisplayOrigin::UpperLeft);
    EXPECT_EQ(calls(*env), "getDisplayMode,getDisplayOrigin");
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniKernelCoreRenderer, EachSurfaceKeepsItsOwnKind)
{
    JNIEnv *env = jnitest::launcher_env();
    ASSERT_NE(env, nullptr);
    jobject impl2 = make(*env, "renderSurface2");
    jobject impl1 = make(*env, "renderSurface");
    ASSERT_NE(impl2, nullptr) << "JniTestsMain$RecordingCoreRenderer did not load";
    ASSERT_NE(impl1, nullptr);

    // the RenderSurface2 first, then a plain RenderSurface: upstream's one
    // flag then said "not a RenderSurface2" for both
    ManagedRenderSurface surface2(*env, impl2);
    ManagedRenderSurface surface1(*env, impl1);
    clearCalls(*env);
    EXPECT_EQ(surface2.getWidth(), 640u);
    EXPECT_EQ(surface2.getHeight(), 480u);
    EXPECT_EQ(surface1.getWidth(), 320u);
    EXPECT_EQ(surface1.getHeight(), 240u);
    EXPECT_EQ(calls(*env), "getSurfaceWidth,getSurfaceHeight,getWidth,getHeight");
    EXPECT_FALSE(env->ExceptionCheck());
}
