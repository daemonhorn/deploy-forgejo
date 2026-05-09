#!/usr/bin/env bash
# setup.sh — Run ONCE before first provision.
#
# Does three things:
#   1. Generates an ECCP384 SSH CA key in Yubikey PIV slot 9d.
#   2. Starts a local Vault instance (file backend, persists across reboots).
#   3. Stores all secrets in Vault so provision.sh can retrieve them.
#
# Re-running is safe: Vault init is skipped if already done; slot 9d keygen
# prompts for confirmation if a key already exists there.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn()  { echo -e "${YELLOW}[setup]${NC} $*"; }
error() { echo -e "${RED}[setup]${NC} $*" >&2; exit 1; }

# ── 1. Prerequisite check ─────────────────────────────────────────────────────
info "Checking prerequisites..."
for cmd in ykman vault ssh-keygen openssl uuidgen; do
    command -v "$cmd" &>/dev/null || error "Required tool not found: $cmd"
done

if ! ykman info &>/dev/null; then
    error "No Yubikey detected. Connect your Yubikey and try again."
fi

# ── 2. Slot 9d: generate key ──────────────────────────────────────────────────
info "Checking Yubikey PIV slot 9d..."

SLOT="9d"
PIV_INFO="$(ykman piv info 2>&1 || true)"

if echo "$PIV_INFO" | grep -q "Key Management.*Generated\|Key Management.*Imported"; then
    warn "Slot 9d already contains a key."
    read -rp "Overwrite existing key in slot 9d? This is IRREVERSIBLE. [y/N] " CONFIRM
    [[ "${CONFIRM,,}" == "y" ]] || error "Aborted. Existing slot 9d key preserved."
fi

info "Generating ECCP384 key in PIV slot 9d (requires Yubikey touch/PIN)..."
TMP_PUB="$(mktemp /tmp/yk_9d_XXXXXX.pem)"
trap 'rm -f "$TMP_PUB"' EXIT

ykman piv keys generate \
    --algorithm ECCP384 \
    --pin-policy once \
    --touch-policy cached \
    "$SLOT" "$TMP_PUB"

info "Creating self-signed X.509 certificate in slot 9d (required for PKCS#11 enumeration)..."
ykman piv certificates generate \
    --subject "CN=Forgejo SSH CA" \
    "$SLOT" "$TMP_PUB"

# ── 3. Detect PKCS#11 library ─────────────────────────────────────────────────
info "Detecting PKCS#11 library..."

PKCS11_CANDIDATES=(
    "/usr/lib/x86_64-linux-gnu/libykcs11.so"
    "/usr/lib/aarch64-linux-gnu/libykcs11.so"
    "/usr/local/lib/libykcs11.so"
    "/usr/lib/x86_64-linux-gnu/opensc-pkcs11.so"
    "/usr/lib/opensc-pkcs11.so"
)

PKCS11_LIB=""
for lib in "${PKCS11_CANDIDATES[@]}"; do
    if [ -f "$lib" ]; then
        PKCS11_LIB="$lib"
        info "Found PKCS#11 library: $lib"
        break
    fi
done

if [ -z "$PKCS11_LIB" ]; then
    error "No PKCS#11 library found. Install ykcs11: apt install ykcs11"
fi

echo "$PKCS11_LIB" > .ykcs11_lib

# ── 4. Export SSH-format CA public key ───────────────────────────────────────
info "Exporting SSH-format CA public key from Yubikey..."
ssh-keygen -D "$PKCS11_LIB" > ca.pub
info "CA public key written to ca.pub"
info "Fingerprint: $(ssh-keygen -l -f ca.pub)"

# Also keep the PEM public key locally for use by ssh-keygen -s when signing certs.
cp "$TMP_PUB" ca_public.pem
# ca_public.pem is gitignored; it's a public key so loss is fine (re-export from Yubikey)
info "PEM public key written to ca_public.pem (used by sign-user-key.sh)"

# ── 5. Start Vault (file backend, persists across reboots) ───────────────────
info "Setting up local Vault..."

export VAULT_ADDR="http://127.0.0.1:8200"

# Start Vault if not already running
if ! vault status &>/dev/null; then
    vault server -config vault.hcl > /tmp/vault.log 2>&1 &
    echo $! > .vault.pid
    info "Vault started (PID $(cat .vault.pid))"
    sleep 3
