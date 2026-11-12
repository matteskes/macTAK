package android.graphics;

import java.awt.Font;
import java.awt.font.FontRenderContext;
import java.awt.font.LineMetrics;
import java.awt.geom.AffineTransform;
import java.awt.geom.Rectangle2D;

/** macOS runtime for {@code android.graphics.Paint}, measuring with Java2D font metrics. */
public class Paint {
    public static final int ANTI_ALIAS_FLAG = 0x01;
    public static final int FILTER_BITMAP_FLAG = 0x02;
    public static final int DITHER_FLAG = 0x04;
    public static final int UNDERLINE_TEXT_FLAG = 0x08;
    public static final int STRIKE_THRU_TEXT_FLAG = 0x10;
    public static final int FAKE_BOLD_TEXT_FLAG = 0x20;
    public static final int LINEAR_TEXT_FLAG = 0x40;
    public static final int SUBPIXEL_TEXT_FLAG = 0x80;

    public enum Style { FILL, STROKE, FILL_AND_STROKE }
    public enum Align { LEFT, CENTER, RIGHT }
    public enum Cap { BUTT, ROUND, SQUARE }
    public enum Join { MITER, ROUND, BEVEL }

    public static class FontMetrics {
        public float top, ascent, descent, bottom, leading;
    }

    public static class FontMetricsInt {
        public int top, ascent, descent, bottom, leading;
        @Override public String toString() {
            return "FontMetricsInt: top=" + top + " ascent=" + ascent + " descent=" + descent + " bottom=" + bottom + " leading=" + leading;
        }
    }

    static final FontRenderContext FRC = new FontRenderContext(new AffineTransform(), true, true);

    int flags;
    int color = Color.BLACK;
    Style style = Style.FILL;
    Align align = Align.LEFT;
    float strokeWidth = 0f;
    float textSize = 12f;
    float textSkewX = 0f;
    Typeface typeface = Typeface.DEFAULT;
    Cap cap = Cap.BUTT;
    Join join = Join.MITER;

    public Paint() { }

    public Paint(int flags) { this.flags = flags; }

    // copyFrom, not set(): Android's Paint is subclassable, and an override
    // called from a constructor runs before the subclass is initialized
    // (javac 21's this-escape lint).
    public Paint(Paint src) { copyFrom(src); }

    public void set(Paint src) { copyFrom(src); }

    private void copyFrom(Paint src) {
        flags = src.flags; color = src.color; style = src.style; align = src.align; strokeWidth = src.strokeWidth;
        textSize = src.textSize; textSkewX = src.textSkewX; typeface = src.typeface; cap = src.cap; join = src.join;
    }

    public void reset() { set(new Paint()); }

    public int getFlags() { return flags; }
    public void setFlags(int flags) { this.flags = flags; }
    public boolean isAntiAlias() { return (flags & ANTI_ALIAS_FLAG) != 0; }
    public void setAntiAlias(boolean aa) { flags = aa ? (flags | ANTI_ALIAS_FLAG) : (flags & ~ANTI_ALIAS_FLAG); }
    public boolean isFilterBitmap() { return (flags & FILTER_BITMAP_FLAG) != 0; }
    public void setFilterBitmap(boolean f) { flags = f ? (flags | FILTER_BITMAP_FLAG) : (flags & ~FILTER_BITMAP_FLAG); }
    public boolean isUnderlineText() { return (flags & UNDERLINE_TEXT_FLAG) != 0; }
    public void setUnderlineText(boolean u) { flags = u ? (flags | UNDERLINE_TEXT_FLAG) : (flags & ~UNDERLINE_TEXT_FLAG); }
    public boolean isStrikeThruText() { return (flags & STRIKE_THRU_TEXT_FLAG) != 0; }
    public void setStrikeThruText(boolean s) { flags = s ? (flags | STRIKE_THRU_TEXT_FLAG) : (flags & ~STRIKE_THRU_TEXT_FLAG); }
    public boolean isFakeBoldText() { return (flags & FAKE_BOLD_TEXT_FLAG) != 0; }
    public void setFakeBoldText(boolean b) { flags = b ? (flags | FAKE_BOLD_TEXT_FLAG) : (flags & ~FAKE_BOLD_TEXT_FLAG); }

