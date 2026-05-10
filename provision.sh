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

# ── Region / plan helpers ─────────────────────────────────────────────────────

# Read a field from a terraform.tfvars file (returns empty string if file/field absent)
tfvars_get() {
    local file="$1" var="$2"
    [[ -f "$file" ]] || return 0
    grep -E "^\s*${var}\s*=" "$file" 2>/dev/null \
        | head -1 | sed 's/.*=\s*"\(.*\)".*/\1/' | tr -d '[:space:]'
}

# Interactive numbered menu. Items are "code:description" strings.
# Writes the selected code into global _MENU_RESULT (avoids subshell capture).
_MENU_RESULT=""
show_menu() {
    local header="$1" default="$2"; shift 2
    local -a items=("$@")
    local n="${#items[@]}" i code desc mark _sel _item
    echo
    info "$header"
    for ((i=0; i<n; i++)); do
        code="${items[$i]%%:*}"
        desc="${items[$i]#*:}"
        mark=""
        [[ "$code" == "$default" ]] && mark=" [default]"
        printf "    %2d) %-24s %s%s\n" "$((i+1))" "$code" "$desc" "$mark"
    done
    echo
    _MENU_RESULT=""
    while [[ -z "$_MENU_RESULT" ]]; do
        read -rp "    Select [${default}]: " _sel
        _sel="${_sel:-$default}"
        if [[ "$_sel" =~ ^[0-9]+$ ]] && (( _sel >= 1 && _sel <= n )); then
            _MENU_RESULT="${items[$((_sel-1))]%%:*}"
        else
            for _item in "${items[@]}"; do
                [[ "${_item%%:*}" == "$_sel" ]] && { _MENU_RESULT="$_sel"; break; }
            done
        fi
        [[ -n "$_MENU_RESULT" ]] \
            || warn "Invalid selection '${_sel}'. Enter a number (1-${n}) or a valid code."
    done
}

# ── CLI arguments ─────────────────────────────────────────────────────────────
CERTBOT_STAGING=""
PROVIDER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)
            CERTBOT_STAGING=1
            warn "Debug mode: certbot will use staging CA and verbose logs."
            shift ;;
        --provider)
            [[ $# -ge 2 ]] || error "--provider requires a value (vultr|aws|azure)"
            PROVIDER="$2"
            shift 2 ;;
        *)
            error "Unknown argument: $1. Usage: $0 [--provider vultr|aws|azure] [--debug]" ;;
    esac
done

if [[ -n "$PROVIDER" && "$PROVIDER" != "vultr" && "$PROVIDER" != "aws" && "$PROVIDER" != "azure" ]]; then
    error "Invalid provider '$PROVIDER'. Use vultr, aws, or azure."
fi

# If not specified, default to last used provider (or prompt)
if [[ -z "$PROVIDER" ]]; then
    DEFAULT_PROVIDER="vultr"
    if [[ -f .last-provider ]]; then
        DEFAULT_PROVIDER="$(cat .last-provider | tr -d '[:space:]')"
    elif grep -q 'provider_name' terraform/terraform.tfvars 2>/dev/null; then
        _p="$(grep 'provider_name' terraform/terraform.tfvars | sed 's/.*=\s*"\(.*\)".*/\1/')"
        [[ -n "$_p" ]] && DEFAULT_PROVIDER="$_p"
    fi

    read -rp "[provision] Cloud provider (vultr/aws/azure) [${DEFAULT_PROVIDER}]: " _prov
    PROVIDER="${_prov:-$DEFAULT_PROVIDER}"
    [[ "$PROVIDER" == "vultr" || "$PROVIDER" == "aws" || "$PROVIDER" == "azure" ]] \
        || error "Invalid provider '$PROVIDER'. Use vultr, aws, or azure."
fi

info "Provider: $PROVIDER"

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

CERTBOT_EMAIL="$(vget certbot_email secret/forgejo/deploy)"
ADMIN_SSH_PUBLIC_KEY="$(vget admin_ssh_public_key secret/forgejo/deploy)"
FORGEJO_ADMIN_USER="$(vget forgejo_admin_user secret/forgejo/deploy)"
FORGEJO_ADMIN_EMAIL="$(vget forgejo_admin_email secret/forgejo/deploy)"

# Generate a secure admin password once and persist it; reused on re-runs so
# Vault is always the authoritative source for the current admin credential.
FORGEJO_ADMIN_PASSWORD="$(vget admin_password secret/forgejo/deploy 2>/dev/null || true)"
if [ -z "$FORGEJO_ADMIN_PASSWORD" ]; then
    info "Generating Forgejo admin password (20-24 chars)..."
    # 18 random bytes → 24 base64 chars; strip +/= → 20-24 alphanumeric chars
    FORGEJO_ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -d '+/=')"
    vault kv patch secret/forgejo/deploy admin_password="$FORGEJO_ADMIN_PASSWORD"
    info "Admin password saved to Vault: secret/forgejo/deploy (field: admin_password)"
