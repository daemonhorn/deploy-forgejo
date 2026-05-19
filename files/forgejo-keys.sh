#!/bin/bash
# /usr/local/bin/forgejo-keys.sh — installed on VPS by deploy.sh
#
# Called by sshd AuthorizedKeysCommand for port-2222 (git user) connections.
# Arguments match sshd_config tokens: %u %t %k
#
# For raw key auth: passes type and key directly to Forgejo.
# For cert auth: extracts the base public key from the certificate, then
# queries Forgejo so it returns the correct "command=forgejo serv key-X" line.
#
# Audit log: every auth attempt is logged to syslog (tag forgejo-auth).  View with:
#   journalctl -t forgejo-auth
#
# Verbose debug: set FORGEJO_KEYS_DEBUG=1 in the AuthorizedKeysCommand environment
# (or export it before the sshd invocation) to enable per-field cert parsing traces.
set -euo pipefail

USERNAME="$1"
KEY_TYPE="$2"
KEY_B64="$3"

# ── Helpers ────────────────────────────────────────────────────────────────────

# Structured audit line → syslog (tag forgejo-auth).  Runs as nobody; no file
# write needed.  Journald captures it; `journalctl -t forgejo-auth` to read.
_audit() { /usr/bin/logger -t forgejo-auth -- "$*"; }

# Compute SHA256 fingerprint for a "type base64" public key string.
# Writes the fingerprint (e.g. SHA256:xxxx) to stdout, or "fp:unknown" on failure.
_fingerprint() {
    local _f _fp
    _f="$(mktemp)"
    printf '%s\n' "$1" > "$_f"
    _fp="$(ssh-keygen -l -E sha256 -f "$_f" 2>/dev/null | awk '{print $2}')" || true
    rm -f "$_f"
    printf '%s' "${_fp:-fp:unknown}"
}

# Query Forgejo for the authorized_keys line for (username, key-type, key-base64).
# Captures docker exec stderr and logs any non-empty output; prints Forgejo stdout.
_forgejo_query() {
    local _err_f _out _rc _err
    _err_f="$(mktemp)"
    _rc=0
    _out="$(sudo /usr/bin/docker exec -u git forgejo \
        forgejo keys -e git -u "$1" -t "$2" -k "$3" 2>"$_err_f")" || _rc=$?
    _err="$(cat "$_err_f")"; rm -f "$_err_f"
    if [[ -n "$_err" ]]; then
        _audit "WARN docker-exec-stderr user=$USERNAME: ${_err:0:300}"
    fi
    if [[ $_rc -ne 0 ]]; then
        _audit "WARN docker-exec-failed user=$USERNAME rc=$_rc"
    fi
    printf '%s' "$_out"
}

# ── Main auth flow ─────────────────────────────────────────────────────────────

IS_CERT=false
[[ "$KEY_TYPE" == *"-cert-v01@openssh.com" ]] && IS_CERT=true

FP="$(_fingerprint "$KEY_TYPE $KEY_B64")"

# SSH_CONNECTION is set by sshd: "client_ip client_port server_ip server_port".
# Extract client IP for audit log; fall back to "unknown" if unset (e.g. test invocation).
# Use ${VAR:-} not ${VAR} so set -u does not abort when sshd omits SSH_CONNECTION
# from the AuthorizedKeysCommand environment (observed on OpenSSH 9.2).
CLIENT_IP="${SSH_CONNECTION:-}"
CLIENT_IP="${CLIENT_IP%% *}"
CLIENT_IP="${CLIENT_IP:-unknown}"

if [[ "${FORGEJO_KEYS_DEBUG:-0}" == "1" ]]; then
    _audit "DEBUG user=$USERNAME kt=$KEY_TYPE fp=$FP is_cert=$IS_CERT"
fi

