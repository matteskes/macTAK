/*
 * G1.9 guards-mode pins: ManagedTextFormat2 / ManagedTextFormatFactory
 * when every kernel/Android class lookup fails (empty classpath — the
 * headless desktop shape). The wave-5 class-init guards must surface as
 * NEUTRAL bailouts (0 / 0.f / TE_Err) instead of calling through null
 * method IDs (a pending-exception crash on Android, garbage on desktop).
 * Constructing with a NULL jobject is the no-backing-instance state:
 * NewGlobalRef(NULL) is legal and yields NULL, the destructor's
 * DeleteGlobalRef is null-guarded, and the constructor's static clinit
 * runs (and fails) the class init — exactly the state the guards are for.
 * Patch under test: textformat2-class-init-consumer-guards.patch.
 *
 * 5.5 copy of dev/g1/jni-tests/textformat2_guards_test.cpp: 5.5's factory
 * takes only the JNIEnv (it calls the static GLText.createTextFormat), so
 * the 4.6 file no longer compiles here. Replaces it at the re-pin.
 */
#include <jni.h>

#include <renderer/GLText2.h>

#include <gtest/gtest.h>

#include "jni_test_env.hpp"
#include "interop/renderer/ManagedTextFormat2.h"

namespace
{
    using TAKEngineJNI::Interop::Renderer::ManagedTextFormat2;
    using TAKEngineJNI::Interop::Renderer::ManagedTextFormatFactory;

    class JniGuardsTextFormat2 : public JniGuardsTest
    { };
}

TEST_F(JniGuardsTextFormat2, FactoryCreateTextFormatBailsOut)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    ManagedTextFormatFactory factory(*env);

    TAK::Engine::Renderer::TextFormat2Ptr value(nullptr, nullptr);
    const TAK::Engine::Renderer::TextFormatParams params("sans-serif", 14.f);
    EXPECT_EQ(factory.createTextFormat(value, params), TAK::Engine::Util::TE_Err);
}

TEST_F(JniGuardsTextFormat2, MeasureConsumersBailOutNeutral)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    ManagedTextFormat2 fmt(*env, nullptr);

    /* each trips its null-method-ID guard and returns the neutral value */
    EXPECT_EQ(fmt.getStringWidth("x"), 0.f);
    EXPECT_EQ(fmt.getCharPositionWidth("xy", 1), 0.f);
    EXPECT_EQ(fmt.getCharWidth('A'), 0.f);
    EXPECT_EQ(fmt.getCharHeight(), 0.f);
    EXPECT_EQ(fmt.getDescent(), 0.f);
    EXPECT_EQ(fmt.getStringHeight("x"), 0.f);
    EXPECT_EQ(fmt.getBaselineSpacing(), 0.f);
    EXPECT_EQ(fmt.getFontSize(), 0);
}

TEST_F(JniGuardsTextFormat2, LoadGlyphBailsOut)
{
    JNIEnv *env = jnitest::jni_env();
    ASSERT_NE(env, nullptr);

    ManagedTextFormat2 fmt(*env, nullptr);

    /* the guard bundle: MapTextFormat.renderGlyph, Bitmap, Canvas — all
     * failed init on the empty classpath */
    TAK::Engine::Renderer::BitmapPtr glyph(nullptr, nullptr);
    EXPECT_EQ(fmt.loadGlyph(glyph, 'A'), TAK::Engine::Util::TE_Err);
}
