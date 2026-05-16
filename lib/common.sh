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
