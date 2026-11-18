#!/usr/bin/env bash
# Runtime acceptance checks for the nginx mainline migration, split into
# command modes so readiness probing stays outside this script (the caller
# probes the container with its own readiness mechanism between modes and no
# sleeping loops are executed here).
#
# Usage:
#   check-nginx-migration.sh start   IMAGE CONTAINER CONFIG_DIR [SUBFOLDER]
#       Boot a throwaway container with a private config bind-mount, dummy
#       basic-auth credentials, and a probe file for the file-manager checks.
#       SUBFOLDER is optional (default "/"); pass e.g. "/desktop/" or
#       "/desktop" to exercise a non-root subfolder deployment.
#   check-nginx-migration.sh check   CONTAINER CONFIG_DIR [SUBFOLDER]
#       Run every acceptance assertion once against the running container.
#       Call only after the container reports ready; all commands here are
#       single-shot.
#   check-nginx-migration.sh restart CONTAINER
#       Restart the container once (the caller re-probes readiness after).
#   check-nginx-migration.sh cleanup CONTAINER CONFIG_DIR
#       Remove the throwaway container and the config directory it owns.
set -euo pipefail

MIN_RELEASE="${MIN_RELEASE:-1.31.9}"
CHECK_USER="abc"
CHECK_PASSWORD="dcs-nginx-check-password"

fail() { echo "CHECK FAILED: $*" >&2; exit 1; }
pass() { echo "CHECK OK: $*"; }

# Normalize SUBFOLDER the same way the guard does: exactly one leading and
# one trailing slash.
normalize_subfolder() {
    local sub="${1:-/}"
    sub="${sub#/}"
    sub="${sub#/}"
    sub="${sub%/}"
    sub="${sub%/}"
    if [ -z "${sub}" ]; then
        printf '/'
    else
        printf '/%s/' "${sub}"
    fi
}

