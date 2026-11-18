package android.content;

import android.content.pm.PackageManager;
import android.content.res.AssetManager;
import android.content.res.Resources;

import java.io.File;

// The symbol golden test's Context (dev/g3/test/symbol-oracle.gradle, G3.7):
// android-port-3.1.0-g55's Context with a Resources that can open raw
// resources, so takkernel's desktop 2525 providers can load their symbol
// tables (JavaResourceManager opens them through `new Context()`). On the
// oracle's classpath only, ahead of android-port; the app never loads it.
public class Context {
    private static final Resources RESOURCES = new Resources();

    public Context() { }
    public PackageManager getPackageManager() { return null; }
    public String getPackageName() { return "mactak.oracle"; }
    public Resources getResources() { return RESOURCES; }
    public AssetManager getAssets() { return null; }
    public ContentResolver getContentResolver() { return null; }
    public File getCacheDir() { return null; }
    public File getFilesDir() { return null; }
    public File[] getExternalCacheDirs() { return new File[0]; }
    public String getString(int id) { return RESOURCES.getString(id); }
    public File getDatabasePath(String name) { return null; }
}