fi

# ── Provider credentials ──────────────────────────────────────────────────────
export TF_VAR_admin_ssh_public_key="$ADMIN_SSH_PUBLIC_KEY"

case "$PROVIDER" in
    vultr)
        export TF_VAR_vultr_api_key="$(vget vultr_api_key secret/forgejo/cloud)"
        TF_DIR="$SCRIPT_DIR/terraform"
        ;;
    aws)
        [ -f aws_access_key ]        || error "aws_access_key file not found in $SCRIPT_DIR"
        [ -f aws_secret_access_key ] || error "aws_secret_access_key file not found in $SCRIPT_DIR"
        export AWS_ACCESS_KEY_ID="$(tr -d '[:space:]' < aws_access_key)"
        export AWS_SECRET_ACCESS_KEY="$(tr -d '[:space:]' < aws_secret_access_key)"
        TF_DIR="$SCRIPT_DIR/terraform/aws"
        ;;
    azure)
        [ -f azure_credentials ] || error "azure_credentials file not found in $SCRIPT_DIR"
        # Parse JSON credentials; support both az-cli field names (appId/password/tenant)
        # and the SDK-auth aliases (clientId/clientSecret/tenantId/subscriptionId).
        # shlex.quote ensures values with special characters are safely shell-escaped.
        eval "$(python3 - <<'PY'
import json, sys, shlex
try:
    d = json.load(open("azure_credentials"))
except Exception as e:
    sys.exit(f"Cannot parse azure_credentials: {e}")
def get(key, *aliases):
    for k in (key,) + aliases:
        if k in d and d[k]:
            return d[k]
    sys.exit(f"azure_credentials: missing required field '{key}' (aliases checked: {aliases})")
pairs = [
    ("ARM_CLIENT_ID",       get("clientId",     "appId")),
    ("ARM_CLIENT_SECRET",   get("clientSecret",  "password")),
    ("ARM_SUBSCRIPTION_ID", get("subscriptionId")),
    ("ARM_TENANT_ID",       get("tenantId",      "tenant")),
]
for k, v in pairs:
    print(f"export {k}={shlex.quote(v)}")
PY
        )"
        TF_DIR="$SCRIPT_DIR/terraform/azure"
        ;;
esac

# ── Region & plan selection ───────────────────────────────────────────────────
CURRENT_REGION="$(tfvars_get "${TF_DIR}/terraform.tfvars" region)"
CURRENT_PLAN="$(tfvars_get "${TF_DIR}/terraform.tfvars" plan)"

