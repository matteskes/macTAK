package android.graphics;

import java.awt.image.BufferedImage;
import java.awt.image.DataBufferInt;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.Buffer;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.IntBuffer;

import javax.imageio.ImageIO;

/**
 * macOS runtime for {@code android.graphics.Bitmap}, backed by a
 * {@link BufferedImage#TYPE_INT_ARGB} (non-premultiplied, Android ARGB int
 * layout). Every config is stored as ARGB_8888; {@link #getConfig()} reports
 * the requested one so callers' format logic is unaffected.
 */
public final class Bitmap {

    public enum Config {
        ALPHA_8, RGB_565, ARGB_4444, ARGB_8888, RGBA_F16, HARDWARE
    }

    public enum CompressFormat {
        JPEG("jpg"), PNG("png"), WEBP("webp");
        final String ioName;
        CompressFormat(String n) { ioName = n; }
    }

    static final int DENSITY_NONE = 0;

    BufferedImage image;
    private final Config config;
    private boolean hasAlpha;
    private boolean premultiplied = true;
    private boolean recycled;
    private int density = 160;

    Bitmap(BufferedImage image, Config config) {
        if (image.getType() != BufferedImage.TYPE_INT_ARGB) {
            BufferedImage c = new BufferedImage(image.getWidth(), image.getHeight(), BufferedImage.TYPE_INT_ARGB);
            java.awt.Graphics2D g = c.createGraphics();
            g.setComposite(java.awt.AlphaComposite.Src);
            g.drawImage(image, 0, 0, null);
            g.dispose();
            image = c;
        }
        this.image = image;
        this.config = config == null ? Config.ARGB_8888 : config;
        this.hasAlpha = this.config != Config.RGB_565;
    }

    /**
     * takkernel's desktop {@code gov.tak.api.commons.graphics.BitmapMarshal}
     * wraps a {@code BufferedImage} with this constructor and unwraps it with
     * {@link #getAwtBufferedImageImplementation()}, both by reflection, as the
     * TAK artifactory's android-port provides them; the public substitute has
     * neither, so the marshal returned null (G3.7: the 2525 providers' icons).
     */
    private Bitmap(BufferedImage image) {
        this(image, Config.ARGB_8888);
    }

    private BufferedImage getAwtBufferedImageImplementation() {
        return image;
    }

    /** Direct access to the ARGB pixel array (row-major, width*height). */
    int[] pixels() { return ((DataBufferInt) image.getRaster().getDataBuffer()).getData(); }

