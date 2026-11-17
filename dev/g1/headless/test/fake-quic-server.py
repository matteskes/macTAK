"""A QUIC stand-in for a TAK server's streaming endpoint (ALPN "takstream").

From spike 2 (dev/spike/g55/NOTES.md §Commo): commo's streaming QUIC client
needs a server, and commo's own QUIC inbound speaks only the peer protocol
("takcot"). This one completes the handshake with the certificate it is
given (no client certificate requested), then logs, one line each, the
handshake and every stream payload, so quic.sh can check what arrived.

Like fake-cot-server.py, it relays each client's events to every other
client, never back to the sender, so two clients can see each other (G3.2's
QUIC leg, app/Tests/MacTAKCommsTests). commo's client opens one
bidirectional stream and reads on it, so a relayed event goes out on the
stream the receiving client opened. Inbound framing is on '</event>', per
client; the XML prolog is dropped.

usage: fake-quic-server.py PORT CERT_PEM KEY_PEM
needs: aioquic (quic.sh installs the hash-pinned requirements-quic.txt into a venv)
"""
import asyncio
import sys

from aioquic.asyncio import QuicConnectionProtocol, serve
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ConnectionTerminated, HandshakeCompleted, StreamDataReceived

ALPN = "takstream"
END = b"</event>"
MAX_BUF = 1 << 20  # drop a client's buffer if it sends 1 MiB with no </event>
CLIENTS = set()


def log(line):
    print("fake-quic-server: " + line, flush=True)


class TakStreamProtocol(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.stream_id = None  # the client's own bidirectional stream
        self.buf = bytearray()

    def quic_event_received(self, event):
        if isinstance(event, HandshakeCompleted):
            log("handshake alpn=%s" % event.alpn_protocol)
            CLIENTS.add(self)
        elif isinstance(event, StreamDataReceived):
            log("rx stream=%d bytes=%d %r" % (event.stream_id, len(event.data), event.data[:400]))
            if self.stream_id is None:
                self.stream_id = event.stream_id
            self.receive(event.data)
        elif isinstance(event, ConnectionTerminated):
            CLIENTS.discard(self)

    def receive(self, data):
        self.buf.extend(data)
        if len(self.buf) > MAX_BUF:  # unframed flood: resync rather than grow
            del self.buf[:]
        while True:
            end = self.buf.find(END)
            if end < 0:
                return
            raw = bytes(self.buf[:end + len(END)])
            del self.buf[:end + len(END)]
            start = raw.find(b"<event")
            if start >= 0:
                self.relay(raw[start:] + b"\n")

    def relay(self, payload):
        for peer in list(CLIENTS):
            if peer is self or peer.stream_id is None:
                continue
            peer._quic.send_stream_data(peer.stream_id, payload)
            peer.transmit()


async def main(port, cert, key):
    config = QuicConfiguration(is_client=False, alpn_protocols=[ALPN])
    config.load_cert_chain(cert, key)
    await serve("127.0.0.1", port, configuration=config, create_protocol=TakStreamProtocol)
    log("listening on udp/127.0.0.1:%d" % port)
    await asyncio.Future()


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("usage: fake-quic-server.py PORT CERT_PEM KEY_PEM")
    asyncio.run(main(int(sys.argv[1]), sys.argv[2], sys.argv[3]))
