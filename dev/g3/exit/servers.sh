#!/usr/bin/env bash
#
# The G3 exit run's server (dev/g3/NOTES.md §The G3 exit, PR a):
# OpenTAKServer as a compose project (dev/g3/exit/ots/compose.yml) in
# VMPal's container engine on the dev Mac.
#
#   servers.sh up         start it, make the exit users, and run the preflight
#   servers.sh preflight  check it is ready for the exit run
#   servers.sh stop       stop it, keeping its data
#   servers.sh reset      remove it and its data (a new CA next time)
#
# The engine is reached through VMPal's own socket (MACTAK_EXIT_DOCKER_HOST
# to use another), so the user's docker context is never changed.
#
# The exit users (exit_a, exit_b) and OpenTAKServer's administrator share
# one password, made the first time and kept in the login Keychain as the
# generic password `mactak-exit` (account `exit`). It is passed to the
# container in its environment and never printed.
#
# The preflight passes when every service runs, 8089, 8443 and 8446 answer
# with the server's certificate, a test enrollment as exit_a on 8446 signs
# a certificate under the server's CA, and that certificate opens a TLS
# session on the CoT port 8089. It writes the versions it ran against to
# dev/g3/build/exit-servers.txt.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
compose_file="$here/ots/compose.yml"
report="$repo/dev/g3/build/exit-servers.txt"

export DOCKER_HOST="${MACTAK_EXIT_DOCKER_HOST:-unix://$HOME/.vmpal/docker.sock}"

readonly keychain_service=mactak-exit
readonly keychain_account=exit
readonly exit_users=(exit_a exit_b)
readonly default_admin_password=password
readonly ots_container=mactak-exit-ots
readonly services=(mactak-exit-ots mactak-exit-ots-cot-parser mactak-exit-ots-eud-ssl
                   mactak-exit-ots-nginx mactak-exit-ots-rabbitmq mactak-exit-ots-db)
readonly tls_ports=(8089 8443 8446)
readonly host=127.0.0.1
readonly enrollment_port=8446
readonly cot_port=8089

say() { printf '[exit-servers] %s\n' "$*"; }
fail() { printf '[exit-servers] FAIL: %s\n' "$*" >&2; exit 1; }

compose() { docker compose -f "$compose_file" "$@"; }

require_engine() {
    command -v docker >/dev/null || fail "docker isn't installed (it drives VMPal's engine)"
    docker info >/dev/null 2>&1 \
        || fail "VMPal's container engine doesn't answer at $DOCKER_HOST: turn Containers on in VMPal › Settings › Containers"
}

# The shared password, made on first use.
exit_password() {
    if ! security find-generic-password -s "$keychain_service" -a "$keychain_account" >/dev/null 2>&1; then
        security add-generic-password -s "$keychain_service" -a "$keychain_account" \
            -l "macTAK exit run server" -w "$(openssl rand -base64 18 | tr -d '/+=')"
        say "made the exit password (login Keychain: $keychain_service)" >&2
    fi
    security find-generic-password -s "$keychain_service" -a "$keychain_account" -w
}

# Runs a shell script in the OpenTAKServer container, with PW (the exit
# password) and U (a user, or empty) in its environment; the script talks
# to OpenTAKServer's own API on its loopback port, 8081. Scripts are
# single-quoted on purpose: they expand in the container.
in_ots() { docker exec -e PW="$1" -e U="$2" "$ots_container" sh -c "$3"; }

# The administrator's password moves from OpenTAKServer's default to the
# exit password the first time; after that the default no longer logs in.
secure_admin() {
    local password=$1
    local status
    status=$(docker exec -e DEFAULT="$default_admin_password" "$ots_container" sh -c '
        curl -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" \
            -d "{\"username\":\"administrator\",\"password\":\"$DEFAULT\"}" http://localhost:8081/api/login')
    [[ $status == 200 ]] || return 0
    # shellcheck disable=SC2016
    in_ots "$password" "" 'cd /app/venv/lib/python3.*/site-packages/opentakserver &&
        flask --app app.py users change_password administrator --password "$PW" >/dev/null 2>&1' \
        || fail "couldn't change the administrator's default password"
    say "changed the administrator's default password to the exit password"
}

# Adds each exit user that isn't there yet, logged in as the administrator.
make_users() {
    local password=$1 user answer
    for user in "${exit_users[@]}"; do
        # shellcheck disable=SC2016
        answer=$(in_ots "$password" "$user" '
            c=$(mktemp); trap "rm -f $c" EXIT
            curl -s -c "$c" -b "$c" -o /dev/null -H "Content-Type: application/json" \
                -d "{\"username\":\"administrator\",\"password\":\"$PW\"}" \
                http://localhost:8081/api/login
            curl -s -c "$c" -b "$c" -H "Content-Type: application/json" \
                -d "{\"username\":\"$U\",\"password\":\"$PW\",\"confirm_password\":\"$PW\",\"roles\":[\"user\"]}" \
                http://localhost:8081/api/user/add')
        case $answer in
            *'"success":true'*) say "made user $user" ;;
            *'already exists'*) say "user $user is there" ;;
            *) fail "couldn't make user $user: $answer" ;;
        esac
    done
}

