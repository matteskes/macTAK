/*
 * Issue 142, batch 1 (wave 7, feature area): the four Java-backed feature
 * wrappers when their class init fails, and FeatureDataStore2's method IDs
 * when it doesn't.
 *
 * Guards mode (empty classpath, every lookup fails). Each wrapper wraps a
 * real Java object that is none of the classes it expects (a String, as
 * featuredefinition_guards_test.cpp does), and:
 *  - its constructor must not call through the NULL IDs (IsInstanceOf,
 *    NewObject and the listener registration in ManagedFeatureDataStore2;
 *    getName in ManagedFeatureDataSource2);
 *  - every consumer must bail (TE_Err, or 0 for parseVersion) instead of
 *    calling through a NULL method ID, and leave the JNIEnv clean;
 *  - feature/Interop.cpp's marshals bail TE_IllegalState when their lazy
 *    init (checkInit) fails, instead of NewObject on its NULL IDs.
 *
 * Kernel mode (the takkernel jars). ManagedFeatureDataStore2 wraps
 * JniTestsMain.RecordingFeatureDataStore, a proxy that records each call:
 *  - queryFeaturesCount() reaches Java's queryFeaturesCount (upstream
 *    called queryFeatureSetsCount);
 *  - setFeatureSetVisible(fsid, visible) reaches setFeatureSetVisible, and
 *    setFeatureSetsVisible(params, visible) reaches setFeatureSetsVisible
 *    (upstream's init stored the plural lookup in the singular's slot and
 *    left the plural's NULL).
 *
 * Patches under test: managedfeature-class-init-guards.patch (which also
 * guards feature/Interop.cpp's checkInit callers) and
 * managedfeaturedatastore2-method-ids.patch.
 */
#include <jni.h>

#include <feature/FeatureDataStore2.h>
#include <feature/FeatureSet2.h>

#include <gtest/gtest.h>

#include <string>

#include "jni_test_env.hpp"
#include "interop/feature/Interop.h"
#include "interop/java/JNILocalRef.h"
#include "interop/feature/ManagedFeatureCursor.h"
#include "interop/feature/ManagedFeatureDataSource2.h"
#include "interop/feature/ManagedFeatureDataStore2.h"
#include "interop/feature/ManagedFeatureSetCursor.h"

namespace
{
    using TAK::Engine::Feature::FeatureDataStore2;
    using TAK::Engine::Feature::FeatureSet2;
    using TAK::Engine::Util::TE_Err;
    using TAK::Engine::Util::TE_IllegalState;
    using TAK::Engine::Util::TE_Ok;
    using TAKEngineJNI::Interop::Feature::ManagedFeatureCursor;
    using TAKEngineJNI::Interop::Feature::ManagedFeatureDataSource2;
    using TAKEngineJNI::Interop::Feature::ManagedFeatureDataStore2;
    using TAKEngineJNI::Interop::Feature::ManagedFeatureSetCursor;

    class JniGuardsFeature : public JniGuardsTest
    {
    protected:
        /* a live Java object that is none of the feature classes */
        jobject javaObject(JNIEnv &env)
        {
            return env.NewStringUTF("not a feature class");
        }
    };

    class JniKernelFeatureDataStore : public JniKernelTest
    {
    protected:
        jclass recorder(JNIEnv &env)
        {
            return env.FindClass("JniTestsMain$RecordingFeatureDataStore");
        }
        jobject newRecordingStore(JNIEnv &env)
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

TEST_F(JniGuardsFeature, DataStoreConstructorSurvivesFailedInit)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    {
        ManagedFeatureDataStore2 store(*env, javaObject(*env));
    }
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniGuardsFeature, DataStoreConsumersBailOut)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    ManagedFeatureDataStore2 store(*env, javaObject(*env));

