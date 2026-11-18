package mactak.engine;

import mactak.render.WindowApp;

/**
 * The narrow facade the Swift app calls over JNI (G3; the hybrid engine
 * decision in {@code docs/atak-feature-coverage.md} §The app-layer decision).
 * Every call is non-blocking and made on the AppKit main thread; the render
 * thread does the work.
 *
 * <p>v0 (G3.0) is the map window's life cycle, delegated to
 * {@link WindowApp}, which keeps the render thread, the gates and the frame
 * log. Later milestones add map items (engine features written in batches),
 * layers and coordinate conversions here, so that Swift never needs to
 * reach past this class.
 */
public final class EngineBridge {

    /** {@link WindowApp}'s phases, for the host's poll. */
    public static final int PHASE_RENDERING = WindowApp.PHASE_RENDERING;
    public static final int PHASE_FRAME_DONE = WindowApp.PHASE_FRAME_DONE;
    public static final int PHASE_EXITED = WindowApp.PHASE_EXITED;

    private EngineBridge() { }

    /**
     * Start the render thread on the host's {@code CAMetalLayer} and return.
     *
     * @param layerPtr the {@code CAMetalLayer*}, opaque here
     * @param w h      surface size in pixels (points x backing scale)
     * @param dpi      72 x the backing scale
     */
    public static void start(long layerPtr, int w, int h, double dpi, MapConfig config) {
        if (config == null) throw new IllegalArgumentException("EngineBridge.start: null MapConfig");
        WindowApp.start(layerPtr, w, h, dpi, config);
    }

    /** The render thread's phase: {@code PHASE_*}. */
    public static int pollStatus() { return WindowApp.pollStatus(); }

    /** The final exit code, once the phase is {@link #PHASE_EXITED}. */
    public static int exitCode() { return WindowApp.exitCode(); }

    /** Ask the render thread to tear down; poll for {@link #PHASE_EXITED}. */
    public static void stop() { WindowApp.stop(); }

    /** The layer's drawable is now {@code w x h} pixels at {@code dpi}. */
    public static void resize(int w, int h, double dpi) { WindowApp.resize(w, h, dpi); }

    /** The window's occlusion state; rendering pauses while hidden. */
    public static void setVisible(boolean visible) { WindowApp.setVisible(visible); }

    /** One input event in surface pixels from the upper left (InputBridge's kinds). */
    public static void input(int kind, float x, float y, float dx, float dy, double amount) {
        WindowApp.input(kind, x, y, dx, dy, amount);
    }

    /** Centre the map on (lat, lon), animated (G3.6b). */
    public static void panTo(double lat, double lon) { WindowApp.panTo(lat, lon); }

    /**
     * Add or move a marker (G3.7b): {@code hae} NaN draws it at 0,
     * {@code rotation} NaN leaves the icon upright, {@code label} null draws
     * none. Dropped until {@link #markersReady()}.
     */
    public static void putMarker(String uid, double lat, double lon, double hae,
                                 String iconUri, int color, int width, int height, double rotation, String label) {
        WindowApp.putMarker(uid, lat, lon, hae, iconUri, color, width, height, rotation, label);
    }

    /** The self marker's icon in these colours, as 5.5 builds it ({@code base64://}). */
    public static String selfIconUri(int fill, int stroke) { return mactak.render.SelfIcon.uri(fill, stroke); }

    /** Remove a marker. */
    public static void removeMarker(String uid) { WindowApp.removeMarker(uid); }

    /** Whether the map takes markers yet; the host resends them all once it does. */
    public static boolean markersReady() { return WindowApp.markersReady(); }

    /** A MIL-STD-2525 point symbol as PNG, or null (G3.7, {@link Symbols}). */
    public static byte[] symbolPng(String code) { return Symbols.renderPng(code); }

    /** Whether {@link #symbolPng} draws {@code code}. */
    public static boolean canRenderSymbol(String code) { return Symbols.canRender(code); }
}
