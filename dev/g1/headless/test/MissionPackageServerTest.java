import com.atakmap.commoncommo.CoTPointData;
import com.atakmap.commoncommo.Commo;
import com.atakmap.commoncommo.CommoLogger;
import com.atakmap.commoncommo.MissionPackageIO;
import com.atakmap.commoncommo.MissionPackageReceiveStatusUpdate;
import com.atakmap.commoncommo.MissionPackageSendStatusUpdate;
import com.atakmap.commoncommo.MissionPackageTransferException;
import com.atakmap.commoncommo.MissionPackageTransferStatus;

import java.io.File;
import java.net.HttpURLConnection;
import java.net.ServerSocket;
import java.net.URI;
import java.net.URL;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.security.cert.X509Certificate;
import java.util.UUID;

import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

/**
 * commo's mission-package web server answers, over plain HTTP and through
 * its HTTPS proxy (test/mp-server.sh; bundling plan PR B).
 *
 * commo serves mission packages from libmicrohttpd, started without TLS;
 * its local HTTPS port is commo's own OpenSSL proxy (core/impl/httpsproxy.cpp)
 * in front of that plain server. macTAK builds libmicrohttpd without HTTPS
 * (dev/g1/fetch-microhttpd.sh), so this pins both paths: a GET for a transfer
 * that doesn't exist must come back as an HTTP 404 from libmicrohttpd, on the
 * plain port and through the proxy.
 *
 * Usage: MissionPackageServerTest LIBCOMMO LIBCOMMOJNI SERVER_P12
 * Prints "RESULT http <code>" and "RESULT https <code>"; exits 0 when both
 * are 404.
 */
public final class MissionPackageServerTest {
    private static final String PASS = "atakatak";
    private static final int NOT_FOUND = 404;
    private static final int TIMEOUT_MS = 10_000;

    private MissionPackageServerTest() {}

    public static void main(String[] args) throws Exception {
        System.load(args[0]);
        System.load(args[1]);
        Commo.initThirdpartyNativeLibraries();
        final boolean verbose = System.getenv("MP_SERVER_VERBOSE") != null;
        final Commo commo = new Commo(new CommoLogger() {
            public void log(CommoLogger.Level level, CommoLogger.Type type, String message,
                            CommoLogger.LoggingDetail detail) {
                if (verbose || level == CommoLogger.Level.ERROR)
                    System.err.println("commo[" + level + "] " + message);
            }
        }, "mp-server-test", "MP-SERVER-TEST");
        commo.setupMissionPackageIO(new NoTransfers());

        final int httpPort = freePort();
        final int httpsPort = freePort();
        enablePlainPort(commo, httpPort);
        commo.setMissionPackageLocalHttpsParams(httpsPort, Files.readAllBytes(Paths.get(args[2])), PASS);

        final int http = get(URI.create("http://127.0.0.1:" + httpPort + "/getfile?file=no-such-transfer").toURL());
        final int https = get(URI.create("https://127.0.0.1:" + httpsPort + "/getfile?file=no-such-transfer").toURL());
        System.out.println("RESULT http " + http);
        System.out.println("RESULT https " + https);
        commo.shutdown();
        System.exit(http == NOT_FOUND && https == NOT_FOUND ? 0 : 1);
    }

    /**
     * commo deprecates its plain local port in favour of the HTTPS one, but
     * ATAK 5.5 still exposes it, so the plain leg stays covered.
     */
    @SuppressWarnings("deprecation")
    private static void enablePlainPort(Commo commo, int port) throws Exception {
        commo.setMissionPackageLocalPort(port);
    }

    private static int freePort() throws Exception {
        try (ServerSocket s = new ServerSocket(0)) {
            return s.getLocalPort();
        }
    }

    /** The response code, or -1 when no HTTP response came back. */
    private static int get(URL url) throws Exception {
        final HttpURLConnection c = (HttpURLConnection) url.openConnection();
        if (c instanceof HttpsURLConnection) {
            // the test's own throwaway certificate: what's checked is that
            // the proxy terminates TLS and reaches the server behind it
            final SSLContext tls = SSLContext.getInstance("TLS");
            tls.init(null, new TrustManager[] { new TrustTestCertificate() }, null);
            ((HttpsURLConnection) c).setSSLSocketFactory(tls.getSocketFactory());
            ((HttpsURLConnection) c).setHostnameVerifier((host, session) -> true);
        }
        c.setConnectTimeout(TIMEOUT_MS);
        c.setReadTimeout(TIMEOUT_MS);
        try {
            return c.getResponseCode();
        } catch (java.io.IOException e) {
            System.err.println(url.getProtocol() + ": " + e);
            return -1;
        } finally {
            c.disconnect();
        }
    }

    private static final class TrustTestCertificate implements X509TrustManager {
        public void checkClientTrusted(X509Certificate[] chain, String authType) {}
        public void checkServerTrusted(X509Certificate[] chain, String authType) {}
        public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
    }

    /** Refuses every incoming transfer; the test sends none. */
    private static final class NoTransfers implements MissionPackageIO {
        public File missionPackageReceiveInit(String fileName, String transferName, String sha256hash,
                                              long sizeInBytes, String senderCallsign)
                throws MissionPackageTransferException {
            throw new MissionPackageTransferException(MissionPackageTransferStatus.FINISHED_DISABLED_LOCALLY);
        }
        public void missionPackageReceiveStatusUpdate(MissionPackageReceiveStatusUpdate update) {}
        public void missionPackageSendStatusUpdate(MissionPackageSendStatusUpdate update) {}
        public CoTPointData getCurrentPoint() { return new CoTPointData(0, 0); }
        public String createUUID() { return UUID.randomUUID().toString(); }
    }
}
