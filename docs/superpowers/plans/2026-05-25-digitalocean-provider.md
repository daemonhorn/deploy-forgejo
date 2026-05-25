# DigitalOcean Provider + Credential Lifecycle Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add DigitalOcean as a sixth cloud provider and refactor all providers to use a shared `lib/credential-manager.sh` that reads credentials from a local file first, backs them up to Vault immediately, and reminds the admin to delete the file after a successful run.

**Architecture:** A new `lib/credential-manager.sh` library (sourced by `provision.sh`) provides `load_credential` (text tokens) and `load_credential_json` (JSON blobs); both follow a file-first / Vault-backup / end-of-run-reminder lifecycle. DigitalOcean uses the standard three-file Terraform module contract (`variables.tf`, `outputs.tf`, `main.tf`) plus a root under `terraform/digitalocean/`, integrated into `provision.sh` at the same five touch-points as every other provider.

**Tech Stack:** Bash, Terraform (HCL, `digitalocean/digitalocean ~> 2.0`), HashiCorp Vault KV v2, Python 3 (existing inline scripts in `provision.sh`).

**Spec:** `docs/superpowers/specs/2026-05-25-digitalocean-provider-design.md`

---

## File Map

**New files:**
- `lib/credential-manager.sh` — credential lifecycle library
- `tests/test-credential-manager.sh` — shell unit tests for the library
- `terraform/modules/providers/digitalocean/variables.tf`
- `terraform/modules/providers/digitalocean/outputs.tf`
- `terraform/modules/providers/digitalocean/main.tf`
- `terraform/digitalocean/main.tf`
- `terraform/digitalocean/variables.tf`
- `terraform/digitalocean/outputs.tf`
- `terraform/digitalocean/terraform.tfvars.example`

**Modified files:**
- `.gitignore` — add `digitalocean_personal_token` + terraform cache entries
- `provision.sh` — source library; refactor 6 credential cases; add `digitalocean` to 5 provider-validation strings, region/plan menu, tfvars writer, and Done banner
- `CLAUDE.md` — provider table + credential-flow note

---

## Task 1: Feature branch and `.gitignore`

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Create the feature branch**

```bash
git checkout -b feature/provider-digitalocean
```

Expected: `Switched to a new branch 'feature/provider-digitalocean'`

- [ ] **Step 2: Add `digitalocean_personal_token` to `.gitignore`**

In `.gitignore`, the credentials block currently ends with `google_credentials`. Add the new line immediately after:

Old block (lines 1–8):
```
# Secrets and credentials
vultr_api_key
aws_access_key
aws_secret_access_key
azure_credentials
linode_api_key
google_credentials
users
```

New block:
```
# Secrets and credentials
vultr_api_key
aws_access_key
aws_secret_access_key
azure_credentials
linode_api_key
google_credentials
digitalocean_personal_token
users
```

- [ ] **Step 3: Add DigitalOcean Terraform cache entries to `.gitignore`**

The Terraform cache block currently ends with:
```
terraform/google/.terraform/
terraform/google/.terraform.lock.hcl
```

Add immediately after:
```
terraform/digitalocean/.terraform/
terraform/digitalocean/.terraform.lock.hcl
```

- [ ] **Step 4: Commit**

```bash
git add .gitignore
git commit -m "chore: add digitalocean_personal_token and terraform cache to .gitignore"
```

---

## Task 2: Write tests for `lib/credential-manager.sh`

**Files:**
- Create: `tests/test-credential-manager.sh`

**Design notes:**
- Tests run **inline** (no `(...)` subshells). Subshells copy `PASS`/`FAIL` and never write back, so the final tally would always show `0 passed, 0 failed`.
- `warn()` appends to `_WARNINGS` instead of writing to stderr. This lets us assert on warnings without using command substitution (which would run `load_credential` in a subshell and lose the returned variable value).
- The hard-error test uses `$()` command substitution intentionally: `error()` calls `exit 1`, which exits the command-substitution subshell and sets `_rc` via `|| _rc=$?`. The outer shell continues.
- `_rst()` resets all mock state and library arrays between tests for isolation.

- [ ] **Step 1: Create the test file**

