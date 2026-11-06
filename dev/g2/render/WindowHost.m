/*
 * G2 M3.1 window-harness host: the host side of the window-surface
 * exercise, behind the JNI surface mactak.render.WindowHost calls.
 *
 * RenderSmoke --window asks this dylib for a CAMetalLayer, renders the
 * engine into it through NativeEgl's window surface, changes the layer's
 * drawableSize mid-run the way a host would when its window changes size,
 * and lets the smoke gate the whole chain — the first real caller of
 * NativeEgl.createWindowSurface and of the window branch of
 * NativeEgl.resize (eglQuerySurface tracking the drawableSize).
 *
 * No NSWindow, deliberately. AppKit hard-requires the main thread for
 * NSWindow init, and under the plain `java` launcher the JVM's main runs
 * on a spawned pthread (JavaMain), not the process's main thread — the
 * abort ("NSWindow should only be instantiated on the main thread!") and
 * its stack are direct evidence for M3.2's Swift-shell host model
 * (NOTES.md §"M3 design"), which owns a real main thread. EGL only ever
 * needs the layer itself (the M3.0 smoke already proved an on-screen
 * window's CAMetalLayer accepts the surface), so the harness hosts a bare
 * CAMetalLayer: the same native window ANGLE's Metal backend takes, its
 * drawableSize pinned by us instead of by AppKit. Nothing is composited
 * on screen — the readback PNGs are the evidence — which is why CI can run
 * the exercise itself. The real host is M3.2's Swift shell; this one is
 * throwaway test scaffolding in its own dylib — nothing in dev/g1 or the
 * glue links it.
 *
 * The M3 design's JNI boundary, kept: the CAMetalLayer* crosses as an
 * opaque jlong, Java never dereferences it. The layer is created, resized
 * and released on the calling (render) thread — CAMetalLayer is documented
 * thread-safe, and making the render thread its only caller keeps the
 * harness free of the marshaling machinery the real shell will own.
 *
 * Compiled by dev/g2/render/build-window-host.sh; needs no GUI session.
 */
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <jni.h>
#import <stdint.h>
#import <stdio.h>

/* One harness layer at a time: a static strong ref, like the smoke's stack. */
static CAMetalLayer *g_layer = nil;
static char g_error[256];

static void setError(const char *msg) { snprintf(g_error, sizeof g_error, "%s", msg); }

JNIEXPORT jstring JNICALL
Java_mactak_render_WindowHost_getError(JNIEnv *env, jclass cls)
{
    (void)cls;
    return (*env)->NewStringUTF(env, g_error);
}

JNIEXPORT jlong JNICALL
Java_mactak_render_WindowHost_open(JNIEnv *env, jclass cls, jint width, jint height)
{
    (void)env; (void)cls;
    g_error[0] = '\0';
    if (g_layer) { setError("layer host already open"); return 0; }
    if (width <= 0 || height <= 0) { setError("bad size"); return 0; }
    /* No Metal device (no GPU): eglCreateWindowSurface would misreport that
     * as a surface failure (M3.0 finding #42). Bail here instead. */
    if (!MTLCreateSystemDefaultDevice()) {
        setError("no Metal device (MTLCreateSystemDefaultDevice returned nil)");
        return 0;
    }

    @autoreleasepool {
        /* The harness pins contentsScale to 1 so drawableSize equals the
         * pixel size the smoke gates on; the points-x-backing-scale
         * calibration is M3.3's business (NOTES.md §"M3 design"). */
        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = MTLCreateSystemDefaultDevice();
        layer.contentsScale = 1.0;
        /* A detached layer has zero bounds, and ANGLE reads the window
         * surface's size from the layer (bounds x contentsScale): give it
         * real bounds and pin drawableSize to the same pixels. */
        layer.bounds = CGRectMake(0, 0, width, height);
        layer.drawableSize = CGSizeMake(width, height);
        g_layer = layer;   /* strong ref: EGL's surface outlives this call */
        return (jlong)(intptr_t)layer;
    }
}

JNIEXPORT jlong JNICALL
Java_mactak_render_WindowHost_drawableSize(JNIEnv *env, jclass cls, jlong layerPtr)
{
    (void)env; (void)cls;
    if (!g_layer || (jlong)(intptr_t)g_layer != layerPtr) { setError("unknown layer"); return -1; }
    const CGSize s = g_layer.drawableSize;
    return ((jlong)(int)s.width << 32) | (jlong)(unsigned int)s.height;
}

JNIEXPORT jboolean JNICALL
Java_mactak_render_WindowHost_resizeWindow(JNIEnv *env, jclass cls, jlong layerPtr,
                                           jint width, jint height)
{
    (void)env; (void)cls;
    if (!g_layer || (jlong)(intptr_t)g_layer != layerPtr) { setError("unknown layer"); return JNI_FALSE; }
    if (width <= 0 || height <= 0) { setError("bad size"); return JNI_FALSE; }
    /* What a host does when its window changes size: the layer's geometry
     * takes the new size — bounds (what ANGLE queries) and drawableSize
     * (what ANGLE renders into), kept equal with contentsScale pinned to
     * 1. Skipping this is exactly what a resize must refuse: EGL would
     * report the stale size. */
    g_layer.bounds = CGRectMake(0, 0, width, height);
    g_layer.drawableSize = CGSizeMake(width, height);
    return JNI_TRUE;
}

JNIEXPORT jboolean JNICALL
Java_mactak_render_WindowHost_close(JNIEnv *env, jclass cls, jlong layerPtr)
{
    (void)env; (void)cls;
    if (!g_layer || (jlong)(intptr_t)g_layer != layerPtr) { setError("unknown layer"); return JNI_FALSE; }
    g_layer = nil;
    return JNI_TRUE;
}