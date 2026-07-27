#!/bin/bash
set -euo pipefail
# Create, list, and download UniFi controller config backups to local disk.
# UniFi auto-backups live ON the gateway — if the device fails, they fail with it.
# This pulls a copy off-box so a real, restorable backup exists elsewhere.
#
# Usage:
#   ./unifi_backup.sh --list                 List backups stored on the controller
#   ./unifi_backup.sh --create [keep]        Create a fresh backup, download it, keep newest `keep` local copies (default 10)
#   ./unifi_backup.sh --download <filename>  Download a specific existing backup by filename
#
# Local backups are saved to: <repo>/backups/  (gitignored — contains full config/PII)
#
# Examples:
#   ./unifi_backup.sh --list
#   ./unifi_backup.sh --create
#   ./unifi_backup.sh --create 5
#   ./unifi_backup.sh --download autobackup_10.5.61_20260714_1400_1784037600015.unf
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/unifi_auth.sh"

BACKUP_DIR="$SCRIPT_DIR/../backups"
KEEP_DEFAULT=10

CMD="${1:-}"

usage() {
    echo "Usage: $0 <--list | --create [keep] | --download <filename>>" >&2
    echo "  --list                 List backups on the controller" >&2
    echo "  --create [keep]        Create + download a backup, keep newest [keep] local copies (default ${KEEP_DEFAULT})" >&2
    echo "  --download <filename>  Download a specific existing backup" >&2
    exit 1
}

# Download a network-app path (e.g. /dl/backup/x.unf) to a local file using the auth cookie.
# The download endpoints live under the /proxy/network app root, not the UniFi OS root —
# hitting the OS root silently returns the SPA HTML shell with HTTP 200, so we guard for that.
_download() {
    local url_path="$1" dest="$2" http_code
    http_code=$(curl -sk -w '%{http_code}' -b "$UNIFI_COOKIE_FILE" \
        "https://${UNIFI_HOST}/proxy/network${url_path}" -o "$dest" 2>/dev/null)
    if [[ "$http_code" != "200" ]]; then
        echo "ERROR: download failed (HTTP ${http_code}) for ${url_path}" >&2
        rm -f "$dest"
        return 1
    fi
    # A backup is opaque binary; an HTML doctype means we got an error/login page instead.
    if head -c 15 "$dest" | grep -qi '<!doctype\|<html'; then
        echo "ERROR: got an HTML page, not a backup, for ${url_path} (auth or path issue)" >&2
        rm -f "$dest"
        return 1
    fi
}

# Keep only the newest N .unf files in BACKUP_DIR, delete the rest.
_prune() {
    local keep="$1" f
    # shellcheck disable=SC2012
    ls -1t "$BACKUP_DIR"/*.unf 2>/dev/null | tail -n "+$((keep + 1))" | while read -r f; do
        echo "Pruning old local backup: $(basename "$f")"
        rm -f "$f"
    done
}

case "$CMD" in
    --list)
        unifi_init
        unifi_post "cmd/backup" '{"cmd":"list-backups"}' | jq -r '
            if (.data | length) == 0 then "No backups on the controller."
            else (.data | sort_by(.time) | .[] |
                "\(.datetime)  v\(.version)  \(.type)  \((.size / 1024 | floor))KB  \(.filename)")
            end'
        unifi_logout
        ;;

    --create)
        KEEP="${2:-$KEEP_DEFAULT}"
        if ! [[ "$KEEP" =~ ^[0-9]+$ ]]; then
            echo "ERROR: keep count must be a number" >&2
            exit 1
        fi
        mkdir -p "$BACKUP_DIR"
        unifi_init

        echo "Requesting a fresh backup from the controller..."
        RESP=$(unifi_post "cmd/backup" '{"cmd":"backup","days":0}')
        URL_PATH=$(echo "$RESP" | jq -r '.data[0].url // empty')
        if [[ -z "$URL_PATH" ]]; then
            echo "ERROR: controller did not return a download URL:" >&2
            echo "$RESP" >&2
            unifi_logout
            exit 1
        fi

        STAMP=$(date +%Y%m%d_%H%M%S)
        DEST="$BACKUP_DIR/unifi_backup_${STAMP}.unf"
        echo "Downloading ${URL_PATH} → $(basename "$DEST")"
        if _download "$URL_PATH" "$DEST"; then
            SIZE_KB=$(( $(wc -c < "$DEST") / 1024 ))
            echo "Saved: ${DEST} (${SIZE_KB}KB)"
            _prune "$KEEP"
        else
            unifi_logout
            exit 1
        fi
        unifi_logout
        ;;

    --download)
        FILENAME="${2:-}"
        if [[ -z "$FILENAME" ]]; then
            echo "Usage: $0 --download <filename>" >&2
            exit 1
        fi
        mkdir -p "$BACKUP_DIR"
        unifi_init
        DEST="$BACKUP_DIR/${FILENAME}"
        echo "Downloading /dl/autobackup/${FILENAME} → $(basename "$DEST")"
        if ! _download "/dl/autobackup/${FILENAME}" "$DEST"; then
            # Fall back to the /dl/backup/ path (manual backups live there)
            echo "Retrying via /dl/backup/ ..."
            _download "/dl/backup/${FILENAME}" "$DEST"
        fi
        if [[ -f "$DEST" ]]; then
            SIZE_KB=$(( $(wc -c < "$DEST") / 1024 ))
            echo "Saved: ${DEST} (${SIZE_KB}KB)"
        fi
        unifi_logout
        ;;

    ""|-h|--help)
        usage
        ;;
    *)
        echo "Unknown option: $CMD" >&2
        usage
        ;;
esac
