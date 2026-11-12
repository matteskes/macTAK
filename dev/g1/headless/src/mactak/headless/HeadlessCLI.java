package mactak.headless;

import com.atakmap.commoncommo.Commo;
import com.atakmap.commoncommo.CommoException;
import com.atakmap.commoncommo.CommoLogger;
import com.atakmap.commoncommo.CoTMessageType;
import com.atakmap.commoncommo.Contact;
import com.atakmap.commoncommo.ContactPresenceListener;
import com.atakmap.commoncommo.NetInterface;
import com.atakmap.commoncommo.InterfaceStatusListener;
import com.atakmap.commoncommo.StreamingTransport;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * atak-headless entry point: one JVM, both stacks. {@link #main} loads the
 * engine ({@code libtakengine} + JNI glue) and comms ({@code libcommoncommo}
 * + JNI glue) dylibs from {@code -Dmactak.native.dist} into this process,
 * then dispatches: {@code --layer} → {@link LayerCLI} (G1.3), anything else
 * → the CoT endpoint below.
 *
 * G1.2 — headless CoT endpoint on the commoncommo JNI stack.
 *
 * Connects to a TAK server's CoT port as a streaming (TCP client)
 * interface — plaintext (e.g. FreeTAKServer tcp/8087, OpenTAKServer 8088)
 * or, with {@code --cert} + {@code --ca} (PKCS#12, the two files in an ATAK
 * data package; passwords from {@code MACTAK_CERT_PASS} /
 * {@code MACTAK_CA_PASS}), SSL with a client certificate (OpenTAKServer
 * 8089). Announces presence on a
 * short heartbeat once the interface comes up (the server only registers a
 * client after its first message — and commo only makes the interface
 * sendable after the interfaceUp listeners return, so sends never happen
 * inside the callback; see the sender thread in main), prints every
 * received CoT verbatim, and exits 0 after --duration seconds.
 *
 * G1.4 — every received CoT that parses as an {@code <event>} with a
 * {@code <point>} is persisted through the engine's {@code DatabaseImpl}
 * JNI into a sqlite tracks DB ({@code --db PATH}; a private temporary DB
 * when omitted), and the newest fix per uid is printed on exit — the
 * roadmap's "plots them in-memory" demo. Everything the smoke script
 * asserts on is printed as a single machine-greppable "headless:" line:
 *
 *   headless: iface-up | iface-down
 *   headless: contact-added &lt;uid&gt;
 *   headless: cot-received &lt;raw xml, one line&gt;
 *   headless: cot-unparsed &lt;reason&gt;
 *   headless: presence-sent | presence-heartbeat n=N
 *   headless: marker-sent lat=&lt;lat&gt; lon=&lt;lon&gt;
 *   headless: summary received=N persisted=N ifaceUpSeen=&lt;b&gt; presenceSent=N markerSent=N
 *   headless: track uid=&lt;uid&gt; type=&lt;t&gt; callsign=&lt;cs&gt; lat=&lt;lat&gt; lon=&lt;lon&gt; time=&lt;t&gt; fixes=N
 *   headless: tracks uids=N fixes=N db=&lt;path|temporary&gt;
 *
 * Exit codes: 0 completed the run, 2 usage, 3 stack/connect failure,
 * 4 dead run: no CoT received or interface never came up.
 */
public final class HeadlessCLI {

    /** Desktop load order: core before its JNI glue, per stack (EngineLibrary's list). */
    private static final String[] NATIVE_LIBS = {
        "libtakengine.dylib", "libtakenginejni.dylib",
        "libcommoncommo.dylib", "libcommoncommojni.dylib",
    };

    public static class Log implements CommoLogger {
        public void log(CommoLogger.Level l, CommoLogger.Type t,
                        String m, CommoLogger.LoggingDetail d) {
            if (l == CommoLogger.Level.VERBOSE || l == CommoLogger.Level.DEBUG)
                return;
            System.err.println("commo[" + l + "] " + m);
        }
    }

    /**
     * G1.5: resolve an ATAK data package (DataPackage.java), extracting its
     * PKCS#12 pair to a private temp dir. Failure prints the reason, exits 2.
     *
     * The dir and the extracted PKCS#12s never outlive this process:
     * deleteOnExit covers every exit path (System.exit here and in main,
     * SIGINT/SIGTERM) — the dir is registered first so its files, registered
     * after, delete first (deleteOnExit is LIFO) — and a failed open() wipes
     * the dir at once, so a mid-extraction failure leaves nothing either.
     * kill -9 is the one exception, as with any temp cleanup.
     */
    private static DataPackage.Resolved resolveDataPackage(String dpPath) {
        final File certDir;
        try {
            certDir = Files.createTempDirectory("mactak-dp-certs.").toFile();
        } catch (IOException e) {
            System.err.println("atak-headless: cannot use data package '"
                    + dpPath + "': cannot create temp cert dir: " + e.getMessage());
            System.exit(2);
            return null;    // not reached
        }
        certDir.deleteOnExit();
        final DataPackage.Resolved dpResolved;
        try {
            dpResolved = DataPackage.open(new File(dpPath), certDir);
        } catch (IOException e) {
            deleteTree(certDir);    // open() may have died mid-extraction
            System.err.println("atak-headless: cannot use data package '"
                    + dpPath + "': " + e.getMessage());
            System.exit(2);
            return null;    // not reached
        }
        if (dpResolved.certPath != null)
            new File(dpResolved.certPath).deleteOnExit();
        if (dpResolved.caPath != null)
            new File(dpResolved.caPath).deleteOnExit();
        System.out.println("headless: datapackage resolved " + dpResolved);
        return dpResolved;
    }

    /**
     * Best-effort recursive delete for the cert temp dir (it holds only the
     * flat PKCS#12 files DataPackage wrote — no subdirs, no links); like any
     * temp cleanup it must never mask the real error by throwing.
     */
    private static void deleteTree(File dir) {
        File[] kids = dir.listFiles();
        if (kids != null)
            for (File kid : kids)
                deleteTree(kid);
        dir.delete();
    }

    private static void usage(int code) {
        System.err.println(
                "usage: atak-headless --connect host:port [--uid UID] [--callsign CS]\n" +
                "                     [--duration SECONDS] [--send-marker LAT LON] [--db PATH]\n" +
                "                     [--cert CLIENT.p12 --ca TRUSTSTORE.p12]   (SSL; passwords via\n" +
                "                      MACTAK_CERT_PASS / MACTAK_CA_PASS, default 'atakatak')\n" +
                "       atak-headless --datapackage FILE   (an ATAK data package: host:port\n" +
                "                      from preference.pref's cot_streams, callsign, and the\n" +
                "                      PKCS#12 pair extracted to a temp dir; --connect /\n" +
                "                      --callsign / --cert + --ca override what it resolved,\n" +
                "                      MACTAK_CERT_PASS overrides the package's cert password)\n" +
                "       atak-headless --layer FILE [--layer FILE ...] [--layer-db DIR]\n" +
                "                     [--expect-features N] [--quiet]");
        System.exit(code);
    }

    public static void main(String[] args) {
        final String dist = System.getProperty("mactak.native.dist");
        if (dist == null) {
            System.err.println("mactak.native.dist not set — run via the atak-headless launcher");
            System.exit(3);
        }
        try {
            for (String lib : NATIVE_LIBS) System.load(dist + "/" + lib);
        } catch (UnsatisfiedLinkError e) {
            System.err.println("atak-headless: native load failed: " + e.getMessage());
            System.exit(3);
        }

        if (args.length > 0 && "--layer".equals(args[0])) {
            System.exit(LayerCLI.run(args));
            return;
        }

        String host = null, uid = "g1-headless-" + (System.nanoTime() % 1000000L),
               callsign = null, markerLat = null, markerLon = null, dbPath = null,
               certPath = null, caPath = null, dpPath = null;
        int port = -1, duration = 15;

        for (int i = 0; i < args.length; i++) {
            String a = args[i];
            switch (a) {
                case "--connect":
                    if (i + 1 >= args.length) usage(2);
                    String[] hp = args[++i].split(":");
                    if (hp.length != 2) usage(2);
                    host = hp[0];
                    try { port = Integer.parseInt(hp[1]); }
                    catch (NumberFormatException e) { usage(2); }
                    // (#32) The same 1-65535 range the package path checks —
                    // an out-of-range port dies at usage, not in an obscure
                    // commo failure at connect.
                    if (port < 1 || port > 65535) usage(2);
                    break;
                case "--uid":       if (i + 1 >= args.length) usage(2);
                                    uid = args[++i]; break;
                case "--callsign":  if (i + 1 >= args.length) usage(2);
                                    callsign = args[++i]; break;
                case "--duration":  if (i + 1 >= args.length) usage(2);
                                    try { duration = Integer.parseInt(args[++i]); }
                                    catch (NumberFormatException e) { usage(2); }
                                    // A zero/negative run ends before iface-up and
                                    // always exits 4 — reject it at usage instead.
                                    if (duration < 1) usage(2);
                                    break;
                case "--send-marker":
                    if (i + 2 >= args.length) usage(2);
                    // The pair is spliced into the marker CoT: only a finite,
                    // in-range number, in plain decimal form, may reach the XML.
                    markerLat = CotXml.coordinate(args[++i], CotXml.MAX_LAT);
                    markerLon = CotXml.coordinate(args[++i], CotXml.MAX_LON);
                    if (markerLat == null || markerLon == null) usage(2);
                    break;
                case "--db":        if (i + 1 >= args.length) usage(2);
                                    dbPath = args[++i]; break;
                case "--cert":      if (i + 1 >= args.length) usage(2);
                                    certPath = args[++i]; break;
                case "--ca":        if (i + 1 >= args.length) usage(2);
                                    caPath = args[++i]; break;
                case "--datapackage":
                                    if (i + 1 >= args.length) usage(2);
                                    dpPath = args[++i]; break;
                default: usage(2);
            }
        }
        if (host == null && dpPath == null) usage(2);
        if ((certPath == null) != (caPath == null)) usage(2);   // SSL needs both
        // G1.5 precedence — explicit flags > data package > defaults, and
        // MACTAK_CERT_PASS > the package's firecrypt Password > 'atakatak' —
        // is one pure-data merge (ConnectOptions), asserted by the canary.
        final DataPackage.Resolved dp =
                dpPath == null ? null : resolveDataPackage(dpPath);
        final ConnectOptions.Resolved opt;
        try {
            opt = ConnectOptions.resolve(host, port, callsign, certPath, caPath,
                    env("MACTAK_CERT_PASS", null), env("MACTAK_CA_PASS", null), dp);
        } catch (IllegalArgumentException e) {
            System.err.println("atak-headless: cannot use data package '"
                    + dpPath + "': " + e.getMessage());
            System.exit(2);
            return;    // not reached
        }
        host = opt.host;
        port = opt.port;
        callsign = opt.callsign;
        certPath = opt.certPath;
        caPath = opt.caPath;
        final String certPass = opt.certPass;
        final String caPass = opt.caPass;

        final AtomicInteger received = new AtomicInteger();
        final AtomicInteger persisted = new AtomicInteger();
        final AtomicInteger presenceSent = new AtomicInteger();
        final AtomicInteger markerSent = new AtomicInteger();
        final AtomicBoolean ifaceUpSeen = new AtomicBoolean(false);
        final AtomicBoolean done = new AtomicBoolean(false);

        // System.exit never returns, so it is called once, after the finally
        // has closed the tracks DB: from inside the try or a catch it would
        // skip that close on every failure path.
        int rc;
        TrackStore tracks = null;
        try {
            // Engine side first: the tracks DB goes through DatabaseImpl's JNI
            // (Java -> glue -> C++ Database2 -> sqlite), same path as the G1.1 smoke.
            tracks = new TrackStore(dbPath);
            final TrackStore fTracks = tracks;
            System.out.println("headless: tracks-db " + (dbPath == null ? "temporary" : dbPath));

            Commo.initThirdpartyNativeLibraries();

            final Commo commo = new Commo(new Log(), uid, callsign);
            final String fUid = uid, fCs = callsign,
                         fLat = markerLat, fLon = markerLon;

            Runtime.getRuntime().addShutdownHook(new Thread() {
                public void run() {
                    if (done.compareAndSet(false, true))
                        commo.shutdown();
                }
            });

            commo.addInterfaceStatusListener(new InterfaceStatusListener() {
                public void interfaceUp(NetInterface iface) {
                    if (!ifaceUpSeen.compareAndSet(false, true)) return;
                    System.out.println("headless: iface-up");
                    // Do NOT broadcast here. commo fires interfaceUp
                    // listeners BEFORE inserting the context into its
                    // sendable up-contexts list (streamingsocketmanagement
                    // fires the change, then inserts), so a send from this
                    // callback reaches zero interfaces — broadcastCoT
                    // reports success while queueing nothing. The sender
                    // thread below announces on a short delay instead.
                }
                public void interfaceDown(NetInterface iface) {
                    System.out.println("headless: iface-down");
                }
                public void interfaceError(NetInterface iface,
                        com.atakmap.commoncommo.NetInterfaceErrorCode code) {
                    System.out.println("headless: iface-error " + code);
                }
            });

            commo.addContactPresenceListener(new ContactPresenceListener() {
                public void contactAdded(Contact c) {
                    System.out.println("headless: contact-added " + CotXml.printable(c.contactUID));
                }
                public void contactRemoved(Contact c) {
                    System.out.println("headless: contact-removed " + CotXml.printable(c.contactUID));
                }
            });

            commo.addCoTMessageListener(
                    new com.atakmap.commoncommo.CoTMessageListener() {
                public void cotMessageReceived(String cotMessage, String rxEndpointId) {
                    received.incrementAndGet();
                    // Server-supplied bytes: whitespace collapsed to keep one line per
                    // message, then every other control made visible (G1.14 #3).
                    System.out.println("headless: cot-received " + (cotMessage == null
                            ? "" : CotXml.printable(cotMessage.replaceAll("\\s+", " ").trim())));
                    if (cotMessage == null || done.get()) return;
                    try {
                        final CotEvent e = CotEvent.parse(cotMessage);
                        // TAK server pings (t-x-c-t, "<uid>-ping") are not tracks; ATAK drops them too.
                        if (e.type.startsWith("t-x-c-t")) return;
                        fTracks.record(e, System.currentTimeMillis());
                        persisted.incrementAndGet();
                    } catch (Exception e) {
                        System.out.println("headless: cot-unparsed " + CotXml.printable(e.getMessage()));
                    }
                }
            });

            System.out.println("headless: connecting " + host + ":" + port
                    + (certPath == null ? "" : " ssl cert=" + new File(certPath).getName())
                    + " uid=" + uid + " callsign=" + callsign);
            // A client cert switches commo's streaming interface to SSL. Data-package
            // PKCS#12 is RC2-40: OpenSSL 3 needs its legacy provider (NativeSsl shim).
            final byte[] clientCert = certPath == null ? null : readFile(certPath);
            final byte[] caCert = caPath == null ? null : readFile(caPath);
            if (clientCert != null && !NativeSsl.loadLegacyProvider())
                System.err.println("headless: OpenSSL legacy provider unavailable; RC2-40 PKCS#12 will fail");
            // The transport, as 5.5's deprecated overload picked it: SSL when a
            // client cert is given, else TCP (QUIC is commo's third option).
            final StreamingTransport transport =
                    clientCert == null ? StreamingTransport.TCP : StreamingTransport.SSL;
            commo.addStreamingInterface(transport, host, port,
                    new CoTMessageType[] { CoTMessageType.SITUATIONAL_AWARENESS },
                    clientCert, caCert,
                    clientCert == null ? null : certPass,
                    caCert == null ? null : caPass,
                    null, null);

            long deadline = System.currentTimeMillis() + duration * 1000L;

            // Announcements run off the interfaceUp callback: the first
            // presence goes out sendDelayMs after iface-up (comfortably
            // after commo makes the interface sendable), then on a steady
            // heartbeat — mirroring ATAK's periodic SA — until the run
            // ends. The marker, if requested, goes out once, on the first
            // send window.
            final long sendDelayMs = 500L, sendPeriodMs = 2000L;
            Thread sender = new Thread() {
                public void run() {
                    boolean markerDone = (fLat == null);
                    boolean firstPresence = true;
                    while (!done.get()
                            && System.currentTimeMillis() < deadline) {
                        if (!ifaceUpSeen.get()) {
                            try { Thread.sleep(100); }
                            catch (InterruptedException e) { return; }
                            continue;
                        }
                        try { Thread.sleep(firstPresence ? sendDelayMs
                                                         : sendPeriodMs); }
                        catch (InterruptedException e) { return; }
                        if (done.get()) return;
                        try {
                            commo.broadcastCoT(CotXml.presence(fUid, fCs));
                            int n = presenceSent.incrementAndGet();
                            System.out.println(firstPresence
                                    ? "headless: presence-sent"
                                    : "headless: presence-heartbeat n=" + n);
                            firstPresence = false;
                        } catch (CommoException e) {
                            System.err.println("commo[ERROR] presence send failed: " + e);
                        }
                        if (!markerDone) {
                            try {
                                commo.broadcastCoT(
                                        CotXml.marker(fUid, fCs, fLat, fLon));
                                markerSent.incrementAndGet();
                                System.out.println("headless: marker-sent lat="
                                        + fLat + " lon=" + fLon);
                            } catch (CommoException e) {
                                System.err.println("commo[ERROR] marker send failed: " + e);
                            }
                            markerDone = true;
                        }
                    }
                }
            };
            sender.setDaemon(true);
            sender.start();
            while (sender.isAlive()) {
                try { sender.join(250); } catch (InterruptedException e) { break; }
            }

            if (done.compareAndSet(false, true))
                commo.shutdown();

            System.out.println("headless: summary received=" + received.get()
                    + " persisted=" + persisted.get()
                    + " ifaceUpSeen=" + ifaceUpSeen.get()
                    + " presenceSent=" + presenceSent.get()
                    + " markerSent=" + markerSent.get());
            // The exit demo: what the tracks DB holds, latest fix per uid.
            System.out.print(tracks.summary(dbPath == null ? "temporary" : dbPath));
            rc = received.get() > 0 && ifaceUpSeen.get() ? 0 : 4;
        } catch (CommoException e) {
            System.err.println("commo[ERROR] stack failure: " + e);
            rc = 3;
        } catch (Throwable t) {
            System.err.println("commo[ERROR] fatal: " + t);
            rc = 3;
        } finally {
            if (tracks != null) tracks.close();
        }
        System.exit(rc);
    }

    private static byte[] readFile(String path) throws IOException {
        return Files.readAllBytes(new File(path).toPath());
    }

    private static String env(String name, String dflt) {
        final String v = System.getenv(name);
        return (v == null || v.isEmpty()) ? dflt : v;
    }

    private HeadlessCLI() {}
}

