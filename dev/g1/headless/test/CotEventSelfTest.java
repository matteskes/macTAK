package mactak.headless;

/**
 * Assertions for the CoT text path of atak-headless, run by test/cot.sh
 * (repo idiom: shell-orchestrated javac+java, no JUnit, no natives).
 *
 * <p>Receive side: {@link CotEvent#parse} — the fields the tracks DB
 * persists, direct-child {@code <point>}/{@code <detail><contact>} lookup,
 * refusal of non-CoT and of DOCTYPE (XXE). Send side: {@link CotXml} — the
 * escaping, the {@code --send-marker} coordinate check, and the presence
 * and marker events, each parsed back through {@link CotEvent} so a
 * builder that emits malformed XML fails here, not on a TAK server.</p>
 */
public final class CotEventSelfTest {

    private static int failures = 0;

    private CotEventSelfTest() {
    }

    private static void check(boolean cond, String what) {
        if (cond)
            System.out.println("PASS: " + what);
        else {
            System.out.println("FAIL: " + what);
            failures++;
        }
    }

    /** Parse expecting failure; returns the message, or null if it parsed. */
    private static String parseMustFail(String xml) {
        try {
            CotEvent.parse(xml);
            return null;
        } catch (Exception e) {
            return String.valueOf(e.getMessage());
        }
    }

    /** The {@code <event>} root's attribute, "" when absent (our own XML, parsed plainly). */
    private static String eventAttribute(String xml, String name) throws Exception {
        return javax.xml.parsers.DocumentBuilderFactory.newInstance().newDocumentBuilder()
                .parse(new org.xml.sax.InputSource(new java.io.StringReader(xml)))
                .getDocumentElement().getAttribute(name);
    }

    private static final String TIME_RE =
            "\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z";

    public static void main(String[] args) throws Exception {
        parseSide();
        escapeAndCoordinates();
        builders();
        printableOutput();
        if (failures == 0) {
            System.out.println("cot-selftest: ALL PASS");
            return;
        }
        System.out.println("cot-selftest: " + failures + " FAILURES");
        System.exit(1);
    }

