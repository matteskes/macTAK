/*
 * Issue 142, batch 2 (wave 7, db area): the four Java-backed db wrappers
 * when their class init fails, and two members they reached wrongly when
 * it doesn't.
 *
 * Guards mode (empty classpath, every lookup fails). Each wrapper wraps a
 * real Java object that is none of the classes it expects (a String, as
 * feature_guards_test.cpp does), and:
 *  - every consumer must bail (TE_Err) instead of calling through a NULL
 *    method ID, and leave the JNIEnv clean;
 *  - the destructors of ManagedDatabase2 and ManagedStatement must not
 *    call close through a NULL ID;
 *  - ManagedQuery's and ManagedStatement's moves and binds go through
 *    db/Interop.cpp, whose lazy init already bails TE_IllegalState.
 *
 * Kernel mode (the takkernel jars), over JniTestsMain.RecordingDb:
 *  - ManagedDatabaseProvider::create reaches IOProvider.createDatabase
 *    with the URI it was given (upstream's init looked up a
 *    DatabaseInformation constructor 5.5 doesn't have, so create called
 *    NewObject through a NULL ID);
 *  - RowIterator_isClosed asks isClosed (upstream asked moveToNext, which
 *    advanced the cursor).
 *
 * Patches under test: manageddb-consumer-guards.patch and
 * manageddb-wrong-members.patch.
 */
#include <jni.h>

#include <db/DatabaseInformation.h>

#include <gtest/gtest.h>

#include <string>

#include "jni_test_env.hpp"
#include "interop/db/Interop.h"
#include "interop/db/ManagedDatabase2.h"
#include "interop/db/ManagedDatabaseProvider.h"
#include "interop/db/ManagedQuery.h"
#include "interop/db/ManagedStatement.h"

namespace
{
    using TAK::Engine::Util::TE_Err;
    using TAK::Engine::Util::TE_IllegalState;
    using TAK::Engine::Util::TE_Ok;

    class JniGuardsDb : public JniGuardsTest
    {
    protected:
        /* a live Java object that is none of the db classes */
        jobject javaObject(JNIEnv &env)
        {
            return env.NewStringUTF("not a db class");
        }
    };

    class JniKernelDb : public JniKernelTest
    {
    protected:
        jclass recorder(JNIEnv &env)
        {
            return env.FindClass("JniTestsMain$RecordingDb");
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

TEST_F(JniGuardsDb, DatabaseConsumersBailOut)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    {
        ManagedDatabase2 db(*env, javaObject(*env));

        const char *args[] = { "1" };
        EXPECT_EQ(db.execute("SELECT ?", args, 1), TE_Err);
        TAK::Engine::DB::QueryPtr query(nullptr, nullptr);
        EXPECT_EQ(db.query(query, "SELECT 1"), TE_Err);
        EXPECT_EQ(db.compileQuery(query, "SELECT 1"), TE_Err);
        EXPECT_EQ(query.get(), nullptr);
        TAK::Engine::DB::StatementPtr stmt(nullptr, nullptr);
        EXPECT_EQ(db.compileStatement(stmt, "SELECT 1"), TE_Err);
        EXPECT_EQ(stmt.get(), nullptr);
        bool flag = false;
        EXPECT_EQ(db.isReadOnly(&flag), TE_Err);
        EXPECT_EQ(db.inTransaction(&flag), TE_Err);
        int version = -1;
        EXPECT_EQ(db.getVersion(&version), TE_Err);
        EXPECT_EQ(db.setVersion(2), TE_Err);
        EXPECT_EQ(db.beginTransaction(), TE_Err);
        EXPECT_EQ(db.setTransactionSuccessful(), TE_Err);
        EXPECT_EQ(db.endTransaction(), TE_Err);
    } // the destructor's close
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniGuardsDb, QueryConsumersBailOut)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    {
        ManagedQuery query(*env, javaObject(*env));

        std::size_t index = 0;
        EXPECT_EQ(query.getColumnIndex(&index, "name"), TE_Err);
        const char *name = nullptr;
        EXPECT_EQ(query.getColumnName(&name, 0), TE_Err);
        EXPECT_EQ(query.getColumnCount(&index), TE_Err);
        const uint8_t *blob = nullptr;
        std::size_t len = 0;
        EXPECT_EQ(query.getBlob(&blob, &len, 0), TE_Err);
        const char *str = nullptr;
        EXPECT_EQ(query.getString(&str, 0), TE_Err);
        int32_t i = 0;
        EXPECT_EQ(query.getInt(&i, 0), TE_Err);
        int64_t l = 0;
        EXPECT_EQ(query.getLong(&l, 0), TE_Err);
        double d = 0;
        EXPECT_EQ(query.getDouble(&d, 0), TE_Err);
        ManagedQuery::FieldType type;
        EXPECT_EQ(query.getType(&type, 0), TE_Err);
        bool isNull = false;
        EXPECT_EQ(query.isNull(&isNull, 0), TE_Err);

        EXPECT_EQ(query.moveToNext(), TE_IllegalState);
        EXPECT_EQ(query.bindInt(1, 7), TE_IllegalState);
        EXPECT_EQ(query.clearBindings(), TE_IllegalState);
    } // the destructor's RowIterator_close
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniGuardsDb, StatementBailsOut)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    {
        ManagedStatement stmt(*env, javaObject(*env));
        EXPECT_EQ(stmt.execute(), TE_Err);
        EXPECT_EQ(stmt.bindString(1, "x"), TE_IllegalState);
    } // the destructor's close
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniGuardsDb, ProviderCreateBailsOut)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    {
        ManagedDatabaseProvider provider(*env, javaObject(*env));
        TAK::Engine::DB::DatabasePtr db(nullptr, nullptr);
        EXPECT_EQ(provider.create(db, TAK::Engine::DB::DatabaseInformation("/nonexistent-takjni/test.db")), TE_Err);
        EXPECT_EQ(db.get(), nullptr);
    }
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniKernelDb, ProviderCreateReachesCreateDatabase)
{
    JNIEnv *env = jnitest::launcher_env();
    ASSERT_NE(env, nullptr);
    jobject impl = make(*env, "provider");
    ASSERT_NE(impl, nullptr) << "JniTestsMain$RecordingDb did not load";

    ManagedDatabaseProvider provider(*env, impl);
    clearCalls(*env);
    {
        TAK::Engine::DB::DatabasePtr db(nullptr, nullptr);
        ASSERT_EQ(provider.create(db, TAK::Engine::DB::DatabaseInformation("/takjni/recorded.db")), TE_Ok)
            << "Java calls: " << calls(*env);
        EXPECT_NE(db.get(), nullptr);
        EXPECT_EQ(calls(*env), "createDatabase /takjni/recorded.db");
        clearCalls(*env);
    } // ManagedDatabase2's destructor closes the Java database
    EXPECT_EQ(calls(*env), "close");
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniKernelDb, RowIteratorIsClosedAsksIsClosed)
{
    JNIEnv *env = jnitest::launcher_env();
    ASSERT_NE(env, nullptr);
    jobject rows = make(*env, "rowIterator");
    ASSERT_NE(rows, nullptr) << "JniTestsMain$RecordingDb did not load";

    clearCalls(*env);
    bool closed = false;
    ASSERT_EQ(TAKEngineJNI::Interop::DB::RowIterator_isClosed(&closed, env, rows), TE_Ok);
    EXPECT_TRUE(closed);
    EXPECT_EQ(calls(*env), "isClosed");
    EXPECT_FALSE(env->ExceptionCheck());
}
