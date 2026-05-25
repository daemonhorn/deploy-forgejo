# lib/credential-manager.sh — provider credential lifecycle helpers.
# Source this file; do not execute directly.
# Requires: VAULT_ADDR, VAULT_TOKEN set; error() and warn() defined by the calling script.

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