    private static void parseSide() throws Exception {
        // --- happy path ----------------------------------------------------
        CotEvent e = CotEvent.parse("<event version='2.0' uid='u-1' type='a-f-G-U-C'"
                + " how='m-g' time='2026-11-09T00:00:00.000Z'"
                + " start='2026-11-09T00:00:01.000Z' stale='2026-11-09T00:05:00.000Z'>"
                + "<point lat='37.5' lon='-122.25' hae='12.5' ce='3.0' le='4.0'/>"
                + "<detail><contact callsign='ALPHA'/></detail></event>");
        check("u-1".equals(e.uid) && "a-f-G-U-C".equals(e.type) && "m-g".equals(e.how),
                "event attributes read");
        check("2026-11-09T00:00:00.000Z".equals(e.time)
                        && "2026-11-09T00:00:01.000Z".equals(e.start)
                        && "2026-11-09T00:05:00.000Z".equals(e.stale),
                "time/start/stale read");
        check(e.lat == 37.5 && e.lon == -122.25 && e.hae == 12.5
                        && e.ce == 3.0 && e.le == 4.0,
                "point attributes read as numbers");
        check("ALPHA".equals(e.callsign), "detail/contact callsign read");

        e = CotEvent.parse("<event uid='u-2' type='t'><point lat='1' lon='2'/></event>");
        check(e.callsign == null, "no <detail>: callsign is null");
        check(Double.isNaN(e.hae) && Double.isNaN(e.ce) && Double.isNaN(e.le),
                "absent point attributes are NaN");

        e = CotEvent.parse("<event uid='u-3' type='t'><point lat='1' lon='2'/>"
                + "<detail><contact callsign=''/></detail></event>");
        check(e.callsign == null, "empty callsign is null");

        // --- direct children only (the audit's CotEvent fix) ----------------
        e = CotEvent.parse("<event uid='u-4' type='t'>"
                + "<detail><precisionlocation><point lat='9' lon='9'/></precisionlocation>"
                + "<link><contact callsign='WRONG'/></link>"
                + "<contact callsign='RIGHT'/></detail>"
                + "<point lat='37.75' lon='-122.5'/></event>");
        check(e.lat == 37.75 && e.lon == -122.5,
                "event's own <point> wins over one nested in <detail>");
        check("RIGHT".equals(e.callsign),
                "detail's own <contact> wins over one nested in <link>");

        String msg = parseMustFail("<event uid='u-5' type='t'><detail>"
                + "<precisionlocation><point lat='1' lon='2'/></precisionlocation>"
                + "</detail></event>");
        check(msg != null && msg.contains("has no <point>"),
                "only a nested <point>: refused, not borrowed: " + msg);

        e = CotEvent.parse("<event uid='u-6' type='t'><point lat='1' lon='2'/>"
                + "<contact callsign='NOT-IN-DETAIL'/></event>");
        check(e.callsign == null, "<contact> outside <detail> is not the callsign");

        // --- refusals --------------------------------------------------------
        msg = parseMustFail("<ping uid='x'/>");
        check(msg != null && msg.contains("not <event>"), "non-event root refused: " + msg);
        msg = parseMustFail("<event type='t'><point lat='1' lon='2'/></event>");
        check(msg != null && msg.contains("no uid"), "event without uid refused: " + msg);
        msg = parseMustFail("<event uid='u' type='t'><point lat='north' lon='2'/></event>");
        check(msg != null, "non-numeric lat refused: " + msg);
        msg = parseMustFail("<event uid='u' type='t'><point lat='1' lon='2'/>");
        check(msg != null, "truncated XML refused: " + msg);
        msg = parseMustFail("<?xml version='1.0'?><!DOCTYPE event ["
                + "<!ENTITY x SYSTEM 'file:///etc/passwd'>]>"
                + "<event uid='&x;' type='t'><point lat='1' lon='2'/></event>");
        check(msg != null && msg.contains("DOCTYPE"),
                "DOCTYPE (XXE) refused: " + msg);

        // --- <point> numbers (audit pass 2) -----------------------------------
        // A point without a usable lat/lon is not a position: persisted, it
        // read back from the tracks DB as 0,0 (null island).
        msg = parseMustFail("<event uid='u' type='t'><point lon='2'/></event>");
        check(msg != null && msg.contains("no lat"), "missing lat refused: " + msg);
        msg = parseMustFail("<event uid='u' type='t'><point lat='1'/></event>");
        check(msg != null && msg.contains("no lon"), "missing lon refused: " + msg);
        msg = parseMustFail("<event uid='u' type='t'><point lat='NaN' lon='2'/></event>");
        check(msg != null, "NaN lat refused: " + msg);
        msg = parseMustFail("<event uid='u' type='t'><point lat='1' lon='Infinity'/></event>");
        check(msg != null, "Infinity lon refused: " + msg);
        msg = parseMustFail("<event uid='u' type='t'><point lat='90.5' lon='2'/></event>");
        check(msg != null && msg.contains("out of range"), "lat > 90 refused: " + msg);
        msg = parseMustFail("<event uid='u' type='t'><point lat='1' lon='-180.01'/></event>");
        check(msg != null && msg.contains("out of range"), "lon < -180 refused: " + msg);
        msg = parseMustFail("<event uid='u' type='t'><point lat='45f' lon='0x1p5'/></event>");
        check(msg != null && msg.contains("not a number"),
                "Java-only number forms (45f, 0x1p5) refused: " + msg);
        msg = parseMustFail("<event uid='u' type='t'><point lat='1' lon='2' hae='12d'/></event>");
        check(msg != null && msg.contains("not a number"), "Java-only hae form refused: " + msg);
        e = CotEvent.parse("<event uid='u-8' type='t'>"
                + "<point lat='-90' lon='180' hae='NaN' ce='9999999.0' le='1e2'/></event>");
        check(e.lat == -90.0 && e.lon == 180.0 && Double.isNaN(e.hae)
                        && e.ce == 9999999.0 && e.le == 100.0,
                "range bounds inclusive; hae='NaN' is unknown; exponent form read");

        // An XML prolog is fine (commo prefixes one on the wire).
        e = CotEvent.parse("<?xml version='1.0' encoding='UTF-8'?>"
                + "<event uid='u-7' type='t'><point lat='1' lon='2'/></event>");
        check("u-7".equals(e.uid), "XML prolog accepted");
    }

