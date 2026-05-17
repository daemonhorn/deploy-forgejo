#!/usr/bin/env bash
# lib/common.sh — Shared utilities sourced by all scripts in this repository.
#
# Source near the top of each script, after SCRIPT_DIR is set:
#   source "$SCRIPT_DIR/lib/common.sh"         # root-level scripts
#   source "$SCRIPT_DIR/lib/common.sh"         # cron/ scripts (SCRIPT_DIR is repo root)
#
# Provides: ANSI color variables, DEBUG flag, _run() helper.

# ── ANSI colors ───────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

# ── Debug mode ────────────────────────────────────────────────────────────────
# Activated by --debug in any script, or by setting DEBUG=1 in the environment.
# export DEBUG propagates it to sub-scripts (cron → export/mirror, provision → deploy).
#
# Effects when DEBUG=1:
#   - set -x is enabled after argument parsing (full bash execution trace to stderr)
#   - _run() logs each wrapped command and its exit code to stderr
#   - Token-generation SSH calls tee their stderr live to the terminal in real time
#
# IMPORTANT: _run() never logs captured stdout — safe around token-generation
# calls where stdout carries a secret value.
DEBUG=${DEBUG:-0}

# _run CMD [ARGS...]: Execute CMD, logging it and its exit code in debug mode.
# In normal mode: transparent pass-through with zero overhead.
_run() {
    if [[ "${DEBUG}" == 1 ]]; then
        printf '[debug] $ %s\n' "$*" >&2
        "$@"; local _rc=$?
        printf '[debug] -> rc=%d\n' "${_rc}" >&2
        return "${_rc}"
    else
        "$@"
    fi
}

# ── External utility validator ─────────────────────────────────────────────────

# Binary → apt package for tools not included in a minimal Debian installation.
declare -A _UTIL_APT_PKG=(
    [curl]="curl"
    [git]="git"
    [python3]="python3"
    [zstd]="zstd"
    [envsubst]="gettext-base"
    [uuidgen]="uuid-runtime"
    [openssl]="openssl"
    [ssh]="openssh-client"
    [scp]="openssh-client"
    [ssh-keygen]="openssh-client"
    [ssh-keyscan]="openssh-client"
    [aws]="awscli"
    [ykman]="python3-yubikey-manager"
)

# Binary → install note for tools not available via apt.
declare -A _UTIL_MANUAL_PKG=(
    [vault]="HashiCorp Vault — https://developer.hashicorp.com/vault/install"
    [terraform]="HashiCorp Terraform — https://developer.hashicorp.com/terraform/install"
)

# validate_external_utils TOOL [TOOL ...]
# Verify each TOOL is in PATH. For any that are missing, print a consolidated
# "sudo apt install ..." line for apt-installable tools and per-tool notes for
# tools that require manual installation. Returns 1 if anything is missing.
validate_external_utils() {
    local -a _apt=() _manual=()
    local -A _seen=()
    local _cmd _pkg

    for _cmd in "$@"; do
        command -v "$_cmd" &>/dev/null && continue

        if [[ -n "${_UTIL_APT_PKG[$_cmd]:-}" ]]; then
            _pkg="${_UTIL_APT_PKG[$_cmd]}"
            # Deduplicate: ssh/scp/ssh-keygen all map to openssh-client.
            [[ -z "${_seen[$_pkg]:-}" ]] && { _apt+=("$_pkg"); _seen[$_pkg]=1; }
        elif [[ -n "${_UTIL_MANUAL_PKG[$_cmd]:-}" ]]; then
            _manual+=("  $_cmd: ${_UTIL_MANUAL_PKG[$_cmd]}")
        else
            _manual+=("  $_cmd: (no install hint — check your PATH)")
        fi
    done

    [[ ${#_apt[@]} -eq 0 && ${#_manual[@]} -eq 0 ]] && return 0

    printf '%b\n' "${RED}[error]${NC} Missing required tools:" >&2
    [[ ${#_manual[@]} -gt 0 ]] && printf '%s\n' "${_manual[@]}" >&2
    [[ ${#_apt[@]} -gt 0 ]] && printf '%b\n' "${RED}  sudo apt install ${_apt[*]}${NC}" >&2
    exit 1
}