case "$PROVIDER" in
    vultr)
        [[ -z "$CURRENT_REGION" ]] && CURRENT_REGION="ewr"
        [[ -z "$CURRENT_PLAN" ]]   && CURRENT_PLAN="vc2-1c-1gb"
        show_menu "Vultr regions (verify at vultr.com/features/datacenter-locations/):" \
            "$CURRENT_REGION" \
            "ewr:Piscataway, NJ - US East" \
            "lax:Los Angeles, CA - US West" \
            "ord:Chicago, IL - US Central" \
            "dfw:Dallas, TX - US South" \
            "sea:Seattle, WA - US West" \
            "mia:Miami, FL - US South" \
            "atl:Atlanta, GA - US South" \
            "fra:Frankfurt - EU" \
            "ams:Amsterdam - EU" \
            "lhr:London - EU" \
            "syd:Sydney - AU" \
            "sin:Singapore - AP" \
            "nrt:Tokyo - AP" \
            "icn:Seoul - AP" \
            "blr:Bangalore - AP"
        REGION="$_MENU_RESULT"
        show_menu "Vultr instance plans (approx; verify current pricing at vultr.com/pricing/):" \
            "$CURRENT_PLAN" \
            "vc2-1c-0.5gb:1C/512MB/10GB NVMe   ~\$2.50/mo  (not recommended: too small for Forgejo+Postgres)" \
            "vc2-1c-1gb:1C/1GB/25GB NVMe        ~\$6/mo     (recommended minimum)" \
            "vc2-1c-2gb:1C/2GB/55GB NVMe        ~\$12/mo" \
            "vc2-2c-4gb:2C/4GB/80GB NVMe        ~\$24/mo"
        PLAN="$_MENU_RESULT"
        ;;
    aws)
        [[ -z "$CURRENT_REGION" ]] && CURRENT_REGION="us-east-1"
        [[ -z "$CURRENT_PLAN" ]]   && CURRENT_PLAN="t3.micro"
        show_menu "AWS regions (pricing varies by region; see aws.amazon.com/ec2/pricing/):" \
            "$CURRENT_REGION" \
            "us-east-1:N. Virginia - US East" \
            "us-east-2:Ohio - US East" \
            "us-west-1:N. California - US West" \
            "us-west-2:Oregon - US West" \
            "ca-central-1:Canada Central - Montreal" \
            "eu-west-1:Ireland - EU" \
            "eu-west-2:London - EU" \
            "eu-central-1:Frankfurt - EU" \
            "ap-southeast-1:Singapore - AP" \
            "ap-southeast-2:Sydney - AP" \
            "ap-northeast-1:Tokyo - AP" \
            "ap-south-1:Mumbai - AP" \
            "sa-east-1:Sao Paulo - SA"
        REGION="$_MENU_RESULT"
        show_menu "AWS EC2 instance types (Linux on-demand, us-east-1; verify at aws.amazon.com/ec2/pricing/):" \
            "$CURRENT_PLAN" \
            "t4g.micro:2C ARM/1GB    ~\$6/mo   (cheapest; Graviton ARM architecture)" \
            "t3a.micro:2C AMD/1GB    ~\$7/mo" \
            "t3.micro:2C Intel/1GB   ~\$8/mo   (free-tier eligible)" \
            "t3.small:2C Intel/2GB   ~\$15/mo" \
            "t3.medium:2C Intel/4GB  ~\$30/mo"
        PLAN="$_MENU_RESULT"
        ;;
    azure)
        [[ -z "$CURRENT_REGION" ]] && CURRENT_REGION="eastus"
        [[ -z "$CURRENT_PLAN" ]]   && CURRENT_PLAN="Standard_B1s"
        show_menu "Azure regions (pricing varies; see azure.microsoft.com/pricing/details/virtual-machines/linux/):" \
            "$CURRENT_REGION" \
            "eastus:East US - Virginia" \
            "eastus2:East US 2 - Virginia" \
            "westus2:West US 2 - Washington" \
            "centralus:Central US - Iowa" \
            "canadacentral:Canada Central - Toronto" \
            "northeurope:North Europe - Ireland" \
            "westeurope:West Europe - Netherlands" \
            "uksouth:UK South - London" \
            "germanywestcentral:Germany West Central - Frankfurt" \
            "francecentral:France Central - Paris" \
            "australiaeast:Australia East - New South Wales" \
            "southeastasia:Southeast Asia - Singapore" \
            "japaneast:Japan East - Tokyo" \
            "koreacentral:Korea Central - Seoul" \
            "centralindia:Central India - Pune" \
            "brazilsouth:Brazil South - Sao Paulo"
        REGION="$_MENU_RESULT"
        show_menu "Azure VM sizes - B-series burstable (Linux; verify at azure.microsoft.com/pricing/details/virtual-machines/linux/):" \
            "$CURRENT_PLAN" \
            "Standard_B1ls:1C/512MB   ~\$4/mo   (not recommended: OOM risk with Forgejo+Postgres)" \
            "Standard_B1s:1C/1GB      ~\$8/mo   (recommended minimum)" \
            "Standard_B1ms:1C/2GB     ~\$15/mo" \
            "Standard_B2s:2C/4GB      ~\$30/mo" \
            "Standard_B2ms:2C/8GB     ~\$61/mo"
        PLAN="$_MENU_RESULT"
        ;;
