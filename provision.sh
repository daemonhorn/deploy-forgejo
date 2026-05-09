#!/usr/bin/env bash
# provision.sh — Provision the VPS and deploy Forgejo.
#
# Reads all secrets from local Vault (started by setup.sh).
# Runs: terraform apply → wait for SSH → render templates → scp files → deploy.sh
#
# Safe to re-run: Terraform reconciles drift; deploy.sh is idempotent.
# Requires: setup.sh to have been run at least once this Vault session.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[provision]${NC} $*"; }
warn()  { echo -e "${YELLOW}[provision]${NC} $*"; }
error() { echo -e "${RED}[provision]${NC} $*" >&2; exit 1; }

# ── CLI arguments ─────────────────────────────────────────────────────────────
CERTBOT_STAGING=""
for arg in "$@"; do
    case "$arg" in
        --debug) CERTBOT_STAGING=1
                 warn "Debug mode: certbot will use staging CA and verbose logs." ;;
        *)       error "Unknown argument: $arg. Usage: $0 [--debug]" ;;
    esac
done

# ── Prerequisites ─────────────────────────────────────────────────────────────
for cmd in vault terraform ssh scp ssh-keyscan envsubst; do
    command -v "$cmd" &>/dev/null || error "Required tool not found: $cmd"
done

[ -f .vault.token ] || error ".vault.token not found. Run ./setup.sh first."
[ -f .vault-keys ]  || error ".vault-keys not found. Run ./setup.sh first."
[ -f ca.pub ]       || error "ca.pub not found. Run ./setup.sh first."

# ── Vault: start and unseal if needed ────────────────────────────────────────
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="$(cat .vault.token)"

if ! vault status &>/dev/null; then
    info "Starting Vault..."
    vault server -config vault.hcl > /tmp/vault.log 2>&1 &
    echo $! > .vault.pid
    sleep 3
fi

if vault status 2>/dev/null | grep -q "Sealed.*true"; then
    info "Unsealing Vault..."
    vault operator unseal "$(cat .vault-keys)"
fi

vault status | grep -q "Initialized.*true" || error "Vault not initialized. Run ./setup.sh first."

# ── Read secrets from Vault ───────────────────────────────────────────────────
info "Reading secrets from Vault..."

vget() { vault kv get -field="$1" "$2"; }

DB_PASSWORD="$(vget db_password secret/forgejo/config)"
DB_USER="$(vget db_user secret/forgejo/config)"
DB_NAME="$(vget db_name secret/forgejo/config)"
FORGEJO_SECRET_KEY="$(vget secret_key secret/forgejo/config 2>/dev/null || true)"
FORGEJO_INTERNAL_TOKEN="$(vget internal_token secret/forgejo/config 2>/dev/null || true)"
# Generate and persist if setup.sh pre-dates these fields
if [ -z "$FORGEJO_SECRET_KEY" ] || [ -z "$FORGEJO_INTERNAL_TOKEN" ]; then
    warn "Forgejo secrets missing from Vault — generating and storing now..."
    FORGEJO_SECRET_KEY="$(openssl rand -hex 32)"
    FORGEJO_INTERNAL_TOKEN="$(openssl rand -base64 32 | tr -d '=/+')"
    vault kv patch secret/forgejo/config \
        secret_key="$FORGEJO_SECRET_KEY" \
        internal_token="$FORGEJO_INTERNAL_TOKEN"
fi
export TF_VAR_vultr_api_key="$(vget vultr_api_key secret/forgejo/cloud)"

CERTBOT_EMAIL="$(vget certbot_email secret/forgejo/deploy)"
ADMIN_SSH_PUBLIC_KEY="$(vget admin_ssh_public_key secret/forgejo/deploy)"
FORGEJO_ADMIN_USER="$(vget forgejo_admin_user secret/forgejo/deploy)"
FORGEJO_ADMIN_EMAIL="$(vget forgejo_admin_email secret/forgejo/deploy)"

# ── SSH key for connecting to VPS ────────────────────────────────────────────
SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
[ -f "$SSH_KEY" ] || error "SSH key not found: $SSH_KEY. Set SSH_KEY_PATH to override."

# ── Terraform ─────────────────────────────────────────────────────────────────
info "Running Terraform..."
cd terraform/
terraform init -upgrade -input=false
terraform apply -auto-approve -input=false
IP="$(terraform output -raw public_ipv4)"
SSH_USER="$(terraform output -raw ssh_user)"
cd "$SCRIPT_DIR"

# Domain is the VPS IP. LE issues IP certificates under the 'shortlived' profile
# (160-hour validity); no DNS setup required.
DOMAIN="$IP"

info "VPS IP: $IP  SSH user: $SSH_USER"