    private static void escapeAndCoordinates() {
        check("&amp;&lt;&gt;&apos;&quot;".equals(CotXml.xmlEscape("&<>'\"")),
                "xmlEscape covers & < > ' \"");
        check("plain-CALLSIGN_1".equals(CotXml.xmlEscape("plain-CALLSIGN_1")),
                "xmlEscape leaves plain text alone");
        check("&amp;amp;".equals(CotXml.xmlEscape("&amp;")),
                "xmlEscape escapes an existing entity (no double-decode)");

        check("a&#9;b&#10;c&#13;d".equals(CotXml.xmlEscape("a\tb\nc\rd")),
                "xmlEscape keeps tab/LF/CR as character references");
        check("x\uFFFDy\uFFFDz".equals(CotXml.xmlEscape("x\u0001y\uFFFEz")),
                "xmlEscape replaces characters XML 1.0 cannot carry");
        check("\uD83D\uDE00\uFFFD".equals(CotXml.xmlEscape("\uD83D\uDE00\uD83D")),
                "xmlEscape keeps a surrogate pair, replaces an unpaired surrogate");

        check("37.7749".equals(CotXml.coordinate("37.7749", CotXml.MAX_LAT)),
                "lat 37.7749 kept as given");
        check("-122.4194".equals(CotXml.coordinate("-122.4194", CotXml.MAX_LON)),
                "lon -122.4194 kept as given");
        check("90.0".equals(CotXml.coordinate("90", CotXml.MAX_LAT))
                        && "-180.0".equals(CotXml.coordinate("-180", CotXml.MAX_LON)),
                "range bounds are inclusive");
        check(CotXml.coordinate("90.0001", CotXml.MAX_LAT) == null
                        && CotXml.coordinate("180.5", CotXml.MAX_LON) == null,
                "out-of-range refused");
        check(CotXml.coordinate("NaN", CotXml.MAX_LAT) == null
                        && CotXml.coordinate("Infinity", CotXml.MAX_LON) == null,
                "NaN/Infinity refused");
        check(CotXml.coordinate("north", CotXml.MAX_LAT) == null
                        && CotXml.coordinate("", CotXml.MAX_LAT) == null,
                "non-numbers refused");
        check("45.0".equals(CotXml.coordinate("45f", CotXml.MAX_LAT))
                        && "10.0".equals(CotXml.coordinate("1e1", CotXml.MAX_LAT))
                        && "32.0".equals(CotXml.coordinate("0x1p5", CotXml.MAX_LAT)),
                "Java-only number forms normalized to plain decimal");
        String tiny = CotXml.coordinate("1e-5", CotXml.MAX_LAT);
        check(tiny != null && tiny.indexOf('E') < 0
                        && Double.parseDouble(tiny) == 1e-5,
                "tiny values stay plain decimal, never 1.0E-5: " + tiny);
    }

