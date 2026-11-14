/*
 * G1.9 kernel-mode pins: the Java-backed IOProviderFactory proxy as the
 * engine's global Filesystem, installed the way production installs it
 * (Java IOProviderFactory.installFactory -> IO_setFilesystem). Real JVM,
 * real java.io.File, real temp files:
 *
 *  - IO_getFileCount's isDirectory branch (the wave-5 fix: pristine
 *    calls isFile twice, so a directory fell through to TE_IllegalState),
 *  - the wave-5 ExceptionClear guards: real Java failures must surface
 *    as TE_Err with a CLEAN JNIEnv (pristine leaves the exception
 *    pending and the next JNI call misfires).
 *
 *  - issue 164: when the proxy's isFile or isDirectory query fails,
 *    getFileCount, listFiles and length fail too, instead of reading the
 *    flag the previous query left (JniKernelFilesystemQueryFails).
 *
 * Patches under test: ioproviderfactory-guards-and-filecount.patch,
 * ioproviderfactory-sweep-init-guards.patch,
 * wave7-rest-ioprovider-query-errors.patch.
 */
#include <jni.h>

#include <util/IO2.h>
#include <db/Database2.h>
#include <db/DatabaseFactory.h>
#include <db/DatabaseInformation.h>

#include <gtest/gtest.h>

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <string>
#include <vector>

#include <port/STLVectorAdapter.h>

#include "jni_test_env.hpp"

namespace
{
    class JniKernelFilesystem : public JniKernelTest
    { };
    class JniKernelDatabase : public JniKernelTest
    { };

    /* The proxy over JniTestsMain$ScriptedIsDirectory: every path exists,
     * and isDirectory answers from a script ('t', 'f', 'x' = throw), so a
     * test picks which of the proxy's queries fails. Java's isFile is
     * exists && !isDirectory, so isFile fails when its isDirectory call
     * does. TearDown puts the real provider back for the other tests. */
    class JniKernelFilesystemQueryFails : public JniKernelTest
    {
    protected:
        void script(const char *answers)
        {
            JNIEnv &env = *jnitest::launcher_env();
            call(env, "install", answers);
        }
        void TearDown() override
        {
            if(JNIEnv *env = jnitest::launcher_env())
                call(*env, "restore", nullptr);
        }
    private:
        static void call(JNIEnv &env, const char *method, const char *answers)
        {
            jclass c = env.FindClass("JniTestsMain$ScriptedIsDirectory");
            ASSERT_NE(c, nullptr) << "JniTestsMain$ScriptedIsDirectory did not load";
            if(answers) {
                jstring s = env.NewStringUTF(answers);
                env.CallStaticVoidMethod(c, env.GetStaticMethodID(c, method, "(Ljava/lang/String;)V"), s);
            } else {
                env.CallStaticVoidMethod(c, env.GetStaticMethodID(c, method, "()V"));
            }
            const jboolean threw = env.ExceptionCheck();
            if(threw) {
                env.ExceptionDescribe();
                env.ExceptionClear();
            }
            ASSERT_FALSE(threw) << "ScriptedIsDirectory." << method << " threw";
        }
    };

    const char kScriptedPath[] = "/takjni-scripted/path";

    std::string make_temp_dir()
    {
        char tmpl[] = "/tmp/takjni-kernel-XXXXXX";
        const char *d = mkdtemp(tmpl);
        return d ? std::string(d) : std::string();
    }

    /* The temp dirs are flat (touch_file only): unlink each entry, then
     * the dir. remove(dir) alone fails with ENOTEMPTY on a non-empty
     * directory, which leaked a /tmp/takjni-kernel-* dir per run. The
     * EXPECT makes a leak a test failure. */
    void remove_flat_dir(const std::string &dir)
    {
        if(DIR *d = opendir(dir.c_str())) {
            while(const dirent *e = readdir(d)) {
                if(strcmp(e->d_name, ".") != 0 && strcmp(e->d_name, "..") != 0)
                    unlink((dir + "/" + e->d_name).c_str());
            }
            closedir(d);
        }
        EXPECT_EQ(rmdir(dir.c_str()), 0) << "temp dir not removed: " << dir;
    }

    void touch_file(const std::string &dir, const char *name)
    {
        const std::string p = dir + "/" + name;
        FILE *f = fopen(p.c_str(), "w");
        ASSERT_NE(f, nullptr);
        fputs("x", f);
        fclose(f);
    }
}

TEST_F(JniKernelFilesystem, GetFileCountOfADirectory)
{
    const std::string dir = make_temp_dir();
    ASSERT_FALSE(dir.empty());
    touch_file(dir, "a.txt");
    touch_file(dir, "b.txt");

    std::size_t count = 0u;
    /* through the Java-backed proxy: exists -> isFile -> isDirectory ->
     * listFiles -> recurse — the fixed isDirectory branch */
    EXPECT_EQ(TAK::Engine::Util::IO_getFileCount(&count, dir.c_str()),
              TAK::Engine::Util::TE_Ok);
    EXPECT_EQ(count, 2u);   /* pristine: TE_IllegalState (isFile twice) */

    remove_flat_dir(dir);
}

TEST_F(JniKernelFilesystem, GetFileCountOfAFile)
{
    const std::string dir = make_temp_dir();
    ASSERT_FALSE(dir.empty());
    touch_file(dir, "one.txt");

    std::size_t count = 0u;
    EXPECT_EQ(TAK::Engine::Util::IO_getFileCount(&count, (dir + "/one.txt").c_str()),
              TAK::Engine::Util::TE_Ok);
    EXPECT_EQ(count, 1u);

    remove_flat_dir(dir);
}

