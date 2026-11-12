/*
 * jni_test_env.hpp — G1.9 JNI guard/behavior canary environment
 * (dev/g1/NOTES.md §G1.9).
 *
 * Boots a REAL desktop JVM in-process (JAVA_HOME -> dlopen libjli ->
 * JNI_CreateJavaVM) and hands it to the guard pins. Anti-mock by design:
 * no fake JNIEnv anywhere — the desktop JVM is itself the failure vector:
 *
 *   guards mode (TAKJNI_TEST_MODE=guards, empty classpath): every
 *     kernel/Android class lookup fails, so the wave-5/6 class-init
 *     guards must surface as neutral bailouts and JNI_OnLoad must fail
 *     cleanly (JNI_ERR) instead of dying on a pending exception.
 *
 *   kernel mode (TAKJNI_TEST_MODE=kernel, TAKJNI_TEST_CLASSPATH = the
 *     takkernel jars): the kernel-backed Java classes load, and the
 *     IOProviderFactory proxy is installed as the engine's global
 *     Filesystem — the behavioral pins run through it on real files.
 *
 * Boot probe order cribbed from dev/g2/shell/jni_boot.c (M3.2 shell —
 * proven against this box's Zulu 8). One JVM per process, never
 * destroyed: DestroyJavaVM on a JVM the engine has registered globals
 * into hangs at exit (jni_boot.c's rule).
 */
#ifndef DEV_G1_JNI_TESTS_JNI_TEST_ENV_HPP_INCLUDED
#define DEV_G1_JNI_TESTS_JNI_TEST_ENV_HPP_INCLUDED

#include <jni.h>

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <string>

#include <gtest/gtest.h>

namespace jnitest
{
    typedef jint (*CreateJavaVM_t)(JavaVM **, void **, void *);

    /* JAVA_HOME -> the first libjli.dylib that dlopens AND exports
     * JNI_CreateJavaVM. Probe order from jni_boot.c. */
    inline bool find_libjli(std::string &value)
    {
        const char *home = getenv("JAVA_HOME");
        if(!home || !*home)
            return false;
        static const char *rel[] = {
            "jre/lib/jli/libjli.dylib",               /* JDK 8 layout */
            "Contents/Home/jre/lib/jli/libjli.dylib", /* a bundle root */
            "Contents/MacOS/libjli.dylib",            /* JDK 8 bundle copy */
            "lib/libjli.dylib",                       /* JDK 9+ */
        };
        char path[4096];
        for(size_t i = 0; i < sizeof(rel)/sizeof(rel[0]); i++) {
            snprintf(path, sizeof(path), "%s/%s", home, rel[i]);
            void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
            if(!h)
                continue;
            if(dlsym(h, "JNI_CreateJavaVM")) {
                value = path;
                return true;
            }
            dlclose(h);
        }
        return false;
    }

    inline JavaVM *boot_jvm()
    {
        static JavaVM *vm = NULL;
        static bool tried = false;
        if(tried)
            return vm;
        tried = true;

        std::string jli;
        if(!find_libjli(jli))
            return vm = NULL;
        void *h = dlopen(jli.c_str(), RTLD_NOW | RTLD_LOCAL);
        if(!h)
            return vm = NULL;
        CreateJavaVM_t create = (CreateJavaVM_t)dlsym(h, "JNI_CreateJavaVM");
        if(!create)
            return vm = NULL;

        /* guards mode runs with NO classpath: the kernel classes MUST be
         * absent, or the guard pins would pin nothing. run.sh enforces
         * this with `env -u` on the guards invocation. */
        JavaVMInitArgs args;
        memset(&args, 0, sizeof(args));
        args.version = JNI_VERSION_1_8;
        args.ignoreUnrecognized = JNI_FALSE;
        /* TAKJNI_TEST_JVM_OPTS: extra JVM options, space-separated —
         * debugging knob (e.g. "-Xcheck:jni" makes hotspot name the
         * exact bad JNI call instead of crashing blind). */
        JavaVMOption opts[9];
        char cpopt[4096];
        static char xbuf[8][256];
        int nopt = 0;
        const char *cp = getenv("TAKJNI_TEST_CLASSPATH");
        if(cp && *cp) {
            snprintf(cpopt, sizeof(cpopt), "-Djava.class.path=%s", cp);
            opts[nopt].optionString = cpopt;
            opts[nopt].extraInfo = NULL;
            nopt++;
        }
        const char *xo = getenv("TAKJNI_TEST_JVM_OPTS");
        if(xo && *xo) {
            char tmp[2048];
            snprintf(tmp, sizeof(tmp), "%s", xo);
            char *save = NULL;
            int nx = 0;
            for(char *tok = strtok_r(tmp, " ", &save);
                tok && nx < 8;
                tok = strtok_r(NULL, " ", &save)) {
                snprintf(xbuf[nx], sizeof(xbuf[0]), "%s", tok);
                opts[nopt].optionString = xbuf[nx];
                opts[nopt].extraInfo = NULL;
                nx++;
                nopt++;
            }
        }
        args.options = opts;
        args.nOptions = nopt;

        JNIEnv *env = NULL;
        if(create(&vm, (void **)&env, &args) != JNI_OK)
            return vm = NULL;
        return vm;
    }

