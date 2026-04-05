#!/bin/bash
# UniFi API authentication library — sourced by other scripts
# Usage: source scripts/unifi_auth.sh && unifi_init
#
# Credentials: set env vars, or create ~/.unifi_credentials:
#   UNIFI_HOST=192.168.1.1
#   UNIFI_USER=admin
#   UNIFI_PASS=yourpassword

UNIFI_COOKIE_FILE="/tmp/unifi_cookies_$$.txt"
UNIFI_HEADERS_FILE="/tmp/unifi_headers_$$.txt"
UNIFI_CSRF=""

# Load credentials: env vars > ~/.unifi_credentials > error
if [[ -z "${UNIFI_PASS:-}" && -f "$HOME/.unifi_credentials" ]]; then
    source "$HOME/.unifi_credentials"
fi
UNIFI_HOST="${UNIFI_HOST:-192.168.1.1}"
UNIFI_USER="${UNIFI_USER:-admin}"
UNIFI_BASE="https://${UNIFI_HOST}/proxy/network/api/s/default"
UNIFI_BASE_V2="https://${UNIFI_HOST}/proxy/network/v2/api/site/default"
if [[ -z "${UNIFI_PASS:-}" ]]; then
    echo "ERROR: UNIFI_PASS not set. Export it or create ~/.unifi_credentials" >&2
    return 1 2>/dev/null || exit 1
fi

_unifi_cleanup() {
    rm -f "$UNIFI_COOKIE_FILE" "$UNIFI_HEADERS_FILE"
}

validate_mac() {
    if ! [[ "$1" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
        echo "ERROR: Invalid MAC address format: $1" >&2
        return 1
    fi
}

normalize_mac() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

unifi_login() {
    local http_code

    if ! http_code=$(curl -sk -w '%{http_code}' -X POST "https://${UNIFI_HOST}/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${UNIFI_USER}\",\"password\":\"${UNIFI_PASS}\"}" \
        -c "$UNIFI_COOKIE_FILE" \
        -D "$UNIFI_HEADERS_FILE" \
        -o /dev/null 2>/dev/null); then
        echo "ERROR: Cannot reach controller at ${UNIFI_HOST}" >&2
        return 1
    fi

    if [[ "$http_code" != "200" ]]; then
        echo "ERROR: Login failed (HTTP ${http_code})" >&2
        return 1
    fi

    # Extract CSRF from TOKEN cookie JWT payload
    local token payload pad
    token=$(grep -i 'TOKEN' "$UNIFI_COOKIE_FILE" | awk '{print $NF}')
    if [[ -n "$token" ]]; then
        payload=$(echo "$token" | cut -d. -f2)
        pad=$(( 4 - ${#payload} % 4 ))
        if [[ $pad -lt 4 ]]; then
            for ((i=0; i<pad; i++)); do payload="${payload}="; done
        fi
        UNIFI_CSRF=$(echo "$payload" | base64 -d 2>/dev/null | jq -r '.csrfToken // empty')
    fi

    rm -f "$UNIFI_HEADERS_FILE"

    if [[ -z "$UNIFI_CSRF" ]]; then
        echo "ERROR: Login failed — no CSRF token extracted" >&2
        return 1
    fi
}

# Shared HTTP request handler — reduces get/post/put to thin wrappers
_unifi_request() {
    local method="$1" path="$2" data="${3:-}"
    local curl_args=(-sk -w '\n%{http_code}' -b "$UNIFI_COOKIE_FILE"
        -H "X-Csrf-Token: ${UNIFI_CSRF}")

    if [[ "$method" != "GET" ]]; then
        curl_args+=(-X "$method" -H "Content-Type: application/json" -d "$data")
    fi

    local response http_code body
    response=$(curl "${curl_args[@]}" "${UNIFI_BASE}/${path}" 2>/dev/null)
    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [[ "$http_code" != "200" ]]; then
        echo "{\"error\": \"HTTP ${http_code} on ${method} ${path}\"}" >&2
        return 1
    fi
    echo "$body"
}

unifi_get()  { _unifi_request GET  "$1"; }
unifi_post() { _unifi_request POST "$1" "$2"; }
unifi_put()  { _unifi_request PUT  "$1" "$2"; }

# v2 API — uses /v2/api/site/{site}/ base path
_unifi_request_v2() {
    local method="$1" path="$2" data="${3:-}"
    local curl_args=(-sk -w '\n%{http_code}' -b "$UNIFI_COOKIE_FILE"
        -H "X-Csrf-Token: ${UNIFI_CSRF}")

    if [[ "$method" != "GET" ]]; then
        curl_args+=(-X "$method" -H "Content-Type: application/json" -d "$data")
    fi

    local response http_code body
    response=$(curl "${curl_args[@]}" "${UNIFI_BASE_V2}/${path}" 2>/dev/null)
    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [[ "$http_code" != "200" ]]; then
        echo "{\"error\": \"HTTP ${http_code} on ${method} v2/${path}\"}" >&2
        return 1
    fi
    echo "$body"
}

unifi_get_v2()  { _unifi_request_v2 GET  "$1"; }
unifi_post_v2() { _unifi_request_v2 POST "$1" "$2"; }

unifi_logout() {
    curl -sk -X POST "https://${UNIFI_HOST}/api/auth/logout" \
        -b "$UNIFI_COOKIE_FILE" -o /dev/null 2>/dev/null
    rm -f "$UNIFI_COOKIE_FILE"
}

# Convenience: trap + login in one call for consumer scripts
unifi_init() {
    trap _unifi_cleanup EXIT
    unifi_login || exit 1
}