# ── Wait for SSH ──────────────────────────────────────────────────────────────
info "Waiting for SSH to become available (this takes ~60-90 seconds)..."
: > known_hosts.deploy
ATTEMPTS=0
until ssh-keyscan -p 22 -T 5 "$IP" >> known_hosts.deploy 2>/dev/null; do
    ATTEMPTS=$((ATTEMPTS + 1))
    [ "$ATTEMPTS" -lt 30 ] || error "Timed out waiting for SSH on $IP"
    sleep 10
done
info "SSH is up."

SSH_OPTS="-i $SSH_KEY -o UserKnownHostsFile=./known_hosts.deploy -o StrictHostKeyChecking=yes"

# ── Render templates ──────────────────────────────────────────────────────────
info "Rendering configuration templates..."
TMPDIR="$(mktemp -d /tmp/forgejo-deploy-XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

# Export vars for envsubst
export DOMAIN DB_PASSWORD DB_USER DB_NAME FORGEJO_SECRET_KEY FORGEJO_INTERNAL_TOKEN

envsubst '${DOMAIN}' \
    < files/templates/nginx-http.conf.tmpl > "$TMPDIR/nginx-http.conf"
envsubst '${DOMAIN}' \
    < files/templates/nginx.conf.tmpl > "$TMPDIR/nginx.conf"
envsubst '${DOMAIN} ${DB_PASSWORD} ${DB_USER} ${DB_NAME} ${FORGEJO_SECRET_KEY} ${FORGEJO_INTERNAL_TOKEN}' \
    < files/templates/app.ini.tmpl > "$TMPDIR/app.ini"
envsubst '${DB_PASSWORD} ${DB_USER} ${DB_NAME}' \
    < files/templates/.env.tmpl > "$TMPDIR/.env"

# ── Copy files to VPS ─────────────────────────────────────────────────────────
info "Copying files to VPS..."
# shellcheck disable=SC2086
ssh $SSH_OPTS "${SSH_USER}@${IP}" "mkdir -p /opt/forgejo"

scp $SSH_OPTS \
    "$TMPDIR/nginx-http.conf" \
    "$TMPDIR/nginx.conf" \
    "$TMPDIR/app.ini" \
    "$TMPDIR/.env" \
    files/docker-compose.yml \
    files/certbot-renew.sh \
    files/forgejo-keys.sh \
    files/forgejo-cert-extract.py \
    files/sshd_forgejo.conf \
    ca.pub \
    "${SSH_USER}@${IP}:/opt/forgejo/"

scp $SSH_OPTS deploy.sh "${SSH_USER}@${IP}:/opt/forgejo/deploy.sh"

# ── Run deploy.sh on VPS ──────────────────────────────────────────────────────
info "Running deploy.sh on VPS..."
ssh $SSH_OPTS "${SSH_USER}@${IP}" \
    "DOMAIN='${DOMAIN}' \
     CERTBOT_EMAIL='${CERTBOT_EMAIL}' \
     CERTBOT_STAGING='${CERTBOT_STAGING}' \
     FORGEJO_ADMIN_USER='${FORGEJO_ADMIN_USER}' \
     FORGEJO_ADMIN_EMAIL='${FORGEJO_ADMIN_EMAIL}' \
     bash /opt/forgejo/deploy.sh"

# ── Verify HTTPS endpoint ─────────────────────────────────────────────────────
info "Verifying HTTPS endpoint at https://${IP} ..."
HTTPS_HTTP_CODE="$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' "https://${IP}" || true)"
if [ "$HTTPS_HTTP_CODE" = "200" ] || [ "$HTTPS_HTTP_CODE" = "302" ]; then
    info "HTTPS check passed (HTTP $HTTPS_HTTP_CODE)."
else
    warn "HTTPS check returned unexpected code: $HTTPS_HTTP_CODE — full output:"
    curl -vvv --max-time 15 "https://${IP}" 2>&1 || true
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "Forgejo is live at https://${IP}"
echo
echo "  To add a user:"
echo "    ./sign-user-key.sh <username> /path/to/user_key.pub"
echo
echo "  ── Git SSH config ──────────────────────────"
echo "  Add to ~/.ssh/config:"
echo
echo "    Host forgejo"
echo "        HostName ${IP}"
echo "        Port 2222"
echo "        User git"
echo "        IdentityFile ~/.ssh/id_ed25519"
echo
echo "  Then clone with:  git clone git@forgejo:/<user>/<repo>.git"
echo
echo "  Or set a git URL alias (no SSH config needed):"
echo "    git config --global url.\"ssh://git@${IP}:2222/\".insteadOf \"forgejo:\""
echo "  Then clone with:  git clone forgejo:<user>/<repo>"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