    private static void printableOutput() throws Exception {
        // G1.14 #3: server-supplied text reaches the terminal only escaped.
        check("\\x1b[2J\\x1b]0;pwned\\x07".equals(CotXml.printable("\u001b[2J\u001b]0;pwned\u0007")),
                "printable escapes ESC/BEL (terminal escape injection)");
        check("a\\x7fb\\x9bc".equals(CotXml.printable("a\u007fb\u009bc")),
                "printable escapes DEL and C1 (8-bit CSI U+009B)");
        check("plain ASCII 123 <event/>".equals(CotXml.printable("plain ASCII 123 <event/>")),
                "printable leaves plain text untouched");
        check("caf\u00e9 \uD83D\uDE00 \u00a0".equals(CotXml.printable("caf\u00e9 \uD83D\uDE00 \u00a0")),
                "printable keeps non-control Unicode (accents, emoji, NBSP)");
        check(CotXml.printable(null) == null, "printable(null) is null");

        // A parsed callsign can carry a real newline (&#10;) or a C1 control
        // (legal in XML 1.0); toString must keep the track to one line.
        CotEvent e = CotEvent.parse("<event uid='u&#10;FAKE' type='t'>"
                + "<point lat='1' lon='2'/><detail><contact callsign='EVIL&#10;headless: track uid=forged&#x9b;31m'/>"
                + "</detail></event>");
        String line = e.toString();
        check(line.indexOf('\n') < 0 && line.indexOf('\u009b') < 0
                        && line.contains("callsign=EVIL\\x0aheadless: track uid=forged\\x9b31m")
                        && line.contains("uid=u\\x0aFAKE"),
                "CotEvent.toString escapes controls per field (no forged line): " + line);
    }

    private static void builders() throws Exception {
        String hostileUid = "u'1&<x>";
        String hostileCs = "O'BRIEN & \"CO\" <HQ>";

        String xml = CotXml.presence(hostileUid, hostileCs);
        CotEvent p = CotEvent.parse(xml);
        check(hostileUid.equals(p.uid), "presence uid round-trips through escaping");
        check(hostileCs.equals(p.callsign),
                "presence callsign round-trips through escaping");
        check("a-f-G-U-C".equals(p.type) && "m-g".equals(p.how),
                "presence is a self-SA (a-f-G-U-C, m-g)");
        check(p.time.matches(TIME_RE) && p.start.equals(p.time)
                        && p.stale.matches(TIME_RE) && p.stale.compareTo(p.time) > 0,
                "presence time/start/stale are CoT UTC times, stale after time");
        check(xml.contains("<__group name='Cyan' role='Team Member'/>"),
                "presence carries the __group OpenTAKServer needs to register");
        check("Undefined".equals(eventAttribute(xml, "access")),
                "presence carries access='Undefined' (MIL-STD-6090, 5.5 cotevent.proto): '"
                        + eventAttribute(xml, "access") + "'");

        String ctlCs = "TAB\tNL\nBEL\u0007";
        CotEvent c = CotEvent.parse(CotXml.presence("u-ctl", ctlCs));
        check("TAB\tNL\nBEL\uFFFD".equals(c.callsign),
                "presence with control characters in the callsign stays parseable: "
                        + c.callsign);

        String m = CotXml.marker(hostileUid, hostileCs,
                CotXml.coordinate("37.7749", CotXml.MAX_LAT),
                CotXml.coordinate("-122.4194", CotXml.MAX_LON));
        CotEvent mk = CotEvent.parse(m);
        check((hostileUid + "-m1").equals(mk.uid), "marker uid is <uid>-m1");
        check((hostileCs + "-M1").equals(mk.callsign), "marker callsign is <cs>-M1");
        check(mk.lat == 37.7749 && mk.lon == -122.4194,
                "marker point comes from the event, not precisionlocation");
        check(mk.stale.compareTo(mk.time) > 0, "marker stale after time");
        check("Undefined".equals(eventAttribute(m, "access")),
                "marker carries access='Undefined' (MIL-STD-6090, 5.5 cotevent.proto): '"
                        + eventAttribute(m, "access") + "'");
    }
}
