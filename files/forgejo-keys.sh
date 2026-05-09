#!/bin/bash
# /usr/local/bin/forgejo-keys.sh — installed on VPS by deploy.sh
#
# Called by sshd AuthorizedKeysCommand for port-2222 (git user) connections.
# Arguments match sshd_config tokens: %u %t %k
#
# For raw key auth: passes type and key directly to Forgejo.
# For cert auth: extracts the base public key from the certificate, then
# queries Forgejo so it returns the correct "command=forgejo serv key-X" line.
set -euo pipefail

USERNAME="$1"
KEY_TYPE="$2"
KEY_B64="$3"

FORGEJO_KEYS_QUERY() {
    sudo docker exec forgejo forgejo keys -e git -u "$1" -t "$2" -k "$3" 2>/dev/null
}

if [[ "$KEY_TYPE" == *"-cert-v01@openssh.com" ]]; then
    BASE_KEY="$(python3 /usr/local/lib/forgejo-cert-extract.py "$KEY_B64" 2>/dev/null || true)"
    if [ -n "$BASE_KEY" ]; then
        BASE_TYPE="${BASE_KEY%% *}"
        BASE_DATA="${BASE_KEY#* }"
        FORGEJO_KEYS_QUERY "$USERNAME" "$BASE_TYPE" "$BASE_DATA"
        exit 0
    fi
    # Fall through to direct lookup if extraction fails (lets Forgejo handle it natively)
fi

FORGEJO_KEYS_QUERY "$USERNAME" "$KEY_TYPE" "$KEY_B64"