    public static Bitmap createBitmap(int width, int height, Config config) {
        if (width <= 0 || height <= 0) throw new IllegalArgumentException("width and height must be > 0");
        return new Bitmap(new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB), config);
    }

    public static Bitmap createBitmap(int[] colors, int width, int height, Config config) {
        Bitmap b = createBitmap(width, height, config);
        System.arraycopy(colors, 0, b.pixels(), 0, width * height);
        return b;
    }

    public static Bitmap createBitmap(int[] colors, int offset, int stride, int width, int height, Config config) {
        Bitmap b = createBitmap(width, height, config);
        int[] dst = b.pixels();
        for (int y = 0; y < height; y++) System.arraycopy(colors, offset + y * stride, dst, y * width, width);
        return b;
    }

    public static Bitmap createBitmap(Bitmap src) { return createBitmap(src, 0, 0, src.getWidth(), src.getHeight(), null, false); }

    public static Bitmap createBitmap(Bitmap source, int x, int y, int width, int height) {
        return createBitmap(source, x, y, width, height, null, false);
    }

    public static Bitmap createBitmap(Bitmap source, int x, int y, int width, int height, Matrix m, boolean filter) {
        source.checkRecycled();
        BufferedImage sub = source.image.getSubimage(x, y, width, height);
        if (m == null || m.isIdentity()) {
            BufferedImage copy = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
            copy.setRGB(0, 0, width, height, sub.getRGB(0, 0, width, height, null, 0, width), 0, width);
            Bitmap b = new Bitmap(copy, source.config);
            b.hasAlpha = source.hasAlpha;
            return b;
        }
        java.awt.geom.AffineTransform at = m.toAwt();
        java.awt.geom.Rectangle2D bounds = at.createTransformedShape(new java.awt.Rectangle(0, 0, width, height)).getBounds2D();
        int nw = Math.max(1, (int) Math.ceil(bounds.getWidth())), nh = Math.max(1, (int) Math.ceil(bounds.getHeight()));
        BufferedImage out = new BufferedImage(nw, nh, BufferedImage.TYPE_INT_ARGB);
        java.awt.Graphics2D g = out.createGraphics();
        if (filter) g.setRenderingHint(java.awt.RenderingHints.KEY_INTERPOLATION, java.awt.RenderingHints.VALUE_INTERPOLATION_BILINEAR);
        g.translate(-bounds.getX(), -bounds.getY());
        g.drawImage(sub, at, null);
        g.dispose();
        Bitmap b = new Bitmap(out, source.config);
        b.hasAlpha = source.hasAlpha;
        return b;
    }

    public static Bitmap createScaledBitmap(Bitmap src, int dstWidth, int dstHeight, boolean filter) {
        src.checkRecycled();
        BufferedImage out = new BufferedImage(dstWidth, dstHeight, BufferedImage.TYPE_INT_ARGB);
        java.awt.Graphics2D g = out.createGraphics();
        g.setComposite(java.awt.AlphaComposite.Src);
        g.setRenderingHint(java.awt.RenderingHints.KEY_INTERPOLATION,
                filter ? java.awt.RenderingHints.VALUE_INTERPOLATION_BILINEAR : java.awt.RenderingHints.VALUE_INTERPOLATION_NEAREST_NEIGHBOR);
        g.drawImage(src.image, 0, 0, dstWidth, dstHeight, null);
        g.dispose();
        Bitmap b = new Bitmap(out, src.config);
        b.hasAlpha = src.hasAlpha;
        return b;
    }

    public Bitmap copy(Config config, boolean isMutable) {
        Bitmap b = createBitmap(this);
        return config == null || config == this.config ? b : new Bitmap(b.image, config);
    }

    public int getWidth() { return image.getWidth(); }
    public int getHeight() { return image.getHeight(); }
    public Config getConfig() { return config; }
    public int getRowBytes() { return getWidth() * 4; }
    public int getByteCount() { return getRowBytes() * getHeight(); }
    public int getAllocationByteCount() { return getByteCount(); }
    public boolean isMutable() { return true; }
    public boolean hasAlpha() { return hasAlpha; }
    public void setHasAlpha(boolean hasAlpha) { this.hasAlpha = hasAlpha; }
    public boolean isPremultiplied() { return premultiplied && hasAlpha; }
    public void setPremultiplied(boolean p) { premultiplied = p; }
    public int getDensity() { return density; }
    public void setDensity(int density) { this.density = density; }
    public boolean isRecycled() { return recycled; }

    public void recycle() { recycled = true; image = null; }

    private void checkRecycled() { if (recycled) throw new IllegalStateException("Can't call on a recycled bitmap"); }

    public int getPixel(int x, int y) { checkRecycled(); return image.getRGB(x, y); }

    public void setPixel(int x, int y, int color) { checkRecycled(); image.setRGB(x, y, color); }

    public void getPixels(int[] pixels, int offset, int stride, int x, int y, int width, int height) {
        checkRecycled();
        image.getRGB(x, y, width, height, pixels, offset, stride);
    }

    public void setPixels(int[] pixels, int offset, int stride, int x, int y, int width, int height) {
        checkRecycled();
        image.setRGB(x, y, width, height, pixels, offset, stride);
    }

    public void eraseColor(int c) { checkRecycled(); java.util.Arrays.fill(pixels(), c); }

    /** Writes RGBA bytes (GL texture order), like Android's ARGB_8888 memory layout. */
    public void copyPixelsToBuffer(Buffer dst) {
        checkRecycled();
        int[] px = pixels();
        if (dst instanceof ByteBuffer) {
            ByteBuffer bb = (ByteBuffer) dst;
            for (int p : px) {
                bb.put((byte) (p >> 16)).put((byte) (p >> 8)).put((byte) p).put((byte) (p >>> 24));
            }
        } else if (dst instanceof IntBuffer) {
            IntBuffer ib = (IntBuffer) dst;
            boolean le = ib.order() == ByteOrder.LITTLE_ENDIAN;
            for (int p : px) ib.put(le ? argbToAbgr(p) : argbToRgba(p));
        } else {
            throw new RuntimeException("unsupported Buffer subclass");
        }
    }

    public void copyPixelsFromBuffer(Buffer src) {
        checkRecycled();
        int[] px = pixels();
        if (src instanceof ByteBuffer) {
            ByteBuffer bb = (ByteBuffer) src;
            for (int i = 0; i < px.length; i++) {
                int r = bb.get() & 0xff, g = bb.get() & 0xff, b = bb.get() & 0xff, a = bb.get() & 0xff;
                px[i] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        } else {
            throw new RuntimeException("unsupported Buffer subclass");
        }
    }

    static int argbToRgba(int p) { return (p << 8) | (p >>> 24); }
    static int argbToAbgr(int p) { return (p & 0xFF00FF00) | ((p & 0xFF) << 16) | ((p >> 16) & 0xFF); }

    public boolean compress(CompressFormat format, int quality, OutputStream stream) {
        checkRecycled();
        try {
            BufferedImage out = image;
            if (format == CompressFormat.JPEG) {
                out = new BufferedImage(getWidth(), getHeight(), BufferedImage.TYPE_INT_RGB);
                out.getGraphics().drawImage(image, 0, 0, null);
            }
            return ImageIO.write(out, format.ioName, stream);
        } catch (IOException e) {
            return false;
        }
    }

    public boolean sameAs(Bitmap other) {
        return other != null && getWidth() == other.getWidth() && getHeight() == other.getHeight()
            && java.util.Arrays.equals(pixels(), other.pixels());
    }
}
