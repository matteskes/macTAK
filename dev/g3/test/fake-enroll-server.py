#!/usr/bin/env python3
"""A TAK Server's certificate-enrollment port (8446) for G3.2c's tests (stdlib only).

Serves, over TLS with the given server certificate, behind basic auth:

  GET  /Marti/api/tls/config               <certificateConfig> with two
                                           nameEntries (O, OU)
  POST /Marti/api/tls/signClient/v2        signs the CSR in the body with
                                           the CA (openssl x509 -req, a
                                           clientAuth leaf) and answers
                                           <enrollment><signedCert/><ca0/>
  GET  /Marti/api/tls/profile/enrollment   the --profile file as a data
                                           package, or 204 without one

The shapes are what commo's enrollment parses (enrollmentmanager.cpp):
certificates as bare base64, no PEM banners, and the <enrollment> reply
compact, as TAK Server sends it: commo reads every child node's text, and a
whitespace node between elements has none. Logs one line per request,
"fake-enroll: METHOD PATH -> STATUS", and "listening" once bound.

USERS is a comma-separated list; all share PASSWORD.

usage: fake-enroll-server.py PORT CERT KEY CA_CERT CA_KEY USERS PASSWORD
                             [--profile FILE] [--no-ca]
needs: openssl (OPENSSL env, default: Homebrew's openssl@3)
"""
import base64
import http.server
import os
import socketserver
import ssl
import subprocess
import sys
import tempfile
import urllib.parse

OPENSSL = os.environ.get("OPENSSL", "/opt/homebrew/opt/openssl@3/bin/openssl")
MAX_BODY = 1 << 16


def log(line):
    print("fake-enroll: " + line, flush=True)


def bare(pem):
    """A PEM certificate's base64 body, banners and newlines dropped."""
    return "".join(l for l in pem.splitlines() if l and not l.startswith("-----"))


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    config = None  # set in main

    def log_message(self, *args):
        pass  # one line per request comes from reply()

    def reply(self, status, body=b"", content_type="application/xml"):
        log("%s %s -> %d" % (self.command, self.path, status))
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        for user in self.config["users"]:
            expected = base64.b64encode(("%s:%s" % (user, self.config["password"])).encode()).decode()
            if self.headers.get("Authorization", "") == "Basic " + expected:
                return True
        self.reply(401)
        return False

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        if not self.authorized():
            return
        if url.path == "/Marti/api/tls/config":
            self.reply(200, (b"<certificateConfig><nameEntries>"
                             b"<nameEntry name='O' value='macTAK test'/>"
                             b"<nameEntry name='OU' value='fake enrollment'/>"
                             b"</nameEntries></certificateConfig>"))
        elif url.path == "/Marti/api/tls/profile/enrollment":
            uid = urllib.parse.parse_qs(url.query).get("clientUid", [""])[0]
            log("profile for clientUid=%s" % uid)
            profile = self.config["profile"]
            if profile:
                with open(profile, "rb") as f:
                    self.reply(200, f.read(), "application/zip")
            else:
                self.reply(204)
        else:
            self.reply(404)

    def do_POST(self):
        url = urllib.parse.urlparse(self.path)
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(min(length, MAX_BODY))
        if not self.authorized():
            return
        if url.path != "/Marti/api/tls/signClient/v2":
            self.reply(404)
            return
        csr = "-----BEGIN CERTIFICATE REQUEST-----\n%s\n-----END CERTIFICATE REQUEST-----\n" % body.decode().strip()
        with tempfile.TemporaryDirectory() as work:
            paths = {name: os.path.join(work, name) for name in ("req.csr", "leaf.crt", "leaf.ext")}
            with open(paths["req.csr"], "w") as f:
                f.write(csr)
            with open(paths["leaf.ext"], "w") as f:
                f.write("extendedKeyUsage=clientAuth\n")
            signed = subprocess.run(
                [OPENSSL, "x509", "-req", "-in", paths["req.csr"], "-CA", self.config["ca_cert"],
                 "-CAkey", self.config["ca_key"], "-CAcreateserial", "-days", "2",
                 "-extfile", paths["leaf.ext"], "-out", paths["leaf.crt"]],
                capture_output=True, text=True)
            if signed.returncode != 0:
                log("signing failed: " + signed.stderr.strip())
                self.reply(400)
                return
            subject = subprocess.run([OPENSSL, "x509", "-in", paths["leaf.crt"], "-noout", "-subject"],
                                     capture_output=True, text=True).stdout.strip()
            with open(paths["leaf.crt"]) as f:
                leaf = bare(f.read())
        uid = urllib.parse.parse_qs(url.query).get("clientUid", [""])[0]
        log("signed %s for clientUid=%s" % (subject, uid))
        reply = "<enrollment><signedCert>%s</signedCert>" % leaf
        if not self.config["no_ca"]:
            with open(self.config["ca_cert"]) as f:
                reply += "<ca0>%s</ca0>" % bare(f.read())
        self.reply(200, (reply + "</enrollment>").encode())


class Server(http.server.ThreadingHTTPServer):
    """ThreadingHTTPServer without its bind-time reverse DNS lookup.

    HTTPServer.server_bind sets server_name from socket.getfqdn(host), a
    reverse lookup that can hang on a CI runner: the server then prints
    nothing until the test gives up (G3 trap 9). Nothing here uses the name.
    """

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


def main():
    args = sys.argv[1:]
    profile, no_ca = None, False
    if "--profile" in args:
        i = args.index("--profile")
        profile = args[i + 1]
        del args[i:i + 2]
    if "--no-ca" in args:
        args.remove("--no-ca")
        no_ca = True
    if len(args) != 7:
        sys.exit(__doc__.split("usage: ")[1].split("needs:")[0].strip())
    port, cert, key, ca_cert, ca_key, users, password = args
    Handler.config = {"users": users.split(","), "password": password, "ca_cert": ca_cert, "ca_key": ca_key,
                      "profile": profile, "no_ca": no_ca}
    server = Server(("127.0.0.1", int(port)), Handler)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(cert, key)
    server.socket = tls.wrap_socket(server.socket, server_side=True)
    log("listening on 127.0.0.1:%s (tls)" % port)
    server.serve_forever()


if __name__ == "__main__":
    main()
