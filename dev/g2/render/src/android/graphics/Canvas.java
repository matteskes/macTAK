package android.graphics;

import java.awt.AlphaComposite;
import java.awt.BasicStroke;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.geom.AffineTransform;

/** macOS runtime for {@code android.graphics.Canvas}, drawing into a {@link Bitmap} via Java2D. */
public class Canvas {
    private Bitmap bitmap;
    private Graphics2D g;
    private final java.util.ArrayDeque<AffineTransform> saves = new java.util.ArrayDeque<>();

    public Canvas() { }

    // attach, not setBitmap(): Android's Canvas is subclassable, and an
    // override called from a constructor runs before the subclass is
    // initialized (javac 21's this-escape lint).
    public Canvas(Bitmap bitmap) { attach(bitmap); }

    public void setBitmap(Bitmap bitmap) { attach(bitmap); }

    private void attach(Bitmap bitmap) {
        if (g != null) g.dispose();
        this.bitmap = bitmap;
        g = bitmap == null ? null : bitmap.image.createGraphics();
        if (g != null) {
            g.setRenderingHint(RenderingHints.KEY_FRACTIONALMETRICS, RenderingHints.VALUE_FRACTIONALMETRICS_ON);
            g.setRenderingHint(RenderingHints.KEY_STROKE_CONTROL, RenderingHints.VALUE_STROKE_PURE);
        }
    }

    public int getWidth() { return bitmap == null ? 0 : bitmap.getWidth(); }
    public int getHeight() { return bitmap == null ? 0 : bitmap.getHeight(); }

    public int save() { saves.push(g.getTransform()); return saves.size(); }
    public void restore() { if (!saves.isEmpty()) g.setTransform(saves.pop()); }
    public int getSaveCount() { return saves.size(); }
    public void translate(float dx, float dy) { g.translate(dx, dy); }
    public void scale(float sx, float sy) { g.scale(sx, sy); }
    public void rotate(float degrees) { g.rotate(Math.toRadians(degrees)); }

    public boolean clipRect(int left, int top, int right, int bottom) { g.clipRect(left, top, right - left, bottom - top); return true; }
    public boolean clipRect(Rect r) { return clipRect(r.left, r.top, r.right, r.bottom); }

