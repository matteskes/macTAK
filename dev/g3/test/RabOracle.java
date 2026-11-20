import java.io.IOException;
import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.List;
import java.util.TimeZone;

import com.atakmap.coremap.conversions.Angle;
import com.atakmap.coremap.conversions.Span;
import com.atakmap.coremap.conversions.SpanUtilities;
import com.atakmap.coremap.conversions.AngleUtilities;
import com.atakmap.util.ConfigOptions;

import gov.tak.api.engine.map.coords.GeoCalculations;
import gov.tak.api.engine.map.coords.GeoPoint;
import gov.tak.api.engine.map.coords.IGeoPoint;

/**
 * The kernel's leg of the range and bearing golden test (G3.8a,
 * dev/g3/test/rab-golden.sh): 5.5's own GeoCalculations, magnetic north,
 * AngleUtilities and SpanUtilities, on the engine's natives, write the
 * expected files the Swift port (RangeBearingTests) is held to.
 *
 * usage: RabOracle LIBTAKENGINE LIBTAKENGINEJNI WMM_COF FIXTURE_DIR OUT_DIR
 * Run with -Duser.timezone=UTC: the magnetic dates are noon UTC.
 */
public final class RabOracle {
    public static void main(String[] args) throws IOException {
        System.load(args[0]);
        System.load(args[1]);
        ConfigOptions.setOption("world-magnetic-model-file", args[2]);
        final Path in = Path.of(args[3]);
        final Path out = Path.of(args[4]);
        Files.createDirectories(out);
        geodesy(in.resolve("pairs.tsv"), out.resolve("geodesy.tsv"));
        magnetic(in.resolve("magnetic.tsv"), out.resolve("magnetic.tsv"));
        angles(in.resolve("angles.tsv"), out.resolve("angles.tsv"));
        ranges(in.resolve("ranges.tsv"), out.resolve("ranges.tsv"));
    }

    private static List<String[]> rows(Path p) throws IOException {
        final List<String[]> rows = new ArrayList<>();
        for (String line : Files.readAllLines(p, StandardCharsets.UTF_8)) {
            if (line.isEmpty() || line.startsWith("#")) continue;
            rows.add(line.split("\t"));
        }
        return rows;
    }

    private static double d(String s) {
        return "NaN".equals(s) ? Double.NaN : Double.parseDouble(s);
    }

    private static PrintWriter writer(Path p, String header) throws IOException {
        final PrintWriter w = new PrintWriter(Files.newBufferedWriter(p, StandardCharsets.UTF_8));
        w.println("# written by dev/g3/test/RabOracle.java (make test-rab-golden --write); do not edit");
        w.println("# " + header);
        return w;
    }

    /** distance, bearing, slant distance and grid convergence per pair. */
    private static void geodesy(Path in, Path out) throws IOException {
        try (PrintWriter w = writer(out, "distance\tbearing\tslantDistance\tgridConvergence")) {
            for (String[] r : rows(in)) {
                final GeoPoint a = new GeoPoint(d(r[0]), d(r[1]), d(r[2]), IGeoPoint.AltitudeReference.HAE,
                        GeoPoint.UNKNOWN, GeoPoint.UNKNOWN);
                final GeoPoint b = new GeoPoint(d(r[3]), d(r[4]), d(r[5]), IGeoPoint.AltitudeReference.HAE,
                        GeoPoint.UNKNOWN, GeoPoint.UNKNOWN);
                w.println(GeoCalculations.distance(a, b) + "\t" + GeoCalculations.bearing(a, b) + "\t"
                        + GeoCalculations.slantDistance(a, b) + "\t"
                        + GeoCalculations.computeGridConvergence(a, b));
            }
        }
    }

    /** the declination at noon UTC on the day, and the bearing made magnetic. */
    private static void magnetic(Path in, Path out) throws IOException {
        try (PrintWriter w = writer(out, "declination\tmagnetic")) {
            for (String[] r : rows(in)) {
                final Calendar c = Calendar.getInstance(TimeZone.getTimeZone("UTC"));
                c.clear();
                c.set(Integer.parseInt(r[2]), Integer.parseInt(r[3]), Integer.parseInt(r[4]), 12, 0, 0);
                final long millis = c.getTimeInMillis();
                final GeoPoint p = new GeoPoint(d(r[0]), d(r[1]));
                w.println(GeoCalculations.magneticDeclination(p, millis) + "\t"
                        + GeoCalculations.convertFromTrueToMagnetic(p, d(r[5]), millis));
            }
        }
    }

    /** bearing degrees, bearing mils, angle degrees, angle mils. */
    private static void angles(Path in, Path out) throws IOException {
        try (PrintWriter w = writer(out, "bearing°\tbearing mils\tangle°\tangle mils")) {
            for (String[] r : rows(in)) {
                final double v = d(r[0]);
                w.println(AngleUtilities.format(v, Angle.DEGREE, Angle.DEGREE, true) + "\t"
                        + AngleUtilities.format(v, Angle.DEGREE, Angle.MIL, true) + "\t"
                        + AngleUtilities.format(v, Angle.DEGREE, Angle.DEGREE, false) + "\t"
                        + AngleUtilities.format(v, Angle.DEGREE, Angle.MIL, false));
            }
        }
    }

    /** ft/mi, m/km, NM at 5.5's thresholds, then ft/mi and m/km at 100 ft and 500 m. */
    private static void ranges(Path in, Path out) throws IOException {
        try (PrintWriter w = writer(out, "ft/mi\tm/km\tNM\tft/mi@100\tm/km@500")) {
            for (String[] r : rows(in)) {
                final double m = d(r[0]);
                SpanUtilities.setFeetToMileThreshold(5280);
                SpanUtilities.setMetersToKilometersThreshold(2000);
                final String english = SpanUtilities.formatType(Span.ENGLISH, m, Span.METER);
                final String metric = SpanUtilities.formatType(Span.METRIC, m, Span.METER);
                final String nm = SpanUtilities.formatType(Span.NM, m, Span.METER);
                SpanUtilities.setFeetToMileThreshold(100);
                SpanUtilities.setMetersToKilometersThreshold(500);
                w.println(english + "\t" + metric + "\t" + nm + "\t"
                        + SpanUtilities.formatType(Span.ENGLISH, m, Span.METER) + "\t"
                        + SpanUtilities.formatType(Span.METRIC, m, Span.METER));
            }
        }
    }
}
