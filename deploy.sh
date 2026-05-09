#!/usr/bin/env bash
# deploy.sh — Runs on the VPS (as root) to install and start all services.
#
# Invoked by provision.sh via SSH. Required env vars (injected by provision.sh):
#   DOMAIN, CERTBOT_EMAIL, FORGEJO_ADMIN_USER, FORGEJO_ADMIN_EMAIL
#
# Idempotent: each step checks before acting, safe to re-run.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[deploy]${NC} $*"; }
warn()  { echo -e "${YELLOW}[deploy]${NC} $*"; }
error() { echo -e "${RED}[deploy]${NC} $*" >&2; exit 1; }

WORKDIR="/opt/forgejo"
cd "$WORKDIR"

# ── 1. Install Docker Engine ──────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    info "Installing Docker..."
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin python3
    systemctl enable --now docker
    info "Docker installed."
else
    info "Docker already installed, skipping."
fi

# ── 2. Create system git user ─────────────────────────────────────────────────
if ! id git &>/dev/null; then
    info "Creating git system user..."
    useradd -r -m -d /home/git -s /bin/bash git
fi
# git user needs to run 'docker exec forgejo' via sudo
usermod -aG docker git 2>/dev/null || true

# ── 3. Create directory structure ─────────────────────────────────────────────
info "Creating directories..."
mkdir -p /data/forgejo /var/www/certbot /etc/letsencrypt
# Forgejo data: UID 1000 = git user inside the Forgejo container
chown -R 1000:1000 /data/forgejo

# ── 4. Install files ──────────────────────────────────────────────────────────
info "Installing SSH CA public key..."
cp "$WORKDIR/ca.pub" /etc/ssh/forgejo_ca.pub
chmod 644 /etc/ssh/forgejo_ca.pub

info "Installing forgejo-keys.sh..."
cp "$WORKDIR/forgejo-keys.sh" /usr/local/bin/forgejo-keys.sh
chmod 755 /usr/local/bin/forgejo-keys.sh
mkdir -p /usr/local/lib
cp "$WORKDIR/forgejo-cert-extract.py" /usr/local/lib/forgejo-cert-extract.py
chmod 755 /usr/local/lib/forgejo-cert-extract.py

info "Installing host Forgejo command wrapper..."
cat > /usr/local/bin/forgejo << 'EOF'
#!/bin/bash
exec /usr/bin/docker exec -i -u git forgejo /usr/local/bin/forgejo "$@"
EOF
chmod 755 /usr/local/bin/forgejo

info "Setting file permissions..."
chmod 600 "$WORKDIR/.env" "$WORKDIR/app.ini"
chmod 644 "$WORKDIR/docker-compose.yml" "$WORKDIR/nginx.conf" "$WORKDIR/nginx-http.conf"
chmod 755 "$WORKDIR/certbot-renew.sh"

# ── 5. sudoers: allow nobody to run forgejo key lookup via Docker ─────────────
info "Configuring sudoers for forgejo-keys..."
cat > /etc/sudoers.d/forgejo-keys << 'EOF'
# Allow sshd AuthorizedKeysCommand (runs as nobody) to query Forgejo for keys.
nobody ALL=(root) NOPASSWD: /usr/bin/docker exec forgejo forgejo keys *
EOF
chmod 440 /etc/sudoers.d/forgejo-keys

# ── 6. Install and start Forgejo sshd on port 2222 ───────────────────────────
info "Configuring Forgejo SSH daemon (port 2222)..."
cp "$WORKDIR/sshd_forgejo.conf" /etc/ssh/sshd_forgejo.conf

cat > /etc/systemd/system/sshd-forgejo.service << 'EOF'
[Unit]
Description=Forgejo SSH daemon (port 2222)
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
ExecStartPre=/usr/sbin/sshd -t -f /etc/ssh/sshd_forgejo.conf
ExecStart=/usr/sbin/sshd -D -f /etc/ssh/sshd_forgejo.conf
ExecReload=/usr/sbin/sshd -t -f /etc/ssh/sshd_forgejo.conf
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sshd-forgejo

# ── 7. Start nginx in HTTP-only mode (needed before cert issuance) ────────────
info "Starting nginx in HTTP-only mode for ACME challenge..."
cp "$WORKDIR/nginx.conf" "$WORKDIR/nginx-tls.conf"
cp "$WORKDIR/nginx-http.conf" "$WORKDIR/nginx.conf"

docker compose -f "$WORKDIR/docker-compose.yml" \
    --env-file "$WORKDIR/.env" \
    --project-directory "$WORKDIR" \
    up -d nginx