fi

# Initialize Vault if first run
if ! vault status 2>/dev/null | grep -q "Initialized.*true"; then
    info "Initializing Vault (1 key share, 1 threshold for local use)..."
    INIT_OUTPUT="$(vault operator init -key-shares=1 -key-threshold=1 -format=json)"

    UNSEAL_KEY="$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['unseal_keys_b64'][0])")"
    ROOT_TOKEN="$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['root_token'])")"

    printf '%s\n' "$UNSEAL_KEY" > .vault-keys
    chmod 600 .vault-keys
    printf '%s\n' "$ROOT_TOKEN" > .vault.token
    chmod 600 .vault.token

    warn "Vault unseal key saved to .vault-keys (gitignored). BACK THIS UP SECURELY."
    warn "Loss of .vault-keys means Vault cannot be unsealed after restart."
fi

# Unseal if sealed
if vault status 2>/dev/null | grep -q "Sealed.*true"; then
    info "Unsealing Vault..."
    vault operator unseal "$(cat .vault-keys)"
fi

export VAULT_TOKEN="$(cat .vault.token)"

# ── 6. Collect configuration ──────────────────────────────────────────────────
info "Collecting deployment configuration..."

prompt_if_empty() {
    local var_name="$1" prompt="$2" default="${3:-}"
    if [ -z "${!var_name:-}" ]; then
        if [ -n "$default" ]; then
            read -rp "$prompt [$default]: " INPUT
            eval "$var_name=\"${INPUT:-$default}\""
        else
            read -rp "$prompt: " INPUT
            eval "$var_name=\"$INPUT\""
        fi
    fi
    [ -n "${!var_name}" ] || error "$var_name cannot be empty"
}

prompt_if_empty DOMAIN            "Forgejo domain (e.g. git.example.com)"
prompt_if_empty CERTBOT_EMAIL     "Email for Let's Encrypt registration"
prompt_if_empty ADMIN_SSH_PUBLIC_KEY "Admin ed25519 public key for VPS access (contents of id_ed25519.pub)"
prompt_if_empty FORGEJO_ADMIN_USER   "Forgejo admin username" "gitadmin"
prompt_if_empty FORGEJO_ADMIN_EMAIL  "Forgejo admin email"

# ── 7. Store secrets in Vault ────────────────────────────────────────────────
info "Generating database password..."
DB_PASSWORD="$(openssl rand -base64 32 | tr -d '=/+')"

# Check if Vultr API key is already in Vault; if not, read from file
if ! vault kv get secret/forgejo/cloud &>/dev/null; then
    if [ -f vultr_api_key ]; then
        VULTR_API_KEY="$(tr -d '[:space:]' < vultr_api_key)"
    else
        read -rp "Vultr API key: " VULTR_API_KEY
    fi
    vault kv put secret/forgejo/cloud vultr_api_key="$VULTR_API_KEY"
    info "Stored Vultr API key in Vault."
else
    info "Vultr API key already in Vault, skipping."
fi

vault kv put secret/forgejo/config \
    db_password="$DB_PASSWORD" \
    db_user="forgejo" \
    db_name="forgejo" \
    ssh_ca_pubkey="$(cat ca.pub)"

vault kv put secret/forgejo/deploy \
    domain="$DOMAIN" \
    certbot_email="$CERTBOT_EMAIL" \
    admin_ssh_public_key="$ADMIN_SSH_PUBLIC_KEY" \
    forgejo_admin_user="$FORGEJO_ADMIN_USER" \
    forgejo_admin_email="$FORGEJO_ADMIN_EMAIL"

info "All secrets stored in Vault."

# ── 8. Summary ────────────────────────────────────────────────────────────────
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "Setup complete."
echo "  CA public key : ca.pub"
echo "  Fingerprint   : $(ssh-keygen -l -f ca.pub)"
echo "  PKCS#11 lib   : $PKCS11_LIB"
echo "  Vault addr    : $VAULT_ADDR"
echo
echo "  Next steps:"
echo "    1. Copy terraform/terraform.tfvars.example → terraform/terraform.tfvars"
echo "       and fill in region, plan, admin_ssh_public_key."
echo "    2. Run: ./provision.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
