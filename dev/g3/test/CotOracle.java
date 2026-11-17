package mactak.g3;

import com.atakmap.coremap.cot.event.CotDetail;
import com.atakmap.coremap.cot.event.CotEvent;
import com.atakmap.coremap.cot.event.CotPoint;
import com.atakmap.coremap.maps.time.CoordinatedTime;

import gov.tak.api.cot.detail.GroupDetailHandler;
import gov.tak.api.cot.event.CotAttribute;
import gov.tak.api.util.AttributeSet;

import org.w3c.dom.Element;
import org.w3c.dom.NamedNodeMap;
import org.w3c.dom.Node;
import org.w3c.dom.NodeList;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.Properties;

import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;

/**
 * The kernel's leg of the CoT golden test (G3.4; dev/g3/NOTES.md, decision 2):
 * the kernel's own CotEvent writes each fixture, and what it writes must equal
 * the expected file the Swift port is held to (app/Tests/MacTAKCotTests).
 *
 * <ul>
 * <li>{@code parse/*.xml}: {@link CotEvent#parse} then {@link CotEvent#toString}.</li>
 * <li>{@code self/*.properties}: the self-SA built as ATAK 5.5's
 * CotMapComponent.getSelfEvent builds it, with the kernel's CotEvent, CotPoint
 * and CotDetail, and {@link GroupDetailHandler#toCotDetail(AttributeSet)} for
 * {@code __group}. precisionlocation and how follow the app's
 * PrecisionLocationHandler and getSelfEvent, which are not in the kernel.</li>
 * </ul>
 *
 * <p>Both legs compare in one canonical form (canonical() here,
 * Golden.canonical in Swift): elements in order, attributes sorted, point
 * numbers to 7 decimals, trimmed text with empty the same as none.</p>
 *
 * <p>usage: CotOracle &lt;cot-golden dir&gt; (dev/g3/test/cot-golden.sh)</p>
 */
public final class CotOracle {

    private static int failures = 0;
    private static int checks = 0;

