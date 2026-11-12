/*
 * G1.17 noslf4j-mode pins: JNI_OnLoad's ManagedLogger when
 * com.atakmap.coremap.log.Log cannot load (slf4j-api left off the
 * classpath; Log's class init needs it). Before the patch, the logger's
 * GetStaticMethodID(NULL, ...) crashed the JVM inside System.load, so
 * reaching these tests at all is the first half of the pin: JniTestsMain
 * loaded the glue and JNI_OnLoad returned. The second half is native
 * logging at every level going quiet, with a clean JNIEnv.
 * Patch under test: common-managedlogger-guards.patch.
 */
#include <jni.h>

#include <util/Logging2.h>

#include <gtest/gtest.h>

#include "jni_test_env.hpp"

namespace
{
    class JniNoSlf4jLogger : public JniNoSlf4jTest
    {
    protected:
        /* true when FindClass fails; the pending error is cleared */
        static bool classMissing(JNIEnv &env, const char *name)
        {
            jclass cls = env.FindClass(name);
            if(env.ExceptionCheck())
                env.ExceptionClear();
            if(!cls)
                return true;
            env.DeleteLocalRef(cls);
            return false;
        }
    };
}

TEST_F(JniNoSlf4jLogger, TheVectorIsInPlace)
{
    JNIEnv *env = jnitest::launcher_env();
    ASSERT_NE(env, nullptr);

    /* without these, the pin below would pass with or without the patch */
    EXPECT_TRUE(classMissing(*env, "org/slf4j/LoggerFactory"));
    EXPECT_TRUE(classMissing(*env, "com/atakmap/coremap/log/Log"));
    EXPECT_FALSE(classMissing(*env, "com/atakmap/interop/Pointer"));
}

TEST_F(JniNoSlf4jLogger, NativeLoggingGoesQuiet)
{
    JNIEnv *env = jnitest::launcher_env();
    ASSERT_NE(env, nullptr);

    using namespace TAK::Engine::Util;
    const LogLevel levels[] = { TELL_All, TELL_Debug, TELL_Info, TELL_Warning, TELL_Error, TELL_Severe };
    for(const LogLevel level : levels)
        Logger_log(level, "jni-tests: noslf4j logger pin, level %d", (int)level);
    EXPECT_FALSE(env->ExceptionCheck());
}