# ── 8. Issue Let's Encrypt certificate ────────────────────────────────────────
info "Issuing TLS certificate for $DOMAIN..."
# Give nginx a moment to be ready
sleep 5

if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    docker run --rm \
        -v letsencrypt:/etc/letsencrypt \
        -v certbot-webroot:/var/www/certbot \
        certbot/certbot certonly \
            --webroot \
            --webroot-path=/var/www/certbot \
            --email "$CERTBOT_EMAIL" \
            --agree-tos \
            --no-eff-email \
            --non-interactive \
            --preferred-profile short-lived \
            -d "$DOMAIN" \
        || error "Certbot failed for IP $DOMAIN. Ensure port 80 is reachable from the internet."
    info "Certificate issued."
else
    info "Certificate already exists, skipping issuance."
fi

# ── 9. Switch nginx to full TLS config and start all services ─────────────────
info "Activating TLS nginx config and starting all services..."
cp "$WORKDIR/nginx-tls.conf" "$WORKDIR/nginx.conf"

docker compose -f "$WORKDIR/docker-compose.yml" \
    --env-file "$WORKDIR/.env" \
    --project-directory "$WORKDIR" \
    up -d

# Allow nginx to reload with the TLS config now that cert exists
sleep 3
docker exec "$(docker compose -f "$WORKDIR/docker-compose.yml" --project-directory "$WORKDIR" ps -q nginx)" \
    nginx -s reload 2>/dev/null || true

# ── 10. Wait for Forgejo to be ready ──────────────────────────────────────────
info "Waiting for Forgejo web UI..."
ATTEMPTS=0
until curl -sf --max-time 5 "http://localhost:3000" -o /dev/null; do
    ATTEMPTS=$((ATTEMPTS + 1))
    [ "$ATTEMPTS" -lt 24 ] || error "Forgejo did not become healthy after 120s"
    sleep 5
done
info "Forgejo is responding."

# ── 11. Create Forgejo admin user ─────────────────────────────────────────────
FORGEJO_CONTAINER="$(docker compose -f "$WORKDIR/docker-compose.yml" --project-directory "$WORKDIR" ps -q forgejo)"

if ! docker exec "$FORGEJO_CONTAINER" \
        forgejo admin user list 2>/dev/null | grep -q "^1 "; then
    info "Creating Forgejo admin user '$FORGEJO_ADMIN_USER'..."
    ADMIN_PASS="$(docker exec "$FORGEJO_CONTAINER" \
        forgejo admin user create \
            --username "$FORGEJO_ADMIN_USER" \
            --email "$FORGEJO_ADMIN_EMAIL" \
            --admin \
            --random-password \
            2>&1 | grep -oP 'password: \K\S+' || true)"
    if [ -n "$ADMIN_PASS" ]; then
        warn "Admin one-time password: $ADMIN_PASS  (change this immediately after login)"
    else
        warn "Admin user created (check output above for password or use 'forgejo admin user change-password')"
    fi
else
    info "Admin user already exists, skipping."
fi

# ── 12. Start Forgejo sshd ────────────────────────────────────────────────────
info "Starting Forgejo SSH daemon on port 2222..."
systemctl start sshd-forgejo

# ── 13. Certbot renewal timer (belt-and-suspenders) ──────────────────────────
if [ ! -f /etc/systemd/system/certbot-renew.timer ]; then
    info "Installing certbot renewal systemd timer..."
    cat > /etc/systemd/system/certbot-renew.service << EOF
[Unit]
Description=Certbot renewal for Forgejo (short-lived IP cert)

[Service]
Type=oneshot
ExecStart=/usr/bin/docker run --rm \
  -v letsencrypt:/etc/letsencrypt \
  -v certbot-webroot:/var/www/certbot \
  certbot/certbot renew --quiet --webroot --webroot-path=/var/www/certbot \
  --preferred-profile short-lived
ExecStartPost=/usr/bin/docker exec \$(docker compose -f $WORKDIR/docker-compose.yml --project-directory $WORKDIR ps -q nginx) nginx -s reload
EOF
    cat > /etc/systemd/system/certbot-renew.timer << 'EOF'
[Unit]
Description=Certbot renewal — every 12 h (short-lived certs expire in 6 days)

[Timer]
OnCalendar=*:0/12
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now certbot-renew.timer
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo
info "Deploy complete."
echo "  Forgejo URL  : https://${DOMAIN}"
echo "  Git SSH port : 2222"
