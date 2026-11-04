#!/usr/bin/env python3
"""Hermetic CoT server for the headless round-trip smoke (stdlib only).

Sends one minimal CoT <event> XML line to every connected TCP client every
~2s; prints client lines prefixed 'cot-rx:'. Also relays each client line to
the *other* connected clients, like a real TAK server: a server does not
reflect a client's own events back to it, so a two-client round-trip needs
the relay. Relaying is byte-exact and newline-framed: each client gets its
own accumulation buffer so an event split across recv() boundaries is
forwarded once, whole, rather than as two malformed fragments. usage:
fake-cot-server.py [PORT] (env PORT overrides; default 8087). Runs until
SIGTERM.
"""
import datetime
import os
import signal
import socket
import sys
import time
RUNNING, FMT = [True], "%Y-%m-%dT%H:%M:%S.%f"
MAX_BUF = 1 << 20  # drop a peer's buffer if it sends 1 MiB with no newline


def cot_line():
    now = datetime.datetime.now(datetime.timezone.utc)
    t = now.strftime(FMT)[:-3] + "Z"
    stale = (now + datetime.timedelta(seconds=30)).strftime(FMT)[:-3] + "Z"
    return ("<?xml version='1.0' encoding='UTF-8'?>"
            "<event version='2.0' uid='fake-cot-001' type='a-f-G-U-C'"
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


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("PORT", "8087"))
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(8)
    srv.setblocking(False)
    print("fake-cot: listening on 127.0.0.1:%d" % port, flush=True)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    clients, next_tx = {}, time.time()  # sock -> pending inbound bytes
    while RUNNING[0]:
        for sock in list(clients):  # receive from clients
            if sock not in clients:  # dropped by a relay earlier this pass
                continue
            try:
                data = sock.recv(4096)
            except (BlockingIOError, InterruptedError):
                continue
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
                    nl = buf.find(b"\n")
                    if nl < 0:  # partial event: keep it until the newline lands
                        break
                    raw = bytes(buf[:nl])
                    del buf[:nl + 1]
                    if not raw.strip():
                        continue
                    print("cot-rx: " + raw.decode("utf-8", "replace").strip(), flush=True)
                    relay(clients, sock, raw + b"\n")
            else:
                drop(clients, sock, "disconnected")
        try:  # accept new clients
            sock, addr = srv.accept()
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