    /* kernel mode: the launcher (JniTestsMain) hands the running VM's
     * JNIEnv to the module entry, which stashes it. module_main.cpp links
     * into BOTH products (build-native.sh; ld64 refuses undefined weak
     * imports in executables, NOTES §G1.9), so the function always exists:
     * in the guards binary nothing stashes an env and it returns NULL.
     * (The old null check on the function's address was always true:
     * clang -Wpointer-bool-conversion, once per including TU.) */
    extern "C" JNIEnv *takengine_jni_tests_env(void);

    inline JNIEnv *launcher_env()
    {
        return takengine_jni_tests_env();
    }

    inline JNIEnv *jni_env()
    {
        JavaVM *vm = boot_jvm();
        if(!vm)
            return NULL;
        void *env = NULL;
        if(vm->GetEnv(&env, JNI_VERSION_1_8) != JNI_OK)
            return NULL;
        return (JNIEnv *)env;
    }
}

/* Fixture bases. The wrong-mode / no-JVM cases SKIP, never FAIL: the
 * native build itself needs no JDK (run.sh is the interface; CI's native
 * job installs JDK 21 before build-native.sh). */
class JniGuardsTest : public ::testing::Test
{
protected:
    void SetUp() override
    {
        const char *mode = getenv("TAKJNI_TEST_MODE");
        if(!mode || strcmp(mode, "guards") != 0)
            GTEST_SKIP() << "guards suite: run via dev/g1/jni-tests/run.sh "
                            "(TAKJNI_TEST_MODE=guards, no classpath)";
        if(!jnitest::jni_env())
            GTEST_SKIP() << "no desktop JVM: JAVA_HOME unset or libjli unusable";
    }
};

class JniKernelTest : public ::testing::Test
{
protected:
    void SetUp() override
    {
        const char *mode = getenv("TAKJNI_TEST_MODE");
        if(!mode || strcmp(mode, "kernel") != 0)
            GTEST_SKIP() << "kernel suite: run via dev/g1/jni-tests/run.sh "
                            "(TAKJNI_TEST_MODE=kernel, TAKJNI_TEST_CLASSPATH=jars)";
        JNIEnv *env = jnitest::launcher_env();
        if(!env)
            GTEST_SKIP() << "kernel suite runs under the java launcher "
                            "(dev/g1/jni-tests/run.sh kernel mode)";
        install_filesystem(*env);
    }

    /* The IOProviderFactoryProxy is TU-local (anonymous namespace in
     * jioproviderfactory.cpp); the only public way in is the Java-side
     * installFactory, which registers it as the engine's global Filesystem
     * (IO_setFilesystem) — the same install production does. */
    void install_filesystem(JNIEnv &env)
    {
        static bool done = false;
        static bool ok = false;
        if(done) {
            ASSERT_TRUE(ok) << "IOProviderFactory install failed earlier in this process";
            return;
        }
        done = true;

        /* the launcher's static init (JniTestsMain) already System.load'ed
         * the engine dylibs — JNI_OnLoad ran in the healthy launcher
         * context, binding the native installFactory implementation */

        jclass cls = env.FindClass("com/atakmap/coremap/io/IOProviderFactory");
        if(!cls)
            env.ExceptionClear();
        ASSERT_NE(cls, nullptr) << "kernel classpath: IOProviderFactory missing";

        jmethodID install = env.GetStaticMethodID(cls, "installFactory", "()J");
        if(!install)
            env.ExceptionClear();
        ASSERT_NE(install, nullptr) << "IOProviderFactory.installFactory missing";

        const jlong ptr = env.CallStaticLongMethod(cls, install);
        const jboolean threw = env.ExceptionCheck();
        if(threw) {
            env.ExceptionDescribe();
            env.ExceptionClear();
        }
        ASSERT_FALSE(threw) << "installFactory threw (stack trace above)";
        ok = (ptr != 0);
        ASSERT_TRUE(ok) << "installFactory returned no handle";
    }
};

#endif
