/*
 * Issue 142, batch 3 (wave 7, elevation area): the two Java-backed
 * elevation wrappers when their class init fails, and the chunk cursor's
 * strings when it doesn't.
 *
 * Guards mode (empty classpath, every lookup fails). Each wrapper wraps a
 * real Java object that is none of the classes it expects (a String, as
 * feature_guards_test.cpp does), and:
 *  - its constructor must not call through the NULL IDs (getType, getUri
 *    and getBounds in ManagedElevationChunk; getName in
 *    ManagedElevationSource);
 *  - every consumer must bail (TE_Err, or NaN, false and 0 for the
 *    getters that return plain values), and the destructors must not call
 *    dispose, leaving the JNIEnv clean.
 *
 * Kernel mode (the takkernel jars), over JniTestsMain.RecordingElevation:
 * the cursor ManagedElevationSource::query returns keeps getType's string
 * when getUri runs after it (upstream stored the type in the URI's
 * member, so getUri overwrote the string getType had returned).
 *
 * Patches under test: managedelevation-consumer-guards.patch and
 * managedelevation-wrong-members.patch.
 */
#include <jni.h>

#include <elevation/ElevationChunk.h>
#include <elevation/ElevationSource.h>

#include <gtest/gtest.h>

#include <cmath>
#include <string>

#include "jni_test_env.hpp"
#include "interop/elevation/ManagedElevationChunk.h"
#include "interop/elevation/ManagedElevationSource.h"

namespace
{
    using TAK::Engine::Elevation::ElevationChunkCursorPtr;
    using TAK::Engine::Elevation::ElevationSource;
    using TAK::Engine::Util::TAKErr;
    using TAK::Engine::Util::TE_Err;
    using TAK::Engine::Util::TE_Ok;
    using TAKEngineJNI::Interop::Elevation::ManagedElevationChunk;
    using TAKEngineJNI::Interop::Elevation::ManagedElevationSource;

    class CountingListener : public ElevationSource::OnContentChangedListener
    {
    public:
        TAKErr onContentChanged(const ElevationSource &) NOTHROWS override
        {
            ++changes;
            return TE_Ok;
        }
        int changes = 0;
    };

    class JniGuardsElevation : public JniGuardsTest
    {
    protected:
        /* a live Java object that is none of the elevation classes */
        jobject javaObject(JNIEnv &env)
        {
            return env.NewStringUTF("not an elevation class");
        }
    };

    class JniKernelElevation : public JniKernelTest
    {
    protected:
        jclass recorder(JNIEnv &env)
        {
            return env.FindClass("JniTestsMain$RecordingElevation");
        }
        jobject newRecordingSource(JNIEnv &env)
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

TEST_F(JniGuardsElevation, ChunkBailsOut)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    {
        ManagedElevationChunk chunk(env, javaObject(*env));
        EXPECT_EQ(chunk.getUri(), nullptr);
        EXPECT_EQ(chunk.getType(), nullptr);
        EXPECT_EQ(chunk.getBounds(), nullptr);
        EXPECT_TRUE(std::isnan(chunk.getResolution()));
        EXPECT_TRUE(std::isnan(chunk.getCE()));
        EXPECT_TRUE(std::isnan(chunk.getLE()));
        EXPECT_FALSE(chunk.isAuthoritative());
        EXPECT_EQ(chunk.getFlags(), 0u);

        TAK::Engine::Elevation::ElevationChunkDataPtr data(nullptr, nullptr);
        EXPECT_EQ(chunk.createData(data), TE_Err);
        EXPECT_EQ(data.get(), nullptr);
        double hae = 0;
        EXPECT_EQ(chunk.sample(&hae, 37.77, -122.47), TE_Err);
        const double lat[] = { 37.77 };
        const double lng[] = { -122.47 };
        double out[] = { NAN };
        EXPECT_EQ(chunk.sample(out, 1, lat, lng, 1, 1, 1), TE_Err);
    } // the destructor's dispose
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniGuardsElevation, SourceBailsOut)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    CountingListener listener;
    {
        ManagedElevationSource source(env, javaObject(*env));
        EXPECT_EQ(source.getName(), nullptr);

        ElevationChunkCursorPtr cursor(nullptr, nullptr);
        ElevationSource::QueryParameters params;
        EXPECT_EQ(source.query(cursor, params), TE_Err);
        EXPECT_EQ(cursor.get(), nullptr);

        const auto bounds = source.getBounds();
        EXPECT_TRUE(std::isnan(bounds.minX));

        EXPECT_EQ(source.addOnContentChangedListener(&listener), TE_Err);
        EXPECT_EQ(source.removeOnContentChangedListener(&listener), TE_Ok); // never registered
    } // the destructor has no listener to unbind
    EXPECT_EQ(listener.changes, 0);
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniKernelElevation, CursorTypeAndUriKeepTheirOwnStrings)
{
    JNIEnv *env = jnitest::launcher_env();
    ASSERT_NE(env, nullptr);
    jobject impl = newRecordingSource(*env);
    ASSERT_NE(impl, nullptr) << "JniTestsMain$RecordingElevation did not load";

    ManagedElevationSource source(env, impl);
    EXPECT_STREQ(source.getName(), "RecordingElevation");
    clearCalls(*env);

    ElevationChunkCursorPtr cursor(nullptr, nullptr);
    ElevationSource::QueryParameters params;
    ASSERT_EQ(source.query(cursor, params), TE_Ok) << "Java calls: " << calls(*env);
    ASSERT_NE(cursor.get(), nullptr);
    ASSERT_EQ(cursor->moveToNext(), TE_Ok);

    const char *type = nullptr;
    ASSERT_EQ(cursor->getType(&type), TE_Ok);
    const char *uri = nullptr;
    ASSERT_EQ(cursor->getUri(&uri), TE_Ok);
    // read the type only after getUri: upstream kept both in one member,
    // and both strings fit Port::String's inline buffer, so getUri
    // overwrote the type in place
    EXPECT_EQ(std::string(type ? type : "(null)"), "DTED2");
    EXPECT_EQ(std::string(uri ? uri : "(null)"), "n37w122.dt2");
    EXPECT_EQ(calls(*env), "query,moveToNext,getType,getUri");
    EXPECT_FALSE(env->ExceptionCheck());
}
