package mactak.g3;

import com.atakmap.coremap.cot.event.CotDetail;
import com.atakmap.coremap.cot.event.CotEvent;
import com.atakmap.coremap.cot.event.CotPoint;
import com.atakmap.coremap.maps.coords.GeoPoint;
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
 * <li>{@code point/*.properties}: a point placed with the Point Dropper (G3.9d),
 * as ATAK 5.5's CotEventFactory.createDefaultEvent and the app's detail
 * handlers write the marker PlacePointTool.MarkerCreator makes, with the
 * kernel's CotEvent, CotPoint, CotDetail and CoordinatedTime; then the
 * remarks and address the inspector gives it. 5.5 runs its handlers out of
 * a HashSet, in no set order; this follows the port's.</li>
 * <li>{@code route/*.properties}: a route (G3.10a), as ATAK 5.5's
 * EditablePolyline.toCot and Route.toCot write it, with the kernel's
 * CotEvent, CotDetail, CoordinatedTime and {@link CotPoint#decimate(GeoPoint)}
 * for each link's point; then the details the app's handlers write for a
 * route, written here in the port's order (they need a MapView).</li>
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
        for (File spec : fixtures(new File(root, "point"), ".properties")) {
            check(pointEvent(load(spec)).toString(), expected(root, "point", spec));
        }
        for (File spec : fixtures(new File(root, "route"), ".properties")) {
            check(routeEvent(load(spec)).toString(), expected(root, "route", spec));
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

    /** createDefaultEvent over the marker MarkerCreator.placePoint makes, then its edits. */
    static CotEvent pointEvent(Properties s) {
        CotEvent e = new CotEvent();
        e.setPoint(new CotPoint(number(s, "lat"), number(s, "lon"), number(s, "hae"),
                CotPoint.UNKNOWN, CotPoint.UNKNOWN));
        e.setType(s.getProperty("type"));
        e.setUID(s.getProperty("uid"));
        e.setHow("h-g-i-g-o"); // MarkerCreator's how
        e.setAccess("Undefined"); // AccessUtils.setAccessDefault: mapitem.access's default
        e.setVersion("2.0");
        CoordinatedTime time = new CoordinatedTime(Instant.parse(s.getProperty("time")).toEpochMilli());
        e.setTime(time);
        e.setStart(time);
        e.setStale(time.addSeconds(31536000));

        CotDetail detail = new CotDetail("detail");
        e.setDetail(detail);
        CotDetail status = new CotDetail("status");
        status.setAttribute("readiness", String.valueOf(true));
        detail.addChild(status);
        detail.addChild(new CotDetail("archive"));

        // ContactDetailHandler: the callsign meta
        CotDetail contact = new CotDetail("contact");
        contact.setAttribute("callsign", s.getProperty("callsign"));
        detail.addChild(contact);
        // PrecisionLocationHandler over the clicked point's metadata
        CotDetail precision = new CotDetail("precisionlocation");
        precision.setAttribute("altsrc", s.getProperty("altsrc"));
        detail.addChild(precision);
        // LinkDetailHandler and CreatorDetailHandler over setAuthorInformation's meta
        String productionTime = time.toString();
        CotDetail link = new CotDetail("link");
        link.setAttribute("uid", s.getProperty("author.uid"));
        link.setAttribute("type", s.getProperty("author.type"));
        link.setAttribute("relation", "p-p");
        link.setAttribute("production_time", productionTime);
        link.setAttribute("parent_callsign", s.getProperty("author.callsign"));
        detail.addChild(link);
        detail.addChild(new CotDetail("archive")); // ArchiveDetailHandler
        CotDetail creator = new CotDetail("creator");
        creator.setAttribute("uid", s.getProperty("author.uid"));
        creator.setAttribute("type", s.getProperty("author.type"));
        creator.setAttribute("callsign", s.getProperty("author.callsign"));
        creator.setAttribute("time", productionTime);
        detail.addChild(creator);
        // UserIconHandler, ColorDetailHandler (a Marker's colour is argb)
        CotDetail usericon = new CotDetail("usericon");
        usericon.setAttribute("iconsetpath", s.getProperty("iconsetpath"));
        detail.addChild(usericon);
        CotDetail color = new CotDetail("color");
        color.setAttribute("argb", String.valueOf(Integer.parseInt(s.getProperty("color"))));
        detail.addChild(color);

        // the inspector's edits: RemarksDetailHandler, AddressDetailHandler
        if (s.getProperty("remarks") != null) {
            CotDetail remarks = new CotDetail("remarks");
            remarks.setInnerText(s.getProperty("remarks").trim());
            detail.addChild(remarks);
        }
        if (s.getProperty("address.text") != null) {
            CotDetail address = new CotDetail("__address");
            address.setAttribute("text", s.getProperty("address.text"));
            address.setAttribute("geocoder", s.getProperty("address.geocoder", "unknown"));
            address.setAttribute("time", s.getProperty("address.time"));
            detail.addChild(address);
        }
        return e;
    }

    /** Route.toCot (EditablePolyline.toCot, then link_attr), then the handlers' details. */
    static CotEvent routeEvent(Properties s) {
        CotEvent e = new CotEvent(); // the point stays CotPoint.ZERO: toCot never sets it
        e.setType("b-m-r");
        CoordinatedTime time = new CoordinatedTime(Instant.parse(s.getProperty("time")).toEpochMilli());
        e.setTime(time);
        e.setStart(time);
        e.setStale(time.addDays(1));
        e.setUID(s.getProperty("uid"));
        e.setVersion("2.0");
        e.setHow("h-e");
        e.setAccess("Undefined"); // AccessUtils.setAccessDefault

        CotDetail detail = new CotDetail("detail");
        e.setDetail(detail);
        for (int i = 1; s.getProperty("point." + i + ".uid") != null; i++) {
            String p = "point." + i + ".";
            String hae = s.getProperty(p + "hae");
            GeoPoint gp = hae == null
                    ? new GeoPoint(Double.parseDouble(s.getProperty(p + "lat")), Double.parseDouble(s.getProperty(p + "lon")))
                    : new GeoPoint(Double.parseDouble(s.getProperty(p + "lat")), Double.parseDouble(s.getProperty(p + "lon")),
                            Double.parseDouble(hae));
            CotDetail link = new CotDetail("link");
            link.setAttribute("point", CotPoint.decimate(gp));
            link.setAttribute("type", s.getProperty(p + "type"));
            link.setAttribute("uid", s.getProperty(p + "uid"));
            link.setAttribute("relation", "c");
            link.setAttribute("callsign", s.getProperty(p + "callsign", ""));
            link.setAttribute("remarks", s.getProperty(p + "remarks", ""));
            detail.addChild(link);
        }
        CotDetail linkAttr = new CotDetail("link_attr");
        linkAttr.setAttribute("color", String.valueOf(Integer.parseInt(s.getProperty("color"))));
        linkAttr.setAttribute("stroke", String.valueOf((int) Double.parseDouble(s.getProperty("stroke"))));
        linkAttr.setAttribute("style", String.valueOf(Integer.parseInt(s.getProperty("style"))));
        linkAttr.setAttribute("type", s.getProperty("transport"));
        linkAttr.setAttribute("method", s.getProperty("method"));
        linkAttr.setAttribute("direction", s.getProperty("direction"));
        linkAttr.setAttribute("routetype", s.getProperty("routetype"));
        linkAttr.setAttribute("order", s.getProperty("order"));
        linkAttr.setAttribute("planningmethod", s.getProperty("planningmethod"));
        linkAttr.setAttribute("prefix", s.getProperty("prefix"));
        detail.addChild(linkAttr);

        // ContactDetailHandler: a shape's title
        CotDetail contact = new CotDetail("contact");
        contact.setAttribute("callsign", s.getProperty("title"));
        detail.addChild(contact);
        // PrecisionLocationHandler over Shape.getCenter (getElevationMetadata: altsrc only)
        CotDetail precision = new CotDetail("precisionlocation");
        precision.setAttribute("altsrc", s.getProperty("altsrc"));
        detail.addChild(precision);
        // RemarksDetailHandler
        if (s.getProperty("remarks") != null) {
            CotDetail remarks = new CotDetail("remarks");
            remarks.setInnerText(s.getProperty("remarks"));
            detail.addChild(remarks);
        }
        detail.addChild(new CotDetail("archive")); // ArchiveDetailHandler: Route sets archive
        // CreatorDetailHandler over setAuthorInformation's meta (RouteCreationDialog)
        CotDetail creator = new CotDetail("creator");
        creator.setAttribute("uid", s.getProperty("author.uid"));
        creator.setAttribute("type", s.getProperty("author.type"));
        creator.setAttribute("callsign", s.getProperty("author.callsign"));
        creator.setAttribute("time", time.toString());
        detail.addChild(creator);
        // ColorDetailHandler: a shape's colour is value
        CotDetail color = new CotDetail("color");
        color.setAttribute("value", String.valueOf(Integer.parseInt(s.getProperty("color"))));
        detail.addChild(color);
        // LabelDetailHandler: not a Marker, so labels_on, off
        CotDetail labels = new CotDetail("labels_on");
        labels.setAttribute("value", String.valueOf(false));
        detail.addChild(labels);
        // StrokeFillDetailHandler: a route is a Shape, never closed
        CotDetail strokeColor = new CotDetail("strokeColor");
        strokeColor.setAttribute("value", Integer.toString(Integer.parseInt(s.getProperty("color"))));
        detail.addChild(strokeColor);
        CotDetail strokeWeight = new CotDetail("strokeWeight");
        strokeWeight.setAttribute("value", Double.toString(Double.parseDouble(s.getProperty("stroke"))));
        detail.addChild(strokeWeight);
        CotDetail strokeStyle = new CotDetail("strokeStyle");
        strokeStyle.setAttribute("value", new String[] { "solid", "dashed", "dotted", "outlined" }[
                Integer.parseInt(s.getProperty("style"))]);
        detail.addChild(strokeStyle);
        // NavigationCueHandler (RouteDetailHandler): no cues
        CotDetail routeInfo = new CotDetail("__routeinfo");
        routeInfo.addChild(new CotDetail("__navcues"));
        detail.addChild(routeInfo);
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