check_services() {
    local name state
    for name in "${services[@]}"; do
        state=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
            "$name" 2>/dev/null) || fail "$name doesn't exist: run servers.sh up"
        [[ $state == running* ]] || fail "$name is $state"
        [[ $state != *unhealthy* ]] || fail "$name is unhealthy"
    done
    say "all ${#services[@]} services run"
}

# The server certificate on each port, checked against the CA it gives.
check_ports() {
    local ca=$1 port
    for port in "${tls_ports[@]}"; do
        echo | openssl s_client -connect "$host:$port" -CAfile "$ca" -verify_return_error \
            >/dev/null 2>&1 || fail "port $port doesn't answer with a certificate under the server's CA"
    done
    say "ports ${tls_ports[*]} answer with the server's certificate"
}

# A test enrollment as exit_a, then that certificate on the CoT port.
check_enrollment() {
    local password=$1 work=$2
    local csr_body
    openssl req -new -newkey rsa:2048 -nodes -keyout "$work/client.key" \
        -subj "/CN=${exit_users[0]}" -out "$work/client.csr" 2>/dev/null
    csr_body=$(sed '1d;$d' "$work/client.csr" | tr -d '\n')
    curl -sk --fail -u "${exit_users[0]}:$password" -H 'Content-Type: text/plain' \
        --data-binary "$csr_body" -o "$work/enrolled.json" \
        "https://$host:$enrollment_port/Marti/api/tls/signClient/v2?clientUid=mactak-exit-preflight&version=5.5" \
        || fail "enrollment as ${exit_users[0]} on $enrollment_port was refused"
    python3 -I - "$work" <<'PY' || fail "the enrollment answer has no signed certificate and CA"
import json, sys, textwrap
work = sys.argv[1]
answer = json.load(open(f"{work}/enrolled.json"))
def pem(body):
    return "-----BEGIN CERTIFICATE-----\n" + "\n".join(textwrap.wrap(body, 64)) + "\n-----END CERTIFICATE-----\n"
open(f"{work}/client.pem", "w").write(pem(answer["signedCert"]))
open(f"{work}/ca.pem", "w").write("".join(pem(v) for k, v in sorted(answer.items()) if k.startswith("ca")))
PY
    openssl verify -CAfile "$work/ca.pem" "$work/client.pem" >/dev/null \
        || fail "the enrolled certificate isn't signed by the server's CA"
    say "a test enrollment as ${exit_users[0]} signs a certificate under the server's CA"
    check_ports "$work/ca.pem"
    echo | openssl s_client -connect "$host:$cot_port" -CAfile "$work/ca.pem" -verify_return_error \
        -cert "$work/client.pem" -key "$work/client.key" >/dev/null 2>&1 \
        || fail "the enrolled certificate doesn't open a TLS session on $cot_port"
    say "the enrolled certificate opens a TLS session on $cot_port"
}

record_versions() {
    mkdir -p "$(dirname "$report")"
    {
        printf 'exit servers, %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'OpenTAKServer package: %s\n' \
            "$(docker exec "$ots_container" sh -c 'pip show opentakserver 2>/dev/null' | sed -n 's/^Version: //p')"
        local name
        for name in "${services[@]}"; do
            printf '%s: %s\n' "$name" "$(docker inspect -f '{{.Config.Image}}' "$name")"
        done
    } > "$report"
    say "versions written to ${report#"$repo"/}"
}

preflight() {
    require_engine
    check_services
    local password
    password=$(exit_password)
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    check_enrollment "$password" "$work"
    record_versions
    say "PASS: OpenTAKServer is ready for the exit run"
}

up() {
    require_engine
    local log
    log=$(mktemp)
    compose up -d --wait --wait-timeout 300 >"$log" 2>&1 \
        || { cat "$log" >&2; rm -f "$log"; fail "OpenTAKServer didn't come up"; }
    rm -f "$log"
    say "OpenTAKServer is up"
    local password
    password=$(exit_password)
    secure_admin "$password"
    make_users "$password"
    preflight
}

case "${1:-}" in
    up) up ;;
    preflight) preflight ;;
    stop) require_engine; compose stop 2>/dev/null; say "stopped; the data is kept" ;;
    reset) require_engine; compose down -v 2>/dev/null; say "removed, with its data" ;;
    *) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