TEST_F(JniKernelFilesystem, GetFileCountOfAMissingPath)
{
    std::size_t count = 0u;
    EXPECT_EQ(TAK::Engine::Util::IO_getFileCount(&count, "/nonexistent-takjni/gone"),
              TAK::Engine::Util::TE_InvalidArg);
}

TEST_F(JniKernelFilesystem, CreateTempFileOnABadDirBailsClean)
{
    JNIEnv *env = jnitest::launcher_env();
    ASSERT_NE(env, nullptr);

    TAK::Engine::Port::String value;
    /* the Java side throws IOException for the missing parent directory */
    EXPECT_EQ(TAK::Engine::Util::IO_createTempFile(value, "takjni", ".tmp", "/nonexistent-takjni"),
              TAK::Engine::Util::TE_Err);
    /* the wave-5 ExceptionClear guard: pristine leaves the exception pending */
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniKernelFilesystem, DeleteOfAMissingPathIsTErr)
{
    /* no exception on the Java side — File.delete just reports false —
     * so this pins the success-check path: TE_Err either way, cleanly */
    EXPECT_EQ(TAK::Engine::Util::IO_delete("/nonexistent-takjni/gone"),
              TAK::Engine::Util::TE_Err);
}

TEST_F(JniKernelDatabase, CreateOnABadUriBailsClean)
{
    JNIEnv *env = jnitest::launcher_env();
    ASSERT_NE(env, nullptr);

    TAK::Engine::DB::DatabasePtr db(nullptr, nullptr);
    /* the proxy is a registered DatabaseProvider; the Java side fails to
     * open the (nonexistent) database and throws */
    EXPECT_EQ(TAK::Engine::DB::DatabaseFactory_create(
                  db, TAK::Engine::DB::DatabaseInformation("/nonexistent-takjni/test.db")),
              TAK::Engine::Util::TE_Err);
    EXPECT_FALSE(env->ExceptionCheck());
}

/* Issue 164. The comment on each test gives the Java isDirectory calls in
 * order, and what the engine returned before the fix. */

TEST_F(JniKernelFilesystemQueryFails, GetFileCountWhenIsFileFails)
{
    /* the proxy's isFile: throws. Before: TE_Ok and a count of 1, because
     * exists' true was still in the flag */
    script("x");
    std::size_t count = 0u;
    EXPECT_EQ(TAK::Engine::Util::IO_getFileCount(&count, kScriptedPath), TAK::Engine::Util::TE_Err);
    EXPECT_FALSE(jnitest::launcher_env()->ExceptionCheck());
}

TEST_F(JniKernelFilesystemQueryFails, GetFileCountWhenIsDirectoryFails)
{
    /* isFile: true (not a file); isDirectory: throws. Before: TE_IllegalState */
    script("tx");
    std::size_t count = 0u;
    EXPECT_EQ(TAK::Engine::Util::IO_getFileCount(&count, kScriptedPath), TAK::Engine::Util::TE_Err);
    EXPECT_FALSE(jnitest::launcher_env()->ExceptionCheck());
}

TEST_F(JniKernelFilesystemQueryFails, ListFilesWhenIsFileFails)
{
    /* IO_listFiles' own isDirectory: true; the proxy's isFile: throws.
     * Before: TE_InvalidArg, as if the path were a file */
    script("tx");
    std::vector<TAK::Engine::Port::String> files;
    TAK::Engine::Port::STLVectorAdapter<TAK::Engine::Port::String> files_w(files);
    EXPECT_EQ(TAK::Engine::Util::IO_listFiles(files_w, kScriptedPath), TAK::Engine::Util::TE_Err);
    EXPECT_FALSE(jnitest::launcher_env()->ExceptionCheck());
}

TEST_F(JniKernelFilesystemQueryFails, ListFilesWhenIsDirectoryFails)
{
    /* IO_listFiles' isDirectory: true; isFile: true (not a file); the
     * proxy's isDirectory: throws. Before: TE_IllegalState */
    script("ttx");
    std::vector<TAK::Engine::Port::String> files;
    TAK::Engine::Port::STLVectorAdapter<TAK::Engine::Port::String> files_w(files);
    EXPECT_EQ(TAK::Engine::Util::IO_listFiles(files_w, kScriptedPath), TAK::Engine::Util::TE_Err);
    EXPECT_FALSE(jnitest::launcher_env()->ExceptionCheck());
}

TEST_F(JniKernelFilesystemQueryFails, LengthWhenIsFileFails)
{
    /* IO_length's own isDirectory: false; the proxy's isFile: throws.
     * Before: TE_Ok, with Java's length (42) read as a file's */
    script("fx");
    int64_t length = 0;
    EXPECT_EQ(TAK::Engine::Util::IO_length(&length, kScriptedPath), TAK::Engine::Util::TE_Err);
    EXPECT_FALSE(jnitest::launcher_env()->ExceptionCheck());
}

TEST_F(JniKernelFilesystemQueryFails, LengthWhenIsDirectoryFails)
{
    /* IO_length's isDirectory: false; isFile: true (not a file); the
     * proxy's isDirectory: throws. Before: TE_IllegalState */
    script("ftx");
    int64_t length = 0;
    EXPECT_EQ(TAK::Engine::Util::IO_length(&length, kScriptedPath), TAK::Engine::Util::TE_Err);
    EXPECT_FALSE(jnitest::launcher_env()->ExceptionCheck());
}
