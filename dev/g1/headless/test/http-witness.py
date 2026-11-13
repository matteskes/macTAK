#!/usr/bin/env python3
"""A loopback HTTP listener that records every request it gets (stdlib only).

For test/gdal-network.sh: a file that makes GDAL reach the network is caught
by its request arriving here. Binds 127.0.0.1 on a free port, writes the
port to PORT_FILE once it listens, appends "METHOD PATH" per request to
LOG_FILE, and answers 404. Runs until SIGTERM.

usage: http-witness.py PORT_FILE LOG_FILE
"""
import http.server
import signal
import socketserver
import sys


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: http-witness.py PORT_FILE LOG_FILE")
    port_file, log_file = sys.argv[1], sys.argv[2]
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

    server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
    signal.signal(signal.SIGTERM, lambda *_a: sys.exit(0))
    with open(port_file, "w", encoding="utf-8") as f:
        f.write("%d\n" % server.server_address[1])
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
