#!/usr/bin/env bash
# setup.sh — Run before first provision; safe to re-run.
#
# 1. Ensures Yubikey PIV slot 9d has an ECCP384 SSH CA key (generate or reuse).
# 2. Starts a local Vault instance (file backend, persists across reboots).
# 3. Stores all deployment secrets in Vault for provision.sh to retrieve.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn()  { echo -e "${YELLOW}[setup]${NC} $*"; }
error() { echo -e "${RED}[setup]${NC} $*" >&2; exit 1; }

# ── 1. Prerequisite check ─────────────────────────────────────────────────────
info "Checking prerequisites..."
validate_external_utils ykman vault ssh-keygen openssl || exit 1

ykman info &>/dev/null || error "No Yubikey detected. Connect your Yubikey and try again."

# ── 2. Detect PKCS#11 library ─────────────────────────────────────────────────
# Done before slot check because the re-export path (use-existing) also needs it.
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
[ -n "$PKCS11_LIB" ] || error "No PKCS#11 library found. Install ykcs11: apt install ykcs11"
echo "$PKCS11_LIB" > .ykcs11_lib

# ── 3. Yubikey PIV slot 9d: detect and decide ─────────────────────────────────
SLOT="9d"
TMP_PUB="$(mktemp /tmp/yk_9d_XXXXXX.pem)"
trap 'rm -f "$TMP_PUB"' EXIT

# Probe slot 9d by attempting a public-key export — more reliable than parsing
# text output of `ykman piv info`, which varies across firmware versions.
SLOT_HAS_KEY=false
if ykman piv keys export "$SLOT" "$TMP_PUB" 2>/dev/null && [ -s "$TMP_PUB" ]; then
    SLOT_HAS_KEY=true
fi

GENERATE_NEW_KEY=false

if $SLOT_HAS_KEY; then
    if [ -f ca.pub ] && [ -f ca_public.pem ]; then
        warn "Existing PKI detected: slot 9d has a key and local CA files exist."
        read -rp "Use existing PKI? [Y/n] " CHOICE
        if [[ "${CHOICE,,}" == "n" ]]; then
            warn "Generating a new key will IRREVERSIBLY destroy the existing CA."
            warn "Any certificates already signed by the old CA will stop working."
            read -rp "Confirm overwrite of slot 9d? [y/N] " CONFIRM
            [[ "${CONFIRM,,}" == "y" ]] || error "Aborted. Existing PKI preserved."
            GENERATE_NEW_KEY=true
        else
            info "Using existing PKI."
        fi
    else
        # Slot has a key but local files are missing — re-export rather than regenerate.
        # TMP_PUB already holds the exported PEM from the probe above.
        warn "Slot 9d has a key but local CA files are missing — re-exporting public keys."
    fi
else
    info "No key found in slot 9d — generating new CA key."
    GENERATE_NEW_KEY=true
fi

# ── 4. Generate new CA key, or accept the already-exported public key ──────────
if $GENERATE_NEW_KEY; then
    info "Generating ECCP384 key in PIV slot 9d (requires Yubikey touch/PIN)..."
    ykman piv keys generate \
        --algorithm ECCP384 \
        --pin-policy once \
        --touch-policy cached \
        "$SLOT" "$TMP_PUB"

    info "Creating self-signed X.509 certificate in slot 9d (required for PKCS#11 enumeration)..."
    ykman piv certificates generate \
        --subject "CN=Forgejo SSH CA" \
        "$SLOT" "$TMP_PUB"
fi

# TMP_PUB now holds the correct PEM public key for either path.
cp "$TMP_PUB" ca_public.pem
info "PEM public key written to ca_public.pem (used by sign-user-key.sh)"

# Export SSH-format CA public key from the Yubikey (always refresh).
info "Exporting SSH-format CA public key from Yubikey..."
ssh-keygen -D "$PKCS11_LIB" > ca.pub
info "CA public key written to ca.pub"
info "Fingerprint: $(ssh-keygen -l -f ca.pub)"

# ── 5. Start and initialize Vault ─────────────────────────────────────────────
info "Setting up local Vault..."
export VAULT_ADDR="http://127.0.0.1:8200"

# Stop Vault and wipe all local state so it can be re-initialized from scratch.
destroy_vault() {
    info "Destroying existing Vault data..."
    if [ -f .vault.pid ]; then
        kill "$(cat .vault.pid)" 2>/dev/null || true
        sleep 1
    fi
    rm -rf .vault-data/ .vault-keys .vault.token .vault.pid
    info "Vault data destroyed."
}

# A new CA invalidates every secret previously stored (ssh_ca_pubkey changes,
# and a fresh deploy will need a new DB password anyway). Destroy automatically.
# For an unchanged CA, give the user the choice.
if [ -f .vault-keys ]; then
    if $GENERATE_NEW_KEY; then
        warn "New CA key generated — existing Vault secrets are stale. Recreating Vault."
        destroy_vault
    else
        warn "Vault is already initialized."
        read -rp "Destroy and recreate Vault? [y/N] " CHOICE
        [[ "${CHOICE,,}" == "y" ]] && destroy_vault
    fi
fi