    private CotOracle() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 1)
            throw new IllegalArgumentException("usage: CotOracle <cot-golden dir>");
        File root = new File(args[0]);
        for (File in : fixtures(new File(root, "parse"), ".xml")) {
            String xml = new String(Files.readAllBytes(in.toPath()), StandardCharsets.UTF_8);
            check(CotEvent.parse(xml).toString(), expected(root, "parse", in));
        }
        for (File spec : fixtures(new File(root, "self"), ".properties")) {
            check(selfEvent(load(spec)).toString(), expected(root, "self", spec));
        }
        if (checks == 0)
            fail("no fixtures under " + root);
        System.out.println(failures == 0
                ? "[cot-golden] PASS: " + checks + " fixtures, the kernel writes what the Swift port writes"
                : "[cot-golden] FAIL: " + failures + " of " + checks);
        System.exit(failures == 0 ? 0 : 1);
    }

    private static List<File> fixtures(File dir, String ext) {
        File[] files = dir.listFiles((d, name) -> name.endsWith(ext));
        List<File> list = new ArrayList<>(files == null ? List.of() : Arrays.asList(files));
        list.sort(null);
        return list;
    }

    private static File expected(File root, String kind, File input) {
        String name = input.getName();
        return new File(root, "expected/" + kind + "-" + name.substring(0, name.lastIndexOf('.')) + ".xml");
    }

    private static void check(String kernelXml, File expectedFile) throws Exception {
        checks++;
        String want = canonical(new String(Files.readAllBytes(expectedFile.toPath()), StandardCharsets.UTF_8));
        String got = canonical(kernelXml);
        if (want.equals(got)) {
            System.out.println("PASS: " + expectedFile.getName());
        } else {
            fail(expectedFile.getName() + "\n--- kernel\n" + got + "--- expected\n" + want
                    + "--- kernel XML\n" + kernelXml);
        }
    }

    private static void fail(String what) {
        failures++;
        System.out.println("FAIL: " + what);
    }

    private static Properties load(File spec) throws Exception {
        Properties p = new Properties();
        try (InputStream in = new FileInputStream(spec)) {
            p.load(new InputStreamReader(in, StandardCharsets.UTF_8));
        }
        return p;
    }

    /** getSelfEvent, from a spec instead of the map and the preferences. */
    static CotEvent selfEvent(Properties s) {
        CotEvent e = new CotEvent();
        e.setVersion("2.0");
        e.setUID(s.getProperty("uid"));
        e.setType(s.getProperty("type", "a-f-G-U-C"));
        CoordinatedTime time = new CoordinatedTime(Instant.parse(s.getProperty("time")).toEpochMilli());
        e.setTime(time);
        e.setStart(time);
        e.setStale(time.addMilliseconds((int) (Double.parseDouble(s.getProperty("staleSeconds")) * 1000)));

        String source = s.getProperty("source");
        if (source == null) {
            e.setPoint(CotPoint.ZERO);
            e.setHow("h-g-i-g-o");
        } else {
            e.setPoint(new CotPoint(number(s, "lat"), number(s, "lon"), number(s, "hae"),
                    number(s, "ce"), number(s, "le")));
            e.setHow(source.equals("manual") ? "h-e" : "m-g");
        }

        CotDetail detail = new CotDetail("detail");
        e.setDetail(detail);
        CotDetail takv = new CotDetail("takv");
        for (String k : new String[] { "device", "platform", "os", "version" })
            takv.setAttribute(k, s.getProperty("takv." + k));
        detail.addChild(takv);
        CotDetail contact = new CotDetail("contact");
        detail.addChild(contact);
        String remarks = s.getProperty("remarks", "").trim();
        if (!remarks.isEmpty()) {
            CotDetail r = new CotDetail("remarks");
            r.setInnerText(remarks);
            detail.addChild(r);
        }
        contact.setAttribute("callsign", s.getProperty("callsign"));
        CotDetail uid = new CotDetail("uid");
        uid.setAttribute("Droid", s.getProperty("callsign"));
        detail.addChild(uid);
        if (source != null) {
            // PrecisionLocationHandler.toPrecisionLocation over the self point's metadata
            CotDetail precision = new CotDetail("precisionlocation");
            boolean manual = source.equals("manual");
            precision.setAttribute("geopointsrc", manual ? "USER" : "GPS");
            boolean altitudeKnown = s.getProperty("hae") != null;
            precision.setAttribute("altsrc", manual ? (altitudeKnown ? "USER" : "???") : "GPS");
            detail.addChild(precision);
        }
        contact.setAttribute("endpoint", s.getProperty("endpoint"));

        AttributeSet group = new AttributeSet();
        if (s.getProperty("team") != null)
            group.setAttribute("team", s.getProperty("team"));
        group.setAttribute("atakRoleType", s.getProperty("role", "Team Member"));
        if (s.getProperty("customRole") != null)
            group.setAttribute("customRole", s.getProperty("customRole"));
        if (s.getProperty("customRoleAbbreviation") != null)
            group.setAttribute("customRoleAbbreviation", s.getProperty("customRoleAbbreviation"));
        if (Boolean.parseBoolean(s.getProperty("typeIcon", "false")))
            group.setAttribute("displayAsSymbologyGraphic", true);
        detail.addChild(fromApi(GroupDetailHandler.toCotDetail(group)));

        CotDetail status = new CotDetail("status");
        status.setAttribute("battery", s.getProperty("battery", "100"));
        detail.addChild(status);
        CotDetail track = new CotDetail("track");
        track.setAttribute("speed", Double.toString(number(s, "speed")));
        track.setAttribute("course", Double.toString(number(s, "course")));
        detail.addChild(track);
        return e;
    }

    private static double number(Properties s, String key) {
        String v = s.getProperty(key);
        return v == null ? CotPoint.UNKNOWN : Double.parseDouble(v);
    }

    /** What MarshalManager does for getSelfEvent: the API detail as a wire detail. */
    private static CotDetail fromApi(gov.tak.api.cot.event.CotDetail api) {
        CotDetail d = new CotDetail(api.getElementName());
        for (CotAttribute a : api.getAttributes())
            d.setAttribute(a.getName(), a.getValue());
        if (api.getInnerText() != null)
            d.setInnerText(api.getInnerText());
        for (gov.tak.api.cot.event.CotDetail c : api.getChildren())
            d.addChild(fromApi(c));
        return d;
    }

    static String canonical(String xml) throws Exception {
        DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
        f.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
        DocumentBuilder b = f.newDocumentBuilder();
        Element root = b.parse(new ByteArrayInputStream(xml.getBytes(StandardCharsets.UTF_8))).getDocumentElement();
        StringBuilder out = new StringBuilder();
        write(root, out, 0);
        return out.toString();
    }

    private static void write(Element e, StringBuilder out, int depth) {
        String name = e.getTagName();
        out.append("  ".repeat(depth)).append('<').append(name);
        NamedNodeMap attrs = e.getAttributes();
        List<String[]> pairs = new ArrayList<>();
        for (int i = 0; i < attrs.getLength(); i++)
            pairs.add(new String[] { attrs.item(i).getNodeName(), attrs.item(i).getNodeValue() });
        pairs.sort((a, c) -> a[0].compareTo(c[0]));
        for (String[] p : pairs) {
            String value = p[1];
            if (name.equals("point")) {
                try {
                    value = String.format(Locale.ROOT, "%.7f", Double.parseDouble(value));
                } catch (NumberFormatException ignored) {
                    // compared as text
                }
            }
            out.append(' ').append(p[0]).append('=').append(quote(value));
        }
        out.append(">\n");
        List<Element> children = new ArrayList<>();
        NodeList nodes = e.getChildNodes();
        for (int i = 0; i < nodes.getLength(); i++)
            if (nodes.item(i).getNodeType() == Node.ELEMENT_NODE)
                children.add((Element) nodes.item(i));
        if (children.isEmpty()) {
            String text = e.getTextContent().trim();
            if (!text.isEmpty())
                out.append("  ".repeat(depth + 1)).append(quote(text)).append('\n');
        }
        for (Element c : children)
            write(c, out, depth + 1);
    }

    /** Swift's String.debugDescription, for what the fixtures hold. */
    private static String quote(String s) {
        StringBuilder q = new StringBuilder("\"");
        for (char ch : s.toCharArray()) {
            switch (ch) {
                case '"': q.append("\\\""); break;
                case '\\': q.append("\\\\"); break;
                case '\n': q.append("\\n"); break;
                case '\t': q.append("\\t"); break;
                case '\r': q.append("\\r"); break;
                default: q.append(ch);
            }
        }
        return q.append('"').toString();
    }
}
