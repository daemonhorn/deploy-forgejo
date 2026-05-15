#!/usr/bin/env bash
# daily-export.sh — Export all Forgejo repositories to a timestamped archive.
#
# Invoked by cron twice daily (see crontab.example).  Writes one archive per
# run, then prunes old archives so the backup directory doesn't grow unbounded.
#
# The archive is a zstd-compressed tar of bare git bundles — one bundle per
# repository, laid out as <owner>/<repo>.bundle inside the tar.  Restore with:
#   tar -xf forgejo-YYYYMMDD-HHMM.tar.zst
#   git clone path/to/<owner>/<repo>.bundle  destination/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root

# Where to write archives.  Override with FORGEJO_BACKUP_DIR= in the environment
# or in crontab.example.
BACKUP_DIR="${FORGEJO_BACKUP_DIR:-/var/backups/forgejo}"

# Number of archives to retain.  At twice-daily cadence, 14 = 7 days.
# Increase for longer retention; be mindful of disk space (each archive is
# roughly proportional to your total repository size).
KEEP=14

log() { echo "[$(date -u +%FT%TZ)] $*"; }

mkdir -p "$BACKUP_DIR"

ARCHIVE="$BACKUP_DIR/forgejo-$(date -u +%Y%m%d-%H%M).tar.zst"

log "Export starting → $ARCHIVE"

# export-git.sh auto-detects the Forgejo URL from the Terraform state of the
# last-used provider (.last-provider + 'terraform output public_ipv4'), then
# SSHes as deploy@ to generate a temporary admin API token.
#
# For fully unattended operation without Terraform state on this machine, add:
#   --forgejo-url https://<ip>   --admin-token <token>
# and pre-generate a long-lived token via sign-user-key.sh or the Forgejo UI.
#
# --quiet suppresses per-repo progress lines; errors still go to stderr and
# therefore to the log file via the 2>&1 redirect in crontab.example.
"$SCRIPT_DIR/export-git.sh" \
    --output "$ARCHIVE" \
    --quiet

log "Export complete: $ARCHIVE ($(du -sh "$ARCHIVE" | cut -f1))"

# ── Prune old archives ────────────────────────────────────────────────────────
# List all matching archives, sort oldest-first by mtime, drop the newest $KEEP,
# and delete whatever remains.  'head -n -N' keeps all but the last N lines,
# meaning the first (oldest) lines are passed to xargs for deletion.
#
# This approach is more reliable than find -mtime because it counts files rather
# than estimating age — a paused or skipped cron run won't confuse retention.
TOTAL_BEFORE=$(find "$BACKUP_DIR" -maxdepth 1 -name 'forgejo-*.tar.zst' | wc -l)

find "$BACKUP_DIR" -maxdepth 1 -name 'forgejo-*.tar.zst' -printf '%T@ %p\n' \
    | sort -n \
    | head -n -"$KEEP" \
    | awk '{print $2}' \
    | xargs -r rm -f

TOTAL_AFTER=$(find "$BACKUP_DIR" -maxdepth 1 -name 'forgejo-*.tar.zst' | wc -l)
PRUNED=$(( TOTAL_BEFORE - TOTAL_AFTER ))

log "Retention: kept $TOTAL_AFTER archive(s), pruned $PRUNED (limit: $KEEP)."
