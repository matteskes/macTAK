package mactak.headless;

import java.math.BigDecimal;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;

/**
 * The CoT that atak-headless sends, built as text: the self-SA presence,
 * the dropped marker, and the escaping and coordinate checks that keep
 * both well-formed. Moved out of {@link HeadlessCLI} so it is pure JDK (no
 * commo, no natives) and test/cot.sh can assert on it directly; the CLI
 * still owns argument parsing and sending.
 */
final class CotXml {

    private static final SimpleDateFormat COT_TIME = new SimpleDateFormat(
            "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US);
    static {
        COT_TIME.setTimeZone(TimeZone.getTimeZone("UTC"));
    }

    private static String now(long offsetMs) {
        synchronized (COT_TIME) {
            return COT_TIME.format(new Date(System.currentTimeMillis() + offsetMs));
        }
    }

    static final double MAX_LAT = 90.0;
    static final double MAX_LON = 180.0;

    /**
     * value as a plain decimal string when it is a finite number within
     * [-limit, limit], else null. Normalized because Double.parseDouble also
     * takes forms a CoT parser does not ("45f", "0x1p5", "1e1").
     */
    static String coordinate(String value, double limit) {
        final double d;
        try {
            d = Double.parseDouble(value);
        } catch (NumberFormatException e) {
            return null;
        }
        if (Double.isNaN(d) || Math.abs(d) > limit)
            return null;
        return BigDecimal.valueOf(d).toPlainString();
    }

    /**
     * Escape a value for an XML attribute or text node. uid and callsign come
     * from the command line or a data package: an apostrophe (O'BRIEN) or an
     * ampersand would otherwise make every presence/marker unparseable. Tab,
     * LF and CR become character references (a parser normalizes them to a
     * space in an attribute); characters XML 1.0 cannot carry at all (other
     * C0 controls, U+FFFE/U+FFFF, unpaired surrogates) become U+FFFD, since
     * one of them makes the whole event unparseable.
     */
    static String xmlEscape(String value) {
        final StringBuilder sb = new StringBuilder(value.length());
        for (int i = 0; i < value.length(); i++) {
            final char c = value.charAt(i);
            switch (c) {
                case '&':  sb.append("&amp;");  break;
                case '<':  sb.append("&lt;");   break;
                case '>':  sb.append("&gt;");   break;
                case '\'': sb.append("&apos;"); break;
                case '"':  sb.append("&quot;"); break;
                case '\t': sb.append("&#9;");   break;
                case '\n': sb.append("&#10;");  break;
                case '\r': sb.append("&#13;");  break;
                default:
                    if (Character.isHighSurrogate(c) && i + 1 < value.length()
                            && Character.isLowSurrogate(value.charAt(i + 1))) {
                        sb.append(c).append(value.charAt(++i));
                    } else if (c < 0x20 || c == 0xFFFE || c == 0xFFFF
                            || Character.isSurrogate(c)) {
                        sb.append('\uFFFD');
                    } else {
                        sb.append(c);
                    }
            }
        }
        return sb.toString();
    }

    /**
     * value made safe to print on a terminal: every C0 control, DEL and C1
     * control (U+0080–U+009F, which includes the 8-bit CSI U+009B some
     * terminals honour) becomes a visible {@code \\xNN}. Everything else,
     * non-ASCII text included, passes through. For inbound data (G1.14,
     * security audit #3): a hostile server's ESC sequences could otherwise
     * rewrite earlier output, retitle the window, or worse.
     */
    static String printable(String value) {
        if (value == null)
            return null;
        StringBuilder sb = null;
        for (int i = 0; i < value.length(); i++) {
            final char c = value.charAt(i);
            final boolean control = c < 0x20 || (c >= 0x7F && c <= 0x9F);
            if (control && sb == null)
                sb = new StringBuilder(value.length() + 8).append(value, 0, i);
            if (sb == null)
                continue;
            if (control)
                sb.append(String.format(Locale.US, "\\x%02x", (int) c));
            else
                sb.append(c);
        }
        return sb == null ? value : sb.toString();
    }

    /**
     * Every outgoing event's {@code access}. MIL-STD-6090 requires it; early
     * CoT left it optional, and 5.5's takproto/cotevent.proto asks new clients
     * to populate it on every outgoing message, "Undefined" when there is no
     * real value.
     */
    private static final String ACCESS = " access='Undefined'";

    /**
     * Self-SA as ATAK sends it (a-f-G-U-C + contact/__group/takv/uid): this is
     * what registers the EUD on a TAK server — OpenTAKServer only starts the
     * per-client fan-out consumer once a parseable self-SA with uid, callsign
     * and group has arrived; a bare t-x-a-t-a-k ping does not register.
     */
    static String presence(String rawUid, String rawCallsign) {
        final String uid = xmlEscape(rawUid), callsign = xmlEscape(rawCallsign);
        String t = now(0), stale = now(30000L);
        return "<event version='2.0' uid='" + uid + "' type='a-f-G-U-C'" + ACCESS
                + " time='" + t + "' start='" + t + "' stale='" + stale + "' how='m-g'>"
                + "<point lat='0.0' lon='0.0' ce='9999999' le='9999999' hae='0.0'/>"
                + "<detail>"
                + "<takv os='macOS' device='macTAK' platform='atak-headless' version='0.1.0'/>"
                + "<contact endpoint='*:-1:stcp' callsign='" + callsign + "'/>"
                + "<uid Droid='" + callsign + "'/>"
                + "<__group name='Cyan' role='Team Member'/>"
                + "<status battery='100'/>"
                + "<track course='0.0' speed='0.0'/>"
                + "</detail></event>";
    }

    static String marker(String rawUid, String rawCallsign, String lat, String lon) {
        // lat/lon were validated as plain numbers at argument parsing
        final String uid = xmlEscape(rawUid), callsign = xmlEscape(rawCallsign);
        String t = now(0), stale = now(120000L);
        return "<event version='2.0' uid='" + uid + "-m1' type='a-f-G-U-C'" + ACCESS
                + " time='" + t + "' start='" + t + "' stale='" + stale + "' how='m-g'>"
                + "<point lat='" + lat + "' lon='" + lon + "' ce='10.0' le='10.0' hae='0.0'/>"
                + "<detail>"
                + "<contact callsign='" + callsign + "-M1'/>"
                + "<precisionlocation geopossrc='gps'><point>" + lat + "," + lon
                + "</point></precisionlocation>"
                + "</detail></event>";
    }

    private CotXml() {}
}