```bash
cat > tests/test-credential-manager.sh << 'HEREDOC'
#!/usr/bin/env bash
# Unit tests for lib/credential-manager.sh.
# Run: bash tests/test-credential-manager.sh
# Requires: lib/credential-manager.sh to exist (will fail until Task 3).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
MOCK_DIR="$(mktemp -d)"
trap 'rm -rf "$MOCK_DIR"' EXIT

# ── Stubs ─────────────────────────────────────────────────────────────────────
# error() exits the current shell (or subshell when used in $(...)).
# warn() appends to $_WARNINGS so tests can assert on it without $() subshells.
error()    { echo "ERROR: $*" >&2; exit 1; }
_WARNINGS=""
warn()     { _WARNINGS+="WARN: $*"$'\n'; }

# ── Mock vault ────────────────────────────────────────────────────────────────
# Bash function lookup takes precedence over PATH, so `vault` here intercepts
# all `vault kv ...` calls inside the library. Controls set per test in _rst().
_MOCK_VAULT_PATCH_FAIL=false
_MOCK_VAULT_METADATA_EXISTS=true
_MOCK_VAULT_GET_VALUE=""
_MOCK_VAULT_CALLS=""

vault() {
    _MOCK_VAULT_CALLS+="$*"$'\n'
    case "$2" in
        get)      [[ "$_MOCK_VAULT_GET_VALUE" == "__MISS__" ]] && return 1
                  echo "$_MOCK_VAULT_GET_VALUE" ;;
        patch)    $_MOCK_VAULT_PATCH_FAIL && return 1; return 0 ;;
        put)      return 0 ;;
        metadata) $_MOCK_VAULT_METADATA_EXISTS && return 0; return 1 ;;
    esac
}

# ── Source library under test ─────────────────────────────────────────────────
source "$SCRIPT_DIR/../lib/credential-manager.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────
pass() { echo "  PASS: $1"; (( PASS+=1 )); }
fail() { echo "  FAIL: $1 | expected='$2' got='$3'"; (( FAIL+=1 )); }
assert_eq()      { [[ "$3" == "$2" ]] && pass "$1" || fail "$1" "$2" "$3"; }
assert_has()     { [[ "$3" == *"$2"* ]] && pass "$1" || fail "$1" "has '$2'" "NOT FOUND"; }
assert_not_has() { [[ "$3" != *"$2"* ]] && pass "$1" || fail "$1" "no '$2' in output" "FOUND"; }

_rst() {
    _MOCK_VAULT_PATCH_FAIL=false; _MOCK_VAULT_METADATA_EXISTS=true
    _MOCK_VAULT_GET_VALUE=""; _MOCK_VAULT_CALLS=""; _WARNINGS=""
    _CRED_FILES_USED=(); _CRED_FIELDS_USED=()
}

# ── Tests ─────────────────────────────────────────────────────────────────────

echo "--- file present: text credential ---"
_rst
_tf="$MOCK_DIR/tok1"; printf '  val123  ' > "$_tf"
load_credential OUT "$_tf" tok_field
assert_eq    "whitespace stripped"   "val123"    "$OUT"
assert_has   "vault patch called"    "kv patch"  "$_MOCK_VAULT_CALLS"
assert_eq    "file tracked"          "$_tf"      "${_CRED_FILES_USED[0]}"
assert_eq    "field tracked"         "tok_field" "${_CRED_FIELDS_USED[0]}"

echo "--- vault fallback: text credential ---"
_rst
_MOCK_VAULT_GET_VALUE="from_vault"
load_credential OUT "$MOCK_DIR/nosuchfile" tok_field
assert_eq      "value from vault"   "from_vault" "$OUT"
assert_eq      "files_used empty"   "0"          "${#_CRED_FILES_USED[@]}"
assert_not_has "no vault patch"      "kv patch"   "$_MOCK_VAULT_CALLS"

echo "--- hard error: file absent + vault missing ---"
_rst
_MOCK_VAULT_GET_VALUE="__MISS__"
_rc=0
_out=$( load_credential OUT "$MOCK_DIR/nosuchfile" miss_f 2>&1 ) || _rc=$?
assert_eq  "exits nonzero"   "1"      "$_rc"
assert_has "mentions field"  "miss_f" "$_out"

echo "--- patch fail + path exists: warns, no put ---"
_rst
_tf="$MOCK_DIR/tok2"; printf 'v2' > "$_tf"
_MOCK_VAULT_PATCH_FAIL=true; _MOCK_VAULT_METADATA_EXISTS=true
load_credential OUT "$_tf" tok_field
assert_has     "warns"         "WARN"   "$_WARNINGS"
assert_not_has "no vault put"  "kv put" "$_MOCK_VAULT_CALLS"
assert_eq      "value set"     "v2"     "$OUT"

echo "--- patch fail + path absent: falls back to put ---"
_rst
_tf="$MOCK_DIR/tok3"; printf 'v3' > "$_tf"
_MOCK_VAULT_PATCH_FAIL=true; _MOCK_VAULT_METADATA_EXISTS=false
load_credential OUT "$_tf" tok_field
assert_has  "vault put called" "kv put"  "$_MOCK_VAULT_CALLS"
assert_eq   "value set"        "v3"      "$OUT"

echo "--- file present: json credential ---"
_rst
_jf="$MOCK_DIR/creds.json"; printf '{"project_id":"myproj"}' > "$_jf"
load_credential_json JOUT "$_jf" json_field
assert_has   "json preserved"   '"project_id"' "$JOUT"
assert_has   "vault patch"      "kv patch"     "$_MOCK_VAULT_CALLS"
assert_eq    "file tracked"     "$_jf"         "${_CRED_FILES_USED[0]}"

echo "--- vault fallback: json credential ---"
_rst
_MOCK_VAULT_GET_VALUE='{"p":"vaultval"}'
load_credential_json JOUT "$MOCK_DIR/nojson" json_field
assert_has  "json from vault"    '"vaultval"'  "$JOUT"
assert_eq   "files_used empty"   "0"           "${#_CRED_FILES_USED[@]}"

echo "--- print_credential_reminders: with files ---"
_rst
_CRED_FILES_USED=("$MOCK_DIR/fa" "$MOCK_DIR/fb")
_CRED_FIELDS_USED=("f1" "f2")
_out=$( print_credential_reminders )
assert_has  "vault path"    "secret/forgejo/cloud"  "$_out"
assert_has  "file fa shown" "fa"                    "$_out"
assert_has  "rm suggested"  "rm "                   "$_out"

echo "--- print_credential_reminders: empty ---"
_rst
_out=$( print_credential_reminders )
assert_eq   "no output"   ""   "$_out"

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[[ "$FAIL" -eq 0 ]]
HEREDOC
chmod +x tests/test-credential-manager.sh
```

- [ ] **Step 2: Run tests — confirm they fail (library does not exist yet)**

```bash
bash tests/test-credential-manager.sh
```

Expected: `tests/test-credential-manager.sh: line N: .../lib/credential-manager.sh: No such file or directory`

- [ ] **Step 3: Commit the test file**

```bash
git add tests/test-credential-manager.sh
git commit -m "test: add unit tests for lib/credential-manager.sh (failing)"
```

---

## Task 3: Implement `lib/credential-manager.sh`

**Files:**
- Create: `lib/credential-manager.sh`

- [ ] **Step 1: Create the library**

