import com.atakmap.commoncommo.CoTMessageType;
import com.atakmap.commoncommo.Commo;
import com.atakmap.commoncommo.CommoLogger;
import com.atakmap.commoncommo.InterfaceStatusListener;
import com.atakmap.commoncommo.NetInterface;
import com.atakmap.commoncommo.NetInterfaceErrorCode;
import com.atakmap.commoncommo.StreamingTransport;

import java.nio.file.Files;
import java.nio.file.Paths;
import java.time.Instant;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Spike 2 QUIC canary (dev/spike/g55/NOTES.md §Commo): commo's streaming
 * QUIC client (StreamingTransport.QUIC, ALPN "takstream") on ngtcp2's ossl
 * backend (OpenSSL 3.5's QUIC TLS API), against commo/fake-quic-server.py
 * presenting a certificate signed by the CA in TRUST_P12.
 *
 *   accept  the server presents a serverAuth leaf: the interface comes up,
 *           and markers go out on it (commo.sh checks that the server
 *           received MARKER_UID)
 *   refuse  the server presents a clientAuth-only leaf, the impostor of G1
 *           security finding #1: the interface reports
 *           CONN_SSL_PEER_CERT_NOT_TRUSTED and never comes up
 *           (0002-sslcertchecker-require-server-purpose, on the QUIC path)
 *
 * usage: QuicStreamingTest CORE_LIB JNI_LIB CLIENT_P12 TRUST_P12 PORT accept|refuse
 * env:   QUIC_TEST_VERBOSE=1 prints commo's log at every level
 * Exit 0 = every check passed.
 */
public final class QuicStreamingTest {
    static final String MARKER_UID = "quic-streaming-marker";
    private static final String PASS = "atakatak";
    private static final long UP_TIMEOUT_MS = 10_000L;
    private static final long REFUSE_WINDOW_MS = 8_000L;
    // commo fires interfaceUp before the interface is sendable (HeadlessCLI)
    private static final long SEND_DELAY_MS = 500L;
    private static final int MARKERS = 3;
    private static final boolean VERBOSE = System.getenv("QUIC_TEST_VERBOSE") != null;

    private static int failures;

    private QuicStreamingTest() {}

    private static void check(boolean ok, String behavior) {
        System.out.println((ok ? "PASS: " : "FAIL: ") + behavior);
        if (!ok) failures++;
    }

    private static final class CommoLog implements CommoLogger {
        public void log(CommoLogger.Level level, CommoLogger.Type type, String message,
                        CommoLogger.LoggingDetail detail) {
            if (VERBOSE || level == CommoLogger.Level.ERROR)
                System.out.println("quic-streaming: [" + level + "] " + message);
        }
    }

    private static final class StatusLatch implements InterfaceStatusListener {
        final CountDownLatch up = new CountDownLatch(1);
        final AtomicReference<NetInterfaceErrorCode> error = new AtomicReference<>();
        public void interfaceUp(NetInterface iface) { up.countDown(); }
        public void interfaceDown(NetInterface iface) { }
        public void interfaceError(NetInterface iface, NetInterfaceErrorCode code) { error.compareAndSet(null, code); }
    }

    private static String marker() {
        final Instant now = Instant.now();
        return "<event version='2.0' uid='" + MARKER_UID + "' type='a-f-G-U-C' time='" + now
                + "' start='" + now + "' stale='" + now.plusSeconds(120) + "' how='h-g-i-g-o'>"
                + "<point lat='37.7749' lon='-122.4194' ce='9999999' le='9999999' hae='0.0'/>"
                + "<detail><contact callsign='QUIC-TEST'/></detail></event>";
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 6 || !(args[5].equals("accept") || args[5].equals("refuse"))) {
            System.err.println("usage: QuicStreamingTest CORE_LIB JNI_LIB CLIENT_P12 TRUST_P12 PORT accept|refuse");
            System.exit(2);
        }
        System.load(args[0]);
        System.load(args[1]);
        final byte[] clientP12 = Files.readAllBytes(Paths.get(args[2]));
        final byte[] trustP12 = Files.readAllBytes(Paths.get(args[3]));
        final int port = Integer.parseInt(args[4]);
        final boolean expectAccept = args[5].equals("accept");

        final Commo commo = new Commo(new CommoLog(), "quic-streaming-test", "QUIC-TEST");
        try {
            final StatusLatch status = new StatusLatch();
            commo.addInterfaceStatusListener(status);
            commo.addStreamingInterface(StreamingTransport.QUIC, "127.0.0.1", port,
                    new CoTMessageType[] { CoTMessageType.SITUATIONAL_AWARENESS },
                    clientP12, trustP12, PASS, PASS, null, null);

            if (expectAccept) {
                final boolean up = status.up.await(UP_TIMEOUT_MS, TimeUnit.MILLISECONDS);
                check(up, "QUIC streaming interface comes up against a serverAuth certificate (error="
                        + status.error.get() + ")");
                if (up) {
                    for (int i = 0; i < MARKERS; i++) {
                        Thread.sleep(SEND_DELAY_MS);
                        commo.broadcastCoT(marker());
                    }
                    Thread.sleep(SEND_DELAY_MS);
                    System.out.println("quic-streaming: sent " + MARKERS + " markers uid=" + MARKER_UID);
                }
            } else {
                final boolean up = status.up.await(REFUSE_WINDOW_MS, TimeUnit.MILLISECONDS);
                check(!up, "QUIC streaming interface never comes up against a clientAuth-only certificate");
                check(status.error.get() == NetInterfaceErrorCode.CONN_SSL_PEER_CERT_NOT_TRUSTED,
                        "the refusal is CONN_SSL_PEER_CERT_NOT_TRUSTED (got " + status.error.get() + ")");
            }
        } finally {
            commo.shutdown();
        }
        System.out.println("quic-streaming " + args[5] + ": " + (failures == 0 ? "PASS" : "FAIL (" + failures + ")"));
        System.exit(failures == 0 ? 0 : 1);
    }
}
