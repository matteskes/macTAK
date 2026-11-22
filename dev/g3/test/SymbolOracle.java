package mactak.g3;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.TreeSet;

import java.awt.image.BufferedImage;

import ArmyC2.C2SD.Utilities.RendererSettings;
import ArmyC2.C2SD.Utilities.UnitDefTable;
import armyc2.c5isr.renderer.utilities.MSLookup;
import gov.tak.api.commons.graphics.Bitmap;
import gov.tak.api.cot.CotUtils;
import gov.tak.api.util.AttributeSet;
import gov.tak.platform.symbology.SymbologyProvider;
import gov.tak.platform.symbology.milstd2525.MilStd2525cSymbologyProvider;
import gov.tak.platform.symbology.milstd2525.MilStd2525dSymbologyProvider;
import gov.tak.platform.symbology.milstd2525.MilStd2525eSymbologyProvider;
import mactak.engine.Symbols;

/**
 * The kernel's leg of the symbol golden test (G3.7, make test-symbol-golden):
 * takkernel's own {@code CotUtils.mil2525cFromCotType}, with the 2525C, D and
 * E providers registered as ATAK 5.5's {@code ATAKUtilities} registers them,
 * maps every CoT type the Swift port ({@code CotSymbols}) is tested on.
 *
 * <p>The types: one per 2525C warfighting unit in the renderer's own table
 * (its code turned back into a CoT type by {@code cotTypeFromMil2525C}),
 * plus {@code symbol-golden/types.txt}, the edge cases.
 *
 * <p>Writes to {@code args[1]}:
 * <ul>
 * <li>{@code cot-to-2525c.tsv}: type, then the kernel's code;</li>
 * <li>{@code renderable.tsv}: every code the mapping can ask about for those
 * types (each type and each of its parents), upper case, then whether the
 * kernel's provider draws it. The Swift test answers its renderer's
 * questions from this file.</li>
 * </ul>
 * and fails (exit 1) if the app's renderer ({@code mactak.engine.Symbols})
 * answers any of those codes differently from the kernel, or draws one the
 * kernel draws with different pixels.
 *
 * <p>The providers run on the app's own Android runtime (G2's
 * {@code android.graphics}) and the test-only {@code Context} and
 * {@code Resources} in {@code oracle-android/}; see symbol-oracle.gradle.
 */
public final class SymbolOracle {

    private SymbolOracle() { }

    public static void main(String[] args) throws IOException {
        final Path golden = Path.of(args[0]);
        final Path out = Path.of(args[1]);

        SymbologyProvider.registerProvider(new MilStd2525cSymbologyProvider(), 0);
        SymbologyProvider.registerProvider(new MilStd2525dSymbologyProvider(), 0);
        SymbologyProvider.registerProvider(new MilStd2525eSymbologyProvider(), 0);

        final TreeSet<String> types = new TreeSet<>(unitTypes());
        for (String line : Files.readAllLines(golden.resolve("types.txt"), StandardCharsets.UTF_8)) {
            if (!line.isBlank() && !line.startsWith("#")) types.add(line.strip());
        }

        final StringBuilder mapped = new StringBuilder("# type\tkernel 2525C code (CotUtils.mil2525cFromCotType)\n");
        for (String type : types) {
            mapped.append(type).append('\t').append(CotUtils.mil2525cFromCotType(type)).append('\n');
        }

        final Map<String, Bitmap> drawn = new TreeMap<>();
        for (String type : types) {
            for (String t = type; t.indexOf('-') >= 0; t = t.substring(0, t.lastIndexOf('-'))) {
                final String code = candidate(t);
                if (code != null && !drawn.containsKey(code))
                    drawn.put(code, SymbologyProvider.renderSinglePointIcon(code, new AttributeSet(), null));
            }
        }
        final StringBuilder answers = new StringBuilder("# code\twhether the kernel's provider draws it\n");
        final List<String> disagree = new ArrayList<>();
        int compared = 0;
        for (Map.Entry<String, Bitmap> e : drawn.entrySet()) {
            final boolean kernel = e.getValue() != null;
            answers.append(e.getKey()).append('\t').append(kernel).append('\n');
            compared += judge(e.getKey(), e.getValue(), disagree);
        }

        // The D/E leg: the codes of symbol-golden/des.txt, rendered by the
        // kernel's 2525D and 2525E providers and held to Symbols.render
        // pixel for pixel. Nothing here feeds renderable.tsv: the kernel's
        // CoT mapping never produces a 2525D/E code, so the Swift port has
        // nothing to answer about them (trap #22).
        final List<String> desCodes = desCodes(golden);
        int compared2525DE = 0;
        for (String code : desCodes) {
            compared2525DE += judge(code, SymbologyProvider.renderSinglePointIcon(code, new AttributeSet(), null), disagree);
        }

        Files.createDirectories(out);
        Files.writeString(out.resolve("cot-to-2525c.tsv"), mapped, StandardCharsets.UTF_8);
        Files.writeString(out.resolve("renderable.tsv"), answers, StandardCharsets.UTF_8);
        System.out.println("[symbol-oracle] " + types.size() + " types, " + drawn.size() + " codes, "
                + compared + " drawn and compared pixel for pixel; "
                + desCodes.size() + " 2525D/E codes, " + compared2525DE + " compared");
        if (!disagree.isEmpty()) {
            System.out.println("[symbol-oracle] FAIL: mactak.engine.Symbols disagrees with the kernel on " + disagree.size() + " codes:");
            disagree.stream().limit(20).forEach(d -> System.out.println("  " + d));
            System.exit(1);
        }
    }

