package mactak.g3;

import com.atakmap.coremap.conversions.CoordinateFormat;
import com.atakmap.coremap.conversions.CoordinateFormatUtilities;
import com.atakmap.coremap.conversions.Span;
import com.atakmap.coremap.conversions.SpanUtilities;
import com.atakmap.coremap.maps.coords.Ellipsoid;
import com.atakmap.coremap.maps.coords.GeoPoint;
import com.atakmap.coremap.maps.coords.MGRSPoint;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * The kernel's leg of the coordinate golden test (G3.6a): ATAK 5.5's own
 * CoordinateFormatUtilities and CoordinateFormat (from the app at the pin,
 * compiled here by dev/g3/test/coord-golden.sh) over the kernel's MGRSPoint,
 * UTMPoint and SpanUtilities, write what the Swift port must write
 * (app/Tests/MacTAKCotTests/CoordinateTests.swift).
 *
 * <ul>
 * <li>{@code points.tsv} (lat, lon) → {@code expected/format.tsv}: each
 * format's long and short string, and MGRS as the self readout writes it
 * (getFormattedString).</li>
 * <li>the same points → {@code expected/roundtrip.tsv}: each format's string
 * read back by convert.</li>
 * <li>{@code parse.tsv} (format, typed text) → {@code expected/parse.tsv}:
 * the position, {@code !null}, {@code !error <message>} for 5.5's
 * IllegalArgumentException, or {@code !exception} for anything else it
 * throws (NumberFormatException, an index out of range).</li>
 * <li>{@code altitudes.tsv} (metres) → {@code expected/altitudes.tsv}:
 * SpanUtilities.format to feet and to metres.</li>
 * </ul>
 *
 * <p>U+200E (the left-to-right mark 5.5 puts before each space) is written
 * {@code ‎} in the files. Positions are written to 10 decimals; the
 * Swift side compares them to 1e-9.</p>
 *
 * <p>usage: CoordOracle &lt;coord-golden dir&gt; [write]</p>
 */
public final class CoordOracle {
    private static final CoordinateFormat[] FORMATS = {
            CoordinateFormat.MGRS, CoordinateFormat.UTM, CoordinateFormat.DD,
            CoordinateFormat.DM, CoordinateFormat.DMS
    };

    private CoordOracle() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length < 1)
            throw new IllegalArgumentException("usage: CoordOracle <coord-golden dir> [write]");
        File root = new File(args[0]);
        boolean write = args.length > 1 && args[1].equals("write");

        List<String[]> points = rows(new File(root, "points.tsv"), 2);
        StringBuilder format = new StringBuilder();
        StringBuilder roundTrip = new StringBuilder();
        for (String[] p : points) {
            GeoPoint point = new GeoPoint(Double.parseDouble(p[0]), Double.parseDouble(p[1]));
            StringBuilder line = new StringBuilder(p[0] + "\t" + p[1]);
            for (CoordinateFormat f : FORMATS) {
                String s = CoordinateFormatUtilities.formatToString(point, f);
                line.append('\t').append(escape(s));
                line.append('\t').append(escape(CoordinateFormatUtilities.formatToShortString(point, f)));
                roundTrip.append(p[0]).append('\t').append(p[1]).append('\t').append(f.getDisplayName())
                        .append('\t').append(convert(s, f)).append('\n');
            }
            line.append('\t').append(MGRSPoint.fromLatLng(Ellipsoid.WGS_84, point.getLatitude(),
                    point.getLongitude(), null).getFormattedString());
            format.append(line).append('\n');
        }

        StringBuilder parse = new StringBuilder();
        for (String[] p : rows(new File(root, "parse.tsv"), 2)) {
            parse.append(p[0]).append('\t').append(p[1]).append('\t')
                    .append(convert(unescape(p[1]), CoordinateFormat.find(p[0]))).append('\n');
        }

        StringBuilder altitudes = new StringBuilder();
        for (String[] p : rows(new File(root, "altitudes.tsv"), 1)) {
            double metres = Double.parseDouble(p[0]);
            altitudes.append(p[0]).append('\t').append(SpanUtilities.format(metres, Span.METER, Span.FOOT))
                    .append('\t').append(SpanUtilities.format(metres, Span.METER, Span.METER)).append('\n');
        }

        int failures = 0;
        failures += result(root, "format.tsv", format.toString(), write);
        failures += result(root, "roundtrip.tsv", roundTrip.toString(), write);
        failures += result(root, "parse.tsv", parse.toString(), write);
        failures += result(root, "altitudes.tsv", altitudes.toString(), write);
        if (!write)
            System.out.println(failures == 0
                    ? "[coord-golden] PASS: 5.5's formatter writes what the expected files say"
                    : "[coord-golden] FAIL: " + failures + " files differ");
        System.exit(failures == 0 ? 0 : 1);
    }

    /** convert, written as the expected files record it. */
    private static String convert(String text, CoordinateFormat f) {
        try {
            GeoPoint p = CoordinateFormatUtilities.convert(text, f);
            if (p == null)
                return "!null";
            return String.format(Locale.ROOT, "%.10f,%.10f", p.getLatitude(), p.getLongitude());
        } catch (NumberFormatException e) {
            // a subclass of IllegalArgumentException, thrown by MGRSPoint
            // and UTMPoint rather than by the formatter's own checks
            return "!exception";
        } catch (IllegalArgumentException e) {
            return "!error " + e.getMessage();
        } catch (RuntimeException e) {
            return "!exception";
        }
    }

    private static int result(File root, String name, String got, boolean write) throws Exception {
        File expected = new File(root, "expected/" + name);
        if (write) {
            expected.getParentFile().mkdirs();
            Files.write(expected.toPath(), got.getBytes(StandardCharsets.UTF_8));
            System.out.println("wrote " + expected);
            return 0;
        }
        String want = new String(Files.readAllBytes(expected.toPath()), StandardCharsets.UTF_8);
        if (want.equals(got)) {
            System.out.println("PASS: " + name);
            return 0;
        }
        String[] w = want.split("\n", -1), g = got.split("\n", -1);
        for (int i = 0; i < Math.max(w.length, g.length); i++) {
            String a = i < w.length ? w[i] : "<none>", b = i < g.length ? g[i] : "<none>";
            if (!a.equals(b)) {
                System.out.println("FAIL: " + name + " line " + (i + 1) + "\n  expected: " + a + "\n  5.5:      " + b);
                break;
            }
        }
        return 1;
    }

    /** Tab-separated rows, '#' comments and blank lines skipped. */
    private static List<String[]> rows(File file, int columns) throws Exception {
        List<String[]> out = new ArrayList<>();
        for (String line : Files.readAllLines(file.toPath(), StandardCharsets.UTF_8)) {
            if (line.isEmpty() || line.startsWith("#"))
                continue;
            String[] cells = line.split("\t", -1);
            if (cells.length != columns)
                throw new IllegalArgumentException(file.getName() + ": not " + columns + " columns: " + line);
            out.add(cells);
        }
        return out;
    }

    private static String escape(String s) {
        return s.replace("‎", "\\u200E");
    }

    private static String unescape(String s) {
        return s.replace("\\u200E", "‎");
    }
}
