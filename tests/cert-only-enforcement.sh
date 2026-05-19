#!/bin/bash
# tests/cert-only-enforcement.sh
#
# Regression test: verify that the Forgejo git SSH port rejects raw key authentication
# unconditionally, and that the audit log records result=denied:cert_required.
#
# Usage:
#   ./tests/cert-only-enforcement.sh <ip>              # auto-reads known_hosts.deploy
#   ./tests/cert-only-enforcement.sh <ip> <known_hosts_file>
#
# Exit codes:
#   0  pass — raw key was denied AND audit log shows cert_required
#   1  fail — raw key was accepted (critical regression) or audit log shows wrong result
#   2  error — cannot connect to host or ssh config issue
set -euo pipefail

IP="${1:?Usage: $0 <ip> [known_hosts_file]}"
KNOWN_HOSTS="${2:-$(dirname "$0")/../known_hosts.deploy}"

# ── Helpers ────────────────────────────────────────────────────────────────────

pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*" >&2; }
info() { printf '     %s\n' "$*"; }

TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

# ── Generate a throw-away key (never registered in Forgejo) ───────────────────
RAW_KEY="$TMPDIR_LOCAL/test_raw_key"
ssh-keygen -t ed25519 -N "" -f "$RAW_KEY" -q
info "Generated ephemeral test key: $(ssh-keygen -l -f "$RAW_KEY" | awk '{print $2}')"

# ── Common SSH options ─────────────────────────────────────────────────────────
SSH_OPTS=(
    -i "$RAW_KEY"
    -o IdentitiesOnly=yes
    -o CertificateFile=none
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o StrictHostKeyChecking=yes
    -p 2222
)
if [[ -f "$KNOWN_HOSTS" ]]; then
    SSH_OPTS+=(-o "UserKnownHostsFile=$KNOWN_HOSTS")
else
    SSH_OPTS+=(-o StrictHostKeyChecking=no)
    info "known_hosts.deploy not found — skipping host key verification"
fi

# ── Test 1: raw key must be rejected ──────────────────────────────────────────
info "Test 1: raw key auth on port 2222 must be denied..."
AUTH_RESULT="$(ssh "${SSH_OPTS[@]}" "git@$IP" 2>&1 || true)"

if echo "$AUTH_RESULT" | grep -qiE 'Permission denied|publickey'; then
    pass "Test 1: raw key auth denied by sshd"
else
    fail "Test 1: raw key auth may have succeeded — unexpected output:"
    info "$AUTH_RESULT"
    exit 1
fi

# ── Test 2: audit log must show cert_required ──────────────────────────────────
info "Test 2: forgejo-auth audit log must record result=denied:cert_required..."
AUDIT="$(ssh \
    -o StrictHostKeyChecking=yes \
    -o "UserKnownHostsFile=$KNOWN_HOSTS" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "deploy@$IP" \
    'sudo journalctl -t forgejo-auth -n 20 --no-pager --output=cat 2>/dev/null' 2>&1 || true)"

if echo "$AUDIT" | grep -q 'result=denied:cert_required'; then
    pass "Test 2: audit log contains result=denied:cert_required"
else
    fail "Test 2: result=denied:cert_required not found in last 20 forgejo-auth log entries"
    info "Last 20 forgejo-auth entries:"
    echo "$AUDIT" | tail -20 | sed 's/^/       /'
    exit 1
fi

echo
pass "All cert-only enforcement tests passed."
