#!/usr/bin/env python3
"""Hermetic CoT server for the headless round-trip smoke (stdlib only).

Sends one minimal CoT <event> XML line to every connected TCP client every
~2s; prints client events prefixed 'cot-rx:'. Also relays each client event
to the *other* connected clients, like a real TAK server: a server does not
reflect a client's own events back to it, so a two-client round-trip needs
the relay. Inbound framing is on the '</event>' end token, exactly as commo
and TAK Server frame a CoT stream (commo writes '<?xml ...?>\n<event .../>'
with no trailing newline, so newline framing would glue each event to the
next one's prolog); each client gets its own accumulation buffer so an
event split across recv() boundaries is forwarded once, whole. The prolog
is dropped and the bare '<event>...</event>\n' is relayed. usage:
fake-cot-server.py [PORT] [--tls CERT KEY [--client-ca CA]] (env PORT
overrides; default 8087). --tls serves TLS with that PEM cert/key and
requests no client cert: test/tls-purpose.sh uses it to present a server
cert, or a client-only impostor cert, to commo (G1.14). --client-ca adds
mutual TLS, the way a TAK server's port 8089 runs: a client must present a
certificate that chains to that PEM CA, or its handshake fails (G3.2's TLS
leg, app/Tests/MacTAKCommsTests). Runs until SIGTERM.
"""
import datetime
import os
import signal
import socket
import ssl
import sys
import time
RUNNING, FMT = [True], "%Y-%m-%dT%H:%M:%S.%f"
END = b"</event>"
MAX_BUF = 1 << 20  # drop a peer's buffer if it sends 1 MiB with no </event>


def cot_line():
    # No XML prolog: commo frames on '</event>' and leaves the trailing newline of the
    # previous message in its buffer, and libxml2 rejects a prolog that isn't byte 0.
    now = datetime.datetime.now(datetime.timezone.utc)
    t = now.strftime(FMT)[:-3] + "Z"
    stale = (now + datetime.timedelta(seconds=30)).strftime(FMT)[:-3] + "Z"
    return ("<event version='2.0' uid='fake-cot-001' type='a-f-G-U-C'"
            " time='" + t + "' start='" + t + "' stale='" + stale + "' how='m-g'>"
            "<point lat='37.7749' lon='-122.4194' ce='10.0' le='10.0' hae='0.0'/>"
            "</event>\n")


def stop(*_a):
    RUNNING[0] = False


def drop(clients, sock, why):
    clients.pop(sock, None)
    try:
        sock.close()
    except OSError:
        pass
    print("fake-cot: client %s" % why, flush=True)


def relay(clients, sender, payload):
    """Forward a client line to every other client (never back to sender)."""
    for peer in list(clients):
        if peer is sender:
            continue
        try:
            peer.sendall(payload)
        except OSError:
            drop(clients, peer, "send-failed")


USAGE = "usage: fake-cot-server.py [PORT] [--tls CERT KEY [--client-ca CA]]"


def parse_args(argv):
    """[PORT] [--tls CERT KEY [--client-ca CA]] -> (port, tls_context or None)."""
    args = list(argv)
    tls = None
    if "--tls" in args:
        i = args.index("--tls")
        if i + 2 >= len(args):
            sys.exit(USAGE)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(args[i + 1], args[i + 2])
        del args[i:i + 3]
    if "--client-ca" in args:
        i = args.index("--client-ca")
        if tls is None or i + 1 >= len(args):
            sys.exit(USAGE)
        tls.verify_mode = ssl.CERT_REQUIRED
        tls.load_verify_locations(cafile=args[i + 1])
        del args[i:i + 2]
    port = int(args[0]) if args else int(os.environ.get("PORT", "8087"))
    return port, tls


def accept_tls(sock, tls):
    """Blocking TLS handshake (bounded), then back to non-blocking."""
    sock.settimeout(5.0)
    try:
        wrapped = tls.wrap_socket(sock, server_side=True)
    except (ssl.SSLError, OSError) as e:
        print("fake-cot: tls handshake failed: %s" % e, flush=True)
        sock.close()
        return None
    peer = wrapped.getpeercert()  # {} or None unless --client-ca verified one
    if peer:
        subject = dict(rdn[0] for rdn in peer.get("subject", ()))
        print("fake-cot: tls client CN=%s" % subject.get("commonName", "?"), flush=True)
    return wrapped


def main():
    port, tls = parse_args(sys.argv[1:])
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(8)
    srv.setblocking(False)
    print("fake-cot: listening on 127.0.0.1:%d%s" % (port, " (tls)" if tls else ""), flush=True)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    clients, next_tx = {}, time.time()  # sock -> pending inbound bytes
    while RUNNING[0]:
        for sock in list(clients):  # receive from clients
            if sock not in clients:  # dropped by a relay earlier this pass
                continue
            try:
                data = sock.recv(4096)
            except (BlockingIOError, InterruptedError,
                    ssl.SSLWantReadError, ssl.SSLWantWriteError):
                continue  # TLS: "no record yet" is not a dead peer
            except OSError:
                drop(clients, sock, "errored")
                continue
            if data:
                buf = clients[sock]
                buf.extend(data)
                if len(buf) > MAX_BUF:  # unframed flood: resync rather than grow
                    print("fake-cot: oversized buffer, resyncing", flush=True)
                    del buf[:]
                while True:
                    end = buf.find(END)
                    if end < 0:  # partial event: keep it until the end token lands
                        break
                    raw = bytes(buf[:end + len(END)])
                    del buf[:end + len(END)]
                    start = raw.find(b"<event")
                    if start < 0:
                        continue
                    raw = raw[start:]  # drops the XML prolog and inter-event whitespace
                    print("cot-rx: " + raw.decode("utf-8", "replace"), flush=True)
                    relay(clients, sock, raw + b"\n")
            else:
                drop(clients, sock, "disconnected")
        try:  # accept new clients
            sock, addr = srv.accept()
            if tls:
                sock = accept_tls(sock, tls)
                if sock is None:
                    continue
            sock.setblocking(False)
            clients[sock] = bytearray()
            print("fake-cot: client connected %s" % (addr,), flush=True)
        except OSError:
            pass
        now = time.time()
        if now >= next_tx:  # broadcast one CoT event to everyone
            line = cot_line().encode("utf-8")
            for sock in list(clients):
                try:
                    sock.sendall(line)
                except OSError:
                    drop(clients, sock, "send-failed")
            next_tx = now + 2.0
        time.sleep(0.1)
    srv.close()
    print("fake-cot: shutting down", flush=True)

if __name__ == "__main__":
    main()
