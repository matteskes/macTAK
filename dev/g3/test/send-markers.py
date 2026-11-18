#!/usr/bin/env python3
"""Send typed CoT markers to a macTAK copy, for G3.7c's hand check (stdlib only).

Connects to a copy's direct TCP input (the mesh's "Direct messages", port 4242
by default; one connection per event, as commo reads each connection as one
message), sends a set of non-contact markers in a row just north of the Ferry
Building (37.7962, -122.3937), clear of a self marker placed on it, and closes. Each shows one of ATAK 5.5's icon
rules; the label says which:

  2525 F INF   a-f-G-U-C-I        friendly infantry, 2525C symbol
  2525 H ARM   a-h-G-U-C-A        hostile armour, 2525C symbol
  2525 N       a-n-G              neutral ground, 2525C symbol
  2525 U AIR   a-u-A              unknown air, 2525C symbol
  FILTER TTL   a-f-G-E-S-t        icon_filters.xml: ttl-icon-f.png
  DAMAGED      a-h-G              readiness=false: damaged_hostile.png
  RED TINT     a-f-G-U-C          <color argb=-65536>: the symbol tinted red
  SPOT MAP     a-h-G              usericon COT_MAPPING_SPOTMAP: a red dot
  NO SYMBOL    a-u-Q              no 2525C symbol: unknown-type-u.png
  SHORT LIFE   a-n-G              stale after 20 s: dark grey at 30 s,
                                  gone 5 minutes later

usage:
  send-markers.py [--host H] [--port P]           send the set
  send-markers.py --delete UID [--force]          send a delete task (t-x-d-d):
                                                  stale now, or gone with --force
"""
import argparse
import datetime
import socket
from xml.sax.saxutils import quoteattr

LAT, LON, STEP = 37.7962, -122.3937, 0.0006
LIFE = 300  # seconds

MARKERS = [
    # (uid, type, label, stale seconds, extra detail)
    ("g37c-friend", "a-f-G-U-C-I", "2525 F INF", LIFE, ""),
    ("g37c-hostile", "a-h-G-U-C-A", "2525 H ARM", LIFE, ""),
    ("g37c-neutral", "a-n-G", "2525 N", LIFE, ""),
    ("g37c-unknown", "a-u-A", "2525 U AIR", LIFE, ""),
    ("g37c-filter", "a-f-G-E-S-t", "FILTER TTL", LIFE, ""),
    ("g37c-damaged", "a-h-G", "DAMAGED", LIFE, "<status readiness='false'/>"),
    ("g37c-tint", "a-f-G-U-C", "RED TINT", LIFE, "<color argb='-65536'/>"),
    ("g37c-spot", "a-h-G", "SPOT MAP", LIFE, "<usericon iconsetpath='COT_MAPPING_SPOTMAP/b-m-p-s-m/-65536'/>"),
    ("g37c-nosymbol", "a-u-Q", "NO SYMBOL", LIFE, ""),
    ("g37c-short", "a-n-G", "SHORT LIFE", 20, ""),
]


def stamp(t):
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (t.microsecond // 1000)


def event(uid, type_, stale_s, lat, lon, detail, how="h-g-i-g-o"):
    now = datetime.datetime.now(datetime.timezone.utc)
    stale = now + datetime.timedelta(seconds=stale_s)
    return ("<event version='2.0' uid=%s type=%s time='%s' start='%s' stale='%s' how=%s>"
            "<point lat='%.6f' lon='%.6f' hae='0' ce='9999999' le='9999999'/>"
            "<detail>%s</detail></event>" % (quoteattr(uid), quoteattr(type_), stamp(now), stamp(now),
                                               stamp(stale), quoteattr(how), lat, lon, detail))


def markers():
    out = []
    for i, (uid, type_, label, stale_s, extra) in enumerate(MARKERS):
        lon = LON + (i - len(MARKERS) / 2) * STEP
        out.append(event(uid, type_, stale_s, LAT, lon, "<contact callsign=%s/>%s" % (quoteattr(label), extra)))
    return out


def delete(uid, force):
    detail = "<link uid=%s relation='none' type='none'/>%s" % (quoteattr(uid), "<__forcedelete/>" if force else "")
    return [event("g37c-delete-" + uid, "t-x-d-d", 20, LAT, LON, detail)]


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=4242)
    p.add_argument("--delete", metavar="UID")
    p.add_argument("--force", action="store_true")
    a = p.parse_args()
    events = delete(a.delete, a.force) if a.delete else markers()
    for e in events:  # commo reads one TCP connection as one message
        with socket.create_connection((a.host, a.port), timeout=5) as s:
            s.sendall(e.encode("utf-8"))
    print("sent %d event(s) to %s:%d" % (len(events), a.host, a.port))


if __name__ == "__main__":
    main()
