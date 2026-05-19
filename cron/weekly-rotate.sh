#!/usr/bin/env bash
# weekly-rotate.sh — Rolling Forgejo instance rotation.
#
# Provisions a fresh cloud instance, mirrors recently-active repositories,
# verifies the new instance is reachable, then destroys the old instance.
# Invoked by cron every Sunday (see crontab.example).
#
# WORKFLOW
#   1. Record the current (about-to-be-old) workspace name and IP.
#   2. Run mirror-git.sh: provisions a new instance and syncs repos.
#   3. Identify the new workspace from the provision log.
#   4. Verify the new instance returns HTTP 200 or 302 on its HTTPS endpoint.
#   5. Destroy the old workspace — ONLY if step 4 passed.
#   6. Switch Terraform's active workspace to the new one so that subsequent
#      auto-detection in export-git.sh and sign-user-key.sh targets the right IP.
#
# FAILURE HANDLING
#   set -euo pipefail means any unexpected error aborts the script immediately.
#   The old instance is never destroyed unless step 4 explicitly succeeds.
#   .provision-log.json always records what was provisioned, so you can run
#   'provision.sh --destroy --workspace mirror-TIMESTAMP --non-interactive'
#   manually to clean up an orphaned new instance if needed.
#
# CONFIGURATION (via environment variables, set in crontab.example)
#   ROTATE_PROVIDER   Cloud provider (default: vultr)
#   ROTATE_REGION     Provider region (default: ewr)
#   ROTATE_PLAN       Instance plan   (default: vc2-1c-0.5gb)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root
cd "$SCRIPT_DIR"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

PROVIDER="${ROTATE_PROVIDER:-vultr}"
REGION="${ROTATE_REGION:-ewr}"
PLAN="${ROTATE_PLAN:-vc2-1c-0.5gb}"

TF_DIR="$SCRIPT_DIR/terraform/$PROVIDER"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug) DEBUG=1; shift ;;
        *) log "Unknown argument: $1"; exit 1 ;;
    esac
done

[[ "${DEBUG}" == 1 ]] && { export DEBUG; set -x; }

log "=== Weekly rotation start: provider=$PROVIDER region=$REGION plan=$PLAN ==="

# ── Step 1: Snapshot the current (old) workspace before anything changes ──────
# terraform workspace show gives us the workspace name; terraform output gives
# the IP.  Both are captured now because mirror-git.sh will switch workspaces
# internally and we need to know where to point the destroy at the end.
OLD_WORKSPACE="$(cd "$TF_DIR" && terraform workspace show 2>/dev/null || echo "default")"
OLD_IP="$(cd "$TF_DIR" && terraform output -raw public_ipv4 2>/dev/null || true)"
if [[ -z "$OLD_IP" ]]; then
    _old_ipv6="$(cd "$TF_DIR" && terraform output -raw public_ipv6 2>/dev/null || true)"
    [[ -n "$_old_ipv6" ]] && OLD_IP="[${_old_ipv6}]"
fi
log "Old workspace: $OLD_WORKSPACE  IP: ${OLD_IP:-unknown}"

# ── Step 2: Provision new instance and mirror repositories ────────────────────
# mirror-git.sh calls provision.sh internally with --non-interactive, so no
# interactive prompts will appear.  --quiet suppresses per-repo progress lines
# while still logging errors to stderr (captured by the crontab redirect).
#
# The destination workspace name is auto-generated as mirror-YYYYMMDD-HHMMSS.
# --days 7 (the default) mirrors repos with activity in the past week; increase
# if you want a fuller safety net at the cost of a longer migration window.
log "Running mirror-git.sh..."
_run "$SCRIPT_DIR/mirror-git.sh" \
    --dest-provider "$PROVIDER" \
    --dest-region   "$REGION"   \
    --dest-plan     "$PLAN"     \
    --quiet
log "mirror-git.sh complete."

# ── Step 3: Identify the new workspace from the provision log ─────────────────
# .provision-log.json is an append-only NDJSON file; the new workspace is the
# most recent "provision" event for this provider that isn't the old workspace.
# We reverse-iterate so we find it in O(1) even on a long log.
NEW_WORKSPACE="$(python3 - "$SCRIPT_DIR/.provision-log.json" "$PROVIDER" "$OLD_WORKSPACE" <<'PY'
import json, sys
log_file, provider, old_ws = sys.argv[1], sys.argv[2], sys.argv[3]
with open(log_file) as f:
    records = [json.loads(line) for line in f if line.strip()]
