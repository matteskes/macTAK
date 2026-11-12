package mactak.render;

import android.content.Context;

import com.atakmap.map.AtakMapView;
import com.atakmap.map.RenderSurface;
import com.atakmap.map.opengl.GLMapSurface;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayDeque;
import java.util.IdentityHashMap;
import java.util.Set;

/**
 * The takkernel render context over {@link NativeEgl}: the macOS counterpart
 * of upstream's {@code gov.tak.platform.engine.JOGLRenderContext}. Extends the
 * jar's abstract {@code GLMapSurface} (RenderContext + RenderSurface) because
 * {@code GLMapView.getSurface()} casts the context to it and the asynchronous
 * layer renderers call that. The thread that constructs it is the render
 * thread; it owns the EGL context and drains {@link #queueEvent} work via
 * {@link #pump()} before each frame. The surface is resizeable at run time
 * ({@link #resize}): today a pbuffer rebuild; once a host owns a CAMetalLayer
 * its window surface takes the same path (adopt the layer's drawableSize).
 */
@SuppressWarnings("deprecation")   // GLMapSurface.getGLMapView() is typed with the deprecated MapRenderer
final class EglRenderContext extends GLMapSurface {

    private final Thread renderThread = Thread.currentThread();
    private final ArrayDeque<Runnable> queue = new ArrayDeque<>();
    /** Surface size; written on the render thread, readable from any (volatile). */
    private volatile int width, height;
    private final double dpi;
    private ByteBuffer readback;
    private final Set<OnSizeChangedListener> listeners =
            java.util.Collections.newSetFromMap(new IdentityHashMap<OnSizeChangedListener, Boolean>());
    private com.atakmap.map.MapRenderer glMapView;

    EglRenderContext(int width, int height, double dpi) {
        this.width = width; this.height = height; this.dpi = dpi;
        GLMapSurface.setMainGLThread();
    }

    void setGLMapView(com.atakmap.map.MapRenderer view) { this.glMapView = view; }

    /** Run everything queued from other threads; call on the render thread each frame. */
    void pump() {
        Runnable r;
        while (true) {
            synchronized (queue) { r = queue.pollFirst(); }
            if (r == null) return;
            r.run();
        }
    }

    /**
     * Resize the surface at run time; render-thread only, because the engine
     * renders on this surface and the swap must not race the rebuild. Fires
     * {@link OnSizeChangedListener} once the new size is live (GLMapView
     * implements the listener and re-lays out on its next frame). Returns
     * false with the size unchanged if EGL refused; NativeEgl's lastError
     * says why.
     */
    boolean resize(int newWidth, int newHeight) {
        if (!isRenderThread())
            throw new IllegalStateException("resize off the render thread");
        if (newWidth == width && newHeight == height) return true;
        if (!NativeEgl.resize(newWidth, newHeight)) return false;
        width = newWidth;
        height = newHeight;
        final OnSizeChangedListener[] ls;
        synchronized (listeners) { ls = listeners.toArray(new OnSizeChangedListener[0]); }
        for (OnSizeChangedListener l : ls) l.onSizeChanged(this, width, height);
        return true;
    }

    /**
     * A direct RGBA8 buffer sized to the current surface, GL row order — the
     * shape {@link NativeEgl#readPixels} bounds-checks against, so callers
     * re-ask after every {@link #resize} instead of sizing a buffer from a
     * stale width/height. Reallocated when the size changed since last call.
     */
    ByteBuffer readbackBuffer() {
        final int need = width * height * 4;
        if (readback == null || readback.capacity() != need)
            readback = ByteBuffer.allocateDirect(need).order(ByteOrder.nativeOrder());
        return readback;
    }

    // ---- GLMapSurface -------------------------------------------------------
    @Override public com.atakmap.map.MapRenderer getGLMapView() { return glMapView; }
    @Override public AtakMapView getMapView() { return null; }
    /** Serves {@code asset:} URIs from the classpath (see {@link ClasspathAssets}). */
    @Override public Context getContext() { return ClasspathAssets.CONTEXT; }

    // ---- RenderContext ------------------------------------------------------
    @Override public boolean isRenderThread() { return Thread.currentThread() == renderThread; }

    @Override public void queueEvent(Runnable r) {
        if (isRenderThread()) { r.run(); return; }
        synchronized (queue) { queue.addLast(r); }
    }

    @Override public void requestRefresh() { }
    @Override public void setFrameRate(float rate) { }
    @Override public float getFrameRate() { return 0f; }
    @Override public void setContinuousRenderEnabled(boolean enabled) { }
    @Override public boolean isContinuousRenderEnabled() { return true; }
    @Override public boolean supportsChildContext() { return false; }
    // upstream declares these with the raw type (so does JOGLRenderContext)
    @SuppressWarnings("rawtypes")
    @Override public gov.tak.api.engine.map.RenderContext createChildContext() { return null; }
    @SuppressWarnings("rawtypes")
    @Override public void destroyChildContext(gov.tak.api.engine.map.RenderContext child) { }

    @Override public boolean isAttached() { return isRenderThread() && NativeEgl.isCurrent(); }

    @Override public boolean attach() {
        if (!isRenderThread()) return false;
        return NativeEgl.makeCurrent();
    }

    @Override public boolean detach() {
        if (!isRenderThread()) return false;
        NativeEgl.release();
        return !NativeEgl.isCurrent();
    }

    @Override public boolean isMainContext() { return true; }
    @Override public RenderSurface getRenderSurface() { return this; }

    // ---- RenderSurface (dynamic size; see resize()) -------------------------
    @Override public double getDpi() { return dpi; }
    @Override public int getWidth() { return width; }
    @Override public int getHeight() { return height; }
    @Override public void addOnSizeChangedListener(OnSizeChangedListener l) { synchronized (listeners) { listeners.add(l); } }
    @Override public void removeOnSizeChangedListener(OnSizeChangedListener l) { synchronized (listeners) { listeners.remove(l); } }
}
