#!/usr/bin/env python3
"""A Nominatim server for the ADDR tests (stdlib only, plain http).

  GET /<prefix>reverse?…&lat=&lon=   one place at the position asked, or
                                     {"error": …} at 0,0 (nothing there)
  GET /<prefix>search?…&q=…          a list: [] for "nowhere"; for "far",
                                     [] when bounded=1 and a place when
                                     not, as a place outside the viewbox
  any path under /missing/           404

Every place is "Test Street 1, Testville, Testland": the client drops the
country, as 5.5 does. Logs "fake-nominatim: GET <path>?<query> ua=<agent>"
per request, and "listening" once bound.

usage: fake-nominatim-server.py PORT
"""
import http.server
import json
import socketserver
import sys
import urllib.parse


def log(line):
    print("fake-nominatim: " + line, flush=True)


PLACE = "Test Street 1, Testville, Testland"


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        log("GET %s?%s ua=%s" % (url.path, url.query, self.headers.get("User-Agent", "")))
        q = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
        if "/missing/" in url.path:
            self.reply(404, {"error": "no such service"})
        elif url.path.endswith("/reverse"):
            if float(q.get("lat", "0")) == 0 and float(q.get("lon", "0")) == 0:
                self.reply(200, {"error": "Unable to geocode"})
            else:
                self.reply(200, {"lat": q["lat"], "lon": q["lon"], "display_name": PLACE,
                                 "address": {"road": "Test Street"}})
        elif url.path.endswith("/search"):
            query = q.get("q", "")
            if query == "nowhere" or (query == "far" and q.get("bounded") == "1"):
                self.reply(200, [])
            else:
                self.reply(200, [{"lat": "38.8977", "lon": "-77.0365", "display_name": PLACE}])
        else:
            self.reply(404, {"error": "no such endpoint"})


class Server(http.server.ThreadingHTTPServer):
    """No bind-time reverse DNS lookup (G3 trap 9)."""

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: fake-nominatim-server.py PORT")
    server = Server(("127.0.0.1", int(sys.argv[1])), Handler)
    log("listening on 127.0.0.1:%s" % sys.argv[1])
    server.serve_forever()


if __name__ == "__main__":
    main()
