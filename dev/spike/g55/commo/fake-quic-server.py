"""A QUIC stand-in for a TAK server's streaming endpoint (ALPN "takstream").

Spike 2 (dev/spike/g55/NOTES.md §Commo): commo's streaming QUIC client
needs a server, and commo's own QUIC inbound speaks only the peer protocol
("takcot"). This one completes the handshake with the certificate it is
given (no client certificate requested), then logs, one line each, the
handshake and every stream payload, so commo.sh can check what arrived.

usage: fake-quic-server.py PORT CERT_PEM KEY_PEM
needs: aioquic (commo.sh installs a pinned copy into a venv)
"""
import asyncio
import sys

from aioquic.asyncio import QuicConnectionProtocol, serve
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import HandshakeCompleted, StreamDataReceived

ALPN = "takstream"


def log(line):
    print("fake-quic-server: " + line, flush=True)


class TakStreamProtocol(QuicConnectionProtocol):
    def quic_event_received(self, event):
        if isinstance(event, HandshakeCompleted):
            log("handshake alpn=%s" % event.alpn_protocol)
        elif isinstance(event, StreamDataReceived):
            log("rx stream=%d bytes=%d %r" % (event.stream_id, len(event.data), event.data[:400]))


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