for rec in reversed(records):
    if (rec.get("provider") == provider
            and rec.get("action") == "provision"
            and rec.get("workspace") != old_ws):
        print(rec["workspace"])
        break
PY
)"

if [[ -z "$NEW_WORKSPACE" ]]; then
    log "ERROR: Could not determine new workspace from provision log." >&2
    exit 1
fi

# Retrieve the new instance's IP from its Terraform workspace output.
NEW_IP="$(cd "$TF_DIR" && \
    terraform workspace select "$NEW_WORKSPACE" >/dev/null 2>&1 && \
    terraform output -raw public_ipv4 2>/dev/null || true)"
if [[ -z "$NEW_IP" ]]; then
    _new_ipv6="$(cd "$TF_DIR" && terraform output -raw public_ipv6 2>/dev/null || true)"
    [[ -n "$_new_ipv6" ]] && NEW_IP="[${_new_ipv6}]"
fi

log "New workspace: $NEW_WORKSPACE  IP: $NEW_IP"

# ── Step 4: Verify the new instance is healthy ────────────────────────────────
# A 200 (Forgejo landing page) or 302 (redirect to login when REQUIRE_SIGNIN_VIEW
# is enabled) both confirm that nginx is up and TLS is terminating correctly.
# We use -k here because we trust this specific IP we just provisioned; the real
# TLS validation happened when certbot issued the certificate during deploy.sh.
# --max-time 30 gives Forgejo a generous window to respond after first boot.
log "Verifying new instance at https://$NEW_IP ..."
HTTP_CODE="$(curl -sk --max-time 30 -o /dev/null -w '%{http_code}' "https://$NEW_IP" || true)"

if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "302" ]]; then
    log "ERROR: New instance unhealthy (HTTP $HTTP_CODE). Old instance preserved." >&2
    # Restore Terraform context to the old workspace so auto-detection in other
    # scripts continues to target the known-good instance.
    cd "$TF_DIR" && terraform workspace select "$OLD_WORKSPACE" >/dev/null 2>&1 || true
    exit 1
fi

log "New instance healthy (HTTP $HTTP_CODE)."

# ── Step 4b: Cert-only enforcement regression test ────────────────────────────
# Verify that the new instance rejects raw key auth on port 2222.
# A regression here means forgejo-keys.sh shipped with the cert-only block removed.
log "Running cert-only enforcement regression test on port 2222..."
_raw_key_tmp="$(mktemp)"
trap 'rm -f "$_raw_key_tmp" "${_raw_key_tmp}.pub"' EXIT
ssh-keygen -t ed25519 -N "" -f "$_raw_key_tmp" -q
_raw_auth_out="$(ssh \
    -i "$_raw_key_tmp" \
    -o IdentitiesOnly=yes \
    -o CertificateFile=none \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=no \
    -p 2222 "git@$NEW_IP" 2>&1 || true)"
if echo "$_raw_auth_out" | grep -qiE 'Permission denied|publickey'; then
    log "Cert-only enforcement: raw key correctly denied (regression test passed)."
else
    log "ERROR: cert-only regression — unexpected output: $_raw_auth_out" >&2
    log "ERROR: Raw key may have been accepted. Old instance preserved." >&2
    cd "$TF_DIR" && terraform workspace select "$OLD_WORKSPACE" >/dev/null 2>&1 || true
    exit 1
fi

log "Proceeding to destroy old instance."

# ── Step 5: Destroy the old instance ─────────────────────────────────────────
# --non-interactive skips the interactive 'yes' confirmation prompt, which is
# necessary in cron (there is no terminal to read from).
# provision.sh appends a "destroy" event to .provision-log.json for audit.
log "Destroying old workspace '$OLD_WORKSPACE' (IP: ${OLD_IP:-unknown}) ..."
_run "$SCRIPT_DIR/provision.sh" \
    --provider "$PROVIDER" \
    --destroy \
    --workspace "$OLD_WORKSPACE" \
    --non-interactive
log "Old instance destroyed."

# ── Step 6: Leave Terraform pointing at the new workspace ─────────────────────
# Without this, the next 'terraform workspace show' would return "default"
# (where the old, now-deleted instance was), breaking auto-detection in
# export-git.sh, sign-user-key.sh, and any subsequent provision.sh run.
cd "$TF_DIR" && terraform workspace select "$NEW_WORKSPACE" >/dev/null 2>&1
log "Active Terraform workspace set to: $NEW_WORKSPACE"

log "=== Rotation complete. New instance: https://$NEW_IP (workspace: $NEW_WORKSPACE) ==="
