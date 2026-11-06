package mactak.render;

/**
 * Test-only host for the M3.1 window exercise: {@code
 * dev/g2/render/WindowHost.m}, compiled by
 * {@code dev/g2/render/build-window-host.sh}. It hands out a CAMetalLayer
 * and changes its drawableSize the way a host does when its window changes
 * size, so {@link RenderSmoke} can drive the window-surface path end to
 * end — the first real caller of {@link NativeEgl#createWindowSurface} and
 * of the window branch of {@link NativeEgl#resize}.
 *
 * <p>No NSWindow: AppKit hard-requires the main thread for NSWindow init,
 * and under the plain {@code java} launcher the JVM's main runs on a
 * spawned pthread (the abort and its stack are recorded in the .m's
 * header — direct evidence for M3.2's Swift-shell host model, which owns a
 * real main thread). EGL only ever needs the layer itself, so the harness
 * hosts a bare CAMetalLayer and presents off-screen; the readback PNGs are
 * the evidence, and CI runs the exercise itself — no GUI session involved.
 * The real host is the M3.2 Swift shell (NOTES.md &sect;"M3 design"); this
 * one is throwaway scaffolding in its own dylib. The M3 JNI boundary
 * holds: the {@code CAMetalLayer*} crosses as an opaque {@code long}, Java
 * never dereferences it, and the render thread is the layer's only caller.
 */
final class WindowHost {

    private WindowHost() { }

    /** System.load the harness dylib (path from build-window-host.sh). */
    static void load(String dylibPath) { System.load(dylibPath); }

    /**
     * Create the harness layer ({@code width} &times; {@code height}
     * pixels); returns the {@code CAMetalLayer*} as an opaque pointer, or
     * 0 on failure — {@link #getError} says why (no Metal device, already
     * open).
     */
    static native long open(int width, int height);

    /**
     * The layer's drawableSize — the host's truth about its backing size,
     * what EGL queries — packed as {@code width << 32 | height}; -1 on a
     * bad pointer.
     */
    static native long drawableSize(long layerPtr);

    /**
     * Resize like a host does on a window change: the layer's drawableSize
     * takes the new pixel size (contentsScale is pinned to 1). Returns
     * false on a bad pointer or size.
     */
    static native boolean resizeWindow(long layerPtr, int width, int height);

    /** Release the harness layer (after EGL tore its surface down). */
    static native boolean close(long layerPtr);

    /** Last harness-side error, empty when there was none. */
    static native String getError();

    /** Unpack {@link #drawableSize}'s width. */
    static int widthOf(long packed) { return (int) (packed >> 32); }

    /** Unpack {@link #drawableSize}'s height. */
    static int heightOf(long packed) { return (int) packed; }
}