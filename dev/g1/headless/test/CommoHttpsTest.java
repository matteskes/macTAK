import com.atakmap.commoncommo.Commo;
import com.atakmap.commoncommo.CommoLogger;
import com.atakmap.commoncommo.EnrollmentIO;
import com.atakmap.commoncommo.EnrollmentIOUpdate;
import com.atakmap.commoncommo.EnrollmentStep;
import com.atakmap.commoncommo.SimpleFileIOStatus;

import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/**
 * One leg of test/commo-https.sh: commo's https path (its curl, through
 * certificate enrollment's first request) against a local server.
 *
 * <p>Enrollment starts with a GET of {@code /Marti/api/tls/config}; the test
 * server answers 404, so a leg whose TLS handshake succeeds ends in a
 * non-TLS failure, and the server records the request. A refused
 * certificate ends in one of the SSL statuses, with no request recorded.
 *
 * <p>Prints {@code RESULT <SimpleFileIOStatus> <detail>} and exits 0 once the
 * request step ends, 3 if it never does.
 *
 * <p>usage: CommoHttpsTest LIBCOMMO LIBJNI PORT TRUSTSTORE.p12|none VERIFYHOST(true|false)
 */
public final class CommoHttpsTest {
    private static final String PASS = "atakatak";
    private static final long TIMEOUT_S = 30;

    private CommoHttpsTest() {}

    public static void main(String[] args) throws Exception {
        System.load(args[0]);
        System.load(args[1]);
        Commo.initThirdpartyNativeLibraries();
        final boolean verbose = System.getenv("COMMO_HTTPS_VERBOSE") != null;
        final Commo commo = new Commo(new CommoLogger() {
            public void log(CommoLogger.Level level, CommoLogger.Type type, String message,
                            CommoLogger.LoggingDetail detail) {
                if (verbose || level == CommoLogger.Level.ERROR)
                    System.err.println("commo[" + level + "] " + message);
            }
        }, "commo-https-test", "COMMO-HTTPS-TEST");

        final CountDownLatch done = new CountDownLatch(1);
        final AtomicReference<String> result = new AtomicReference<>();
        commo.enableEnrollment(new EnrollmentIO() {
            public void enrollmentUpdate(EnrollmentIOUpdate u) {
                // key generation runs first and succeeds locally; the leg is
                // the first request (step CSR, the /tls/config GET)
                if (u.step == EnrollmentStep.KEYGEN || u.status == SimpleFileIOStatus.INPROGRESS)
                    return;
                result.compareAndSet(null, u.status + " " + u.additionalInfo);
                done.countDown();
            }
        });

        final byte[] ca = "none".equals(args[3]) ? null : Files.readAllBytes(Paths.get(args[3]));
        final int id = commo.enrollmentInit("127.0.0.1", Integer.parseInt(args[2]),
                Boolean.parseBoolean(args[4]), "user", "pass", false,
                ca, ca == null ? null : PASS, "clientpass", "trustpass", "keypass", 2048,
                "commo-https-test");
        commo.enrollmentStart(id);
        final boolean finished = done.await(TIMEOUT_S, TimeUnit.SECONDS);
        System.out.println("RESULT " + (finished ? result.get() : "TIMEOUT no update in " + TIMEOUT_S + " s"));
        commo.shutdown();
        System.exit(finished ? 0 : 3);
    }
}
