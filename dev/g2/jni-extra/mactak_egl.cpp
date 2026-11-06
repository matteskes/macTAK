// macTAK addition to the JNI glue (built into libtakenginejni.dylib by
// dev/g1/build-native.sh). G2: an EGL render context for the engine on macOS,
// backed by ANGLE (EGL 1.5 + GL ES 3 on Metal). This is the piece the
// upstream macOS branch leaves to the host — the engine's C++ never touches
// EGL — and the JVM-side `mactak.render.EglRenderContext` drives it.
//
// EGL/GLES are resolved with dlopen/dlsym by path (not linked) so this TU
// also builds in MACTAK_GLES=stub mode, where no EGL exists; init() simply
// fails there. The GLES library passed in MUST be the same file the engine
// was linked against (@rpath/libGLESv2.dylib staged in native-dist) so that
// the context created here is the one the engine's GL calls land in.
//
// One surface, one context, no sharing. init() makes a pbuffer (offscreen
// frames, the CI canary); createWindowSurface() swaps it for a window surface
// on a CAMetalLayer (proven by dev/g2/smoke/egl-triangle-window.m, M3.0) on
// the SAME display, config and context — only the surface changes. resize()
// adopts a new size after the host resizes the layer's drawableSize; swap()
// presents the back buffer.
#include <jni.h>

#include <dlfcn.h>
#include <execinfo.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>

// ANGLE platform enums; the pinned Khronos registry predates the Metal one.
#ifndef EGL_PLATFORM_ANGLE_ANGLE
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif

namespace {
    struct Egl {
        void *eglLib = nullptr;
        void *glesLib = nullptr;

        EGLDisplay (*GetDisplay)(EGLNativeDisplayType) = nullptr;
        EGLBoolean (*Initialize)(EGLDisplay, EGLint *, EGLint *) = nullptr;
        EGLBoolean (*Terminate)(EGLDisplay) = nullptr;
        EGLBoolean (*ChooseConfig)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *) = nullptr;
        EGLSurface (*CreatePbufferSurface)(EGLDisplay, EGLConfig, const EGLint *) = nullptr;
        EGLSurface (*CreateWindowSurface)(EGLDisplay, EGLConfig, EGLNativeWindowType, const EGLint *) = nullptr;
        EGLBoolean (*SwapBuffers)(EGLDisplay, EGLSurface) = nullptr;
        EGLBoolean (*QuerySurface)(EGLDisplay, EGLSurface, EGLint, EGLint *) = nullptr;
        EGLBoolean (*DestroySurface)(EGLDisplay, EGLSurface) = nullptr;
        EGLBoolean (*BindAPI)(EGLenum) = nullptr;
        EGLContext (*CreateContext)(EGLDisplay, EGLConfig, EGLContext, const EGLint *) = nullptr;
        EGLBoolean (*DestroyContext)(EGLDisplay, EGLContext) = nullptr;
        EGLBoolean (*MakeCurrent)(EGLDisplay, EGLSurface, EGLSurface, EGLContext) = nullptr;
        EGLContext (*GetCurrentContext)(void) = nullptr;
        EGLint (*GetError)(void) = nullptr;
        const char *(*QueryString)(EGLDisplay, EGLint) = nullptr;
        void *(*GetProcAddress)(const char *) = nullptr;

