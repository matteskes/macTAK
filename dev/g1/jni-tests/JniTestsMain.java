/**
 * G1.9 kernel-mode launcher (dev/g1/jni-tests/run.sh).
 *
 * The kernel tests run UNDER THE JAVA LAUNCHER — the smoke's proven boot
 * (EngineLoadSmoke): a raw JNI_CreateJavaVM boot crashes inside hotspot's
 * jni_FindClass when the VM itself invokes JNI_OnLoad (as_Klass(NULL) on
 * Zulu 8 aarch64), while the launcher context runs it clean.
 *
 * The static block loads the three staged dylibs in smoke order (core,
 * JNI glue — JNI_OnLoad runs here — then the gtest suite as a library)
 * and main() hands the gtest arguments to the suite's JNI entry.
 */
public final class JniTestsMain
{
    static
    {
        final String libdir = System.getenv("TAKJNI_TEST_LIBDIR");
        if(libdir == null || libdir.isEmpty())
            throw new IllegalStateException(
                "TAKJNI_TEST_LIBDIR unset (run.sh exports it as the staged dir)");
        System.load(libdir + "/libtakengine.dylib");
        System.load(libdir + "/libtakenginejni.dylib");
        System.load(libdir + "/libtakengine-jni-tests.dylib");
    }

    public static void main(final String[] args)
    {
        System.exit(takengineJniTestsMain(args));
    }

    private static native int takengineJniTestsMain(String[] args);

    /**
     * Issue 142 (feature_guards_test.cpp, kernel mode): a FeatureDataStore2
     * whose every call is recorded, so a pin can see which Java method the
     * native wrapper reached. The two counts differ on purpose: a wrapper
     * that calls the wrong one returns the wrong number.
     */
    public static final class RecordingFeatureDataStore implements java.lang.reflect.InvocationHandler
    {
        public static final int FEATURES_COUNT = 7;
        public static final int FEATURE_SETS_COUNT = 3;

        private static final java.util.List<String> calls =
            java.util.Collections.synchronizedList(new java.util.ArrayList<String>());

        public static Object create()
        {
            return java.lang.reflect.Proxy.newProxyInstance(
                com.atakmap.map.layer.feature.FeatureDataStore2.class.getClassLoader(),
                new Class<?>[] { com.atakmap.map.layer.feature.FeatureDataStore2.class },
                new RecordingFeatureDataStore());
        }

        /** The calls since the last clear, oldest first. */
        public static String calls()
        {
            synchronized(calls) { return String.join(",", calls); }
        }

        public static void clear()
        {
            calls.clear();
        }

        @Override
        public Object invoke(Object proxy, java.lang.reflect.Method method, Object[] args)
        {
            final String name = method.getName();
            switch(name) {
                case "equals": return proxy == args[0];
                case "hashCode": return System.identityHashCode(proxy);
                case "toString": return "RecordingFeatureDataStore";
                default: break;
            }
            calls.add(name);
            if(name.equals("queryFeaturesCount"))
                return FEATURES_COUNT;
            if(name.equals("queryFeatureSetsCount"))
                return FEATURE_SETS_COUNT;
            final Class<?> type = method.getReturnType();
            if(type == int.class) return 0;
            if(type == long.class) return 0L;
            if(type == boolean.class) return false;
            if(type == double.class) return 0.0;
            return null;
        }
    }

    /**
     * Issue 142, batch 2 (db_guards_test.cpp, kernel mode): a RowIterator
     * and an IOProvider whose calls are recorded, so a pin can see which
     * Java method the db wrappers reached. isClosed answers true, so a
     * wrapper that asks moveToNext instead reads false.
     */
    public static final class RecordingDb implements java.lang.reflect.InvocationHandler
    {
        private static final java.util.List<String> calls =
            java.util.Collections.synchronizedList(new java.util.ArrayList<String>());

        public static Object rowIterator()
        {
            return proxy(com.atakmap.database.RowIterator.class);
        }

        public static Object provider()
        {
            return new Provider();
        }

        /** The calls since the last clear, oldest first. */
        public static String calls()
        {
            synchronized(calls) { return String.join(",", calls); }
        }

        public static void clear()
        {
            calls.clear();
        }

        private static Object proxy(Class<?> iface)
        {
            return java.lang.reflect.Proxy.newProxyInstance(
                iface.getClassLoader(), new Class<?>[] { iface }, new RecordingDb());
        }

        @Override
        public Object invoke(Object proxy, java.lang.reflect.Method method, Object[] args)
        {
            final String name = method.getName();
            switch(name) {
                case "equals": return proxy == args[0];
                case "hashCode": return System.identityHashCode(proxy);
                case "toString": return "RecordingDb";
                default: break;
            }
            calls.add(name);
            if(name.equals("isClosed"))
                return true;
            final Class<?> type = method.getReturnType();
            if(type == int.class) return 0;
            if(type == long.class) return 0L;
            if(type == boolean.class) return false;
            if(type == double.class) return 0.0;
            return null;
        }