if $IS_CERT; then
    # ── Certificate auth path ──────────────────────────────────────────────────
    # Extract the embedded base public key from the cert blob so we can look it
    # up in Forgejo (which stores raw keys, not cert types).
    _py_err_f="$(mktemp)"
    BASE_KEY="$(FORGEJO_KEYS_DEBUG="${FORGEJO_KEYS_DEBUG:-0}" \
        python3 /usr/local/lib/forgejo-cert-extract.py "$KEY_B64" 2>"$_py_err_f" || true)"
    _py_err="$(cat "$_py_err_f")"; rm -f "$_py_err_f"

    if [[ -n "$_py_err" ]]; then
        # Always surface extractor errors (not just in debug mode).
        _audit "WARN cert-extract-stderr user=$USERNAME: ${_py_err:0:300}"
    fi

    if [[ -n "$BASE_KEY" ]]; then
        BASE_TYPE="${BASE_KEY%% *}"
        BASE_DATA="${BASE_KEY#* }"
        BASE_FP="$(_fingerprint "$BASE_KEY")"

        if [[ "${FORGEJO_KEYS_DEBUG:-0}" == "1" ]]; then
            _audit "DEBUG cert-extracted base_type=$BASE_TYPE base_fp=$BASE_FP"
        fi

        RESULT="$(_forgejo_query "$USERNAME" "$BASE_TYPE" "$BASE_DATA")"
        if [[ -n "$RESULT" ]]; then
            # Return a cert-authority line rather than the raw Forgejo key line.
            # With TrustedUserCAKeys absent, sshd passes the cert blob here via
            # AuthorizedKeysCommand; a cert-authority response causes sshd to
            # validate the CA signature AND apply the command= restriction in one
            # step. Returning the user key line directly would bypass CA validation.
            #
            # Use the first non-comment key in forgejo_ca.pub (the ECDSA signing key).
            CA_LINE="$(grep -Ev '^(#|[[:space:]]*$)' /etc/ssh/forgejo_ca.pub 2>/dev/null | head -1)"
            if [[ -z "$CA_LINE" ]]; then
                _audit "WARN cert-auth-no-ca-key user=$USERNAME"
                exit 1
            fi
            # Forgejo output may start with a "# gitea public key" comment line;
            # strip comments before extracting the options.
            # Format from Forgejo: 'command="...",<opts> <key-type> <key-b64>'
            KEY_LINE="$(printf '%s\n' "$RESULT" | grep -v '^[[:space:]]*#' | head -1)"
            OPTS="${KEY_LINE%% ${BASE_TYPE} *}"
            _audit "ts=$(date -u +%FT%TZ) client=$CLIENT_IP user=$USERNAME kt=$KEY_TYPE fp=$FP base_fp=$BASE_FP mode=cert result=ok"
            printf 'cert-authority,%s %s\n' "$OPTS" "$CA_LINE"
            exit 0
        else
            # Key not found in Forgejo — do NOT exit 0 with empty stdout (sshd
            # would treat it as "no keys" and fail silently).  Exit 1 explicitly
            # so the audit entry captures the real reason.
            _audit "ts=$(date -u +%FT%TZ) client=$CLIENT_IP user=$USERNAME kt=$KEY_TYPE fp=$FP base_fp=$BASE_FP mode=cert result=empty:key_not_registered"
            exit 1
        fi
    else
        _audit "ts=$(date -u +%FT%TZ) client=$CLIENT_IP user=$USERNAME kt=$KEY_TYPE fp=$FP mode=cert result=err:extract_failed"
        exit 1
    fi
fi

# ── Raw key auth path ──────────────────────────────────────────────────────────
# Policy: only CA-signed certificates are accepted for Git-over-SSH.
# A raw public key alone — even if registered in Forgejo — is insufficient.
# This ensures an attacker who obtains a user's public key but not a valid
# CA-signed certificate cannot authenticate. Log and deny unconditionally.
_audit "ts=$(date -u +%FT%TZ) client=$CLIENT_IP user=$USERNAME kt=$KEY_TYPE fp=$FP mode=raw result=denied:cert_required"
exit 1
