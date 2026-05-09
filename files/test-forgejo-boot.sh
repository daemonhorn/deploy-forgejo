#!/usr/bin/env bash
# Smoke test: verifies Forgejo starts and serves HTTP without a live VPS.
# Run locally before provisioning to catch app.ini / startup regressions.
# Requires: docker, envsubst, openssl
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR="$(mktemp -d /tmp/forgejo-smoke-XXXXXX)"
DC="$TMPDIR/dc.yml"
TOUCH_PORT=13000

cleanup() {
    docker compose -f "$DC" down -v --remove-orphans 2>/dev/null || true
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

echo "[smoke] Rendering app.ini from template..."
DOMAIN=test.local \
DB_PASSWORD=smoketest \
DB_USER=forgejo \
DB_NAME=forgejo \
FORGEJO_SECRET_KEY="$(openssl rand -hex 32)" \
FORGEJO_INTERNAL_TOKEN="$(openssl rand -base64 32 | tr -d '=/+')" \
    envsubst \
        '${DOMAIN} ${DB_PASSWORD} ${DB_USER} ${DB_NAME} ${FORGEJO_SECRET_KEY} ${FORGEJO_INTERNAL_TOKEN}' \
        < "$REPO_ROOT/files/templates/app.ini.tmpl" > "$TMPDIR/app.ini"
chmod 600 "$TMPDIR/app.ini"

# Use a throwaway CA pub key (content irrelevant for boot test)
ssh-keygen -q -t ed25519 -N "" -C "smoke-ca" -f "$TMPDIR/smoke_ca" 2>/dev/null
cp "$TMPDIR/smoke_ca.pub" "$TMPDIR/ca.pub"

cat > "$DC" << EOF
services:
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: forgejo
      POSTGRES_USER: forgejo
      POSTGRES_PASSWORD: smoketest
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U forgejo -d forgejo"]
      interval: 2s
      timeout: 3s
      retries: 30

  forgejo:
    image: codeberg.org/forgejo/forgejo:15
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "127.0.0.1:${TOUCH_PORT}:3000"
    volumes:
      - ${TMPDIR}/app.ini:/data/gitea/conf/app.ini
      - ${TMPDIR}/ca.pub:/data/gitea/ssh/trusted-user-ca-keys.pub:ro
    environment:
      USER_UID: "1000"
      USER_GID: "1000"
EOF

echo "[smoke] Starting containers..."
docker compose -f "$DC" up -d

echo "[smoke] Waiting for Forgejo on port ${TOUCH_PORT}..."
ATTEMPTS=0
until curl -sf --max-time 3 "http://127.0.0.1:${TOUCH_PORT}" -o /dev/null; do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ "$ATTEMPTS" -ge 45 ]; then
        echo "[smoke] FAIL — Forgejo did not respond after 90s"
        echo "[smoke] --- forgejo logs ---"
        docker compose -f "$DC" logs --tail 40 forgejo 2>&1 || true
        exit 1
    fi
    sleep 2
done

echo "[smoke] PASS — Forgejo is serving HTTP."
