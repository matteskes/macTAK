package mactak.render;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.BitmapRegionDecoder;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Rect;

import java.awt.image.BufferedImage;
import java.io.File;
import java.io.IOException;
import java.nio.file.Files;

import javax.imageio.ImageIO;

/**
 * Assertions for two of the {@code android.graphics} stand-ins, run by
 * {@code dev/g2/render/test/graphics.sh}. Pure Java: no natives, no GL.
 *
 * <ul>
 *   <li>{@code BitmapRegionDecoder} (issue 131): opening by path, decoding and
 *       recycling leaves the process's open-descriptor count where it
 *       started, and so does a failed open.</li>
 *   <li>{@code Canvas} (issue 132): {@code save()} and {@code restore()} cover
 *       the clip as well as the transform, as on Android, and
 *       {@code restoreToCount()} undoes every save after the one it names.</li>
 * </ul>
 *
 * <p>Exit: 0 PASS, 1 FAIL.
 */
public final class GraphicsSelfTest {

    private static final int DECODE_ROUNDS = 20;
    private static final int SIZE = 20;
    private static final int RED = Color.argb(255, 255, 0, 0);

    private static int failures = 0;

    private GraphicsSelfTest() { }

    private static void check(boolean cond, String what) {
        System.out.println((cond ? "PASS: " : "FAIL: ") + what);
        if (!cond) failures++;
    }

    /** This process's open descriptors (listing /dev/fd opens one more, the same each time). */
    private static int openDescriptors() {
        String[] fds = new File("/dev/fd").list();
        return fds == null ? -1 : fds.length;
    }

    private static void decoderReleasesItsFile(File dir) throws IOException {
        File png = new File(dir, "tile.png");
        ImageIO.write(new BufferedImage(SIZE, SIZE, BufferedImage.TYPE_INT_ARGB), "png", png);
        File notAnImage = new File(dir, "not-an-image.png");
        Files.write(notAnImage.toPath(), "not an image".getBytes("US-ASCII"));

        final int before = openDescriptors();
        for (int i = 0; i < DECODE_ROUNDS; i++) {
            BitmapRegionDecoder decoder = BitmapRegionDecoder.newInstance(png.getPath(), false);
            Bitmap region = decoder.decodeRegion(new Rect(0, 0, SIZE / 2, SIZE / 2), new BitmapFactory.Options());
            if (region == null) throw new IOException("decodeRegion returned null");
            decoder.recycle();
        }
        check(openDescriptors() == before,
                "open-decode-recycle x" + DECODE_ROUNDS + " leaves the descriptor count at " + before
                        + " (now " + openDescriptors() + ")");

        final int beforeFailure = openDescriptors();
        boolean threw = false;
        try {
            BitmapRegionDecoder.newInstance(notAnImage.getPath(), false);
        } catch (IOException expected) {
            threw = true;
        }
        check(threw, "newInstance on a file that isn't an image throws IOException");
        check(openDescriptors() == beforeFailure,
                "a failed newInstance leaves the descriptor count at " + beforeFailure
                        + " (now " + openDescriptors() + ")");
    }

    private static boolean paintedRed(Bitmap bitmap, int x, int y) {
        return bitmap.getPixel(x, y) == RED;
    }

    private static void canvasRestoresTheClip() {
        Bitmap bitmap = Bitmap.createBitmap(SIZE, SIZE, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        check(canvas.getSaveCount() == 1, "a new Canvas has a save count of 1, as on Android");

        canvas.save();
        canvas.clipRect(0, 0, 5, 5);
        canvas.restore();
        canvas.drawColor(RED);
        check(paintedRed(bitmap, 15, 15), "a clipRect inside save/restore doesn't clip a draw after the restore");

        Bitmap second = Bitmap.createBitmap(SIZE, SIZE, Bitmap.Config.ARGB_8888);
        canvas.setBitmap(second);
        final int base = canvas.save();
        canvas.clipRect(0, 0, 5, 5);
        canvas.save();
        canvas.translate(100, 100);
        canvas.restoreToCount(base);
        check(canvas.getSaveCount() == base, "restoreToCount(" + base + ") returns the save count to " + base);
        canvas.drawColor(RED);
        check(paintedRed(second, 15, 15) && paintedRed(second, 0, 0),
                "restoreToCount undoes both saves' clip and transform");
    }

    public static void main(String[] args) throws IOException {
        File dir = Files.createTempDirectory("mactak-graphics").toFile();
        try {
            decoderReleasesItsFile(dir);
            canvasRestoresTheClip();
        } finally {
            File[] files = dir.listFiles();
            if (files != null) for (File f : files) Files.deleteIfExists(f.toPath());
            Files.deleteIfExists(dir.toPath());
        }
        System.out.println(failures == 0 ? "graphics-canary: PASS" : "graphics-canary: FAIL (" + failures + " check(s))");
        System.exit(failures == 0 ? 0 : 1);
    }
}
