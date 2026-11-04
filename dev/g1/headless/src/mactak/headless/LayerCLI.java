package mactak.headless;

import java.io.File;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * G1.3 — {@code atak-headless --layer}: offline vector layer open on the
 * engine stack (the comms-side commands live in {@code HeadlessCLI}).
 *
 * <pre>
 *   atak-headless --layer FILE [--layer FILE ...] [--layer-db DIR]
 *                 [--expect-features N] [--quiet]
 * </pre>
 *
 * Loads the native engine in-process, opens every {@code --layer} file
 * through the engine's feature stack (native OGR provider →
 * {@code PersistentDataSourceFeatureDataStore2}) and prints what the
 * {@code FeatureDataStore2} cursors read back. Exit 0 = every layer opened
 * (and, with {@code --expect-features}, held at least N features in total);
 * 1 = failure; 2 = usage.
 */
public final class LayerCLI {

    private static final int EXIT_OK = 0;
    private static final int EXIT_FAIL = 1;
    private static final int EXIT_USAGE = 2;

    static final String USAGE =
        "usage: atak-headless --layer FILE [--layer FILE ...] [options]\n"
      + "  --layer FILE         open an offline vector layer (GeoJSON/SHP/KML/GPX/GPKG; repeatable)\n"
      + "  --layer-db DIR       feature store directory (default ./atak-headless-layers)\n"
      + "  --expect-features N  exit 1 unless the --layer files yield >= N features (test hook)\n"
      + "  --lib PATH           native library to System.load (repeatable, in order)\n"
      + "  --quiet              summary only";

    public static void main(String[] args) {
        final List<String> libs = new ArrayList<String>();
        final List<String> layers = new ArrayList<String>();
        String layerDb = "atak-headless-layers";
        int expectFeatures = -1;
        boolean quiet = false;
        try {
            for (int i = 0; i < args.length; i++) {
                final String a = args[i];
                if ("--quiet".equals(a)) { quiet = true; continue; }
                if ("--help".equals(a) || "-h".equals(a)) { System.out.println(USAGE); System.exit(EXIT_OK); }
                if (i + 1 >= args.length) throw new IllegalArgumentException(a + " needs a value");
                final String v = args[++i];
                if ("--layer".equals(a)) layers.add(v);
                else if ("--layer-db".equals(a)) layerDb = v;
                else if ("--expect-features".equals(a)) expectFeatures = Integer.parseInt(v);
                else if ("--lib".equals(a)) libs.add(v);
                else throw new IllegalArgumentException("unknown option " + a);
            }
            if (layers.isEmpty()) throw new IllegalArgumentException("--layer is required");
            if (expectFeatures < -1) throw new IllegalArgumentException("--expect-features must be >= 0");
        } catch (IllegalArgumentException e) {
            System.err.println("atak-headless: " + e.getMessage());
            System.err.println(USAGE);
            System.exit(EXIT_USAGE);
            return;
        }

        if (!quiet) log("java %s (%s)", System.getProperty("java.version"), System.getProperty("java.vm.name"));
        for (String lib : libs) {
            System.load(lib);
            if (!quiet) log("loaded %s", new File(lib).getName());
        }
        System.exit(openLayers(layers, layerDb, expectFeatures, quiet));
    }

    static int openLayers(List<String> paths, String layerDb, int expectFeatures, boolean quiet) {
        LayerStore layers = null;
        try {
            layers = new LayerStore(layerDb);
            if (!quiet) log("layer store %s (%d feature(s) already present)", layerDb, layers.featureCount());
            int total = 0;
            for (String path : paths) {
                final File f = new File(path);
                final long t = System.currentTimeMillis();
                layers.add(f);
                final int n = layers.featureCount(f);
                total += n;
                System.out.println(String.format(Locale.US, "layer %-28s %5d feature(s) in %d ms",
                        f.getName(), n, System.currentTimeMillis() - t));
            }
            System.out.print(layers.summary(quiet ? 0 : 10));
            if (expectFeatures >= 0) {
                if (total < expectFeatures) {
                    System.out.println("FAIL: expected at least " + expectFeatures
                            + " feature(s) from the given layer(s), got " + total);
                    return EXIT_FAIL;
                }
                System.out.println("PASS: " + total + " feature(s) opened through FeatureDataStore2");
            }
            return EXIT_OK;
        } catch (Throwable t) {
            System.out.println("FAIL: " + t);
            if (!quiet) t.printStackTrace(System.out);
            return EXIT_FAIL;
        } finally {
            if (layers != null) layers.close();
        }
    }

    private static void log(String fmt, Object... a) {
        System.out.println("[headless] " + String.format(Locale.US, fmt, a));
    }
}
