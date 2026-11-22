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
import com.atakmap.map.AtakMapView;
import armyc2.c5isr.renderer.MilStdIconRenderer;
import armyc2.c5isr.renderer.utilities.ImageInfo;
import armyc2.c5isr.renderer.utilities.MSLookup;
import armyc2.c5isr.renderer.utilities.MilStdAttributes;
import armyc2.c5isr.renderer.utilities.SymbolID;
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
 * <li>32 pixels times the display's relative scaling (both providers;
 * the 2525D one reads it through {@code GLRenderGlobals}, which returns
 * {@code DisplaySettings}'); for 2525C, unit ratio off and not drawn as an
 * icon;</li>
 * <li>civilian units filled purple unless hostile or suspect, as the 2525D
 * provider reads them (the affiliation digit against the exercise context,
 * then the basic code's civilian prefixes);</li>
 * <li>no modifiers (a marker passes no attributes).</li>
 * </ul>
 *
 * <p>Only point symbols render. 5.5 draws a 2525C multi-point graphic as an
 * icon too, but a CoT {@code a-*} type always maps to a unit, which is a
 * point; graphics wait for the drawing tools. Both paths are held to the
 * kernel by the symbol golden test (dev/g3/test/SymbolOracle.java), the
 * 2525D/E codes of symbol-golden/des.txt included.
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

    /** mil-sym's context digit for exercise, as the 2525D provider reads it. */
    private static final int CONTEXT_EXERCISE = 1;
    /** mil-sym's affiliation digit for Suspect (Joker in exercise), as {@code SymbolID.getAffiliation} returns it. */
    private static final int AFFILIATION_SUSPECT_JOKER = 5;
    /** mil-sym's affiliation digit for Hostile (Faker in exercise), as {@code SymbolID.getAffiliation} returns it. */
    private static final int AFFILIATION_HOSTILE_FAKER = 6;

    /** 2525C basic-code prefixes of civilian units (MIL-STD-2525C 5.3.2). */
    private static final String[] CIVILIAN_2525C = { "S*A*C", "S*S*X", "S*G*UULC", "S*G*EVC" };
    /** 2525D symbol set + entity prefixes of civilian units (MIL-STD-2525D 5.3.3). */
    private static final Set<String> CIVILIAN_2525D = Set.of("0112", "0512", "1111", "1516", "3014", "3512");

    // the 2525C renderer's attribute keys (mil-sym-renderer's SECRenderer);
    // the 2525D/E path uses MilStdAttributes
    private static final String SIZE = "SIZE", KEEP_UNIT_RATIO = "KEEPUNITRATIO", ICON = "ICON", FILL = "FILLCOLOR";

    /** The 2525D/E interop's label font ({@code MilStd2525dInterop} renders every icon under it). */
    private static final String LABEL_FONT = "serif";
    private static final int LABEL_FONT_TYPE = 0;

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
        attrs.put(MilStdAttributes.PixelSize, String.valueOf(iconSize()));
        if (civilian2525D(code)) attrs.put(MilStdAttributes.FillColor, PURPLE);
        // the interop's label font ({@code RenderContextWrapper.setLabelFontD}),
        // what 5.5's provider renders every icon under
        armyc2.c5isr.renderer.utilities.RendererSettings.getInstance()
                .setLabelFont(LABEL_FONT, LABEL_FONT_TYPE, AtakMapView.getDefaultTextFormat().getFontSize());
        final ImageInfo info = MilStdIconRenderer.getInstance().RenderIcon(full, new HashMap<>(), attrs);
        return info == null ? null : info.getSquareImageInfo().getImage();
    }

    /**
     * Whether the 2525D/E provider fills the code purple: hostile and
     * suspect stay red (MIL-STD-2525D 5.3.3) and the rest does when the
     * basic code is one of the six civilian prefixes (the provider's
     * {@code getBasicSymbolID(code).substring(0, 4)}). That is mil-sym-java's
     * {@code SymbolUtilities}, not the 2525C renderer's imported above: the
     * 2525C one reads a 2525D code as a 2525C one and never matches.
     */
    private static boolean civilian2525D(String code) {
        return !hostileOrSuspect2525D(code)
                && CIVILIAN_2525D.contains(
                        armyc2.c5isr.renderer.utilities.SymbolUtilities.getBasicSymbolID(code).substring(0, 4));
    }

    /**
     * The provider's Hostile and Suspect: mil-sym's affiliation digit
     * (5 suspect, 6 hostile), with simulated variants included and the
     * exercise context excluded — Joker and Faker, the provider's names
     * for the latter, fall to the civilian check.
     */
    private static boolean hostileOrSuspect2525D(String code) {
        if (SymbolID.getContext(code) == CONTEXT_EXERCISE) return false;
        final int affiliation = SymbolID.getAffiliation(code);
        return affiliation == AFFILIATION_SUSPECT_JOKER || affiliation == AFFILIATION_HOSTILE_FAKER;
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
