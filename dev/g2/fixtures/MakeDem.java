import java.io.BufferedWriter;
import java.io.FileWriter;
import java.io.IOException;
import java.util.Locale;

/**
 * Synthetic elevation for the G2.6 fixtures: a tilted plane,
 * {@code h = BASE + DH_DLAT * (lat - LAT0) + DH_DLON * (lon - LON0)} metres,
 * written as an ESRI ASCII grid (AAIGrid) of cell-centre samples.
 * make-dem.sh turns it into a GeoTIFF DEM and a DTED cell.
 *
 * Why a plane: bilinear interpolation reproduces a plane exactly, so the
 * height the engine reports anywhere must equal the formula, and the gate
 * (render/test/elevation.sh) can check it to a fraction of a metre. Its
 * relief over the San Francisco fixture area is about 50 to 1,090 m.
 *
 * usage: MakeDem OUT.asc WEST SOUTH EAST NORTH CELLS_PER_DEGREE
 */
public final class MakeDem {
    static final double BASE = 50, LAT0 = 37.72, LON0 = -122.56, DH_DLAT = 4000, DH_DLON = 2000;

    private MakeDem() { }

    static double height(double lat, double lon) {
        return BASE + DH_DLAT * (lat - LAT0) + DH_DLON * (lon - LON0);
    }

    public static void main(String[] a) throws IOException {
        if (a.length != 6) {
            System.err.println("usage: MakeDem OUT.asc WEST SOUTH EAST NORTH CELLS_PER_DEGREE");
            System.exit(2);
        }
        final double w = Double.parseDouble(a[1]), s = Double.parseDouble(a[2]);
        final double e = Double.parseDouble(a[3]), n = Double.parseDouble(a[4]);
        final double cpd = Double.parseDouble(a[5]);
        final int cols = (int) Math.round((e - w) * cpd), rows = (int) Math.round((n - s) * cpd);
        final double cell = 1d / cpd;
        try (BufferedWriter out = new BufferedWriter(new FileWriter(a[0]))) {
            out.write(String.format(Locale.US, "ncols %d%nnrows %d%nxllcorner %.12f%nyllcorner %.12f%ncellsize %.12f%nNODATA_value -9999%n",
                    cols, rows, w, s, cell));
            final StringBuilder row = new StringBuilder();
            for (int r = 0; r < rows; r++) {
                final double lat = n - (r + 0.5) * cell;   // cell centres, north to south
                row.setLength(0);
                for (int c = 0; c < cols; c++) {
                    if (c > 0) row.append(' ');
                    row.append(String.format(Locale.US, "%.3f", height(lat, w + (c + 0.5) * cell)));
                }
                out.write(row.toString());
                out.newLine();
            }
        }
        System.out.printf(Locale.US, "MakeDem: %s %dx%d cells, [%.4f %.4f %.4f %.4f]%n", a[0], cols, rows, w, s, e, n);
    }
}
