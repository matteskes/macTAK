package android.content.res;

import android.util.DisplayMetrics;

import java.io.InputStream;

// Compile-time stub (dev/spike/g55/android-port/build-android-port.py): the 3.1.0
// substitute's Resources plus getColor and getStringArray, which 5.5's
// gov.tak.platform.commons.resources.ResourceManagerBase calls.
public class Resources {
    public class Theme {
    }

    public static class NotFoundException extends RuntimeException {
        public NotFoundException() {
        }

        public NotFoundException(String message) {
            super(message);
        }

        public NotFoundException(String message, Exception cause) {
            super(message, cause);
        }
    }

    public AssetManager getAssets() { return null; }
    public DisplayMetrics getDisplayMetrics() { return null; }
    public int getIdentifier(String name, String defType, String defPackage) { return 0; }
    public InputStream openRawResource(int id) { return null; }
    public String getString(int id) { return null; }
    public int getColor(int id) { return 0; }
    public String[] getStringArray(int id) { return null; }
}
