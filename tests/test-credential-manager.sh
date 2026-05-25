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
        *)        echo "unexpected vault subcommand: $2" >&2; return 1 ;;
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
assert_has  "file fb shown" "fb"                    "$_out"
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
