#!/usr/bin/env bash
#
# The G3 exit run (`make g3-exit`; dev/g3/NOTES.md §The G3 exit, PR c): two
# copies of the app on one Mac, each enrolled with OpenTAKServer (PR a's, in
# VMPal's container engine) into the login Keychain, connected over TLS,
# with the mesh off, so they can hear each other only through the server.
#
#   1. preflight: the server is ready (dev/g3/exit/servers.sh preflight)
#   2. a clean start: each copy's earlier exit server and certificates are
#      removed (a cleanup-only --exit-script), and its settings suite, chat
#      history and kept map items are deleted, so nothing from an earlier
#      run can stand in for this one
#   3. both copies run their --exit-script (PR b) at once: enroll, connect,
#      hear the other as a contact, drop a Spot Map point (A red, B blue)
#      and send it, chat to All Chat Rooms and one-to-one
#   4. the reports: each copy passed; heard the other through the server,
#      not the mesh; has the other's point, from the other, where it was
#      dropped; both chats; the delivered and read receipts of its own
#      one-to-one
#   5. on screen: each window is captured (the copy fitted the map to both
#      points) and must show the other's dot as a small solid patch of its
#      colour; a Spot Map colour nobody dropped (green) must be absent, so
#      the check can fail
#   6. tidy-up: both copies quit, and the cleanup removes the identities
#      and truststore the run enrolled; their fingerprints must be gone
#
# PASS or FAIL, with the log in dev/g3/build/g3-exit.txt and the captures
# and reports in dev/g3/build/exit-run/. Needs build/MacTAK.app (make app),
# Screen Recording for the terminal (the window captures), and a GUI
# session. The exit password comes from the login Keychain (`mactak-exit`)
# and reaches the copies only in their environment.

set -euo pipefail

repo="$(cd "$(dirname "$0")/../../.." && pwd)"
app="$repo/build/MacTAK.app/Contents/MacOS/MacTAK"
work="$repo/dev/g3/build/exit-run"
log="$repo/dev/g3/build/g3-exit.txt"
capture="$repo/dev/g3/build/exit-capture"
support="$HOME/Library/Application Support/macTAK"
export DOCKER_HOST="${MACTAK_EXIT_DOCKER_HOST:-unix://$HOME/.vmpal/docker.sock}"

readonly suites=(mactak-exit-a mactak-exit-b)
readonly ots_container=mactak-exit-ots
readonly report_timeout=120      # s, both reports
readonly settle=6                # s after both reports, for the map to fit
readonly quit_timeout=30         # s
readonly tolerance=40            # per channel, for a dot's colour
readonly dot_min=20 dot_max=400  # pixels in a dot (10x10 at 2x: ~80)
readonly dot_box=30              # px, the most a dot spans
readonly absent_colour=00FF00    # Spot Map green: nobody drops it

say() { printf '[g3-exit] %s\n' "$*" | tee -a "$log"; }
fail() { printf '[g3-exit] FAIL: %s\n' "$*" | tee -a "$log" >&2; exit 1; }