esac

info "Selected: region=${REGION}  plan=${PLAN}"

# Write provider-specific terraform.tfvars (always; overwrites previous values)
case "$PROVIDER" in
    vultr)
        cat > "${TF_DIR}/terraform.tfvars" <<EOF
provider_name = "vultr"
region        = "${REGION}"
plan          = "${PLAN}"
hostname      = "forgejo"
EOF
        ;;
    aws|azure)
        cat > "${TF_DIR}/terraform.tfvars" <<EOF
region   = "${REGION}"
plan     = "${PLAN}"
hostname = "forgejo"
EOF
        ;;
esac
info "terraform.tfvars written (${TF_DIR}/terraform.tfvars)."

# ── SSH key for connecting to VPS ────────────────────────────────────────────
SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
[ -f "$SSH_KEY" ] || error "SSH key not found: $SSH_KEY. Set SSH_KEY_PATH to override."

# ── Terraform ─────────────────────────────────────────────────────────────────
info "Running Terraform ($PROVIDER)..."
cd "$TF_DIR"

terraform init -upgrade -input=false
terraform apply -auto-approve -input=false
IP="$(terraform output -raw public_ipv4)"
SSH_USER="$(terraform output -raw ssh_user)"
cd "$SCRIPT_DIR"

# Persist provider selection so next run defaults to the same provider
echo "$PROVIDER" > .last-provider

# Domain is the VPS IP. LE issues IP certificates under the 'shortlived' profile
# (160-hour validity); no DNS setup required.
DOMAIN="$IP"

info "VPS IP: $IP  SSH user: $SSH_USER  Provider: $PROVIDER"

# ── Wait for SSH ──────────────────────────────────────────────────────────────
info "Waiting for SSH to become available (this takes ~60-90 seconds)..."
: > known_hosts.deploy
ATTEMPTS=0
until ssh-keyscan -p 22 -T 5 "$IP" >> known_hosts.deploy 2>/dev/null; do
    ATTEMPTS=$((ATTEMPTS + 1))
    [ "$ATTEMPTS" -lt 30 ] || error "Timed out waiting for SSH on $IP"
    sleep 10
done
info "SSH port is up."

SSH_OPTS="-i $SSH_KEY -o UserKnownHostsFile=./known_hosts.deploy -o StrictHostKeyChecking=yes"

# On AWS, user_data configures root access after sshd is already listening.
# Retry the actual login until it succeeds (up to 3 extra minutes).
# On re-runs after hardening, root login is disabled — fall back to deploy user.
info "Verifying SSH login as $SSH_USER (will retry as 'deploy' if root is disabled)..."
ATTEMPTS=0
until ssh $SSH_OPTS -o ConnectTimeout=10 -o BatchMode=yes "${SSH_USER}@${IP}" true 2>/dev/null; do
    ATTEMPTS=$((ATTEMPTS + 1))
    [ "$ATTEMPTS" -lt 18 ] || break
    sleep 10
done

