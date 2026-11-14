/*
 * Issue 161 missing-member pins: a JNI class init whose member lookup fails
 * on a real JVM must leave the JNIEnv clean. A failed GetMethodID leaves
 * NoSuchMethodError pending; before the fix the init returned false with it
 * still pending, and its caller's next JNI calls ran with an exception
 * pending, which JNI doesn't allow.
 *
 * The vector: run.sh puts missing-member/android/net/Uri.java, a Uri without
 * parse(String), ahead of the kernel jars. ManagedDatabaseProvider's class
 * init looks up Uri.parse, the init issue 161 was found on (PR #160).
 * Patch under test: wave7-sweep-class-init-clears-exception.patch.
 */
#include <jni.h>

#include <db/DatabaseInformation.h>

#include <gtest/gtest.h>

#include "jni_test_env.hpp"
#include "interop/db/ManagedDatabaseProvider.h"

namespace
{
    using TAK::Engine::Util::TE_Err;

    class JniMissingMemberDb : public JniMissingMemberTest
    {
    protected:
        jobject provider(JNIEnv &env)
        {
            jclass c = env.FindClass("JniTestsMain$RecordingDb");
            if(!c)
                return nullptr;
            return env.CallStaticObjectMethod(c, env.GetStaticMethodID(c, "provider", "()Ljava/lang/Object;"));
        }
        /* true when the exception was pending; reports and clears it so a
         * failure doesn't run on into the next check */
        static bool takePending(JNIEnv &env)
        {
            if(!env.ExceptionCheck())
                return false;
            env.ExceptionDescribe();
            env.ExceptionClear();
            return true;
        }
    };
}

TEST_F(JniMissingMemberDb, TheVectorIsInPlace)
{
    JNIEnv *env = jnitest::launcher_env();
    ASSERT_NE(env, nullptr);

    /* without these, the pin below would pass with or without the fix */
    jclass uri = env->FindClass("android/net/Uri");
    ASSERT_FALSE(takePending(*env));
    ASSERT_NE(uri, nullptr);
    EXPECT_EQ(env->GetStaticMethodID(uri, "parse", "(Ljava/lang/String;)Landroid/net/Uri;"), nullptr);
    EXPECT_TRUE(takePending(*env)) << "GetStaticMethodID left no NoSuchMethodError pending";
}

TEST_F(JniMissingMemberDb, FailedProviderInitLeavesTheEnvClean)
{
    JNIEnv *env = jnitest::launcher_env();
    ASSERT_NE(env, nullptr);
    jobject impl = provider(*env);
    ASSERT_FALSE(takePending(*env));
    ASSERT_NE(impl, nullptr) << "JniTestsMain$RecordingDb did not load";

    ManagedDatabaseProvider provider(*env, impl);
    EXPECT_FALSE(takePending(*env)) << "the class init left its NoSuchMethodError pending";

    TAK::Engine::DB::DatabasePtr db(nullptr, nullptr);
    EXPECT_EQ(provider.create(db, TAK::Engine::DB::DatabaseInformation("/takjni/missing-member.db")), TE_Err);
    EXPECT_EQ(db.get(), nullptr);
    EXPECT_FALSE(takePending(*env));
}