```bash
cat > lib/credential-manager.sh << 'HEREDOC'
# lib/credential-manager.sh — provider credential lifecycle helpers.
# Source this file; do not execute directly.
# Requires: VAULT_ADDR, VAULT_TOKEN set; error() and warn() from lib/common.sh.

_CRED_FILES_USED=()   # filenames loaded from disk this run
_CRED_FIELDS_USED=()  # corresponding Vault field names (parallel array)

# _vault_store_value FIELD VALUE
# Merges a plain-text credential into secret/forgejo/cloud.
# Uses `vault kv patch` (merge); falls back to `vault kv put` only when the
# path does not yet exist. Any other patch failure is a non-fatal warning so
# that existing credentials in Vault are never overwritten by a put.
_vault_store_value() {
    local field="$1" value="$2"
    if ! vault kv patch "secret/forgejo/cloud" "${field}=${value}" 2>/dev/null; then
        if ! vault kv metadata get "secret/forgejo/cloud" >/dev/null 2>&1; then
            vault kv put "secret/forgejo/cloud" "${field}=${value}" 2>/dev/null \
                || warn "Could not create Vault secret for '${field}' — credential available for this run only."
        else
            warn "Could not update Vault credential '${field}' — available for this run only (existing Vault data preserved)."
        fi
    fi
}

# _vault_store_file FIELD FILE
# Same as _vault_store_value but reads the value from a file using @syntax,
# preserving exact content (required for JSON blobs with newlines/special chars).
_vault_store_file() {
    local field="$1" file="$2"
    if ! vault kv patch "secret/forgejo/cloud" "${field}=@${file}" 2>/dev/null; then
        if ! vault kv metadata get "secret/forgejo/cloud" >/dev/null 2>&1; then
            vault kv put "secret/forgejo/cloud" "${field}=@${file}" 2>/dev/null \
                || warn "Could not create Vault secret for '${field}' — credential available for this run only."
        else
            warn "Could not update Vault credential '${field}' — available for this run only (existing Vault data preserved)."
        fi
    fi
}

# load_credential VAR_NAME filename vault_field
# Load a plain-text credential (API token, key). Strips whitespace.
# File wins over Vault. If file is present: reads, backs up to Vault, tracks for reminder.
# If file is absent: reads from Vault. Hard error if neither has a value.
load_credential() {
    local var_name="$1" filename="$2" vault_field="$3"
    local value=""
    if [[ -f "$filename" ]]; then
        value="$(tr -d '[:space:]' < "$filename")"
        [[ -n "$value" ]] || error "Credential file '${filename}' is empty."
        _vault_store_value "$vault_field" "$value"
        _CRED_FILES_USED+=("$filename")
        _CRED_FIELDS_USED+=("$vault_field")
    else
        value="$(vault kv get -field="${vault_field}" secret/forgejo/cloud 2>/dev/null || true)"
        [[ -n "$value" ]] || error "Credential '${vault_field}' not found: '${filename}' does not exist and the field is absent from Vault (secret/forgejo/cloud). Provide the credential file or run: vault kv patch secret/forgejo/cloud ${vault_field}=<value>"
    fi
    printf -v "$var_name" '%s' "$value"
}

# load_credential_json VAR_NAME filename vault_field
# Load a JSON credential (Azure/Google service account blobs). Preserves content exactly.
# Same file-first / Vault-fallback / reminder lifecycle as load_credential.
load_credential_json() {
    local var_name="$1" filename="$2" vault_field="$3"
    local value=""
    if [[ -f "$filename" ]]; then
        value="$(< "$filename")"
        [[ -n "$value" ]] || error "Credential file '${filename}' is empty."
        _vault_store_file "$vault_field" "$filename"
        _CRED_FILES_USED+=("$filename")
        _CRED_FIELDS_USED+=("$vault_field")
    else
        value="$(vault kv get -field="${vault_field}" secret/forgejo/cloud 2>/dev/null || true)"
        [[ -n "$value" ]] || error "Credential '${vault_field}' not found: '${filename}' does not exist and the field is absent from Vault (secret/forgejo/cloud)."
    fi
    printf -v "$var_name" '%s' "$value"
}

# print_credential_reminders
# Prints a reminder for each credential file loaded from disk this run.
# Call once, at the end of a successful provision run.
print_credential_reminders() {
    [[ ${#_CRED_FILES_USED[@]} -eq 0 ]] && return 0
    local i
    echo
    echo "  ── Credential file(s) backed up to Vault ──────────────"
    echo "     Vault path : secret/forgejo/cloud"
    for (( i=0; i<${#_CRED_FILES_USED[@]}; i++ )); do
        echo "     Field '${_CRED_FIELDS_USED[$i]}' backed up from: ${_CRED_FILES_USED[$i]}"
        echo "     Safe to delete: rm ${_CRED_FILES_USED[$i]}"
    done
}
HEREDOC
```

- [ ] **Step 2: Run the tests — all should pass**

```bash
bash tests/test-credential-manager.sh
```