        /** createDatabase records the URI it was given and returns a recorded DatabaseIface. */
        private static final class Provider extends com.atakmap.coremap.io.IOProvider
        {
            @Override
            public com.atakmap.database.DatabaseIface createDatabase(com.atakmap.coremap.io.DatabaseInformation info)
            {
                calls.add("createDatabase " + info.uri);
                return (com.atakmap.database.DatabaseIface)proxy(com.atakmap.database.DatabaseIface.class);
            }

            @Override public String getName() { return "RecordingDb"; }
            @Override public boolean isDatabase(java.io.File f) { throw unused(); }
            @Override public boolean canRead(java.io.File f) { throw unused(); }
            @Override public boolean canWrite(java.io.File f) { throw unused(); }
            @Override public java.io.File createTempFile(String p, String s, java.io.File d) { throw unused(); }
            @Override public boolean delete(java.io.File f, int flags) { throw unused(); }
            @Override public boolean exists(java.io.File f) { throw unused(); }
            @Override public java.nio.channels.FileChannel getChannel(java.io.File f, String mode) { throw unused(); }
            @Override public java.io.FileReader getFileReader(java.io.File f) { throw unused(); }
            @Override public java.io.FileWriter getFileWriter(java.io.File f) { throw unused(); }
            @Override public java.io.FileInputStream getInputStream(java.io.File f) { throw unused(); }
            @Override public java.io.FileOutputStream getOutputStream(java.io.File f, boolean append) { throw unused(); }
            @Override public java.io.RandomAccessFile getRandomAccessFile(java.io.File f, String mode) { throw unused(); }
            @Override public boolean isDirectory(java.io.File f) { throw unused(); }
            @Override public long lastModified(java.io.File f) { throw unused(); }
            @Override public long length(java.io.File f) { throw unused(); }
            @Override public String[] list(java.io.File f) { throw unused(); }
            @Override public String[] list(java.io.File f, java.io.FilenameFilter filter) { throw unused(); }
            @Override public boolean mkdir(java.io.File f) { throw unused(); }
            @Override public boolean mkdirs(java.io.File f) { throw unused(); }
            @Override public boolean renameTo(java.io.File from, java.io.File to) { throw unused(); }
            @Override public boolean setReadable(java.io.File f, boolean r, boolean ownerOnly) { throw unused(); }
            @Override public boolean setWritable(java.io.File f, boolean w, boolean ownerOnly) { throw unused(); }
            @Override public java.net.URI toURI(java.io.File f) { throw unused(); }

            private static UnsupportedOperationException unused()
            {
                return new UnsupportedOperationException("RecordingDb.Provider: only createDatabase is recorded");
            }
        }
    }

    /**
     * Issue 142, batch 3 (elevation_guards_test.cpp, kernel mode): an
     * ElevationSource (an abstract class, so a subclass) whose query returns
     * a one-row Cursor proxy with a distinct URI and type, recording every
     * call to either. Both are short enough (under 23 characters) for
     * Port::String's inline buffer, so a getUri that writes into the
     * type's string overwrites it in place, deterministically.
     */
    public static final class RecordingElevation extends com.atakmap.map.elevation.ElevationSource
        implements java.lang.reflect.InvocationHandler
    {
        public static final String URI = "n37w122.dt2";
        public static final String TYPE = "DTED2";

        private static final java.util.List<String> calls =
            java.util.Collections.synchronizedList(new java.util.ArrayList<String>());

        public static Object create()
        {
            return new RecordingElevation();
        }

        /** The calls since the last clear, oldest first. */
        public static String calls()
        {
            synchronized(calls) { return String.join(",", calls); }
        }

        public static void clear()
        {
            calls.clear();
        }

        @Override
        public String getName()
        {
            return "RecordingElevation";
        }

        @Override
        public Cursor query(QueryParameters params)
        {
            calls.add("query");
            return (Cursor)java.lang.reflect.Proxy.newProxyInstance(
                Cursor.class.getClassLoader(), new Class<?>[] { Cursor.class }, this);
        }

        @Override
        public com.atakmap.map.layer.feature.geometry.Envelope getBounds()
        {
            return null;
        }

        @Override
        public void addOnContentChangedListener(OnContentChangedListener l)
        {
            calls.add("addOnContentChangedListener");
        }

        @Override
        public void removeOnContentChangedListener(OnContentChangedListener l)
        {
            calls.add("removeOnContentChangedListener");
        }

        /** The cursor proxy's calls. */
        @Override
        public Object invoke(Object proxy, java.lang.reflect.Method method, Object[] args)
        {
            final String name = method.getName();
            switch(name) {
                case "equals": return proxy == args[0];
                case "hashCode": return System.identityHashCode(proxy);
                case "toString": return "RecordingElevation.Cursor";
                default: break;
            }
            calls.add(name);
            switch(name) {
                case "moveToNext": return true;
                case "getUri": return URI;
                case "getType": return TYPE;
                default: break;
            }
            final Class<?> type = method.getReturnType();
            if(type == int.class) return 0;
            if(type == long.class) return 0L;
            if(type == boolean.class) return false;
            if(type == double.class) return 0.0;
            return null;
        }
    }

