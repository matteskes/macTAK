#!/usr/bin/env python3
"""A loopback HTTP(S) listener that records every request it gets (stdlib only).

For test/gdal-network.sh: a file that makes GDAL reach the network is caught
by its request arriving here. For test/commo-https.sh, with --tls: a request
arrives only once the client has finished the TLS handshake, so an untrusted
server certificate shows up as no request at all.

Binds 127.0.0.1 on a free port, writes the port to PORT_FILE once it
listens, appends "METHOD PATH" per request to LOG_FILE, and answers 404.
Runs until SIGTERM.

usage: http-witness.py PORT_FILE LOG_FILE [--tls CERT KEY]
"""
import http.server
import signal
import socketserver
import ssl
import sys


def main():
    args = sys.argv[1:]
    tls = None
    if "--tls" in args:
        i = args.index("--tls")
        if i + 2 >= len(args):
            sys.exit("usage: http-witness.py PORT_FILE LOG_FILE [--tls CERT KEY]")
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(args[i + 1], args[i + 2])
        del args[i:i + 3]
    if len(args) != 2:
        sys.exit("usage: http-witness.py PORT_FILE LOG_FILE [--tls CERT KEY]")
    port_file, log_file = args
    log = open(log_file, "a", buffering=1, encoding="utf-8")

    class Handler(http.server.BaseHTTPRequestHandler):
        def _record(self):
            log.write("%s %s\n" % (self.command, self.path))
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

        do_GET = do_HEAD = do_POST = _record

        def log_message(self, *_args):
            pass

    class Server(socketserver.TCPServer):
        def get_request(self):
            sock, addr = super().get_request()
            if tls is not None:
                # bounded: a client that stalls the handshake must not wedge
                # the listener for the next leg
                sock.settimeout(10)
                sock = tls.wrap_socket(sock, server_side=True)
            return sock, addr

        def handle_error(self, request, client_address):
            pass  # a refused handshake is the expected outcome of some legs

    server = Server(("127.0.0.1", 0), Handler)
    signal.signal(signal.SIGTERM, lambda *_a: sys.exit(0))
    with open(port_file, "w", encoding="utf-8") as f:
        f.write("%d\n" % server.server_address[1])
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