Expected output (all lines showing PASS):
```
=== load_credential: file present ===
  PASS: whitespace stripped
  PASS: vault kv patch called
  PASS: file tracked
  PASS: field tracked

=== load_credential: file absent, Vault has value ===
  PASS: value from Vault
  PASS: _CRED_FILES_USED empty
  PASS: vault kv patch NOT called
...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Results: 23 passed, 0 failed
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

If any test fails, read the FAIL output, fix `lib/credential-manager.sh`, and re-run until all pass.

- [ ] **Step 3: Commit**

```bash
git add lib/credential-manager.sh
git commit -m "feat: add lib/credential-manager.sh — file-first Vault-backup credential lifecycle"
```

---

## Task 4: Refactor `provision.sh` credential loading

**Files:**
- Modify: `provision.sh`

This task makes six targeted edits to `provision.sh`. Read each section before editing.

- [ ] **Step 1: Source the library after `lib/common.sh`**

Find the line (currently line 14):
```bash
source "$SCRIPT_DIR/lib/common.sh"
```

Replace with:
```bash
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/credential-manager.sh"
```

- [ ] **Step 2: Update provider validation in `--provider` arg parser**

Find (in the `--provider)` case of the arg parser):
```bash
[[ $# -ge 2 ]] || error "--provider requires a value (vultr|aws|azure|linode|google)"
```

Replace with:
```bash
[[ $# -ge 2 ]] || error "--provider requires a value (vultr|aws|azure|linode|google|digitalocean)"
```

- [ ] **Step 3: Update provider validation — post-parse guard**

Find:
```bash
if [[ -n "$PROVIDER" && "$PROVIDER" != "vultr" && "$PROVIDER" != "aws" && "$PROVIDER" != "azure" && "$PROVIDER" != "linode" && "$PROVIDER" != "google" ]]; then
    error "Invalid provider '$PROVIDER'. Use vultr, aws, azure, linode, or google."
fi
```

Replace with:
```bash
if [[ -n "$PROVIDER" && "$PROVIDER" != "vultr" && "$PROVIDER" != "aws" && "$PROVIDER" != "azure" && "$PROVIDER" != "linode" && "$PROVIDER" != "google" && "$PROVIDER" != "digitalocean" ]]; then
    error "Invalid provider '$PROVIDER'. Use vultr, aws, azure, linode, google, or digitalocean."
fi
```

- [ ] **Step 4: Update `--non-interactive` error message**

Find:
```bash
error "--non-interactive requires --provider <vultr|aws|azure|linode|google>"
```

Replace with:
```bash
error "--non-interactive requires --provider <vultr|aws|azure|linode|google|digitalocean>"
```

- [ ] **Step 5: Update interactive provider prompt**

Find:
```bash
    read -rp "[provision] Cloud provider (vultr/aws/azure/linode/google) [${DEFAULT_PROVIDER}]: " _prov
    PROVIDER="${_prov:-$DEFAULT_PROVIDER}"
    [[ "$PROVIDER" == "vultr" || "$PROVIDER" == "aws" || "$PROVIDER" == "azure" || "$PROVIDER" == "linode" || "$PROVIDER" == "google" ]] \
        || error "Invalid provider '$PROVIDER'. Use vultr, aws, azure, linode, or google."
```

Replace with:
```bash
    read -rp "[provision] Cloud provider (vultr/aws/azure/linode/google/digitalocean) [${DEFAULT_PROVIDER}]: " _prov
    PROVIDER="${_prov:-$DEFAULT_PROVIDER}"
    [[ "$PROVIDER" == "vultr" || "$PROVIDER" == "aws" || "$PROVIDER" == "azure" || "$PROVIDER" == "linode" || "$PROVIDER" == "google" || "$PROVIDER" == "digitalocean" ]] \
        || error "Invalid provider '$PROVIDER'. Use vultr, aws, azure, linode, google, or digitalocean."
```

- [ ] **Step 6: Refactor credential loading — vultr, aws, linode**

Find the entire `case "$PROVIDER" in` credential block. Replace the `vultr)`, `aws)`, and `linode)` arms:

Old `vultr)` arm:
```bash
    vultr)
        export TF_VAR_vultr_api_key="$(vget vultr_api_key secret/forgejo/cloud)"
        TF_DIR="$SCRIPT_DIR/terraform/vultr"
        ;;
```

New `vultr)` arm:
```bash
    vultr)
        load_credential _vultr_token vultr_api_key vultr_api_key
        export TF_VAR_vultr_api_key="$_vultr_token"
        TF_DIR="$SCRIPT_DIR/terraform/vultr"
        ;;
```

Old `aws)` arm:
```bash
    aws)
        [ -f aws_access_key ]        || error "aws_access_key file not found in $SCRIPT_DIR"
        [ -f aws_secret_access_key ] || error "aws_secret_access_key file not found in $SCRIPT_DIR"
        export AWS_ACCESS_KEY_ID="$(tr -d '[:space:]' < aws_access_key)"
        export AWS_SECRET_ACCESS_KEY="$(tr -d '[:space:]' < aws_secret_access_key)"
        TF_DIR="$SCRIPT_DIR/terraform/aws"
        ;;
```

New `aws)` arm:
```bash
    aws)
        load_credential AWS_ACCESS_KEY_ID aws_access_key aws_access_key
        load_credential AWS_SECRET_ACCESS_KEY aws_secret_access_key aws_secret_access_key
        export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
        TF_DIR="$SCRIPT_DIR/terraform/aws"
        ;;
```

Old `linode)` arm:
```bash
    linode)
        [ -f linode_api_key ] || error "linode_api_key file not found in $SCRIPT_DIR"
        export LINODE_TOKEN="$(tr -d '[:space:]' < linode_api_key)"
        TF_DIR="$SCRIPT_DIR/terraform/linode"
        ;;
```

New `linode)` arm:
```bash
    linode)
        load_credential LINODE_TOKEN linode_api_key linode_api_key
        export LINODE_TOKEN
        TF_DIR="$SCRIPT_DIR/terraform/linode"
        ;;
```

- [ ] **Step 7: Refactor credential loading — google**

Old `google)` arm (the entire arm including the Python heredoc):
```bash
    google)
        [ -f google_credentials ] || error "google_credentials file not found in $SCRIPT_DIR"
        # Parse service account JSON to extract project_id and export credentials.
        # Write exports to a temp file and source it — eval "$(python3 ...)" masks Python's
        # exit code (eval "" returns 0 even when python3 exits 1), causing silent failures.
        _google_env="$(mktemp)"
        python3 - "$_google_env" <<'PY' || error "Cannot load google_credentials — see error above."
import json, sys, shlex
try:
    d = json.load(open("google_credentials"))
except Exception as e:
    sys.exit(f"Cannot parse google_credentials: {e}")
project_id = d.get("project_id", "")
if not project_id:
    sys.exit("google_credentials: missing 'project_id'. Ensure this is a valid GCP service account key JSON.")
cred_type = d.get("type", "")
if cred_type not in ("service_account", "authorized_user", "external_account"):
    sys.exit(f"google_credentials: unexpected type '{cred_type}'. Expected service_account JSON from GCP console.")
with open(sys.argv[1], 'w') as f:
    f.write(f"export GOOGLE_PROJECT={shlex.quote(project_id)}\n")
    f.write(f"export GOOGLE_CREDENTIALS={shlex.quote(json.dumps(d))}\n")
PY
        # shellcheck disable=SC1090
        source "$_google_env"
        rm -f "$_google_env"
        TF_DIR="$SCRIPT_DIR/terraform/google"
        ;;