pids=()    # the copies running now
last_pid=""
stop_copies() {
    ((${#pids[@]})) || return 0
    kill -TERM "${pids[@]}" 2>/dev/null || true
    local waited=0
    while kill -0 "${pids[@]}" 2>/dev/null && ((waited < quit_timeout)); do
        sleep 1
        waited=$((waited + 1))
    done
    kill -KILL "${pids[@]}" 2>/dev/null || true
    pids=()
}
# However the run ends: the copies stop, and a run that failed after its
# scripts were written removes what it enrolled (best effort; the next run's
# clean start removes anything left).
tidy() {
    local status=$?
    stop_copies
    if ((status != 0)) && [[ -f ${work:-}/cleanup-a.json ]]; then
        (cleanup) >/dev/null 2>&1 || true
    fi
}
trap tidy EXIT

# A copy, its script, and (for a run) the password in its environment only.
launch() {
    local suite=$1 script=$2 password=${3:-}
    MACTAK_EXIT_PASSWORD="$password" "$app" --settings-suite "$suite" --exit-script "$script" \
        > "$work/$(basename "$script" .json).log" 2>&1 &
    last_pid=$!
    pids+=("$last_pid")
}

# Writes copy $1's script ("run" or "cleanup") to $work/$2.json.
write_script() {
    python3 -I - "$work" "$@" <<'PY'
import json, sys
work, me, kind, ca, ca_password = sys.argv[1:6]
peer = {"a": "b", "b": "a"}[me]
places = {"a": ((37.80, -122.45), (37.795, -122.445), "R"), "b": ((37.81, -122.44), (37.805, -122.435), "B")}
(place, point, colour) = places[me]
script = {
    "server": {"description": "exit", "host": "127.0.0.1", "port": 8089, "enrollmentPort": 8446,
               "truststore": ca, "truststorePassword": ca_password, "user": f"exit_{me}",
               "passwordVariable": "MACTAK_EXIT_PASSWORD"},
    "callsign": f"EXIT-{me.upper()}", "place": {"lat": place[0], "lon": place[1]}, "reportEvery": 3,
    "peer": f"EXIT-{peer.upper()}", "point": {"lat": point[0], "lon": point[1]}, "pointColor": colour,
    "allChatRooms": f"all from EXIT-{me.upper()}", "direct": f"direct from EXIT-{me.upper()}",
    "timeout": 90, "report": f"{work}/{kind}-report-{me}.json", "cleanupOnly": kind == "cleanup"}
json.dump(script, open(f"{work}/{kind}-{me}.json", "w"), indent=1)
PY
}

# Runs the cleanup-only script of each copy, one after the other.
cleanup() {
    local me
    for me in a b; do
        launch "mactak-exit-$me" "$work/cleanup-$me.json"
        local pid=$last_pid waited=0
        while kill -0 "$pid" 2>/dev/null && ((waited < quit_timeout)); do sleep 1; waited=$((waited + 1)); done
        kill -0 "$pid" 2>/dev/null && fail "the cleanup of copy $me didn't quit in ${quit_timeout} s"
        pids=()
        [[ -f $work/cleanup-report-$me.json ]] || fail "the cleanup of copy $me wrote no report"
    done
}

# 1. preflight
mkdir -p "$(dirname "$log")"
: > "$log"
say "G3 exit run, $(date -u +%Y-%m-%dT%H:%M:%SZ), at $(git -C "$repo" rev-parse --abbrev-ref HEAD) $(git -C "$repo" rev-parse --short HEAD)"
[[ -x $app ]] || fail "no app bundle: run make app"
bash "$repo/dev/g3/exit/servers.sh" preflight | tee -a "$log"
password=$(security find-generic-password -s mactak-exit -a exit -w)
swiftc -O "$repo/dev/g3/test/exit-capture.swift" -o "$capture"

# 2. a clean start
rm -rf "${work:?}"
mkdir -p "$work"
docker cp -q "$ots_container:/app/ots/ca/truststore-root.p12" "$work/ca.p12"
ca_password=$(docker exec "$ots_container" sh -c 'sed -n "s/^OTS_CA_PASSWORD: *//p" /app/ots/config.yml')
[[ -n $ca_password ]] || fail "OpenTAKServer's config names no CA password"
for me in a b; do
    write_script "$me" run "$work/ca.p12" "$ca_password"
    write_script "$me" cleanup "$work/ca.p12" "$ca_password"
done
cleanup
for suite in "${suites[@]}"; do
    defaults delete "$suite" >/dev/null 2>&1 || true
    rm -f "$support/chat-$suite.sqlite"{,-shm,-wal} "$support/statesaver-$suite.sqlite"{,-shm,-wal}
done
say "clean start: earlier exit servers and certificates removed, both suites' settings, chats and map items deleted"

# 3. both copies
launch mactak-exit-a "$work/run-a.json" "$password"
launch mactak-exit-b "$work/run-b.json" "$password"
unset password
pid_of() { if [[ $1 == a ]]; then echo "${pids[0]}"; else echo "${pids[1]}"; fi; }
waited=0
until [[ -f $work/run-report-a.json && -f $work/run-report-b.json ]]; do
    ((waited < report_timeout)) || fail "no reports after ${report_timeout} s"
    for me in a b; do kill -0 "$(pid_of "$me")" 2>/dev/null || fail "copy $me quit (see $work/run-$me.log)"; done
    sleep 1
    waited=$((waited + 1))
done
say "both copies reported after ${waited} s"

# 4. the reports
python3 -I - "$work" <<'PY' | tee -a "$log"
import json, sys
work = sys.argv[1]
r = {me: json.load(open(f"{work}/run-report-{me}.json")) for me in "ab"}
dropped = {"a": (37.795, -122.445, "R 1"), "b": (37.805, -122.435, "B 1")}
problems = []
for me, peer in (("a", "b"), ("b", "a")):
    mine, theirs = r[me], r[peer]
    def need(ok, what):
        if not ok: problems.append(f"copy {me}: {what}")
    need(mine["passed"], f"didn't pass: {mine.get('failure')}")
    p = mine.get("peer") or {}
    need(p.get("uid") == theirs["uid"], "the peer isn't the other copy")
    need(p.get("viaServer") is True and p.get("viaMesh") is False, f"heard the peer through {p}")
    m = mine.get("peerMarker") or {}
    lat, lon, label = dropped[peer]
    need(m.get("author") == theirs["uid"], "the point isn't the other copy's")
    need(abs(m.get("lat", 0) - lat) < 1e-6 and abs(m.get("lon", 0) - lon) < 1e-6, f"the point is at {m}")
    need(m.get("label") == label, f"the point is named {m.get('label')}, not {label} (left from an earlier run?)")
    texts = sorted(c["text"] for c in mine.get("chats", []))
    need(texts == sorted([f"all from EXIT-{peer.upper()}", f"direct from EXIT-{peer.upper()}"]), f"chats {texts}")
    need(mine.get("receipts") == {"delivered": True, "read": True}, f"receipts {mine.get('receipts')}")
    took = mine["steps"][-1]["at"] if mine["steps"] else -1
    print(f"[g3-exit] copy {me} ({mine['callsign']}): enrolled, heard {p.get('callsign')} through the server, "
          f"its point {m.get('label')}, {len(texts)} chats, both receipts; {took:.1f} s")
if problems:
    print("[g3-exit] FAIL: " + "; ".join(problems))
    sys.exit(1)
PY

# 5. on screen
sleep "$settle"
for me in a b; do
    window=$("$capture" window "$(pid_of "$me")") || fail "no window for copy $me (Screen Recording?)"
    screencapture -x -o -l "$window" "$work/window-$me.png" || fail "couldn't capture copy $me's window"
done
dot() {   # copy, colour, what
    local result pixels box
    result=$("$capture" count "$work/window-$1.png" "$2" "$tolerance")
    pixels=${result#pixels=}; pixels=${pixels%% *}
    box=${result#*box=}
    printf '[g3-exit] copy %s, %s (%s): %s\n' "$1" "$3" "$2" "$result" | tee -a "$log" >&2
    printf '%s %s' "$pixels" "$box"
}
for me in a b; do
    # A drops red, B blue (write_script)
    if [[ $me == a ]]; then peer_colour=0000FF; else peer_colour=FF0000; fi
    read -r pixels box <<< "$(dot "$me" "$peer_colour" "the other copy's dot")"
    ((pixels >= dot_min && pixels <= dot_max)) || fail "copy $me's window has $pixels pixels of the other copy's colour"
    ((${box%x*} <= dot_box && ${box#*x} <= dot_box)) || fail "copy $me's $box patch of the other copy's colour isn't one dot"
    read -r pixels _ <<< "$(dot "$me" "$absent_colour" "a colour nobody dropped")"
    ((pixels == 0)) || fail "copy $me's window has $pixels pixels of a colour nobody dropped"
done
say "each window shows the other copy's point"

# 6. tidy-up
stop_copies
say "both copies quit"
cleanup
python3 -I - "$work" <<'PY' | tee -a "$log"
import json, sys
work = sys.argv[1]
enrolled = set()
for me in "ab":
    run = json.load(open(f"{work}/run-report-{me}.json"))
    enrolled |= {run.get("identity"), run.get("truststore")} - {None}
removed = set()
for me in "ab":
    removed |= set(json.load(open(f"{work}/cleanup-report-{me}.json"))["removed"])
left = enrolled - removed
if left:
    print(f"[g3-exit] FAIL: left in the Keychain: {sorted(left)}")
    sys.exit(1)
print(f"[g3-exit] the cleanup removed all {len(enrolled)} Keychain items the run made")
PY
say "PASS: two copies, over TLS with Keychain certificates, through OpenTAKServer: each sees the other's contact, its point on screen, and its chats"
