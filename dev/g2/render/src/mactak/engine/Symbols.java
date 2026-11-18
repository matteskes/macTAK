package mactak.engine;

import java.awt.image.BufferedImage;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import javax.imageio.ImageIO;

import ArmyC2.C2SD.Utilities.RendererSettings;
import ArmyC2.C2SD.Utilities.SymbolDef;
import ArmyC2.C2SD.Utilities.SymbolDefTable;
import ArmyC2.C2SD.Utilities.SymbolUtilities;
import ArmyC2.C2SD.Utilities.UnitDef;
import ArmyC2.C2SD.Utilities.UnitDefTable;
import armyc2.c5isr.renderer.MilStdIconRenderer;
import armyc2.c5isr.renderer.utilities.ImageInfo;
import armyc2.c5isr.renderer.utilities.MSLookup;
import gov.tak.api.commons.graphics.DisplaySettings;
import sec.web.renderer.SECRenderer;
import sec.web.renderer.utilities.PNGInfo;

/**
 * MIL-STD-2525 single-point symbols as PNG, for map markers (G3.7).
 *
 * <p>As ATAK 5.5 draws a marker's symbol ({@code SymbologyProvider
 * .renderSinglePointIcon(code, new AttributeSet(), null)}), with its
 * providers' choices:
 * <ul>
 * <li>a 15-character code is 2525C and goes to missioncommand's older
 * renderer ({@code mil-sym-renderer}; 5.5's {@code MilStd2525cSymbologyProviderBase});
 * anything else is 2525D/E and goes to {@code mil-sym-java}
 * ({@code MilStd2525dSymbologyProviderBase});</li>
 * <li>32 pixels times the display's relative scaling; for 2525C, unit ratio
 * off and not drawn as an icon;</li>
 * <li>civilian units filled purple unless hostile or suspect;</li>
 * <li>no modifiers (a marker passes no attributes).</li>
 * </ul>
 *
 * <p>Only point symbols render. 5.5 draws a 2525C multi-point graphic as an
 * icon too, but a CoT {@code a-*} type always maps to a unit, which is a
 * point; graphics wait for the drawing tools. The 2525C path is held to the
 * kernel by the symbol golden test (dev/g3/test/SymbolOracle.java); nothing
 * draws 2525D/E in G3.7.
 *
 * <p>Any thread. Both renderers keep global state, so calls are serialized.
 */
public final class Symbols {

    /** A 2525C symbol code's length; anything else is 2525D/E. */
    static final int LENGTH_2525C = 15;
    /** 2525D/E codes are padded to 30 digits ({@code MilStd2525dInterop}'s workaround). */
    static final int LENGTH_2525DE = 30;
    /** The icon size before scaling (the providers' default). */
    static final int ICON_SIZE = 32;
    /** The providers' {@code PURPLE_ICON_FILL}. */
    static final String PURPLE = "FFFFA1FF";

    /** 2525C basic-code prefixes of civilian units (MIL-STD-2525C 5.3.2). */
    private static final String[] CIVILIAN_2525C = { "S*A*C", "S*S*X", "S*G*UULC", "S*G*EVC" };
    /** 2525D symbol set + entity prefixes of civilian units (MIL-STD-2525D 5.3.3). */
    private static final Set<String> CIVILIAN_2525D = Set.of("0112", "0512", "1111", "1516", "3014", "3512");

    // mil-sym's attribute keys (MilStdAttributes in both libraries)
    private static final String SIZE = "SIZE", KEEP_UNIT_RATIO = "KEEPUNITRATIO", ICON = "ICON", FILL = "FILLCOLOR";

    private Symbols() { }

    /** The symbol as PNG bytes, or null when the code isn't a point symbol the renderer knows. */
    public static synchronized byte[] renderPng(String code) {
        final BufferedImage image = render(code);
        return image == null ? null : png(image);
    }

    /** Whether {@link #renderPng} draws {@code code}: 5.5's test when it maps a CoT type. */
    public static synchronized boolean canRender(String code) {
        return render(code) != null;
    }