```

New `google)` arm:
```bash
    google)
        load_credential_json _google_json google_credentials google_credentials
        _google_env="$(mktemp)"
        _google_cred_tmp="$(mktemp)"
        printf '%s' "$_google_json" > "$_google_cred_tmp"
        python3 - "$_google_env" "$_google_cred_tmp" <<'PY' || error "Cannot load google_credentials — see error above."
import json, sys, shlex
try:
    d = json.load(open(sys.argv[2]))
except Exception as e:
    sys.exit(f"Cannot parse google_credentials: {e}")
project_id = d.get("project_id", "")
if not project_id:
    sys.exit("google_credentials: missing 'project_id'. Ensure this is a valid GCP service account key JSON.")
cred_type = d.get("type", "")
if cred_type not in ("service_account", "authorized_user", "external_account"):
    sys.exit(f"google_credentials: unexpected type '{cred_type}'. Expected service_account JSON from GCP console.")
with open(sys.argv[1], 'w') as f:
    f.write(f"export GOOGLE_PROJECT={shlex.quote(project_id)}\n")
    f.write(f"export GOOGLE_CREDENTIALS={shlex.quote(json.dumps(d))}\n")
PY
        # shellcheck disable=SC1090
        source "$_google_env"
        rm -f "$_google_env" "$_google_cred_tmp"
        TF_DIR="$SCRIPT_DIR/terraform/google"
        ;;
```

- [ ] **Step 8: Refactor credential loading — azure**

Old `azure)` arm:
```bash
    azure)
        [ -f azure_credentials ] || error "azure_credentials file not found in $SCRIPT_DIR"
        # Parse JSON credentials; support both az-cli field names (appId/password/tenant)
        # and SDK-auth aliases (clientId/clientSecret/tenantId/subscriptionId).
        # Write exports to a temp file and source it — eval "$(python3 ...)" masks Python's
        # exit code (eval "" returns 0 even when python3 exits 1), causing silent failures.
        _azure_env="$(mktemp)"
        python3 - "$_azure_env" <<'PY' || error "Cannot load azure_credentials — see error above."
import json, sys, shlex
try:
    d = json.load(open("azure_credentials"))
except Exception as e:
    sys.exit(f"Cannot parse azure_credentials: {e}")
```

New `azure)` arm (replace from `azure)` through `rm -f "$_azure_env"`):
```bash
    azure)
        load_credential_json _azure_json azure_credentials azure_credentials
        _azure_env="$(mktemp)"
        _azure_cred_tmp="$(mktemp)"
        printf '%s' "$_azure_json" > "$_azure_cred_tmp"
        python3 - "$_azure_env" "$_azure_cred_tmp" <<'PY' || error "Cannot load azure_credentials — see error above."
import json, sys, shlex
try:
    d = json.load(open(sys.argv[2]))
except Exception as e:
    sys.exit(f"Cannot parse azure_credentials: {e}")
def require(key, *aliases):
    for k in (key,) + aliases:
        if k in d and d[k]:
            return d[k]
    if key == "subscriptionId":
        import subprocess
        try:
            r = subprocess.run(['az', 'account', 'show', '--query', 'id', '-o', 'tsv'],
                               capture_output=True, text=True, timeout=10)
            if r.returncode == 0 and r.stdout.strip():
                return r.stdout.strip()
        except Exception:
            pass
        checked = ', '.join((key,) + aliases)
        sys.exit(f"azure_credentials: missing '{key}' and 'az account show' failed.\n"
                 f"  Add it manually: {{\"subscriptionId\": \"<id>\", ...}}\n"
                 f"  Find your subscription ID with: az account show --query id -o tsv")
    checked = ', '.join((key,) + aliases)
    sys.exit(f"azure_credentials: missing required field '{key}' (checked: {checked})")
pairs = [
    ("ARM_CLIENT_ID",       require("clientId",       "appId")),
    ("ARM_CLIENT_SECRET",   require("clientSecret",   "password")),
    ("ARM_SUBSCRIPTION_ID", require("subscriptionId", "subscription_id", "subscription")),
    ("ARM_TENANT_ID",       require("tenantId",       "tenant")),
]
with open(sys.argv[1], 'w') as f:
    for k, v in pairs:
        f.write(f"export {k}={shlex.quote(v)}\n")
PY
        # shellcheck disable=SC1090
        source "$_azure_env"
        rm -f "$_azure_env" "$_azure_cred_tmp"
        TF_DIR="$SCRIPT_DIR/terraform/azure"
        ;;
```

- [ ] **Step 9: Add the digitalocean credential case**

After the `azure)` arm's closing `;;` and before `esac`, add:
```bash
    digitalocean)
        load_credential DIGITALOCEAN_TOKEN digitalocean_personal_token digitalocean_token
        export DIGITALOCEAN_TOKEN
        TF_DIR="$SCRIPT_DIR/terraform/digitalocean"
        ;;
```

- [ ] **Step 10: Add `print_credential_reminders` to the Done banner**

Find the closing banner line at the bottom of `provision.sh`:
```bash
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```
(The final `━━━` line — there are two; use the last one.)

Insert `print_credential_reminders` immediately before it:
```bash
print_credential_reminders
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

- [ ] **Step 11: Commit**

```bash
git add provision.sh
git commit -m "refactor: use credential-manager.sh for all provider credential loading"
```

---

## Task 5: Add DigitalOcean region/plan selection to `provision.sh`

**Files:**
- Modify: `provision.sh`

- [ ] **Step 1: Add the `digitalocean)` region/plan arm**

Find the closing `esac` of the region/plan `case "$PROVIDER" in` block (the one that ends after the `google)` arm, around line 1183). Insert the new arm immediately before that `esac`:

```bash
    digitalocean)
        [[ -z "$CURRENT_REGION" ]] && CURRENT_REGION="nyc1"
        [[ -z "$CURRENT_PLAN" ]]   && CURRENT_PLAN="s-1vcpu-1gb"

        # DigitalOcean regions: static list (API requires auth token; no unauthenticated endpoint).
        REGIONS=(
            "nyc1:New York 1 - US East"
            "nyc3:New York 3 - US East"
            "sfo3:San Francisco 3 - US West"
            "ams3:Amsterdam 3 - EU"
            "sgp1:Singapore - AP"
            "lon1:London - EU"
            "fra1:Frankfurt - EU"
            "tor1:Toronto - Canada"
            "blr1:Bangalore - AP"
            "syd1:Sydney - AU"
        )

        PLANS=(
            "s-1vcpu-1gb:1C/1GB/25GB SSD    ~\$6/mo   (recommended minimum)"
            "s-1vcpu-2gb:1C/2GB/50GB SSD    ~\$12/mo"
            "s-2vcpu-2gb:2C/2GB/60GB SSD    ~\$18/mo"
            "s-2vcpu-4gb:2C/4GB/80GB SSD    ~\$24/mo"
        )

        if $NON_INTERACTIVE; then
            [[ -n "$REGION_ARG" ]] || error "--non-interactive requires --region for digitalocean"
            [[ -n "$PLAN_ARG"   ]] || error "--non-interactive requires --plan for digitalocean"
            REGION="$REGION_ARG"; PLAN="$PLAN_ARG"
        else
            show_menu "DigitalOcean regions (static; verify at slugs.do-api.dev):" \
                "$CURRENT_REGION" "${REGIONS[@]}"
            REGION="$_MENU_RESULT"
            show_menu "DigitalOcean droplet sizes (static; verify at slugs.do-api.dev):" \
                "$CURRENT_PLAN" "${PLANS[@]}"
            PLAN="$_MENU_RESULT"
        fi
        ;;
```

- [ ] **Step 2: Add `digitalocean` to the tfvars-writing case**

Find:
```bash
    aws|azure|linode|google)
```

Replace with:
```bash
    aws|azure|linode|google|digitalocean)
```

- [ ] **Step 3: Commit**

```bash
git add provision.sh
git commit -m "feat: add DigitalOcean provider to provision.sh menus and credential loading"
```

---

## Task 6: Create DigitalOcean Terraform module

**Files:**
- Create: `terraform/modules/providers/digitalocean/variables.tf`
- Create: `terraform/modules/providers/digitalocean/outputs.tf`
- Create: `terraform/modules/providers/digitalocean/main.tf`

- [ ] **Step 1: Create `variables.tf`**

```bash
mkdir -p terraform/modules/providers/digitalocean
cat > terraform/modules/providers/digitalocean/variables.tf << 'EOF'
# Standard provider contract — all provider modules must accept these exact variables.

variable "ssh_public_key" {
  description = "Ed25519 public key material to upload for admin droplet access."
  type        = string
}

variable "region" {
  description = "DigitalOcean region slug (e.g. 'nyc1' = New York 1). See: slugs.do-api.dev"
  type        = string
}

variable "plan" {
  description = "DigitalOcean droplet size slug (e.g. 's-1vcpu-1gb'). See: slugs.do-api.dev"
  type        = string
}

variable "hostname" {
  description = "Droplet hostname / label."
  type        = string
}

variable "firewall_ports" {
  description = "All TCP ports to open inbound. Public ports get 0.0.0.0/0; admin_only_ports get allowed_cidrs."
  type        = list(number)
}

variable "admin_only_ports" {
  description = "Subset of firewall_ports restricted to allowed_cidrs (default: SSH ports + HTTPS)."
  type        = list(number)
  default     = [22, 2222, 443]
}

variable "allowed_cidrs" {
  description = "CIDRs permitted inbound on admin_only_ports. Empty list blocks all admin access (fail-closed). provision.sh populates this from --admin-cidrs or auto-detected admin IP."
  type        = list(string)
  default     = []
}

variable "user_cidrs" {
  description = "CIDRs permitted inbound on user_accessible_ports (2222, 443). Not persisted to tfvars; pass via --user-cidrs on each provision run. Empty list means user ports are admin-only (fail-closed)."
  type        = list(string)
  default     = []
}

variable "ip_stack" {
  description = "IP stack: 'ipv4' (IPv4 only), 'dual' (IPv4 + IPv6), or 'ipv6' (IPv6 only — firewall blocks IPv4)."
  type        = string
  default     = "ipv4"
  validation {
    condition     = contains(["ipv4", "ipv6", "dual"], var.ip_stack)
    error_message = "ip_stack must be 'ipv4', 'ipv6', or 'dual'."
  }
}
EOF
```

- [ ] **Step 2: Create `outputs.tf`**

```bash
cat > terraform/modules/providers/digitalocean/outputs.tf << 'EOF'
# Standard provider contract — all provider modules must emit these exact outputs.

output "public_ipv4" {
  description = "Droplet public IPv4 address (empty string when ip_stack = 'ipv6')."
  value       = var.ip_stack != "ipv6" ? digitalocean_droplet.main.ipv4_address : ""
}

output "public_ipv6" {
  description = "Droplet public IPv6 address (empty string when ip_stack = 'ipv4'). Bare address — no '/128' suffix."
  value       = var.ip_stack != "ipv4" ? digitalocean_droplet.main.ipv6_address : ""
}

output "ssh_user" {
  description = "SSH login user. DigitalOcean Debian droplets boot with root SSH key access."
  value       = "root"
}

output "instance_id" {
  description = "DigitalOcean droplet ID for lifecycle operations."
  value       = digitalocean_droplet.main.id
}
EOF
```

- [ ] **Step 3: Create `main.tf`**

