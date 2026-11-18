package mactak.render;

import java.awt.image.BufferedImage;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.Base64;
import javax.imageio.ImageIO;

/**
 * The self marker's icon (G3.7b), as ATAK 5.5's
 * {@code LocationMapComponent.refreshGpsIcon} builds it: its two drawables,
 * {@code ic_self_tintable} tinted with the fill colour (0xff44b2dd by
 * default) under {@code ic_self_stroke_tintable} tinted with the outline
 * colour (white), flattened to one image and passed as a {@code base64://}
 * URI. A tint keeps each pixel's alpha and replaces its colour, as Android's
 * {@code Drawable.setTint} (SRC_IN) does.
 */
public final class SelfIcon {

    /** 5.5's {@code SELF_MARKER_WIDTH} and {@code SELF_MARKER_HEIGHT}. */
    public static final int WIDTH = 32, HEIGHT = 43;
    /** 5.5's default fill and outline. */
    public static final int DEFAULT_FILL = 0xff44b2dd, DEFAULT_STROKE = 0xffffffff;

    private SelfIcon() { }

    /** The icon for these colours, as a {@code base64://} URI. */
    public static String uri(int fill, int stroke) {
        final BufferedImage body = tinted("ic_self_tintable.png", fill);
        final BufferedImage outline = tinted("ic_self_stroke_tintable.png", stroke);
        final java.awt.Graphics2D g = body.createGraphics();
        g.drawImage(outline, 0, 0, null);
        g.dispose();
        final ByteArrayOutputStream out = new ByteArrayOutputStream();
        try {
            ImageIO.write(body, "png", out);
        } catch (IOException e) {
            throw new IllegalStateException("can't encode the self icon", e);
        }
        // URL-safe: the engine's base64:// loader decodes with URL_SAFE | NO_WRAP
        return "base64://" + Base64.getUrlEncoder().encodeToString(out.toByteArray());
    }

    private static BufferedImage tinted(String name, int argb) {
        final BufferedImage src;
        try (InputStream in = SelfIcon.class.getResourceAsStream("/assets/icons/" + name)) {
            if (in == null) throw new IllegalStateException("no classpath asset icons/" + name);
            src = ImageIO.read(in);
        } catch (IOException e) {
            throw new IllegalStateException("can't read icons/" + name, e);
        }
        final BufferedImage out = new BufferedImage(src.getWidth(), src.getHeight(), BufferedImage.TYPE_INT_ARGB);
        final int tintAlpha = argb >>> 24, rgb = argb & 0xFFFFFF;
        for (int y = 0; y < src.getHeight(); y++) {
            for (int x = 0; x < src.getWidth(); x++) {
                final int a = (src.getRGB(x, y) >>> 24) * tintAlpha / 255;
                out.setRGB(x, y, (a << 24) | rgb);
            }
        }
        return out;
    }
}
