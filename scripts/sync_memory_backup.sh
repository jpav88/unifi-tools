#!/bin/bash
set -euo pipefail
# Mirror this project's Claude auto-memory into the repo so it rides along to GitHub.
#
# Usage: bash scripts/sync_memory_backup.sh   (run by /checkpoint before staging)
#
# WHY: the memory dir lives outside the repo (~/.claude/projects/<sanitized-cwd>/memory/),
# so it is NOT covered by any commit — a machine loss takes it with it.
#
# ⚠️  memory-backup/ IS A MIRROR — never hand-edit it. Edit the real memory files under
#     ~/.claude/projects/.../memory/ and re-run this script; --delete will overwrite you.
#
# ⚠️  PRIVATE ONLY. These files contain device MACs, LAN + WAN IPs, family names and the
#     room-by-room house layout. jpav88/unifi is private; the public mirror (unifi-tools)
#     excludes this directory explicitly in pgit_publish.sh. If that exclusion is ever
#     removed, pgit's scrubber will NOT catch most of this — it only rewrites SSIDs,
#     the UDM/syslog-host hostnames and one personal name.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${ROOT}/memory-backup"

# Claude Code derives the memory dir from the project path with '/' -> '-'
SANITIZED="$(printf '%s' "$ROOT" | tr '/' '-')"
SRC="${HOME}/.claude/projects/${SANITIZED}/memory"

if [[ ! -d "$SRC" ]]; then
    echo "No auto-memory dir at $SRC — nothing to back up."
    exit 0
fi

mkdir -p "$DEST"

# --delete so deletions/renames in memory are reflected, not accumulated forever.
# Only .md is mirrored: memory is markdown, and this refuses to sweep up anything else.
rsync -a --delete --prune-empty-dirs \
    --include='*/' --include='*.md' --exclude='*' \
    "${SRC}/" "${DEST}/"

cat > "${DEST}/README.md" <<'EOF'
# memory-backup — GENERATED MIRROR, DO NOT EDIT

Mirror of this project's Claude Code auto-memory
(`~/.claude/projects/-Users-pavdog-Programming-pavdog-unifi/memory/`), copied here by
`scripts/sync_memory_backup.sh` so it is version-controlled and survives a machine loss.

- **Never hand-edit these files.** Edit the originals under `~/.claude/projects/.../memory/`
  and re-run the script — it syncs with `--delete` and will overwrite local changes.
- **Never publish this directory.** It contains device MACs, LAN and WAN IPs, family names
  and the house layout. `pgit_publish.sh` excludes `memory-backup/` explicitly; its scrubber
  would not catch most of this content.
EOF

count=$(find "$DEST" -name '*.md' -type f | wc -l | tr -d ' ')
echo "Mirrored ${count} memory file(s) -> memory-backup/"
