/*
 * G1.17 guards-mode pins: ManagedFeatureDefinition when its class init
 * fails (empty classpath: FeatureDefinition and its v2-v4 interfaces are
 * absent). The definition wraps a real Java object, a String, so the
 * pins see what a live caller would hand it:
 *
 *  - the constructor must stop before IsInstanceOf against the class the
 *    init could not find (hotspot crashes on a NULL class);
 *  - every consumer must bail (TE_Err, or upstream's default encoding)
 *    instead of calling through a NULL method ID, and leave the JNIEnv
 *    clean;
 *  - the version-gated consumers (timestamp, altitude mode, extrude,
 *    traits) return their defaults, since a failed init leaves version 1.
 *
 * Patches under test: jni-class-inits-new-in-55.patch (the constructor
 * hunk) and managedfeaturedefinition-consumer-guards.patch.
 */
#include <jni.h>

#include <feature/Feature2.h>
#include <feature/FeatureDataStore2.h>
#include <feature/FeatureDefinition2.h>

#include <gtest/gtest.h>

#include "jni_test_env.hpp"
#include "interop/feature/ManagedFeatureDefinition.h"

namespace
{
    using TAK::Engine::Feature::FeatureDefinition2;
    using TAK::Engine::Util::TE_Err;
    using TAK::Engine::Util::TE_Ok;
    using TAKEngineJNI::Interop::Feature::ManagedFeatureDefinition;

    class JniGuardsFeatureDefinition : public JniGuardsTest
    {
    protected:
        /* a live Java object that is no FeatureDefinition: the bare JVM
         * has String, and the init fails before it could tell anyway */
        jobject javaObject(JNIEnv &env)
        {
            return env.NewStringUTF("not a FeatureDefinition");
        }
    };
}

TEST_F(JniGuardsFeatureDefinition, ConstructorSurvivesFailedInit)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    {
        ManagedFeatureDefinition def(*env, javaObject(*env));
    }
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniGuardsFeatureDefinition, JavaBackedConsumersBailOut)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    ManagedFeatureDefinition def(*env, javaObject(*env));

    FeatureDefinition2::RawData raw;
    EXPECT_EQ(def.getRawGeometry(&raw), TE_Err);
    EXPECT_EQ(def.getRawStyle(&raw), TE_Err);
    const char *name = nullptr;
    EXPECT_EQ(def.getName(&name), TE_Err);
    const atakmap::util::AttributeSet *attrs = nullptr;
    EXPECT_EQ(def.getAttributes(&attrs), TE_Err);
    EXPECT_EQ(def.getGeomCoding(), FeatureDefinition2::GeomGeometry);
    EXPECT_EQ(def.getStyleCoding(), FeatureDefinition2::StyleStyle);
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniGuardsFeatureDefinition, FeatureCreationFails)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    ManagedFeatureDefinition def(*env, javaObject(*env));

    /* Feature_create reads the raw geometry first, so it stops there */
    const TAK::Engine::Feature::Feature2 *feature = nullptr;
    EXPECT_NE(def.get(&feature), TE_Ok);
    EXPECT_FALSE(env->ExceptionCheck());
}

TEST_F(JniGuardsFeatureDefinition, VersionGatedConsumersReturnDefaults)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    ManagedFeatureDefinition def(*env, javaObject(*env));

    int64_t timestamp = 0;
    EXPECT_EQ(def.getTimestamp(&timestamp), TE_Ok);
    EXPECT_EQ(timestamp, TE_TIMESTAMP_NONE);
    EXPECT_EQ(def.getAltitudeMode(), TAK::Engine::Feature::AltitudeMode::TEAM_ClampToGround);
    EXPECT_EQ(def.getExtrude(), 0.0);
    /* returns without calling Java; upstream leaves its altitudeMode and
     * extrude uninitialized below version 3, so there is no value to pin */
    (void)def.getTraits();
    EXPECT_FALSE(env->ExceptionCheck());
}