```bash
cat > terraform/modules/providers/digitalocean/main.tf << 'EOF'
terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

locals {
  # Ports open to the world (not in admin_only_ports).
  public_ports = [for p in var.firewall_ports : p if !contains(var.admin_only_ports, p)]

  # Ports within admin_only_ports that user CIDRs may also reach (excludes port 22).
  user_accessible_ports = [for p in var.admin_only_ports : p if !contains([22], p)]

  # ip_stack-aware admin CIDRs: filter by address family to avoid adding IPv4 rules
  # in ipv6-only mode or IPv6 rules in ipv4-only mode. Mixed IPv4+IPv6 in ipv4 mode
  # source_addresses list is not an issue for DO firewall, but we stay consistent
  # with the pattern used in the Google module.
  admin_cidrs = concat(
    var.ip_stack != "ipv6" ? [for c in var.allowed_cidrs : c if !strcontains(c, ":")] : [],
    var.ip_stack != "ipv4" ? [for c in var.allowed_cidrs : c if strcontains(c, ":")] : []
  )

  user_cidrs = concat(
    var.ip_stack != "ipv6" ? [for c in var.user_cidrs : c if !strcontains(c, ":")] : [],
    var.ip_stack != "ipv4" ? [for c in var.user_cidrs : c if strcontains(c, ":")] : []
  )

  # Source ranges for world-open ports, filtered by ip_stack.
  public_source_ranges = concat(
    var.ip_stack != "ipv6" ? ["0.0.0.0/0"] : [],
    var.ip_stack != "ipv4" ? ["::/0"] : []
  )
}

resource "digitalocean_ssh_key" "admin" {
  name       = "${var.hostname}-admin"
  public_key = var.ssh_public_key
}

resource "digitalocean_droplet" "main" {
  image    = "debian-12-x64"
  name     = var.hostname
  region   = var.region
  size     = var.plan
  ssh_keys = [digitalocean_ssh_key.admin.fingerprint]

  # DigitalOcean always assigns an IPv4 address. ipv6 = true adds a /128 SLAAC IPv6 address.
  # In ipv6-only mode the IPv4 address still exists but the firewall blocks all IPv4 inbound.
  ipv6 = var.ip_stack != "ipv4"
}

resource "digitalocean_firewall" "main" {
  name        = "${var.hostname}-fw"
  droplet_ids = [digitalocean_droplet.main.id]

  # World-open ingress for public ports (e.g. port 80 for ACME HTTP-01).
  dynamic "inbound_rule" {
    for_each = { for p in local.public_ports : tostring(p) => p }
    content {
      protocol         = "tcp"
      port_range       = inbound_rule.key
      source_addresses = local.public_source_ranges
    }
  }

  # Admin-only ingress: 22, 2222, 443. Omitted when allowed_cidrs is empty (fail-closed).
  dynamic "inbound_rule" {
    for_each = length(local.admin_cidrs) > 0 ? { for p in var.admin_only_ports : tostring(p) => p } : {}
    content {
      protocol         = "tcp"
      port_range       = inbound_rule.key
      source_addresses = local.admin_cidrs
    }
  }

  # User-accessible ingress: 2222 and 443. Omitted when user_cidrs is empty (fail-closed).
  dynamic "inbound_rule" {
    for_each = length(local.user_cidrs) > 0 ? { for p in local.user_accessible_ports : tostring(p) => p } : {}
    content {
      protocol         = "tcp"
      port_range       = inbound_rule.key
      source_addresses = local.user_cidrs
    }
  }

  # Allow all outbound — required; DigitalOcean Cloud Firewall blocks all egress by default.
  outbound_rule {
    protocol              = "tcp"
    port_range            = "all"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "all"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
EOF
```

- [ ] **Step 4: Run `terraform fmt` on the module**

```bash
terraform fmt terraform/modules/providers/digitalocean/
```

Expected: The three filenames printed (or no output if already formatted).

- [ ] **Step 5: Commit**

```bash
git add terraform/modules/providers/digitalocean/
git commit -m "feat: add terraform/modules/providers/digitalocean — droplet + firewall module"
```

---

## Task 7: Create DigitalOcean Terraform root

**Files:**
- Create: `terraform/digitalocean/main.tf`
- Create: `terraform/digitalocean/variables.tf`
- Create: `terraform/digitalocean/outputs.tf`
- Create: `terraform/digitalocean/terraform.tfvars.example`

- [ ] **Step 1: Create `main.tf`**

```bash
mkdir -p terraform/digitalocean
cat > terraform/digitalocean/main.tf << 'EOF'
terraform {
  required_version = ">= 1.5"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }

  # TODO: migrate to an encrypted remote backend (S3/GCS with SSE) before team use.
  backend "local" {}
}

# Credentials supplied via DIGITALOCEAN_TOKEN env var (set by provision.sh from
# the digitalocean_personal_token file or Vault secret/forgejo/cloud).
provider "digitalocean" {}

module "infra" {
  source = "../modules/providers/digitalocean"

  ssh_public_key   = var.admin_ssh_public_key
  region           = var.region
  plan             = var.plan
  hostname         = var.hostname
  firewall_ports   = var.firewall_ports
  admin_only_ports = var.admin_only_ports
  allowed_cidrs    = var.allowed_cidrs
  user_cidrs       = var.user_cidrs
  ip_stack         = var.ip_stack
}
EOF
```

- [ ] **Step 2: Create `variables.tf`**

```bash
cat > terraform/digitalocean/variables.tf << 'EOF'
variable "region" {
  description = "DigitalOcean region slug (e.g. 'nyc1' = New York 1). See: slugs.do-api.dev"
  type        = string
  default     = "nyc1"
}

variable "plan" {
  description = "DigitalOcean droplet size slug (e.g. 's-1vcpu-1gb' = 1 vCPU, 1 GB RAM). See: slugs.do-api.dev"
  type        = string
  default     = "s-1vcpu-1gb"
}

variable "hostname" {
  description = "Droplet hostname / label."
  type        = string
  default     = "forgejo"
}

variable "admin_ssh_public_key" {
  description = "Ed25519 public key for droplet admin SSH access. Supply via TF_VAR_admin_ssh_public_key; never commit to tfvars."
  type        = string
  sensitive   = true
}

variable "firewall_ports" {
  description = "All TCP ports to open inbound. Public ports get 0.0.0.0/0; admin_only_ports get allowed_cidrs."
  type        = list(number)
  default     = [22, 80, 443, 2222]
}

variable "admin_only_ports" {
  description = "Subset of firewall_ports restricted to allowed_cidrs. Port 443 is admin-restricted; use user_cidrs to open it to a wider audience."
  type        = list(number)
  default     = [22, 2222, 443]
}

variable "allowed_cidrs" {
  description = "CIDRs allowed inbound on admin_only_ports. Empty list blocks all admin access (fail-closed). Written by provision.sh."
  type        = list(string)
  default     = []
}

variable "user_cidrs" {
  description = "CIDRs allowed inbound on ports 2222 and 443 (in addition to admin CIDRs). Not persisted to tfvars; supply via --user-cidrs on each provision run. Empty list = ports 2222/443 are admin-only (fail-closed)."
  type        = list(string)
  default     = []
}

variable "ip_stack" {
  description = "IP stack: 'ipv4' (default), 'dual' (IPv4 + IPv6), or 'ipv6' (IPv6 only)."
  type        = string
  default     = "ipv4"
}
EOF
```