mode="${1:?usage: check-nginx-migration.sh start|check|restart|cleanup ...}"
case "${mode}" in
    start)
        IMAGE="${2:?IMAGE required}"
        CONTAINER="${3:?CONTAINER required}"
        CONFIG_DIR="${4:?CONFIG_DIR required}"
        SUB="${5:-/}"
        mkdir -p "${CONFIG_DIR}/Desktop"
        printf 'dcs nginx mainline migration probe payload\n' > "${CONFIG_DIR}/Desktop/migration-probe.txt"
        docker run -d --name "${CONTAINER}" \
            -v "${CONFIG_DIR}:/config" \
            -e "PASSWORD=${CHECK_PASSWORD}" \
            -e "SUBFOLDER=${SUB}" \
            "${IMAGE}" >/dev/null
        echo "started ${CONTAINER} with config ${CONFIG_DIR} subfolder ${SUB}"
        ;;
    check)
        CONTAINER="${2:?CONTAINER required}"
        CONFIG_DIR="${3:?CONFIG_DIR required}"
        SUB="$(normalize_subfolder "${4:-/}")"
        PREFIX="${SUB}"
        ex() { docker exec "${CONTAINER}" "$@"; }

        ex wget -q -O /dev/null \
            --http-user="${CHECK_USER}" --http-password="${CHECK_PASSWORD}" \
            "http://127.0.0.1:3000${PREFIX}" || fail "nginx not serving the webtop UI under ${PREFIX}"
        pass "nginx serves the webtop UI under ${PREFIX}"

        NGINX_VERSION="$(ex dpkg-query -W -f '${Version}' nginx)"
        NGINX_RELEASE="${NGINX_VERSION%%-*}"
        case "${NGINX_RELEASE}" in
            [0-9]*.[0-9]*.[0-9]*) ;;
            *) fail "unexpected nginx version string: ${NGINX_VERSION}" ;;
        esac
        OLDEST="$(printf '%s\n%s\n' "${MIN_RELEASE}" "${NGINX_RELEASE}" | sort -V | head -n1)"
        [ "${OLDEST}" = "${MIN_RELEASE}" ] \
            || fail "nginx ${NGINX_RELEASE} is older than accepted minimum ${MIN_RELEASE}"
        ex nginx -v 2>&1 | grep -F "nginx/${NGINX_RELEASE}" >/dev/null \
            || fail "nginx binary does not match the installed package version"
        pass "nginx ${NGINX_VERSION} installed and binary matches (>= ${MIN_RELEASE})"

        if ex sh -c 'dpkg -l nginx-common 2>/dev/null | grep -q "^ii"'; then
            fail "Debian nginx-common is still installed"
        fi
        pass "Debian nginx packages migrated out"

        ex test -s /usr/lib/nginx/modules/ngx_http_fancyindex_module.so \
            || fail "fancyindex module file missing"
        ex /bin/bash -c '
            printf "load_module /usr/lib/nginx/modules/ngx_http_fancyindex_module.so;\ndaemon off;\nevents{}\nhttp{server{listen 127.0.0.1:39999;fancyindex on;}}" \
                > /tmp/fancyindex-check.conf
            /usr/sbin/nginx -t -c /tmp/fancyindex-check.conf -p /tmp -e /tmp/fancyindex-check.log \
                >/dev/null 2>&1
            rc=$?
            rm -f /tmp/fancyindex-check.conf /tmp/fancyindex-check.log
            exit $rc
        ' || fail "nginx rejected the fancyindex directive (module ABI mismatch)"
        pass "fancyindex module present and directive accepted"

        EFFECTIVE="$(ex /usr/sbin/nginx -T 2>/dev/null)"
        [ -n "${EFFECTIVE}" ] || fail "nginx -T produced no effective configuration"
        echo "${EFFECTIVE}" | grep -Eq '^[[:space:]]*http2[[:space:]]+off[[:space:]]*;' \
            || fail "http2 off missing from effective configuration"
        echo "${EFFECTIVE}" | grep -Eq 'listen[^#;]*\bhttp2\b' \
            && fail "a listen line still carries an http2 flag"
        echo "${EFFECTIVE}" | grep -Eq '^[[:space:]]*http2[[:space:]]+on' \
            && fail "http2 on present in effective configuration"
        FILE_BLOCKS="$(echo "${EFFECTIVE}" | grep -cF "location ${PREFIX}files {" || true)"
        [ "${FILE_BLOCKS}" -ge 2 ] || fail "expected ${PREFIX}files in both server blocks, found ${FILE_BLOCKS}"
        echo "${EFFECTIVE}" | grep -Eq 'proxy_pass[^;]*127\.0\.0\.1:8082' \
            || fail "desktop websocket proxy to port 8082 missing"
        pass "HTTP/2 off, ${PREFIX}files in both server blocks, websocket proxy intact (effective config)"

        AUTH_ARGS=(--http-user="${CHECK_USER}" --http-password="${CHECK_PASSWORD}")
        ex wget -q -O /dev/null "http://127.0.0.1:3000${PREFIX}" 2>/dev/null \
            && fail "HTTP request without credentials unexpectedly succeeded"
        { ex wget -S -q -O /dev/null "http://127.0.0.1:3000${PREFIX}" 2>&1 || true; } \
            | grep -q "401 Unauthorized" \
            || fail "HTTP request without credentials did not return 401"
        ex wget -q -O /dev/null "${AUTH_ARGS[@]}" "http://127.0.0.1:3000${PREFIX}" \
            || fail "HTTP request with credentials failed"
        pass "HTTP basic auth enforced on port 3000"

        ex wget -q --no-check-certificate -O /dev/null "https://127.0.0.1:3001${PREFIX}" 2>/dev/null \
            && fail "HTTPS request without credentials unexpectedly succeeded"
        { ex wget -S -q --no-check-certificate -O /dev/null "https://127.0.0.1:3001${PREFIX}" 2>&1 || true; } \
            | grep -q "401 Unauthorized" \
            || fail "HTTPS request without credentials did not return 401"
        ex wget -q --no-check-certificate -O /dev/null "${AUTH_ARGS[@]}" "https://127.0.0.1:3001${PREFIX}" \
            || fail "HTTPS request with credentials failed"
        pass "HTTPS basic auth enforced on port 3001 (TLS with container certificate)"

        ex wget -q -O /dev/null "${AUTH_ARGS[@]}" "http://127.0.0.1:3000${PREFIX}nginx/header.html" \
            || fail "fancyindex header theme not served"
        ex wget -q -O /dev/null "${AUTH_ARGS[@]}" "http://127.0.0.1:3000${PREFIX}nginx/footer.html" \
            || fail "fancyindex footer theme not served"
        ex wget -q -O - "${AUTH_ARGS[@]}" "http://127.0.0.1:3000${PREFIX}nginx/header.html" \
            | grep -q "Desktop Files" \
            || fail "fancyindex header theme content unexpected"
        ex wget -q -O - "${AUTH_ARGS[@]}" "http://127.0.0.1:3000${PREFIX}nginx/footer.html" \
            | grep -qF "webPathPrefix = '${PREFIX}files/'" \
            || fail "fancyindex footer theme not rewritten for subfolder ${PREFIX}"
        pass "fancyindex theme files served and footer rewritten for ${PREFIX}"

        ex wget -q -O /dev/null "${AUTH_ARGS[@]}" "http://127.0.0.1:3000${PREFIX}files/" \
            || fail "${PREFIX}files listing did not return 200"
        ex wget -q -O - "${AUTH_ARGS[@]}" "http://127.0.0.1:3000${PREFIX}files/" \
            | grep -q "migration-probe.txt" \
            || fail "${PREFIX}files listing does not show the probe file"
        pass "${PREFIX}files directory listing renders"

        ORIG_SHA="$(ex sha256sum /config/Desktop/migration-probe.txt | awk '{print $1}')"
        DL_SHA="$(ex wget -q -O - "${AUTH_ARGS[@]}" "http://127.0.0.1:3000${PREFIX}files/migration-probe.txt" \
            | sha256sum | awk '{print $1}')"
        [ "${ORIG_SHA}" = "${DL_SHA}" ] || fail "downloaded file hash differs from original"
        DL_HEADERS="$(ex wget -S -q -O /dev/null "${AUTH_ARGS[@]}" \
            "http://127.0.0.1:3000${PREFIX}files/migration-probe.txt" 2>&1)"
        echo "${DL_HEADERS}" | grep -qi "Content-Disposition: attachment" \
            || fail "${PREFIX}files download missing attachment disposition"
        pass "${PREFIX}files download content matches probe file (sha256) with attachment disposition"

        ex env WS_CREDS="${CHECK_USER}:${CHECK_PASSWORD}" WS_PATH="${PREFIX}api/websockets" python3 -c '