    private void apply(Paint p) {
        boolean aa = p == null || p.isAntiAlias();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, aa ? RenderingHints.VALUE_ANTIALIAS_ON : RenderingHints.VALUE_ANTIALIAS_OFF);
        g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, aa ? RenderingHints.VALUE_TEXT_ANTIALIAS_ON : RenderingHints.VALUE_TEXT_ANTIALIAS_OFF);
        g.setRenderingHint(RenderingHints.KEY_INTERPOLATION,
                p != null && p.isFilterBitmap() ? RenderingHints.VALUE_INTERPOLATION_BILINEAR : RenderingHints.VALUE_INTERPOLATION_NEAREST_NEIGHBOR);
        g.setComposite(AlphaComposite.SrcOver);
        if (p != null) {
            g.setColor(new java.awt.Color(p.color, true));
            g.setStroke(new BasicStroke(Math.max(1f, p.strokeWidth), cap(p.cap), join(p.join)));
        }
    }

    private static int cap(Paint.Cap c) {
        switch (c) { case ROUND: return BasicStroke.CAP_ROUND; case SQUARE: return BasicStroke.CAP_SQUARE; default: return BasicStroke.CAP_BUTT; }
    }

    private static int join(Paint.Join j) {
        switch (j) { case ROUND: return BasicStroke.JOIN_ROUND; case BEVEL: return BasicStroke.JOIN_BEVEL; default: return BasicStroke.JOIN_MITER; }
    }

    public void drawColor(int color) {
        g.setComposite(AlphaComposite.SrcOver);
        g.setColor(new java.awt.Color(color, true));
        g.fillRect(0, 0, getWidth(), getHeight());
    }

    public void drawARGB(int a, int r, int gg, int b) { drawColor(Color.argb(a, r, gg, b)); }
    public void drawRGB(int r, int gg, int b) { drawColor(Color.rgb(r, gg, b)); }

    public void drawRect(float left, float top, float right, float bottom, Paint paint) {
        apply(paint);
        java.awt.geom.Rectangle2D r = new java.awt.geom.Rectangle2D.Float(left, top, right - left, bottom - top);
        if (paint.style != Paint.Style.STROKE) g.fill(r);
        if (paint.style != Paint.Style.FILL) g.draw(r);
    }

    public void drawRect(Rect r, Paint paint) { drawRect(r.left, r.top, r.right, r.bottom, paint); }
    public void drawRect(RectF r, Paint paint) { drawRect(r.left, r.top, r.right, r.bottom, paint); }

    public void drawLine(float x0, float y0, float x1, float y1, Paint paint) {
        apply(paint);
        g.draw(new java.awt.geom.Line2D.Float(x0, y0, x1, y1));
    }

    public void drawCircle(float cx, float cy, float radius, Paint paint) {
        apply(paint);
        java.awt.geom.Ellipse2D e = new java.awt.geom.Ellipse2D.Float(cx - radius, cy - radius, radius * 2, radius * 2);
        if (paint.style != Paint.Style.STROKE) g.fill(e);
        if (paint.style != Paint.Style.FILL) g.draw(e);
    }

    /** (x, y) is the text origin on the baseline, as on Android; alignment per {@link Paint#getTextAlign()}. */
    public void drawText(String text, float x, float y, Paint paint) {
        if (text == null || text.isEmpty()) return;
        apply(paint);
        java.awt.Font f = paint.awtFont();
        if (paint.textSkewX != 0f) f = f.deriveFont(AffineTransform.getShearInstance(-paint.textSkewX, 0));
        g.setFont(f);
        float w = paint.measureText(text);
        if (paint.align == Paint.Align.CENTER) x -= w / 2f;
        else if (paint.align == Paint.Align.RIGHT) x -= w;
        if (paint.style == Paint.Style.STROKE || paint.style == Paint.Style.FILL_AND_STROKE) {
            java.awt.Shape outline = f.createGlyphVector(g.getFontRenderContext(), text).getOutline(x, y);
            if (paint.style == Paint.Style.FILL_AND_STROKE) g.fill(outline);
            g.draw(outline);
        } else {
            g.drawString(text, x, y);
        }
        if (paint.isUnderlineText() || paint.isStrikeThruText()) {
            java.awt.font.LineMetrics lm = f.getLineMetrics(text, g.getFontRenderContext());
            if (paint.isUnderlineText()) g.fill(new java.awt.geom.Rectangle2D.Float(x, y + lm.getUnderlineOffset(), w, Math.max(1f, lm.getUnderlineThickness())));
            if (paint.isStrikeThruText()) g.fill(new java.awt.geom.Rectangle2D.Float(x, y + lm.getStrikethroughOffset(), w, Math.max(1f, lm.getStrikethroughThickness())));
        }
    }

    public void drawText(String text, int start, int end, float x, float y, Paint paint) {
        drawText(text.substring(start, end), x, y, paint);
    }

    public void drawText(char[] text, int index, int count, float x, float y, Paint paint) {
        drawText(new String(text, index, count), x, y, paint);
    }

    public void drawBitmap(Bitmap bitmap, float left, float top, Paint paint) {
        apply(paint);
        if (paint != null && paint.getAlpha() < 255) g.setComposite(AlphaComposite.getInstance(AlphaComposite.SRC_OVER, paint.getAlpha() / 255f));
        g.drawImage(bitmap.image, Math.round(left), Math.round(top), null);
    }

    public void drawBitmap(Bitmap bitmap, Rect src, Rect dst, Paint paint) {
        apply(paint);
        if (paint != null && paint.getAlpha() < 255) g.setComposite(AlphaComposite.getInstance(AlphaComposite.SRC_OVER, paint.getAlpha() / 255f));
        if (src == null) src = new Rect(0, 0, bitmap.getWidth(), bitmap.getHeight());
        g.drawImage(bitmap.image, dst.left, dst.top, dst.right, dst.bottom, src.left, src.top, src.right, src.bottom, null);
    }

    public void drawBitmap(Bitmap bitmap, Rect src, RectF dst, Paint paint) {
        apply(paint);
        if (paint != null && paint.getAlpha() < 255) g.setComposite(AlphaComposite.getInstance(AlphaComposite.SRC_OVER, paint.getAlpha() / 255f));
        if (src == null) src = new Rect(0, 0, bitmap.getWidth(), bitmap.getHeight());
        AffineTransform saved = g.getTransform();
        g.translate(dst.left, dst.top);
        g.scale(dst.width() / (double) src.width(), dst.height() / (double) src.height());
        g.drawImage(bitmap.image, 0, 0, src.width(), src.height(), src.left, src.top, src.right, src.bottom, null);
        g.setTransform(saved);
    }

    public void drawBitmap(Bitmap bitmap, Matrix matrix, Paint paint) {
        apply(paint);
        g.drawImage(bitmap.image, matrix.toAwt(), null);
    }
}