- [ ] **Step 3: Create `outputs.tf`**

```bash
cat > terraform/digitalocean/outputs.tf << 'EOF'
output "public_ipv4" {
  description = "Droplet public IPv4 address."
  value       = module.infra.public_ipv4
}

output "public_ipv6" {
  description = "Droplet public IPv6 address."
  value       = module.infra.public_ipv6
}

output "ssh_user" {
  description = "SSH user for provisioning."
  value       = module.infra.ssh_user
}

output "instance_id" {
  description = "DigitalOcean droplet ID."
  value       = module.infra.instance_id
}
EOF
```

- [ ] **Step 4: Create `terraform.tfvars.example`**

```bash
cat > terraform/digitalocean/terraform.tfvars.example << 'EOF'
# Copy to terraform.tfvars (gitignored) and fill in real values.
# Do NOT set digitalocean_token here — supply it via DIGITALOCEAN_TOKEN env var (set by provision.sh).
# admin_ssh_public_key is supplied via TF_VAR_admin_ssh_public_key by provision.sh
# (read from Vault) — do NOT set it here.

region   = "nyc1"         # New York 1; see: slugs.do-api.dev for all region slugs
plan     = "s-1vcpu-1gb"  # 1 vCPU, 1 GB RAM, 25 GB disk — ~$6/mo; smallest viable size
hostname = "forgejo"
EOF
```

- [ ] **Step 5: Run `terraform fmt`**

```bash
terraform fmt terraform/digitalocean/
```

- [ ] **Step 6: Run `terraform init` and `terraform validate`**

```bash
cd terraform/digitalocean
terraform init
terraform validate
cd ../..
```

Expected: `Success! The configuration is valid.`

If `terraform validate` fails, read the error message and fix the HCL before continuing.

- [ ] **Step 7: Commit**

```bash
git add terraform/digitalocean/
git commit -m "feat: add terraform/digitalocean root — DigitalOcean provider root module"
```

---

## Task 8: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add DigitalOcean to the provider table**

Find the Supported Cloud Providers table. It currently ends with:
```
| `google` | `google_credentials` (service account JSON) | `terraform/google/` | `e2-micro` |
```

Add a new row immediately after:
```
| `digitalocean` | `digitalocean_personal_token` | `terraform/digitalocean/` | `s-1vcpu-1gb` |
```

- [ ] **Step 2: Add credential-flow note to Secrets and Security section**

Find the Secrets and Security section. After the bullet:
```
- `vultr_api_key` file: gitignored; read once by `setup.sh` into Vault
```

Add a new bullet:
```
- All credential files (e.g. `digitalocean_personal_token`, `linode_api_key`): gitignored; on each `provision.sh` run the file is read first (file wins over Vault), immediately backed up to `secret/forgejo/cloud`, and the admin is reminded to delete the file at the end of a successful run. The Vault copy is used on subsequent runs once the file is deleted.
```

- [ ] **Step 3: Update the credentials file column header note in the Supported Cloud Providers table (if present) or add a note below the table**

Below the Supported Cloud Providers table, add:

```
**Credential lifecycle:** `provision.sh` reads credentials from the local file first. If a file is present it is immediately backed up to Vault (`secret/forgejo/cloud`) and the admin is reminded to delete the file after a successful run.
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md with DigitalOcean provider and credential lifecycle notes"
```

---

## Task 9: Self-review and final checks

- [ ] **Step 1: Re-run the credential-manager tests**

```bash
bash tests/test-credential-manager.sh
```

Expected: all pass, 0 failed.

- [ ] **Step 2: Verify `provision.sh` has no syntax errors**

```bash
bash -n provision.sh
```

Expected: no output (no syntax errors).

- [ ] **Step 3: Confirm `digitalocean_personal_token` is gitignored**

```bash
echo "test" > digitalocean_personal_token
git status digitalocean_personal_token
rm digitalocean_personal_token
```

Expected: `digitalocean_personal_token` does NOT appear as a tracked or untracked file (it should be ignored). The `git status` command should show nothing for that file.

- [ ] **Step 4: Verify Terraform module validates cleanly**

```bash
cd terraform/digitalocean && terraform validate && cd ../..
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Check all provider strings are updated in `provision.sh`**

```bash
grep -n "vultr|aws|azure|linode|google" provision.sh | grep -v "digitalocean"
```

Expected: zero lines (every occurrence of that pattern now includes `digitalocean`). If any lines appear, add `digitalocean` to those spots and re-run.

- [ ] **Step 6: Confirm git log looks clean**

```bash
git log --oneline feature/provider-digitalocean ^master
```

Expected output (roughly — exact hashes will differ):
```
<hash> docs: update CLAUDE.md with DigitalOcean provider and credential lifecycle notes
<hash> feat: add terraform/digitalocean root — DigitalOcean provider root module
<hash> feat: add terraform/modules/providers/digitalocean — droplet + firewall module
<hash> feat: add DigitalOcean provider to provision.sh menus and credential loading
<hash> refactor: use credential-manager.sh for all provider credential loading
<hash> feat: add lib/credential-manager.sh — file-first Vault-backup credential lifecycle
<hash> test: add unit tests for lib/credential-manager.sh (failing)
<hash> chore: add digitalocean_personal_token and terraform cache to .gitignore
```
