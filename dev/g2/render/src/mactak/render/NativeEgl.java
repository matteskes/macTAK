package mactak.render;

/**
 * EGL on ANGLE (Metal) for the engine on macOS. Binding is
 * {@code dev/g2/jni-extra/mactak_egl.cpp} inside {@code libtakenginejni.dylib}.
 * One surface (the {@link #init} pbuffer, switchable to a CAMetalLayer window
 * surface), one ES3 context; the libGLESv2 passed to {@link #init} must be
 * the one the engine was linked against (staged beside it in native-dist).
 */
final class NativeEgl {

    private NativeEgl() { }

    static final int STR_BACKEND = 0;
    static final int STR_EGL_VERSION = 1;
    static final int STR_GL_RENDERER = 2;
    static final int STR_GL_VERSION = 3;
    static final int STR_LAST_ERROR = 4;

    static native boolean init(String eglLib, String glesLib, int width, int height);

    static native boolean makeCurrent();

    static native boolean release();

    /** Replace the pbuffer with a CAMetalLayer-backed window surface (M3.1):
     *  same display, config and context; {@code layerPtr} is the CAMetalLayer*. */
    static native boolean createWindowSurface(long layerPtr, int width, int height);

    /** Adopt a new size after the host resized the layer's drawableSize. */
    static native boolean resize(int width, int height);

    /** Present the back buffer (window surfaces). */
    static native boolean swap();

    static native boolean isCurrent();

    static native void finish();

    static native int getGlError();

    static native void fill(float r, float g, float b, float a);

    /** RGBA8 bottom-up into a direct buffer of at least width*height*4 bytes. */
    static native boolean readPixels(java.nio.ByteBuffer dst);

    static native String getString(int which);

    static native void destroy();

    /**
     * G2 exit run, GPU time per frame (GL_EXT_disjoint_timer_query): time
     * the GPU work issued from here to {@link #gpuTimerStop}. False if the
     * extension is missing or this frame's slot in the ring is unread.
     */
    static native boolean gpuTimerStart(int frame);

    static native void gpuTimerStop();

    /** Arrived results as (frame, ns) pairs into {@code out}; returns the pair count. ns -1: voided. */
    static native int gpuTimerPoll(long[] out);
}