    /**
     * Issue 142, batch 4 (core_renderer_guards_test.cpp, kernel mode): a
     * MapRenderer3 and two RenderSurfaces whose calls are recorded.
     *  - the MapRenderer3 answers isAnimating true and its display mode and
     *    origin with the non-default Flat and UpperLeft, so a wrapper that
     *    drops Java's answer reads the defaults (false, Globe, LowerLeft);
     *  - the RenderSurface2 answers getSurfaceWidth/Height 640x480 and the
     *    inherited getWidth/Height 1x1, the plain RenderSurface 320x240, so
     *    a wrapper that asks the wrong getter reads a different size.
     */
    public static final class RecordingCoreRenderer implements java.lang.reflect.InvocationHandler
    {
        private static final java.util.List<String> calls =
            java.util.Collections.synchronizedList(new java.util.ArrayList<String>());

        private final boolean surface2;

        private RecordingCoreRenderer(boolean surface2)
        {
            this.surface2 = surface2;
        }

        public static Object mapRenderer()
        {
            return proxy(com.atakmap.map.MapRenderer3.class, false);
        }

        public static Object renderSurface()
        {
            return proxy(gov.tak.api.engine.map.RenderSurface.class, false);
        }

        public static Object renderSurface2()
        {
            return proxy(gov.tak.api.engine.map.RenderSurface2.class, true);
        }

        /** The calls since the last clear, oldest first. */
        public static String calls()
        {
            synchronized(calls) { return String.join(",", calls); }
        }

        public static void clear()
        {
            calls.clear();
        }

        private static Object proxy(Class<?> iface, boolean surface2)
        {
            return java.lang.reflect.Proxy.newProxyInstance(
                iface.getClassLoader(), new Class<?>[] { iface }, new RecordingCoreRenderer(surface2));
        }

        @Override
        public Object invoke(Object proxy, java.lang.reflect.Method method, Object[] args)
        {
            final String name = method.getName();
            switch(name) {
                case "equals": return proxy == args[0];
                case "hashCode": return System.identityHashCode(proxy);
                case "toString": return "RecordingCoreRenderer";
                default: break;
            }
            calls.add(name);
            switch(name) {
                case "isAnimating": return true;
                case "getDisplayMode": return gov.tak.api.engine.map.IMapRendererEnums.DisplayMode.Flat;
                case "getDisplayOrigin": return gov.tak.api.engine.map.IMapRendererEnums.DisplayOrigin.UpperLeft;
                case "getSurfaceWidth": return 640;
                case "getSurfaceHeight": return 480;
                case "getWidth": return surface2 ? 1 : 320;
                case "getHeight": return surface2 ? 1 : 240;
                default: break;
            }
            final Class<?> type = method.getReturnType();
            if(type == int.class) return 0;
            if(type == long.class) return 0L;
            if(type == boolean.class) return false;
            if(type == double.class) return 0.0;
            if(type == float.class) return 0.0f;
            return null;
        }
    }

    /**
     * Issue 142, batch 5 (rest_guards_test.cpp, kernel mode): a ProjectionSpi
     * whose create records the call and throws, so a pin can see whether the
     * native SPI wrapper clears the exception or leaves it pending.
     */
    public static final class ThrowingProjectionSpi implements java.lang.reflect.InvocationHandler
    {
        private static final java.util.List<String> calls =
            java.util.Collections.synchronizedList(new java.util.ArrayList<String>());

        public static Object create()
        {
            final Class<?> iface = com.atakmap.map.projection.ProjectionSpi.class;
            return java.lang.reflect.Proxy.newProxyInstance(
                iface.getClassLoader(), new Class<?>[] { iface }, new ThrowingProjectionSpi());
        }

        /** The calls since the last clear, oldest first. */
        public static String calls()
        {
            synchronized(calls) { return String.join(",", calls); }
        }

        public static void clear()
        {
            calls.clear();
        }

        @Override
        public Object invoke(Object proxy, java.lang.reflect.Method method, Object[] args)
        {
            final String name = method.getName();
            switch(name) {
                case "equals": return proxy == args[0];
                case "hashCode": return System.identityHashCode(proxy);
                case "toString": return "ThrowingProjectionSpi";
                default: break;
            }
            calls.add(name);
            throw new IllegalStateException("ThrowingProjectionSpi: " + name + " throws on purpose");
        }
    }
}
