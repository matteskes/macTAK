#!/usr/bin/env python3
"""held-tls-server.py PORT CERT KEY RELEASE_FILE

A TLS listener that holds each handshake until RELEASE_FILE exists (#270):
it accepts the TCP connection, prints "held", waits for the file, then
finishes the handshake and prints "released". A test can make a client's
stream come up at a moment it picks, e.g. while commo is shutting down.
"""
import os
import signal
import socket
import ssl
import sys
import time


def main():
    if len(sys.argv) != 5:
        sys.exit("usage: held-tls-server.py PORT CERT KEY RELEASE_FILE")
    port, cert, key, release = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(cert, key)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(8)
    print("held-tls: listening on 127.0.0.1:%d" % port, flush=True)

    held = []  # finished handshakes stay open until we exit
    while True:
        sock, _ = srv.accept()
        print("held-tls: held", flush=True)
        while not os.path.exists(release):
            time.sleep(0.001)
        sock.settimeout(5.0)
        try:
            held.append(tls.wrap_socket(sock, server_side=True))
            print("held-tls: released", flush=True)
        except (ssl.SSLError, OSError) as e:
            print("held-tls: handshake failed: %s" % e, flush=True)
            sock.close()


if __name__ == "__main__":
    main()