# Vault uses mlock() to prevent secrets being swapped to disk. On Linux this
# requires CAP_IPC_LOCK; without it Vault refuses to start. Grant the capability
# to the binary once (persists across runs) so Vault never needs to run as root.
VAULT_BIN="$(command -v vault)"
if command -v getcap &>/dev/null; then
    if ! getcap "$VAULT_BIN" 2>/dev/null | grep -q "cap_ipc_lock"; then
        info "Granting cap_ipc_lock to vault binary (requires sudo, one-time)..."
        sudo setcap cap_ipc_lock=+ep "$VAULT_BIN"
    fi
else
    warn "getcap not found (install libcap2-bin). If Vault fails to start with an"
    warn "mlock error, run manually: sudo setcap cap_ipc_lock=+ep $VAULT_BIN"
fi

# vault status exit codes: 0 = unsealed, 2 = sealed, 1 = not running / error.
# Treat exit code 2 (sealed) as "running" — only start if we get code 1.
VAULT_EC=0; vault status &>/dev/null || VAULT_EC=$?
if [ "$VAULT_EC" -eq 1 ]; then
    info "Starting Vault..."
    vault server -config vault.hcl > /tmp/vault.log 2>&1 &
    echo $! > .vault.pid
    # Wait until Vault accepts connections (exit code 0 or 2, not 1).
    for _i in $(seq 1 15); do
        VAULT_EC=0; vault status &>/dev/null || VAULT_EC=$?
        [ "$VAULT_EC" -ne 1 ] && break
        sleep 1
    done
    [ "$VAULT_EC" -ne 1 ] || error "Vault did not start within 15 s. Check /tmp/vault.log"
    info "Vault started (PID $(cat .vault.pid))"
fi

# Parse Vault status as JSON to avoid pipefail traps on exit code 2 (sealed).
# vault status exits 2 when sealed; piping it with pipefail would misreport the
# pipeline result regardless of grep/python succeeding.
vault_json() { vault status -format=json 2>/dev/null || true; }
vault_field() { vault_json | python3 -c "import sys,json; d=json.load(sys.stdin); print(str(d.get('$1','')).lower())" 2>/dev/null || true; }

if [ "$(vault_field initialized)" != "true" ]; then
    info "Initializing Vault (1 key share, threshold 1)..."
    INIT_OUTPUT="$(vault operator init -key-shares=1 -key-threshold=1 -format=json)"
    UNSEAL_KEY="$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['unseal_keys_b64'][0])")"
    ROOT_TOKEN="$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])")"
    printf '%s\n' "$UNSEAL_KEY" > .vault-keys
    chmod 600 .vault-keys
    printf '%s\n' "$ROOT_TOKEN" > .vault.token
    chmod 600 .vault.token
    warn "Vault unseal key saved to .vault-keys (gitignored). BACK THIS UP SECURELY."
    warn "Loss of .vault-keys means Vault cannot be unsealed after restart."
fi

if [ "$(vault_field sealed)" == "true" ]; then
    info "Unsealing Vault..."
    vault operator unseal "$(cat .vault-keys)" > /dev/null
fi

export VAULT_TOKEN="$(cat .vault.token)"

# Dev mode auto-enables secret/; file backend does not. Enable KV v2 if absent.
if ! vault secrets list -format=json 2>/dev/null \
        | python3 -c "import sys,json; exit(0 if 'secret/' in json.load(sys.stdin) else 1)" 2>/dev/null; then
    info "Enabling KV v2 secrets engine at secret/..."
    vault secrets enable -path=secret kv-v2
fi

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

prompt_if_empty CERTBOT_EMAIL      "Email for Let's Encrypt registration"

# Admin SSH key: default to ~/.ssh/id_ed25519.pub if present, show a short
# preview so the user can confirm or type a different key.
if [ -z "${ADMIN_SSH_PUBLIC_KEY:-}" ]; then
    if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
        _DEFAULT_KEY="$(cat "$HOME/.ssh/id_ed25519.pub")"
        _PREVIEW="$(awk '{print $1, substr($2,1,20)"…", $3}' "$HOME/.ssh/id_ed25519.pub")"
        read -rp "Admin SSH public key [~/.ssh/id_ed25519.pub — ${_PREVIEW}]: " INPUT
        ADMIN_SSH_PUBLIC_KEY="${INPUT:-$_DEFAULT_KEY}"
        unset _DEFAULT_KEY _PREVIEW INPUT
    else
        prompt_if_empty ADMIN_SSH_PUBLIC_KEY "Admin SSH public key for VPS access (contents of id_ed25519.pub)"
    fi
fi
[ -n "${ADMIN_SSH_PUBLIC_KEY:-}" ] || error "ADMIN_SSH_PUBLIC_KEY cannot be empty"

prompt_if_empty FORGEJO_ADMIN_USER  "Forgejo admin username" "gitadmin"
prompt_if_empty FORGEJO_ADMIN_EMAIL "Forgejo admin email"

# ── 7. Store secrets in Vault ────────────────────────────────────────────────
info "Generating database password and Forgejo secrets..."
DB_PASSWORD="$(openssl rand -base64 32 | tr -d '=/+')"
FORGEJO_SECRET_KEY="$(openssl rand -hex 32)"
FORGEJO_INTERNAL_TOKEN="$(openssl rand -base64 32 | tr -d '=/+')"

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
    ssh_ca_pubkey="$(cat ca.pub)" \
    secret_key="$FORGEJO_SECRET_KEY" \
    internal_token="$FORGEJO_INTERNAL_TOKEN"

vault kv put secret/forgejo/deploy \
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
echo "  Next step:  ./provision.sh"
echo "  (provision.sh will prompt for cloud provider, region, and instance size)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