    int count = -1;
    EXPECT_EQ(store.queryFeaturesCount(&count), TE_Err);
    EXPECT_EQ(store.queryFeatureSetsCount(&count), TE_Err);
    TAK::Engine::Feature::FeatureCursorPtr features(nullptr, nullptr);
    EXPECT_EQ(store.queryFeatures(features), TE_Err);
    TAK::Engine::Feature::FeatureSetCursorPtr sets(nullptr, nullptr);
    EXPECT_EQ(store.queryFeatureSets(sets), TE_Err);
    EXPECT_EQ(store.deleteFeature(1), TE_Err);
    EXPECT_EQ(store.deleteFeatureSet(1), TE_Err);
    EXPECT_EQ(store.setFeatureVisible(1, true), TE_Err);
    EXPECT_EQ(store.setFeatureSetVisible(1, true), TE_Err);
    FeatureDataStore2::FeatureSetQueryParameters params;
    EXPECT_EQ(store.setFeatureSetsVisible(params, true), TE_Err);
    int flags = 0;
    EXPECT_EQ(store.getModificationFlags(&flags), TE_Err);
    EXPECT_EQ(store.getVisibilitySettingsFlags(&flags), TE_Err);
    TAK::Engine::Port::String uri;
    EXPECT_EQ(store.getUri(uri), TE_Err);
    EXPECT_EQ(store.close(), TE_Err);
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniGuardsFeature, CursorsBailOut)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    {
        ManagedFeatureCursor cursor(*env, javaObject(*env));
        int64_t value = 0;
        EXPECT_EQ(cursor.getId(&value), TE_Err);
        EXPECT_EQ(cursor.getFeatureSetId(&value), TE_Err);
        EXPECT_EQ(cursor.getVersion(&value), TE_Err);
    }
    {
        ManagedFeatureSetCursor cursor(*env, javaObject(*env));
        const FeatureSet2 *set = nullptr;
        EXPECT_EQ(cursor.get(&set), TE_Err);
    }
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniGuardsFeature, DataSourceBailsOut)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    {
        ManagedFeatureDataSource2 source(env, javaObject(*env));
        TAK::Engine::Feature::FeatureDataSource2::ContentPtr content(nullptr, nullptr);
        EXPECT_EQ(source.parse(content, "/nonexistent.geojson"), TE_Err);
        EXPECT_EQ(content.get(), nullptr);
        EXPECT_EQ(source.parseVersion(), 0);
    }
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniGuardsFeature, QueryParameterMarshalsBailOut)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    TAKEngineJNI::Interop::Java::JNILocalRef mparams(*env, nullptr);
    FeatureDataStore2::FeatureQueryParameters features;
    EXPECT_EQ(TAKEngineJNI::Interop::Feature::Interop_marshal(mparams, *env, features), TE_IllegalState);
    FeatureDataStore2::FeatureSetQueryParameters sets;
    EXPECT_EQ(TAKEngineJNI::Interop::Feature::Interop_marshal(mparams, *env, sets), TE_IllegalState);
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniKernelFeatureDataStore, QueryFeaturesCountCountsFeatures)
{
    JNIEnv *env = jnitest::launcher_env();
    ASSERT_NE(env, nullptr);
    jobject impl = newRecordingStore(*env);
    ASSERT_NE(impl, nullptr) << "JniTestsMain$RecordingFeatureDataStore did not load";

    ManagedFeatureDataStore2 store(*env, impl);
    clearCalls(*env);
    int count = -1;
    ASSERT_EQ(store.queryFeaturesCount(&count), TE_Ok);
    EXPECT_EQ(count, 7) << "Java calls: " << calls(*env);
    EXPECT_EQ(calls(*env), "queryFeaturesCount");
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniKernelFeatureDataStore, FeatureSetVisibilityReachesTheRightMethods)
{
    JNIEnv *env = jnitest::launcher_env();
    ASSERT_NE(env, nullptr);
    jobject impl = newRecordingStore(*env);
    ASSERT_NE(impl, nullptr) << "JniTestsMain$RecordingFeatureDataStore did not load";

    ManagedFeatureDataStore2 store(*env, impl);
    clearCalls(*env);
    ASSERT_EQ(store.setFeatureSetVisible(5, true), TE_Ok);
    EXPECT_EQ(calls(*env), "setFeatureSetVisible");

    clearCalls(*env);
    FeatureDataStore2::FeatureSetQueryParameters params;
    ASSERT_EQ(store.setFeatureSetsVisible(params, true), TE_Ok);
    EXPECT_EQ(calls(*env), "setFeatureSetsVisible");
    EXPECT_FALSE(env->ExceptionCheck());
}
