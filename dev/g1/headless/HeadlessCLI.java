import com.atakmap.commoncommo.Commo;
import com.atakmap.commoncommo.CommoException;
import com.atakmap.commoncommo.CommoLogger;
import com.atakmap.commoncommo.CoTMessageType;
import com.atakmap.commoncommo.Contact;
import com.atakmap.commoncommo.ContactPresenceListener;
import com.atakmap.commoncommo.NetInterface;
import com.atakmap.commoncommo.InterfaceStatusListener;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * G1.2 — headless CoT endpoint on the commoncommo JNI stack.
 *
 * Connects to a TAK server's plaintext CoT port (e.g. FreeTAKServer
 * tcp/8087) as a streaming (TCP client) interface, announces presence on a
 * short heartbeat once the interface comes up (the server only registers a
 * client after its first message — and commo only makes the interface
 * sendable after the interfaceUp listeners return, so sends never happen
 * inside the callback; see the sender thread in main), prints every
 * received CoT verbatim, and exits 0 after --duration seconds. Everything
 * the smoke script asserts on is printed as a single machine-greppable
 * "headless:" line:
 *
 *   headless: iface-up | iface-down
 *   headless: contact-added <uid>
 *   headless: cot-received <raw xml, one line>
 *   headless: presence-sent | presence-heartbeat n=N
 *   headless: marker-sent lat=<lat> lon=<lon>
 *   headless: summary received=N ifaceUpSeen=<b> presenceSent=N markerSent=N
 *
 * Exit codes: 0 completed the run, 2 usage, 3 stack/connect failure,
 * 4 dead run: no CoT received or interface never came up.
 */
public final class HeadlessCLI {

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

    public static class Log implements CommoLogger {
        public void log(CommoLogger.Level l, CommoLogger.Type t,
                        String m, CommoLogger.LoggingDetail d) {
            if (l == CommoLogger.Level.VERBOSE || l == CommoLogger.Level.DEBUG)
                return;
            System.err.println("commo[" + l + "] " + m);
        }
    }

    private static void usage(int code) {
        System.err.println(
                "usage: atak-headless --connect host:port [--uid UID] [--callsign CS]\n" +
                "                     [--duration SECONDS] [--send-marker LAT LON]");
        System.exit(code);
    }

    public static void main(String[] args) {
        String host = null, uid = "g1-headless-" + (System.nanoTime() % 1000000L),
               callsign = "HEADLESS", markerLat = null, markerLon = null;
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
                    break;
                case "--uid":       if (i + 1 >= args.length) usage(2);
                                    uid = args[++i]; break;
                case "--callsign":  if (i + 1 >= args.length) usage(2);
                                    callsign = args[++i]; break;
                case "--duration":  if (i + 1 >= args.length) usage(2);
                                    try { duration = Integer.parseInt(args[++i]); }
                                    catch (NumberFormatException e) { usage(2); }
                                    break;
                case "--send-marker":
                    if (i + 2 >= args.length) usage(2);
                    markerLat = args[++i];
                    markerLon = args[++i];
                    break;
                default: usage(2);
            }
        }
        if (host == null) usage(2);

        final String dist = System.getProperty("atakheadless.dist");
        if (dist == null) {
            System.err.println("atakheadless.dist not set — run via the atak-headless launcher");
            System.exit(3);
        }

        final AtomicInteger received = new AtomicInteger();
        final AtomicInteger presenceSent = new AtomicInteger();
        final AtomicInteger markerSent = new AtomicInteger();
        final AtomicBoolean ifaceUpSeen = new AtomicBoolean(false);
        final AtomicBoolean done = new AtomicBoolean(false);

        try {
            System.load(dist + "/libcommoncommo.dylib");
            System.load(dist + "/libcommoncommojni.dylib");
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
                    System.out.println("headless: contact-added " + c.contactUID);
                }
                public void contactRemoved(Contact c) {
                    System.out.println("headless: contact-removed " + c.contactUID);
                }
            });

            commo.addCoTMessageListener(
                    new com.atakmap.commoncommo.CoTMessageListener() {
                public void cotMessageReceived(String cotMessage, String rxEndpointId) {
                    received.incrementAndGet();
                    System.out.println("headless: cot-received " + (cotMessage == null
                            ? "" : cotMessage.replaceAll("\\s+", " ").trim()));
                }
            });

            System.out.println("headless: connecting " + host + ":" + port
                    + " uid=" + uid + " callsign=" + callsign);
            commo.addStreamingInterface(host, port,
                    new CoTMessageType[] { CoTMessageType.SITUATIONAL_AWARENESS },
                    null, null, null, null, null, null);

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
                            commo.broadcastCoT(presence(fUid, fCs));
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
                                        marker(fUid, fCs, fLat, fLon));
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
                    + " ifaceUpSeen=" + ifaceUpSeen.get()
                    + " presenceSent=" + presenceSent.get()
                    + " markerSent=" + markerSent.get());
            System.exit(received.get() > 0 && ifaceUpSeen.get() ? 0 : 4);
        } catch (CommoException e) {
            System.err.println("commo[ERROR] stack failure: " + e);
            System.exit(3);
        } catch (Throwable t) {
            System.err.println("commo[ERROR] fatal: " + t);
            System.exit(3);
        }
    }

    private static String presence(String uid, String callsign) {
        String t = now(0), stale = now(30000L);
        return "<event version='2.0' uid='" + uid + "' type='t-x-a-t-a-k'"
                + " time='" + t + "' start='" + t + "' stale='" + t + "' how='m-g'>"
                + "<point lat='0.0' lon='0.0' ce='9999999' le='9999999' hae='0.0'/>"
                + "<detail>"
                + "<contact endpoint='tcp://-.-.-.-:-' callsign='" + callsign + "'/>"
                + "<takv os='macOS' device='macTAK' platform='atak-headless' version='0.1.0'/>"
                + "</detail></event>";
    }

    private static String marker(String uid, String callsign, String lat, String lon) {
        String t = now(0), stale = now(120000L);
        return "<event version='2.0' uid='" + uid + "-m1' type='a-f-G-U-C'"
                + " time='" + t + "' start='" + t + "' stale='" + t + "' how='m-g'>"
                + "<point lat='" + lat + "' lon='" + lon + "' ce='10.0' le='10.0' hae='0.0'/>"
                + "<detail>"
                + "<contact callsign='" + callsign + "-M1'/>"
                + "<precisionlocation geopossrc='gps'><point>" + lat + "," + lon
                + "</point></precisionlocation>"
                + "</detail></event>";
    }

    private HeadlessCLI() {}
}