    /** Compares one code, kernel bitmap against Symbols, recording any disagreement; 1 when both drew it. */
    private static int judge(String code, Bitmap kernel, List<String> disagree) {
        final BufferedImage ours = Symbols.render(code);
        if ((ours != null) != (kernel != null)) {
            disagree.add(code + ": kernel " + (kernel != null ? "draws it" : "doesn't") + ", Symbols " + (ours != null ? "does" : "doesn't"));
            return 0;
        }
        if (kernel == null) return 0;
        final String diff = differ(kernel, ours);
        if (diff != null) disagree.add(code + ": " + diff);
        return 1;
    }

    /** The 2525D/E codes of des.txt, upper case; refuses one mil-sym doesn't know, so a typo can't pass as a vacuous fixture. */
    private static List<String> desCodes(Path golden) throws IOException {
        final List<String> codes = new ArrayList<>();
        for (String line : Files.readAllLines(golden.resolve("des.txt"), StandardCharsets.UTF_8)) {
            if (line.isBlank() || line.startsWith("#")) continue;
            final String code = line.strip().toUpperCase();
            if (MSLookup.getInstance().getMSLInfo(code) == null) {
                System.out.println("[symbol-oracle] FAIL: des.txt code mil-sym doesn't know: " + code);
                System.exit(1);
            }
            codes.add(code);
        }
        return codes;
    }

    /** null when the two images are the same size with the same ARGB pixels. */
    private static String differ(Bitmap kernel, BufferedImage ours) {
        final int w = kernel.getWidth(), h = kernel.getHeight();
        if (w != ours.getWidth() || h != ours.getHeight())
            return "size " + ours.getWidth() + "x" + ours.getHeight() + ", kernel " + w + "x" + h;
        final int[] k = new int[w * h];
        kernel.getPixels(k, 0, w, 0, 0, w, h);
        final int[] o = ours.getRGB(0, 0, w, h, null, 0, w);
        int n = 0;
        for (int i = 0; i < k.length; i++) {
            if (k[i] != o[i]) n++;
        }
        return n == 0 ? null : n + " of " + k.length + " pixels differ";
    }

    /** A friendly CoT type for every 2525C warfighting unit the renderer knows. */
    private static List<String> unitTypes() {
        final List<String> types = new ArrayList<>();
        for (String basic : UnitDefTable.getInstance().GetAllUnitDefs(RendererSettings.Symbology_2525C).keySet()) {
            if (basic.length() != 15 || basic.charAt(0) != 'S') continue;
            final String code = "SF" + basic.charAt(2) + "P" + basic.substring(4);
            types.add(CotUtils.cotTypeFromMil2525C(code));
        }
        return types;
    }

    /**
     * The code 5.5 builds for {@code type} before it asks the renderer (the
     * first half of {@code mil2525cFromCotType}), upper case; null where the
     * mapping asks nothing.
     */
    private static String candidate(String type) {
        if (!type.startsWith("a") || type.length() <= 2) return null;
        final StringBuilder sb = new StringBuilder(affiliation(type.charAt(2)));
        for (int x = 4; x < type.length(); x += 2) {
            sb.append(Character.toLowerCase(type.charAt(x)));
            if (x == 4) sb.append('p');
        }
        for (int x = sb.length(); x < 15; x++) {
            sb.append(x == 10 && sb.charAt(2) == 'g' && sb.charAt(4) == 'i' ? 'h' : '-');
        }
        return sb.toString().toUpperCase();
    }

    /** The code's first two letters (the kernel's source is Java 11: no switch expressions). */
    private static String affiliation(char c) {
        switch (c) {
            case 'f': case 'a': return "sf";
            case 'n': return "sn";
            case 's': case 'j': case 'k': case 'h': return "sh";
            default: return "su";
        }
    }
}
