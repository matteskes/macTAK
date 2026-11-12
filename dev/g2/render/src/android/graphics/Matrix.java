package android.graphics;

/** macOS runtime for {@code android.graphics.Matrix} (2D affine, row-major 3x3 like Android). */
public class Matrix {
    public static final int MSCALE_X = 0, MSKEW_X = 1, MTRANS_X = 2;
    public static final int MSKEW_Y = 3, MSCALE_Y = 4, MTRANS_Y = 5;
    public static final int MPERSP_0 = 6, MPERSP_1 = 7, MPERSP_2 = 8;

    final float[] m = new float[9];

    // The constructors use the private helpers, not reset()/set(): Android's
    // Matrix is subclassable, and an override called from a constructor runs
    // before the subclass is initialized (javac 21's this-escape lint).
    public Matrix() { identity(m); }

    public Matrix(Matrix src) { copy(src, m); }

    public void reset() { identity(m); }

    public void set(Matrix src) { copy(src, m); }

    private static void identity(float[] m) {
        m[0] = 1; m[1] = 0; m[2] = 0;
        m[3] = 0; m[4] = 1; m[5] = 0;
        m[6] = 0; m[7] = 0; m[8] = 1;
    }

    private static void copy(Matrix src, float[] dst) {
        if (src == null) identity(dst); else System.arraycopy(src.m, 0, dst, 0, 9);
    }

    public boolean isIdentity() {
        return m[0] == 1 && m[1] == 0 && m[2] == 0 && m[3] == 0 && m[4] == 1 && m[5] == 0 && m[6] == 0 && m[7] == 0 && m[8] == 1;
    }

    public void setScale(float sx, float sy) { reset(); m[0] = sx; m[4] = sy; }

    public void setScale(float sx, float sy, float px, float py) {
        reset(); m[0] = sx; m[4] = sy; m[2] = px - sx * px; m[5] = py - sy * py;
    }

    public void setTranslate(float dx, float dy) { reset(); m[2] = dx; m[5] = dy; }

    public void setRotate(float degrees) {
        double r = Math.toRadians(degrees);
        float c = (float) Math.cos(r), s = (float) Math.sin(r);
        reset(); m[0] = c; m[1] = -s; m[3] = s; m[4] = c;
    }

    public boolean postScale(float sx, float sy) { Matrix t = new Matrix(); t.setScale(sx, sy); return setConcat(t, this); }
    public boolean postTranslate(float dx, float dy) { Matrix t = new Matrix(); t.setTranslate(dx, dy); return setConcat(t, this); }
    public boolean preScale(float sx, float sy) { Matrix t = new Matrix(); t.setScale(sx, sy); return setConcat(this, t); }
    public boolean preTranslate(float dx, float dy) { Matrix t = new Matrix(); t.setTranslate(dx, dy); return setConcat(this, t); }

    /** this = a x b */
    public boolean setConcat(Matrix a, Matrix b) {
        float[] r = new float[9];
        for (int row = 0; row < 3; row++)
            for (int col = 0; col < 3; col++)
                r[row * 3 + col] = a.m[row * 3] * b.m[col] + a.m[row * 3 + 1] * b.m[3 + col] + a.m[row * 3 + 2] * b.m[6 + col];
        System.arraycopy(r, 0, m, 0, 9);
        return true;
    }

    public void getValues(float[] values) { System.arraycopy(m, 0, values, 0, 9); }
    public void setValues(float[] values) { System.arraycopy(values, 0, m, 0, 9); }

    public void mapPoints(float[] pts) {
        for (int i = 0; i + 1 < pts.length; i += 2) {
            float x = pts[i], y = pts[i + 1];
            pts[i] = m[0] * x + m[1] * y + m[2];
            pts[i + 1] = m[3] * x + m[4] * y + m[5];
        }
    }

    java.awt.geom.AffineTransform toAwt() {
        return new java.awt.geom.AffineTransform(m[0], m[3], m[1], m[4], m[2], m[5]);
    }

    @Override public String toString() {
        return "Matrix{[" + m[0] + ", " + m[1] + ", " + m[2] + "][" + m[3] + ", " + m[4] + ", " + m[5] + "][" + m[6] + ", " + m[7] + ", " + m[8] + "]}";
    }
}
