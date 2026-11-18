package android.util;

import java.nio.charset.StandardCharsets;

/**
 * macOS runtime for {@code android.util.Base64} (the transplant's body is
 * "Stub!"), on {@link java.util.Base64}. The engine's {@code base64://} icon
 * loader decodes with it ({@code GLBitmapLoader.Base64BitmapLoaderSpi},
 * {@code URL_SAFE | NO_WRAP}); without it every such icon failed to load
 * (G3.7b: the self marker).
 *
 * <p>As Android's: decoding takes either alphabet's padding or none, and
 * skips whitespace; {@code URL_SAFE} picks the "-_" alphabet; encoding wraps
 * at 76 characters with "\n" ({@code CRLF}: "\r\n") unless {@code NO_WRAP},
 * and pads unless {@code NO_PADDING}.
 */
public class Base64 {
    public static final int DEFAULT = 0;
    public static final int NO_PADDING = 1;
    public static final int NO_WRAP = 2;
    public static final int CRLF = 4;
    public static final int URL_SAFE = 8;
    public static final int NO_CLOSE = 16;

    /** Android's line length when wrapping. */
    private static final int LINE = 76;

    public static byte[] decode(String str, int flags) {
        return decode(str.getBytes(StandardCharsets.US_ASCII), flags);
    }

    public static byte[] decode(byte[] input, int flags) {
        return decode(input, 0, input.length, flags);
    }

    public static byte[] decode(byte[] input, int offset, int len, int flags) {
        final StringBuilder clean = new StringBuilder(len);
        for (int i = offset; i < offset + len; i++) {
            final char c = (char) (input[i] & 0xff);
            if (!Character.isWhitespace(c)) clean.append(c);
        }
        final java.util.Base64.Decoder d = (flags & URL_SAFE) != 0
                ? java.util.Base64.getUrlDecoder() : java.util.Base64.getDecoder();
        try {
            return d.decode(clean.toString());
        } catch (IllegalArgumentException e) {
            throw new IllegalArgumentException("bad base-64", e);
        }
    }

    public static String encodeToString(byte[] input, int flags) {
        return new String(encode(input, flags), StandardCharsets.US_ASCII);
    }

    public static String encodeToString(byte[] input, int offset, int len, int flags) {
        return new String(encode(input, offset, len, flags), StandardCharsets.US_ASCII);
    }

    public static byte[] encode(byte[] input, int flags) {
        return encode(input, 0, input.length, flags);
    }

    public static byte[] encode(byte[] input, int offset, int len, int flags) {
        java.util.Base64.Encoder e = (flags & URL_SAFE) != 0
                ? java.util.Base64.getUrlEncoder() : java.util.Base64.getEncoder();
        if ((flags & NO_PADDING) != 0) e = e.withoutPadding();
        final byte[] slice = new byte[len];
        System.arraycopy(input, offset, slice, 0, len);
        final String flat = e.encodeToString(slice);
        if ((flags & NO_WRAP) != 0) return flat.getBytes(StandardCharsets.US_ASCII);
        final String eol = (flags & CRLF) != 0 ? "\r\n" : "\n";
        final StringBuilder out = new StringBuilder(flat.length() + flat.length() / LINE * 2 + 2);
        for (int i = 0; i < flat.length(); i += LINE) {
            out.append(flat, i, Math.min(flat.length(), i + LINE)).append(eol);
        }
        return out.toString().getBytes(StandardCharsets.US_ASCII);
    }
}
