import com.atakmap.commoncommo.CoTMessageType;
import com.atakmap.commoncommo.Commo;
import com.atakmap.commoncommo.CommoLogger;
import com.atakmap.commoncommo.Contact;
import com.atakmap.commoncommo.ContactPresenceListener;
import com.atakmap.commoncommo.NetInterfaceAddressMode;

import java.nio.file.Files;
import java.nio.file.Paths;
import java.time.Instant;
import java.util.Queue;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Peer-to-peer QUIC canary (test/quic.sh, peer leg; dev/g1/NOTES.md G1.18):
 * two commo instances in one JVM, as two ATAK clients on one mesh, with no
 * server between them.
 *
 *   discovery  A multicasts its SA on lo0; B, listening there, adds A as a
 *              contact. A's SA carries A's mesh endpoints, QUIC among them
 *              (commo stamps them from the interface's address)
 *   delivery   B sends a marker to contact A; commo picks A's QUIC endpoint
 *              (B has a QUIC inbound, so QUIC wins over UDP) and A receives
 *              the marker on its QUIC inbound
 *
 * commo advertises QUIC on 4243 whatever port the inbound listens on
 * (CoTMessage::endpointForType), so A's inbound must be on 4243.
 *
 * usage: QuicPeerTest CORE_LIB JNI_LIB PEER_P12 B_QUIC_PORT MESH_PORT
 * env:   QUIC_TEST_VERBOSE=1 prints both instances' logs at every level
 * Exit 0 = every check passed.
 */
public final class QuicPeerTest {
    static final int ADVERTISED_QUIC_PORT = 4243;
    private static final String MESH_GROUP = "239.2.3.1";
    private static final String PASS = "atakatak";
    private static final String UID_A = "quic-peer-a";
    private static final String UID_B = "quic-peer-b";
    private static final String MARKER_UID = "quic-peer-marker";
    private static final long SA_INTERVAL_MS = 500L;
    private static final int SA_ATTEMPTS = 20;
    private static final long DELIVERY_WAIT_MS = 1_500L;
    private static final int DELIVERY_ATTEMPTS = 6;
    private static final boolean VERBOSE = System.getenv("QUIC_TEST_VERBOSE") != null;

    private static int failures;

    private QuicPeerTest() {}

    private static void check(boolean ok, String behavior) {
        System.out.println((ok ? "PASS: " : "FAIL: ") + behavior);
        if (!ok) failures++;
    }

    private static final class CommoLog implements CommoLogger {
        final String who;
        final Queue<String> messages = new ConcurrentLinkedQueue<>();
        CommoLog(String who) { this.who = who; }
        public void log(CommoLogger.Level level, CommoLogger.Type type, String message,
                        CommoLogger.LoggingDetail detail) {
            messages.add(message);
            if (VERBOSE || level == CommoLogger.Level.ERROR)
                System.out.println("quic-peer " + who + ": [" + level + "] " + message);
        }
        boolean saw(String fragment) {
            for (String m : messages)
                if (m.contains(fragment)) return true;
            return false;
        }
    }

    private static final class PeerSeen implements ContactPresenceListener {
        final CountDownLatch seen = new CountDownLatch(1);
        final AtomicReference<Contact> contact = new AtomicReference<>();
        public void contactAdded(Contact c) {
            if (UID_A.equals(c.contactUID) && contact.compareAndSet(null, c)) seen.countDown();
        }
        public void contactRemoved(Contact c) { }
    }

    private static String event(String uid, String type, String detail) {
        final Instant now = Instant.now();
        return "<event version='2.0' uid='" + uid + "' type='" + type + "' time='" + now
                + "' start='" + now + "' stale='" + now.plusSeconds(120) + "' how='h-e'>"
                + "<point lat='41.8781' lon='-87.6298' ce='9999999' le='9999999' hae='0.0'/>"
                + "<detail>" + detail + "</detail></event>";
    }

    /** A's SA; commo replaces the placeholder endpoint with A's mesh endpoints. */
    private static String presenceOfA() {
        return event(UID_A, "a-f-G-U-C", "<contact callsign='QUIC-PEER-A' endpoint='*:-1:stcp'/>");
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 5) {
            System.err.println("usage: QuicPeerTest CORE_LIB JNI_LIB PEER_P12 B_QUIC_PORT MESH_PORT");
            System.exit(2);
        }
        System.load(args[0]);
        System.load(args[1]);
        final byte[] peerP12 = Files.readAllBytes(Paths.get(args[2]));
        final int bQuicPort = Integer.parseInt(args[3]);
        final int meshPort = Integer.parseInt(args[4]);
        final CoTMessageType[] saOnly = { CoTMessageType.SITUATIONAL_AWARENESS };

        final CommoLog logA = new CommoLog("A");
        final CommoLog logB = new CommoLog("B");
        final Commo a = new Commo(logA, UID_A, "QUIC-PEER-A", NetInterfaceAddressMode.NAME);
        final Commo b = new Commo(logB, UID_B, "QUIC-PEER-B", NetInterfaceAddressMode.NAME);
        try {
            // both ends on one host: multicast must loop back to B
            a.setMulticastLoopbackEnabled(true);
            final AtomicReference<String> markerRx = new AtomicReference<>();
            final CountDownLatch delivered = new CountDownLatch(1);
            a.addCoTMessageListener((cot, rxEndpointId) -> {
                if (cot.contains(MARKER_UID) && markerRx.compareAndSet(null, rxEndpointId))
                    delivered.countDown();
            });
            a.addQuicInboundInterface(ADVERTISED_QUIC_PORT, peerP12, PASS);
            b.addQuicInboundInterface(bQuicPort, peerP12, PASS);
            a.addBroadcastInterface("lo0", saOnly, MESH_GROUP, meshPort);
            b.addInboundInterface("lo0", meshPort, new String[] { MESH_GROUP }, false);

            final PeerSeen peer = new PeerSeen();
            b.addContactPresenceListener(peer);
            for (int i = 0; i < SA_ATTEMPTS && peer.seen.getCount() > 0; i++) {
                a.broadcastCoT(presenceOfA());
                peer.seen.await(SA_INTERVAL_MS, TimeUnit.MILLISECONDS);
            }
            final Contact contactA = peer.contact.get();
            check(contactA != null, "B discovers A from A's SA multicast on lo0");

            if (contactA != null) {
                for (int i = 0; i < DELIVERY_ATTEMPTS && delivered.getCount() > 0; i++) {
                    b.sendCoT(contactA, event(MARKER_UID, "a-f-G-U-C", ""));
                    delivered.await(DELIVERY_WAIT_MS, TimeUnit.MILLISECONDS);
                }
                check(logB.saw("using quic endpoint 127.0.0.1:" + ADVERTISED_QUIC_PORT),
                        "B sends to A's advertised QUIC endpoint 127.0.0.1:" + ADVERTISED_QUIC_PORT);
                final String rx = markerRx.get();
                check(rx != null && rx.endsWith(":quic"),
                        "A receives the marker on its QUIC inbound (rx endpoint " + rx + ")");
            }
        } finally {
            a.shutdown();
            b.shutdown();
        }
        System.out.println("quic-peer: " + (failures == 0 ? "PASS" : "FAIL (" + failures + ")"));
        System.exit(failures == 0 ? 0 : 1);
    }
}