import socket, base64, os
auth = base64.b64encode(os.environ["WS_CREDS"].encode()).decode()
path = os.environ["WS_PATH"]
s = socket.create_connection(("127.0.0.1", 3000), timeout=10)
req = ("GET " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\n"
       "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
       "Sec-WebSocket-Version: 13\r\nAuthorization: Basic " + auth + "\r\n\r\n")
s.sendall(req.encode())
data = s.recv(256)
s.close()
status = data.split(b"\r\n", 1)[0].decode("latin-1")
raise SystemExit(0 if " 101 " in status else 1)
' || fail "websocket upgrade handshake on ${PREFIX}api/websockets did not return 101"
        pass "desktop websocket handshake returns 101"

        echo "ALL CHECKS PASSED for ${CONTAINER} (subfolder ${PREFIX})"
        ;;
    restart)
        CONTAINER="${2:?CONTAINER required}"
        docker restart "${CONTAINER}" >/dev/null
        echo "restarted ${CONTAINER}"
        ;;
    cleanup)
        CONTAINER="${2:?CONTAINER required}"
        CONFIG_DIR="${3:?CONFIG_DIR required}"
        docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
        rm -rf "${CONFIG_DIR}" 2>/dev/null || true
        echo "cleaned up ${CONTAINER} and ${CONFIG_DIR}"
        ;;
    *)
        fail "unknown mode: ${mode}" ;;
esac