    public int getColor() { return color; }
    public void setColor(int color) { this.color = color; }
    public int getAlpha() { return color >>> 24; }
    public void setAlpha(int a) { color = (a << 24) | (color & 0x00FFFFFF); }
    public void setARGB(int a, int r, int g, int b) { color = Color.argb(a, r, g, b); }

    public Style getStyle() { return style; }
    public void setStyle(Style style) { this.style = style; }
    public Align getTextAlign() { return align; }
    public void setTextAlign(Align align) { this.align = align; }
    public float getStrokeWidth() { return strokeWidth; }
    public void setStrokeWidth(float width) { this.strokeWidth = width; }
    public Cap getStrokeCap() { return cap; }
    public void setStrokeCap(Cap cap) { this.cap = cap; }
    public Join getStrokeJoin() { return join; }
    public void setStrokeJoin(Join join) { this.join = join; }
    public float getTextSize() { return textSize; }
    public void setTextSize(float textSize) { this.textSize = textSize; }
    public float getTextSkewX() { return textSkewX; }
    public void setTextSkewX(float skewX) { this.textSkewX = skewX; }
    public Typeface getTypeface() { return typeface; }

    public Typeface setTypeface(Typeface typeface) {
        Typeface old = this.typeface;
        this.typeface = typeface != null ? typeface : Typeface.DEFAULT;
        return old;
    }

    Font awtFont() {
        Font f = typeface.awtFont(textSize);
        if (isFakeBoldText() && !typeface.isBold()) f = f.deriveFont(f.getStyle() | Font.BOLD);
        return f;
    }

    public float measureText(String text) { return measureText(text, 0, text.length()); }

    public float measureText(String text, int start, int end) {
        if (end <= start) return 0f;
        return (float) awtFont().getStringBounds(text, start, end, FRC).getWidth();
    }

    public float measureText(char[] text, int index, int count) {
        if (count <= 0) return 0f;
        return (float) awtFont().getStringBounds(text, index, index + count, FRC).getWidth();
    }

    public int getTextWidths(char[] text, int index, int count, float[] widths) {
        Font f = awtFont();
        for (int i = 0; i < count; i++) {
            widths[i] = (float) f.getStringBounds(text, index + i, index + i + 1, FRC).getWidth();
        }
        return count;
    }

    public int getTextWidths(String text, float[] widths) {
        return getTextWidths(text.toCharArray(), 0, text.length(), widths);
    }

    public void getTextBounds(String text, int start, int end, Rect bounds) {
        Rectangle2D r = awtFont().createGlyphVector(FRC, text.substring(start, end)).getVisualBounds();
        bounds.set((int) Math.floor(r.getMinX()), (int) Math.floor(r.getMinY()), (int) Math.ceil(r.getMaxX()), (int) Math.ceil(r.getMaxY()));
    }

    public float ascent() { return -lineMetrics().getAscent(); }
    public float descent() { return lineMetrics().getDescent(); }

    private LineMetrics lineMetrics() { return awtFont().getLineMetrics("Ag", FRC); }

    public FontMetrics getFontMetrics() {
        FontMetrics m = new FontMetrics();
        getFontMetrics(m);
        return m;
    }

    public float getFontMetrics(FontMetrics m) {
        LineMetrics lm = lineMetrics();
        // Android: top/bottom are the max glyph extents; Java2D gives ascent/descent/leading.
        // Use the font's maximum bounds for top/bottom so tall glyphs are not clipped.
        Rectangle2D max = awtFont().getMaxCharBounds(FRC);
        m.ascent = -lm.getAscent();
        m.descent = lm.getDescent();
        m.top = Math.min(m.ascent, (float) max.getMinY());
        m.bottom = Math.max(m.descent, (float) max.getMaxY());
        m.leading = lm.getLeading();
        return m.descent - m.ascent + m.leading;
    }

    public FontMetricsInt getFontMetricsInt() {
        FontMetricsInt m = new FontMetricsInt();
        getFontMetricsInt(m);
        return m;
    }

    public int getFontMetricsInt(FontMetricsInt m) {
        FontMetrics f = getFontMetrics();
        m.ascent = Math.round(f.ascent);     // negative
        m.descent = Math.round(f.descent);
        m.top = (int) Math.floor(f.top);
        m.bottom = (int) Math.ceil(f.bottom);
        m.leading = Math.round(f.leading);
        return m.descent - m.ascent + m.leading;
    }
}
