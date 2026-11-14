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
}