        void (*glFinish_)(void) = nullptr;
        GLenum (*glGetError_)(void) = nullptr;
        const GLubyte *(*glGetString_)(GLenum) = nullptr;
        void (*glReadPixels_)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *) = nullptr;
        void (*glClearColor_)(GLfloat, GLfloat, GLfloat, GLfloat) = nullptr;
        void (*glClear_)(GLbitfield) = nullptr;
        void (*glReadBuffer_)(GLenum) = nullptr;

        EGLDisplay dpy = EGL_NO_DISPLAY;
        EGLSurface surf = EGL_NO_SURFACE;
        EGLContext ctx = EGL_NO_CONTEXT;
        EGLConfig cfg = nullptr;
        void *nativeWindow = nullptr;   // CAMetalLayer backing the window surface, if one is up
        int width = 0, height = 0;
        char backend[16] = "none";
        char lastError[256] = "";
    };

    Egl g;
    JavaVM *g_vm = nullptr;

    void setError(const char *what) {
        std::snprintf(g.lastError, sizeof g.lastError, "%s (eglError=0x%04x)", what,
                      g.GetError ? (unsigned)g.GetError() : 0u);
    }

    template<class F> bool sym(void *lib, const char *name, F &out) {
        out = reinterpret_cast<F>(dlsym(lib, name));
        if (!out) {
            std::snprintf(g.lastError, sizeof g.lastError, "dlsym(%s) failed", name);
            return false;
        }
        return true;
    }

    bool loadSymbols() {
        return sym(g.eglLib, "eglGetDisplay", g.GetDisplay)
            && sym(g.eglLib, "eglInitialize", g.Initialize)
            && sym(g.eglLib, "eglTerminate", g.Terminate)
            && sym(g.eglLib, "eglChooseConfig", g.ChooseConfig)
            && sym(g.eglLib, "eglCreatePbufferSurface", g.CreatePbufferSurface)
            && sym(g.eglLib, "eglCreateWindowSurface", g.CreateWindowSurface)
            && sym(g.eglLib, "eglSwapBuffers", g.SwapBuffers)
            && sym(g.eglLib, "eglQuerySurface", g.QuerySurface)
            && sym(g.eglLib, "eglDestroySurface", g.DestroySurface)
            && sym(g.eglLib, "eglBindAPI", g.BindAPI)
            && sym(g.eglLib, "eglCreateContext", g.CreateContext)
            && sym(g.eglLib, "eglDestroyContext", g.DestroyContext)
            && sym(g.eglLib, "eglMakeCurrent", g.MakeCurrent)
            && sym(g.eglLib, "eglGetCurrentContext", g.GetCurrentContext)
            && sym(g.eglLib, "eglGetError", g.GetError)
            && sym(g.eglLib, "eglQueryString", g.QueryString)
            && sym(g.eglLib, "eglGetProcAddress", g.GetProcAddress)
            && sym(g.glesLib, "glFinish", g.glFinish_)
            && sym(g.glesLib, "glGetError", g.glGetError_)
            && sym(g.glesLib, "glGetString", g.glGetString_)
            && sym(g.glesLib, "glReadPixels", g.glReadPixels_)
            && sym(g.glesLib, "glClearColor", g.glClearColor_)
            && sym(g.glesLib, "glClear", g.glClear_)
            && sym(g.glesLib, "glReadBuffer", g.glReadBuffer_);
    }

    void teardown() {
        if (g.dpy != EGL_NO_DISPLAY) {
            if (g.MakeCurrent) g.MakeCurrent(g.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            if (g.ctx != EGL_NO_CONTEXT && g.DestroyContext) g.DestroyContext(g.dpy, g.ctx);
            if (g.surf != EGL_NO_SURFACE && g.DestroySurface) g.DestroySurface(g.dpy, g.surf);
            if (g.Terminate) g.Terminate(g.dpy);
        }
        g.dpy = EGL_NO_DISPLAY; g.surf = EGL_NO_SURFACE; g.ctx = EGL_NO_CONTEXT;
        g.cfg = nullptr; g.nativeWindow = nullptr;
        // The dylibs stay loaded: the engine is linked against libGLESv2 anyway.
    }

    jstring str(JNIEnv *env, const char *s) { return env->NewStringUTF(s ? s : ""); }

    void GL_APIENTRY debugCallback(GLenum source, GLenum type, GLuint id, GLenum severity,
                                   GLsizei, const GLchar *message, const void *)
    {
        if (type == GL_DEBUG_TYPE_PERFORMANCE_KHR || type == GL_DEBUG_TYPE_OTHER_KHR) return;
        std::fprintf(stderr, "mactak_egl[GL_KHR_debug] src=0x%x type=0x%x id=%u sev=0x%x: %s\n",
                     source, type, id, severity, message ? message : "");
        // MACTAK_GL_DEBUG=2: native backtrace + Java stack for the first few errors
        static int traced = 0;
        const char *v = std::getenv("MACTAK_GL_DEBUG");
        if (type == GL_DEBUG_TYPE_ERROR_KHR && v && std::atoi(v) >= 2 && traced < 6) {
            ++traced;
            void *frames[32];
            int n = backtrace(frames, 32);
            backtrace_symbols_fd(frames, n, 2);
            JNIEnv *env = nullptr;
            if (g_vm && g_vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) == JNI_OK && env) {
                jclass thread = env->FindClass("java/lang/Thread");
                jmethodID dump = thread ? env->GetStaticMethodID(thread, "dumpStack", "()V") : nullptr;
                if (dump) env->CallStaticVoidMethod(thread, dump);
                else env->ExceptionClear();   // debug aid must not leave an exception pending
            }
        }
    }

    // MACTAK_GL_DEBUG=1: debug context + GL_KHR_debug callback (names the
    // call that raised a GL error; ANGLE's messages are specific).
    bool debugRequested() {
        const char *v = std::getenv("MACTAK_GL_DEBUG");
        return v && *v && std::strcmp(v, "0") != 0;
    }

    void installDebugCallback() {
        auto enable = reinterpret_cast<void (*)(GLenum)>(dlsym(g.glesLib, "glEnable"));
        auto cb = reinterpret_cast<PFNGLDEBUGMESSAGECALLBACKKHRPROC>(g.GetProcAddress("glDebugMessageCallbackKHR"));
        auto ctl = reinterpret_cast<PFNGLDEBUGMESSAGECONTROLKHRPROC>(g.GetProcAddress("glDebugMessageControlKHR"));
        if (!enable || !cb || !ctl) { std::fprintf(stderr, "mactak_egl: GL_KHR_debug unavailable\n"); return; }
        enable(GL_DEBUG_OUTPUT_KHR);
        enable(GL_DEBUG_OUTPUT_SYNCHRONOUS_KHR);
        ctl(GL_DONT_CARE, GL_DONT_CARE, GL_DONT_CARE, 0, nullptr, GL_TRUE);
        cb(debugCallback, nullptr);
    }

    // Pbuffers are fixed at creation: a resize is release, recreate at the new
    // size and re-make-current on the same config and context (GL objects are
    // context-owned, so engine state survives). On failure the original
    // pbuffer is made current again — the context keeps a valid surface, as
    // createWindowSurface's fallback does.
    bool rebuildPbuffer(int width, int height) {
        if (!g.MakeCurrent(g.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)) {
            setError("resize: eglMakeCurrent(release)");
            return false;
        }
        const EGLint pbAttrs[] = { EGL_WIDTH, width, EGL_HEIGHT, height, EGL_NONE };
        const EGLSurface pb = g.CreatePbufferSurface(g.dpy, g.cfg, pbAttrs);
        if (pb == EGL_NO_SURFACE) {
            setError("resize: eglCreatePbufferSurface");
            if (!g.MakeCurrent(g.dpy, g.surf, g.surf, g.ctx))
                std::fprintf(stderr, "mactak_egl: resize fallback left no current surface\n");
            return false;
        }
        g.DestroySurface(g.dpy, g.surf);
        g.surf = pb;
        if (!g.MakeCurrent(g.dpy, g.surf, g.surf, g.ctx)) { setError("resize: eglMakeCurrent"); return false; }
        EGLint qw = 0, qh = 0;
        if (!g.QuerySurface(g.dpy, g.surf, EGL_WIDTH, &qw)
                || !g.QuerySurface(g.dpy, g.surf, EGL_HEIGHT, &qh)
                || qw != width || qh != height) {
            setError("resize: rebuilt pbuffer did not take the new size");
            return false;
        }
        g.width = width; g.height = height;
        return true;
    }

    // M3.1: adopt width/height for the current surface after the host
    // changed the backing size. Pbuffers: rebuildPbuffer. Window surfaces:
    // ANGLE's Metal backend sizes a window surface at creation and does not
    // track the layer's drawableSize afterwards (the fast-path query below
    // stays for backends that do), so a window resize is destroy + recreate
    // on the same layer, config and context. Returns false with lastError
    // set.
    bool adoptSurfaceSize(int width, int height) {
        EGLint qw = 0, qh = 0;
        if (g.QuerySurface(g.dpy, g.surf, EGL_WIDTH, &qw)
                && g.QuerySurface(g.dpy, g.surf, EGL_HEIGHT, &qh)
                && qw == width && qh == height) {
            g.width = width; g.height = height;
            return true;
        }
        if (!g.nativeWindow) return rebuildPbuffer(width, height);
        if (!g.MakeCurrent(g.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)) {
            setError("resize: eglMakeCurrent(release)");
            return false;
        }
        // Destroy before create: ANGLE's Metal backend sizes a window
        // surface once, at creation, and refuses a second surface on a live
        // CAMetalLayer with EGL_BAD_ALLOC — the old one cannot linger
        // (observed 2026-11-06 in the window-harness exercise). Until the
        // recreate lands the context has no surface; if it fails there is
        // no window-surface fallback (same refusal), so say so loudly and
        // let the caller's exit gates report it.
        g.DestroySurface(g.dpy, g.surf);
        g.surf = EGL_NO_SURFACE;
        const EGLSurface rebuilt = g.CreateWindowSurface(g.dpy, g.cfg, (EGLNativeWindowType)g.nativeWindow, nullptr);
        if (rebuilt == EGL_NO_SURFACE) {
            setError("resize: eglCreateWindowSurface");
            std::fprintf(stderr, "mactak_egl: resize left the context without a surface\n");
            return false;
        }
        g.surf = rebuilt;
        if (!g.MakeCurrent(g.dpy, g.surf, g.surf, g.ctx)) { setError("resize: eglMakeCurrent"); return false; }
        qw = 0; qh = 0;
        if (!g.QuerySurface(g.dpy, g.surf, EGL_WIDTH, &qw)
                || !g.QuerySurface(g.dpy, g.surf, EGL_HEIGHT, &qh)
                || qw != width || qh != height) {
            setError("resize: rebuilt surface did not take the new size");
            return false;
        }
        g.width = width; g.height = height;
        return true;
    }
}

