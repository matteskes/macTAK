package android.content.res;

import android.util.DisplayMetrics;

import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

// The symbol golden test's Resources (see Context.java beside it): raw
// resources are the files in <mactak.oracle.res>/raw, takkernel :shared's
// src/main/res. Everything else answers as android-port's stub does
// (dev/g1/kernel/android-port/src/android/content/res/Resources.java).
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

    private final List<Path> raw = new ArrayList<>();

    public AssetManager getAssets() { return null; }
    public DisplayMetrics getDisplayMetrics() { return null; }

    /** A raw resource's id (its index + 1), or 0 when there is no such file. */
    public synchronized int getIdentifier(String name, String defType, String defPackage) {
        if (!"raw".equals(defType)) return 0;
        final String dir = System.getProperty("mactak.oracle.res");
        if (dir == null) return 0;
        final Path file = Path.of(dir, "raw", name);
        if (!Files.isRegularFile(file)) return 0;
        int i = raw.indexOf(file);
        if (i < 0) { raw.add(file); i = raw.size() - 1; }
        return i + 1;
    }

    public synchronized InputStream openRawResource(int id) {
        if (id < 1 || id > raw.size()) throw new NotFoundException("no raw resource " + id);
        try {
            return new FileInputStream(raw.get(id - 1).toFile());
        } catch (FileNotFoundException e) {
            throw new NotFoundException(e.getMessage());
        }
    }

    public String getString(int id) { return null; }
    public int getColor(int id) { return 0; }
    public String[] getStringArray(int id) { return null; }
}