if ! ssh $SSH_OPTS -o ConnectTimeout=5 -o BatchMode=yes "${SSH_USER}@${IP}" true 2>/dev/null; then
    info "Login as $SSH_USER failed; trying deploy user (post-hardening re-run)..."
    ATTEMPTS=0
    until ssh $SSH_OPTS -o ConnectTimeout=10 -o BatchMode=yes "deploy@${IP}" true 2>/dev/null; do
        ATTEMPTS=$((ATTEMPTS + 1))
        [ "$ATTEMPTS" -lt 6 ] || error "Cannot log in as ${SSH_USER} or deploy@${IP} — check SSH key and firewall"
        sleep 5
    done
    SSH_USER="deploy"
fi
info "SSH login confirmed as $SSH_USER."

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
info "Copying files to VPS (as $SSH_USER)..."
# shellcheck disable=SC2086

if [[ "$SSH_USER" == "root" ]]; then
    # First run: SSH as root, scp directly to /opt/forgejo
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
else
    # Re-run after hardening: SSH as deploy; /opt/forgejo is chown root:deploy g+w
    # Stage to tmp first, then sudo-move into place
    STAGE_DIR="$(ssh $SSH_OPTS "deploy@${IP}" "mktemp -d")"
    trap 'ssh '"$SSH_OPTS"' "deploy@'"$IP"'" "rm -rf '"$STAGE_DIR"'" 2>/dev/null; rm -rf "$TMPDIR"' EXIT
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
        deploy.sh \
        "deploy@${IP}:${STAGE_DIR}/"
    ssh $SSH_OPTS "deploy@${IP}" \
        "sudo mv ${STAGE_DIR}/* /opt/forgejo/ && sudo rm -rf ${STAGE_DIR}"
fi

# ── Run deploy.sh on VPS ──────────────────────────────────────────────────────
info "Running deploy.sh on VPS as $SSH_USER..."
# On re-runs as deploy user, sudo env passes the environment variables through.
SUDO_PREFIX=""
[[ "$SSH_USER" != "root" ]] && SUDO_PREFIX="sudo env"
# shellcheck disable=SC2086
ssh $SSH_OPTS "${SSH_USER}@${IP}" \
    "${SUDO_PREFIX} DOMAIN='${DOMAIN}' \
     CERTBOT_EMAIL='${CERTBOT_EMAIL}' \
     CERTBOT_STAGING='${CERTBOT_STAGING}' \
     FORGEJO_ADMIN_USER='${FORGEJO_ADMIN_USER}' \
     FORGEJO_ADMIN_EMAIL='${FORGEJO_ADMIN_EMAIL}' \
     FORGEJO_ADMIN_PASSWORD='${FORGEJO_ADMIN_PASSWORD}' \
     ADMIN_SSH_PUBLIC_KEY='${ADMIN_SSH_PUBLIC_KEY}' \
     bash /opt/forgejo/deploy.sh"

# ── Verify HTTPS endpoint ─────────────────────────────────────────────────────
info "Verifying HTTPS endpoint externally at https://${IP} ..."
HTTPS_HTTP_CODE="$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' "https://${IP}" || true)"
if [ "$HTTPS_HTTP_CODE" = "200" ] || [ "$HTTPS_HTTP_CODE" = "302" ]; then
    info "External HTTPS check passed (HTTP $HTTPS_HTTP_CODE)."
else
    warn "External HTTPS check returned code: $HTTPS_HTTP_CODE — running verbose check from VPS:"
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${SSH_USER}@${IP}" \
        "curl -vvv -k --max-time 15 https://localhost 2>&1; echo; echo '--- nginx status ---'; docker ps --filter name=nginx --format '{{.Status}}'; docker exec \$(docker ps -qf name=nginx) nginx -t 2>&1 || true" \
        || true
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "Forgejo is live at https://${IP}  [${PROVIDER}]"
echo
echo "  Admin SSH : ssh deploy@${IP}   (root login disabled after hardening)"
echo
echo "  Forgejo admin credentials:"
echo "    Username : ${FORGEJO_ADMIN_USER}"
echo "    Password : vault kv get -field=admin_password secret/forgejo/deploy"
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