extern "C" {

JNIEXPORT jboolean JNICALL Java_mactak_render_NativeEgl_init
  (JNIEnv *env, jclass, jstring jeglPath, jstring jglesPath, jint width, jint height)
{
    if (g.dpy != EGL_NO_DISPLAY) { setError("already initialized"); return JNI_FALSE; }
    if (!jeglPath || !jglesPath || width <= 0 || height <= 0) { setError("bad arguments"); return JNI_FALSE; }
    env->GetJavaVM(&g_vm);

    const char *eglPath = env->GetStringUTFChars(jeglPath, nullptr);
    const char *glesPath = env->GetStringUTFChars(jglesPath, nullptr);
    // RTLD_GLOBAL so a later dyld resolution of @rpath/libGLESv2 shares this image.
    g.glesLib = dlopen(glesPath, RTLD_NOW | RTLD_GLOBAL);
    g.eglLib = dlopen(eglPath, RTLD_NOW | RTLD_GLOBAL);
    const bool opened = g.glesLib && g.eglLib;
    if (!opened)
        std::snprintf(g.lastError, sizeof g.lastError, "dlopen failed: %s", dlerror());
    env->ReleaseStringUTFChars(jeglPath, eglPath);
    env->ReleaseStringUTFChars(jglesPath, glesPath);
    if (!opened || !loadSymbols()) return JNI_FALSE;

    // Metal platform first (ANGLE's default on macOS is also Metal, but be explicit).
    auto getPlatformDisplay = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(g.GetProcAddress("eglGetPlatformDisplayEXT"));
    if (getPlatformDisplay) {
        const EGLint attrs[] = { EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE };
        g.dpy = getPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, (void *)EGL_DEFAULT_DISPLAY, attrs);
        std::strncpy(g.backend, "metal", sizeof g.backend);
    }
    if (g.dpy == EGL_NO_DISPLAY) {
        g.dpy = g.GetDisplay(EGL_DEFAULT_DISPLAY);
        std::strncpy(g.backend, "default", sizeof g.backend);
    }
    if (g.dpy == EGL_NO_DISPLAY) { setError("no EGL display"); return JNI_FALSE; }

    EGLint major = 0, minor = 0;
    if (!g.Initialize(g.dpy, &major, &minor)) { setError("eglInitialize"); g.dpy = EGL_NO_DISPLAY; return JNI_FALSE; }

    // Engine needs depth + stencil (GLGlobe clears all three buffers).
    // WINDOW_BIT on the same config: createWindowSurface() reuses this config
    // for the CAMetalLayer surface (ANGLE's Metal configs carry both bits).
    const EGLint cfgAttrs[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT | EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
        EGL_NONE
    };
    EGLConfig cfg; EGLint n = 0;
    if (!g.ChooseConfig(g.dpy, cfgAttrs, &cfg, 1, &n) || n < 1) { setError("eglChooseConfig"); teardown(); return JNI_FALSE; }
    g.cfg = cfg;

    const EGLint pbAttrs[] = { EGL_WIDTH, width, EGL_HEIGHT, height, EGL_NONE };
    g.surf = g.CreatePbufferSurface(g.dpy, cfg, pbAttrs);
    if (g.surf == EGL_NO_SURFACE) { setError("eglCreatePbufferSurface"); teardown(); return JNI_FALSE; }

    g.BindAPI(EGL_OPENGL_ES_API);
    const bool dbg = debugRequested();
    const EGLint ctxAttrs[] = { EGL_CONTEXT_CLIENT_VERSION, 3,
                                EGL_CONTEXT_OPENGL_DEBUG, dbg ? EGL_TRUE : EGL_FALSE, EGL_NONE };
    g.ctx = g.CreateContext(g.dpy, cfg, EGL_NO_CONTEXT, ctxAttrs);
    if (g.ctx == EGL_NO_CONTEXT) { setError("eglCreateContext(ES3)"); teardown(); return JNI_FALSE; }

    g.width = width; g.height = height;
    g.lastError[0] = '\0';
    if (dbg && g.MakeCurrent(g.dpy, g.surf, g.surf, g.ctx)) {
        installDebugCallback();
        g.MakeCurrent(g.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
    return JNI_TRUE;
}

JNIEXPORT jboolean JNICALL Java_mactak_render_NativeEgl_makeCurrent(JNIEnv *, jclass)
{
    if (g.dpy == EGL_NO_DISPLAY) return JNI_FALSE;
    if (!g.MakeCurrent(g.dpy, g.surf, g.surf, g.ctx)) { setError("eglMakeCurrent"); return JNI_FALSE; }
    return JNI_TRUE;
}

JNIEXPORT jboolean JNICALL Java_mactak_render_NativeEgl_release(JNIEnv *, jclass)
{
    if (g.dpy == EGL_NO_DISPLAY) return JNI_FALSE;
    return g.MakeCurrent(g.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT) ? JNI_TRUE : JNI_FALSE;
}

// M3.1: replace the init() pbuffer with a window surface on a CAMetalLayer
// (the native window ANGLE's Metal backend takes; see
// dev/g2/smoke/egl-triangle-window.m). Same display, config and context —
// only the surface changes. On failure the pbuffer is recreated so the
// context keeps a valid fallback surface.
JNIEXPORT jboolean JNICALL Java_mactak_render_NativeEgl_createWindowSurface
  (JNIEnv *, jclass, jlong layerPtr, jint width, jint height)
{
    if (g.dpy == EGL_NO_DISPLAY || g.ctx == EGL_NO_CONTEXT) {
        setError("createWindowSurface: not initialized");
        return JNI_FALSE;
    }
    if (!layerPtr || width <= 0 || height <= 0) {
        setError("createWindowSurface: bad arguments");
        return JNI_FALSE;
    }
    auto *layer = reinterpret_cast<void *>(layerPtr);
    if (!g.MakeCurrent(g.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)) {
        setError("createWindowSurface: eglMakeCurrent(release)");
        return JNI_FALSE;
    }
    const EGLSurface win = g.CreateWindowSurface(g.dpy, g.cfg, (EGLNativeWindowType)layer, nullptr);
    if (win == EGL_NO_SURFACE) {
        setError("eglCreateWindowSurface");
        const EGLint pbAttrs[] = { EGL_WIDTH, g.width, EGL_HEIGHT, g.height, EGL_NONE };
        const EGLSurface pb = g.CreatePbufferSurface(g.dpy, g.cfg, pbAttrs);
        if (pb == EGL_NO_SURFACE) {
            std::fprintf(stderr, "mactak_egl: window surface failed; pbuffer restore failed too\n");
        } else {
            if (g.surf != EGL_NO_SURFACE) g.DestroySurface(g.dpy, g.surf);
            g.surf = pb;
            if (!g.MakeCurrent(g.dpy, g.surf, g.surf, g.ctx))
                std::fprintf(stderr, "mactak_egl: pbuffer restored but not made current\n");
        }
        return JNI_FALSE;
    }
    if (g.surf != EGL_NO_SURFACE) g.DestroySurface(g.dpy, g.surf);
    g.surf = win;
    g.nativeWindow = layer;
    if (!g.MakeCurrent(g.dpy, g.surf, g.surf, g.ctx)) {
        setError("createWindowSurface: eglMakeCurrent");
        return JNI_FALSE;
    }
    if (!adoptSurfaceSize(width, height)) return JNI_FALSE;
    g.lastError[0] = '\0';
    return JNI_TRUE;
}

// M3.1: adopt a new size after the host resized the layer's drawableSize.
JNIEXPORT jboolean JNICALL Java_mactak_render_NativeEgl_resize
  (JNIEnv *, jclass, jint width, jint height)
{
    if (g.dpy == EGL_NO_DISPLAY || g.surf == EGL_NO_SURFACE) { setError("resize: no surface"); return JNI_FALSE; }
    if (width <= 0 || height <= 0) { setError("resize: bad arguments"); return JNI_FALSE; }
    return adoptSurfaceSize(width, height) ? JNI_TRUE : JNI_FALSE;
}

// M3.1: present the window surface's back buffer to its CAMetalLayer.
JNIEXPORT jboolean JNICALL Java_mactak_render_NativeEgl_swap(JNIEnv *, jclass)
{
    if (g.dpy == EGL_NO_DISPLAY || g.surf == EGL_NO_SURFACE) { setError("swap: no surface"); return JNI_FALSE; }
    if (!g.SwapBuffers(g.dpy, g.surf)) { setError("eglSwapBuffers"); return JNI_FALSE; }
    return JNI_TRUE;
}

JNIEXPORT jboolean JNICALL Java_mactak_render_NativeEgl_isCurrent(JNIEnv *, jclass)
{
    return (g.ctx != EGL_NO_CONTEXT && g.GetCurrentContext() == g.ctx) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL Java_mactak_render_NativeEgl_finish(JNIEnv *, jclass)
{
    if (g.glFinish_) g.glFinish_();
}

JNIEXPORT jint JNICALL Java_mactak_render_NativeEgl_getGlError(JNIEnv *, jclass)
{
    return g.glGetError_ ? (jint)g.glGetError_() : -1;
}

// Pre-fill the colour buffer so a frame can be told apart from "nothing drew".
JNIEXPORT void JNICALL Java_mactak_render_NativeEgl_fill
  (JNIEnv *, jclass, jfloat r, jfloat gr, jfloat b, jfloat a)
{
    if (!g.glClearColor_) return;
    g.glClearColor_(r, gr, b, a);
    g.glClear_(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
}

// RGBA8, bottom-up (GL order), into a direct ByteBuffer of >= w*h*4 bytes.
JNIEXPORT jboolean JNICALL Java_mactak_render_NativeEgl_readPixels
  (JNIEnv *env, jclass, jobject jbuf)
{
    if (g.dpy == EGL_NO_DISPLAY || !jbuf) return JNI_FALSE;
    void *dst = env->GetDirectBufferAddress(jbuf);
    const jlong cap = env->GetDirectBufferCapacity(jbuf);
    if (!dst || cap < (jlong)g.width * g.height * 4) { setError("readPixels: buffer too small / not direct"); return JNI_FALSE; }
    g.glReadBuffer_(GL_BACK);
    g.glReadPixels_(0, 0, g.width, g.height, GL_RGBA, GL_UNSIGNED_BYTE, dst);
    return g.glGetError_() == GL_NO_ERROR ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jstring JNICALL Java_mactak_render_NativeEgl_getString(JNIEnv *env, jclass, jint which)
{
    switch (which) {
        case 0: return str(env, g.backend);
        case 1: return str(env, g.dpy != EGL_NO_DISPLAY ? g.QueryString(g.dpy, EGL_VERSION) : "");
        case 2: return str(env, g.glGetString_ ? (const char *)g.glGetString_(GL_RENDERER) : "");
        case 3: return str(env, g.glGetString_ ? (const char *)g.glGetString_(GL_VERSION) : "");
        case 4: return str(env, g.lastError);
        default: return str(env, "");
    }
}

JNIEXPORT void JNICALL Java_mactak_render_NativeEgl_destroy(JNIEnv *, jclass)
{
    teardown();
}

} // extern "C"
