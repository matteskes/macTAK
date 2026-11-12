import java.awt.BasicStroke;
import java.awt.Color;
import java.awt.Font;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.geom.Line2D;
import java.awt.image.BufferedImage;
import java.io.File;
import java.io.IOException;
import java.io.PrintWriter;
import java.util.Locale;
import javax.imageio.ImageIO;

/**
 * Synthetic "aerial" imagery for the G2.4 b.1 GeoTIFF fixture: fields in
 * greens and blues, a white road grid every 0.005 degrees, and the label
 * "GeoTIFF" at every 0.05-degree crossing, as an EPSG:4326 PNG plus ESRI
 * world file. make-imagery.sh reprojects it to UTM zone 10N (NAD83, what
 * USGS NAIP ships in) as a tiled GeoTIFF with overviews. Its palette is
 * unlike the MBTiles graticule's beige, so a frame shows which raster drew.
 * Deliberately synthetic: CI is offline and the gates need determinism
 * (decided 2026-11-12; real imagery is the exit run's).
 *
 * usage: MakeImagery OUT.png WEST SOUTH EAST NORTH PX_PER_DEG
 */
public final class MakeImagery {
    private static final double FIELD = 0.005;
    private static final Color[] FIELDS = {
        new Color(0x3F7A4A), new Color(0x5E8F3E), new Color(0x2F6E73), new Color(0x4C8A6A),
    };
    private static final Color ROAD = new Color(0xF2F2EE);
    private static final Color LABEL = new Color(0xFFFFFF);

    private MakeImagery() { }

    public static void main(String[] a) throws IOException {
        if (a.length != 6) {
            System.err.println("usage: MakeImagery OUT.png WEST SOUTH EAST NORTH PX_PER_DEG");
            System.exit(2);
        }
        final File out = new File(a[0]);
        final double w = Double.parseDouble(a[1]), s = Double.parseDouble(a[2]);
        final double e = Double.parseDouble(a[3]), n = Double.parseDouble(a[4]);
        final double ppd = Double.parseDouble(a[5]);
        final int width = (int) Math.round((e - w) * ppd), height = (int) Math.round((n - s) * ppd);
        final BufferedImage img = new BufferedImage(width, height, BufferedImage.TYPE_INT_RGB);
        final Graphics2D g = img.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON);

        // fields: a deterministic pattern of four colours per 0.005-degree cell
        for (double lon = Math.floor(w / FIELD) * FIELD; lon < e; lon += FIELD) {
            for (double lat = Math.floor(s / FIELD) * FIELD; lat < n; lat += FIELD) {
                final long i = Math.round(lon / FIELD), j = Math.round(lat / FIELD);
                g.setColor(FIELDS[(int) Math.floorMod(i * 3 + j * 5, (long) FIELDS.length)]);
                final int x0 = px(lon, w, ppd), x1 = px(lon + FIELD, w, ppd);
                final int y0 = py(lat + FIELD, n, ppd), y1 = py(lat, n, ppd);
                g.fillRect(x0, y0, Math.max(1, x1 - x0), Math.max(1, y1 - y0));
            }
        }
        // roads along the field edges
        g.setColor(ROAD);
        g.setStroke(new BasicStroke(3f));
        for (double lon = Math.floor(w / FIELD) * FIELD; lon <= e; lon += FIELD) {
            final int x = px(lon, w, ppd);
            g.draw(new Line2D.Float(x, 0, x, height));
        }
        for (double lat = Math.floor(s / FIELD) * FIELD; lat <= n; lat += FIELD) {
            final int y = py(lat, n, ppd);
            g.draw(new Line2D.Float(0, y, width, y));
        }
        // labels: what this is, at every 0.05-degree crossing
        g.setColor(LABEL);
        g.setFont(new Font(Font.SANS_SERIF, Font.BOLD, Math.max(12, (int) (ppd * 0.0022))));
        for (double lon = Math.ceil(w / 0.05) * 0.05; lon <= e; lon += 0.05) {
            for (double lat = Math.ceil(s / 0.05) * 0.05; lat <= n; lat += 0.05) {
                g.drawString(String.format(Locale.US, "GeoTIFF %.2f, %.2f", lat, lon),
                        px(lon, w, ppd) + 6, py(lat, n, ppd) - 6);
            }
        }
        g.dispose();
        ImageIO.write(img, "png", out);

        // world file: pixel size, rotation, centre of the upper-left pixel (EPSG:4326 by contract)
        final String world = out.getPath().replaceFirst("\\.png$", ".pgw");
        try (PrintWriter pw = new PrintWriter(world, "US-ASCII")) {
            pw.printf(Locale.US, "%.12f%n0%n0%n%.12f%n%.12f%n%.12f%n", 1 / ppd, -1 / ppd, w + 0.5 / ppd, n - 0.5 / ppd);
        }
        System.out.printf(Locale.US, "MakeImagery: %s %dx%d px, [%.4f %.4f %.4f %.4f]%n", out, width, height, w, s, e, n);
    }

    private static int px(double lon, double w, double ppd) { return (int) Math.round((lon - w) * ppd); }

    private static int py(double lat, double n, double ppd) { return (int) Math.round((n - lat) * ppd); }
}
