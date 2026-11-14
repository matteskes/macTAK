package android.graphics;

import java.awt.image.BufferedImage;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.util.Iterator;

import javax.imageio.ImageReadParam;
import javax.imageio.ImageReader;
import javax.imageio.ImageIO;
import javax.imageio.stream.ImageInputStream;

/** macOS runtime for {@code android.graphics.BitmapRegionDecoder} (ImageIO source-region reads). */
public final class BitmapRegionDecoder {
    private final ImageInputStream iis;
    private final ImageReader reader;
    private final int width, height;
    private boolean recycled;

    private BitmapRegionDecoder(ImageInputStream iis, ImageReader reader) throws IOException {
        this.iis = iis;
        this.reader = reader;
        reader.setInput(iis);
        width = reader.getWidth(0);
        height = reader.getHeight(0);
    }

    /** The caller keeps {@code is} and closes it, as on Android. */
    public static BitmapRegionDecoder newInstance(InputStream is, boolean isShareable) throws IOException {
        return open(ImageIO.createImageInputStream(is));
    }

    /**
     * Issue 131: a FileImageInputStream owns its file, so {@link #recycle()}
     * closes it. A FileInputStream wrapped in ImageIO's cache stream stayed
     * open, because closing the cache stream doesn't close what it wraps.
     */
    public static BitmapRegionDecoder newInstance(String pathName, boolean isShareable) throws IOException {
        return open(ImageIO.createImageInputStream(new File(pathName)));
    }

    /** Takes ownership of {@code iis}: closes it when no decoder comes of it. */
    private static BitmapRegionDecoder open(ImageInputStream iis) throws IOException {
        if (iis == null) throw new IOException("unsupported image stream");
        ImageReader reader = null;
        try {
            Iterator<ImageReader> readers = ImageIO.getImageReaders(iis);
            if (!readers.hasNext()) throw new IOException("no ImageIO reader");
            reader = readers.next();
            return new BitmapRegionDecoder(iis, reader);
        } catch (IOException | RuntimeException e) {
            if (reader != null) reader.dispose();
            iis.close();
            throw e;
        }
    }

    public int getWidth() { return width; }
    public int getHeight() { return height; }
    public boolean isRecycled() { return recycled; }

    public synchronized Bitmap decodeRegion(Rect rect, BitmapFactory.Options opts) {
        if (recycled) throw new IllegalStateException("recycled");
        try {
            ImageReadParam p = reader.getDefaultReadParam();
            int x = Math.max(0, rect.left), y = Math.max(0, rect.top);
            int w = Math.min(width, rect.right) - x, h = Math.min(height, rect.bottom) - y;
            if (w <= 0 || h <= 0) return null;
            p.setSourceRegion(new java.awt.Rectangle(x, y, w, h));
            int sample = opts != null && opts.inSampleSize > 1 ? opts.inSampleSize : 1;
            if (sample > 1) p.setSourceSubsampling(sample, sample, 0, 0);
            BufferedImage img = reader.read(0, p);
            Bitmap b = new Bitmap(img, opts != null && opts.inPreferredConfig != null ? opts.inPreferredConfig : Bitmap.Config.ARGB_8888);
            if (opts != null) { opts.outWidth = b.getWidth(); opts.outHeight = b.getHeight(); }
            return b;
        } catch (IOException e) {
            return null;
        }
    }

    public synchronized void recycle() {
        recycled = true;
        reader.dispose();
        try { iis.close(); } catch (IOException ignored) { }
    }
}