    /** The symbol as an image, or null (the symbol golden test compares it with the kernel's). */
    public static synchronized BufferedImage render(String code) {
        if (code == null || code.isEmpty()) return null;
        try {
            return code.length() == LENGTH_2525C ? render2525C(code) : render2525DE(code);
        } catch (RuntimeException e) {
            return null;   // the renderers throw on codes they half-parse
        }
    }

    private static int iconSize() {
        return (int) Math.ceil(ICON_SIZE * DisplaySettings.getRelativeScaling());
    }

    private static BufferedImage render2525C(String code) {
        final String basic = SymbolUtilities.getBasicSymbolID(code);
        if (!isPoint2525C(basic)) return null;
        final Map<String, String> attrs = new HashMap<>();
        attrs.put(SIZE, String.valueOf(iconSize()));
        attrs.put(KEEP_UNIT_RATIO, "false");
        attrs.put(ICON, "false");
        if (!hostileOrSuspect2525C(code) && startsWithAny(basic, CIVILIAN_2525C)) attrs.put(FILL, PURPLE);
        final PNGInfo icon = SECRenderer.getInstance().getMilStdSymbolImage(code, attrs);
        return icon == null ? null : icon.getImage();
    }

    /**
     * Whether 5.5's 2525C provider takes the code and draws it as a point:
     * its symbol table ({@code MilStd2525cSymbolTable}) holds every graphic,
     * then every unit not already a graphic, by basic ID, less those with no
     * path or under "Basic Shapes" (the renderer's own tables would take
     * those, e.g. the root "S*\*P"); a unit is always a point.
     */
    private static boolean isPoint2525C(String basic) {
        final SymbolDef graphic = SymbolDefTable.getInstance().getSymbolDef(basic, RendererSettings.Symbology_2525C);
        if (graphic != null)
            return listed(graphic.getFullPath()) && graphic.getDrawCategory() == SymbolDef.DRAW_CATEGORY_POINT;
        final UnitDef unit = UnitDefTable.getInstance().getUnitDef(basic, RendererSettings.Symbology_2525C);
        return unit != null && listed(unit.getFullPath());
    }

    /** {@code MilStd2525cSymbolTableBase.push}: what it leaves out of the table. */
    private static boolean listed(String path) {
        return path != null && !path.isEmpty() && !path.equals("Basic Shapes");
    }

    /** The provider's Hostile and Suspect, from the affiliation letter (J and K are neither). */
    private static boolean hostileOrSuspect2525C(String code) {
        final String a = SymbolUtilities.getAffiliation(code);
        return a != null && (a.startsWith("H") || a.startsWith("S"));
    }

    private static boolean startsWithAny(String s, String[] prefixes) {
        for (String p : prefixes) {
            if (s.startsWith(p)) return true;
        }
        return false;
    }

    private static BufferedImage render2525DE(String code) {
        if (MSLookup.getInstance().getMSLInfo(code) == null) return null;
        final StringBuilder padded = new StringBuilder(code);
        while (padded.length() < LENGTH_2525DE) padded.append('0');
        final String full = padded.toString();
        final Map<String, String> attrs = new HashMap<>();
        attrs.put(SIZE, String.valueOf(iconSize()));
        if (!hostileOrSuspect2525D(full) && CIVILIAN_2525D.contains(full.substring(4, 8))) attrs.put(FILL, PURPLE);
        final ImageInfo info = MilStdIconRenderer.getInstance().RenderIcon(full, new HashMap<>(), attrs);
        return info == null ? null : info.getSquareImageInfo().getImage();
    }

    /** 2525D standard identity (the fourth digit): 5 suspect, 6 hostile. */
    private static boolean hostileOrSuspect2525D(String code) {
        final char identity = code.charAt(3);
        return identity == '5' || identity == '6';
    }

    private static byte[] png(BufferedImage image) {
        final ByteArrayOutputStream out = new ByteArrayOutputStream();
        try {
            return ImageIO.write(image, "png", out) ? out.toByteArray() : null;
        } catch (IOException e) {
            return null;
        }
    }
}
