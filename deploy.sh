#!/usr/bin/env bash
# deploy.sh — Runs on the VPS (as root) to install and start all services.
#
# Invoked by provision.sh via SSH. Required env vars (injected by provision.sh):
#   DOMAIN, CERTBOT_EMAIL, FORGEJO_ADMIN_USER, FORGEJO_ADMIN_EMAIL,
#   ADMIN_SSH_PUBLIC_KEY
#
# Idempotent: each step checks before acting, safe to re-run.
# -E propagates the ERR trap into functions and subshells.
set -Eeuo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[deploy]${NC} $*"; }
warn()  { echo -e "${YELLOW}[deploy]${NC} $*"; }
error() { echo -e "${RED}[deploy]${NC} $*" >&2; exit 1; }

# Print line number and exit code on any unexpected command failure so the cause
# is always visible even when the failing command produces no output of its own.
trap 'ret=$?; echo -e "${RED}[deploy] FAILED${NC} at line ${LINENO} — command exited ${ret}" >&2' ERR

# Suppress debconf interactive prompts for every apt-get call in this script.
# NEEDRESTART_MODE=a tells needrestart (Debian 12 default) to auto-restart
# services without asking — without this, apt-get install hangs on a prompt
# even with -y.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# APT lock timeout: apt waits up to 3 minutes for another apt/dpkg process to
# finish before giving up with a clear error message. This handles cloud-init
# running apt on first boot without needing fuser or any external tool.
# (DPkg::Lock::Timeout available since apt 1.9.1 / Debian 11+)
APT_OPTS="-o DPkg::Lock::Timeout=180"

WORKDIR="/opt/forgejo"
cd "$WORKDIR"

# ── 0a. Update all system packages ───────────────────────────────────────────
info "Updating system packages (this may take a minute on first run)..."
# No -q/-qq: Debian 12 apt silences even errors at -qq level.
apt-get $APT_OPTS update
apt-get $APT_OPTS upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"
info "System packages up to date."

# ── 0b. Unattended upgrades — daily at 08:00 UTC, including kernels ───────────
if [ ! -f /etc/apt/apt.conf.d/50unattended-upgrades ] || \
   ! grep -q 'Forgejo-deploy' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null; then
    info "Configuring unattended-upgrades..."
    apt-get $APT_OPTS install -y unattended-upgrades

    DISTRO_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"

    cat > /etc/apt/apt.conf.d/50unattended-upgrades << EOF
// Forgejo-deploy — managed by deploy.sh
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${DISTRO_CODENAME},label=Debian";
    "origin=Debian,codename=${DISTRO_CODENAME},label=Debian-Security";
    "origin=Debian,codename=${DISTRO_CODENAME}-security,label=Debian-Security";
    "origin=Debian,codename=${DISTRO_CODENAME}-updates";
};

Unattended-Upgrade::Package-Blacklist {
};

Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "08:00";
Unattended-Upgrade::MinimalSteps "true";
EOF

    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'APTEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APTEOF

    # Override apt-daily-upgrade.timer to fire at 08:00 UTC exactly
    mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
    cat > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf << 'TIMEREOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 08:00 UTC
RandomizedDelaySec=0
Persistent=true
TIMEREOF

    systemctl daemon-reload
    systemctl enable --now apt-daily-upgrade.timer
    info "Unattended upgrades configured (daily at 08:00 UTC, auto-reboot enabled)."
fi

# ── 0. Configure host firewall (UFW) ─────────────────────────────────────────
# Docker bypasses UFW for container-mapped ports (80, 443), but host services
# like sshd-forgejo on port 2222 go through UFW. Allow required ports explicitly.
# The Vultr cloud firewall is the perimeter control; UFW provides host-level defense.
if command -v ufw &>/dev/null; then
    info "Configuring UFW firewall rules..."
    ufw allow 22/tcp   comment 'SSH admin'    >/dev/null
    ufw allow 80/tcp   comment 'HTTP'         >/dev/null
    ufw allow 443/tcp  comment 'HTTPS'        >/dev/null
    ufw allow 2222/tcp comment 'Forgejo SSH'  >/dev/null
    info "UFW rules updated."
fi

# ── 1. Install Docker Engine ──────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    info "Installing Docker..."
    apt-get $APT_OPTS update
    apt-get $APT_OPTS install -y ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get $APT_OPTS update
    apt-get $APT_OPTS install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin python3
    systemctl enable --now docker
    info "Docker installed."
else
    info "Docker already installed, skipping."
fi

# ── 1b. Kernel lockdown (integrity mode) ─────────────────────────────────────
# integrity mode prevents writing to kernel memory (driver signing, kprobes, etc.)
# confidentiality mode is too restrictive for ops (breaks kexec, hibernate).
info "Enabling kernel lockdown (integrity mode)..."

LOCKDOWN_SYS="/sys/kernel/security/lockdown"
_lockdown_runtime_active=false
if [ -f "$LOCKDOWN_SYS" ]; then
    _cur="$(cat "$LOCKDOWN_SYS" 2>/dev/null || true)"
    if echo "$_cur" | grep -qE '\[(integrity|confidentiality)\]'; then
        info "Kernel lockdown already active: $(echo "$_cur" | tr -d '\n')"
        _lockdown_runtime_active=true
    elif [ -w "$LOCKDOWN_SYS" ]; then
        echo integrity > "$LOCKDOWN_SYS" \
            && { info "Kernel lockdown set to integrity mode (runtime)."; _lockdown_runtime_active=true; } \
            || warn "Runtime lockdown write failed — will take effect after reboot."
    else
        warn "Lockdown sysfs not writable — will take effect after reboot."
    fi
else
    warn "Lockdown sysfs not present — kernel may lack CONFIG_SECURITY_LOCKDOWN_LSM."
fi

# Persist via GRUB cmdline for reboots (and for kernels without runtime sysfs)
if [ -f /etc/default/grub ] && ! grep -q 'lockdown=integrity' /etc/default/grub; then
    sed -i -E 's/^(GRUB_CMDLINE_LINUX_DEFAULT=")(.*)(")$/\1\2 lockdown=integrity\3/' \
        /etc/default/grub
    update-grub 2>/dev/null || update-grub2 2>/dev/null || true
    info "lockdown=integrity added to GRUB kernel cmdline (persistent after reboot)."
elif [ -f /etc/default/grub ]; then
    info "lockdown=integrity already in GRUB cmdline."
else
    warn "GRUB config not found — kernel lockdown not persisted to bootloader."
fi
$_lockdown_runtime_active || warn "Kernel lockdown will be fully active after the next reboot."

# ── 2. Create system git user ─────────────────────────────────────────────────
if ! id git &>/dev/null; then
    info "Creating git system user..."
    useradd -r -m -d /home/git -s /bin/bash git
fi
# git user needs to run 'docker exec forgejo' via sudo
usermod -aG docker git 2>/dev/null || true
# Unlock the git account: useradd -r sets password to '!' which OpenSSH
# rejects via allowed_user() even when UsePAM no. '*' means no password
# but account is not locked, so key/cert auth proceeds normally.
usermod -p '*' git

# ── 2b. Deploy admin user ─────────────────────────────────────────────────────
# Replaces root for SSH access. docker group grants container exec rights needed
# by sign-user-key.sh to fetch Forgejo admin tokens; sudo covers general admin.
# NOTE: docker group membership is effectively root-equivalent — this is accepted
# for an administrative account on a single-purpose server.
info "Setting up deploy admin user..."
DEPLOY_USER="deploy"

if ! id "$DEPLOY_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$DEPLOY_USER"
    info "Created user $DEPLOY_USER."
fi
usermod -aG docker,sudo "$DEPLOY_USER" 2>/dev/null || true
# Lock password (key-only login; '!' = locked, cannot log in with any password)
usermod -p '!' "$DEPLOY_USER"

# Install admin SSH public key (injected by provision.sh from Vault)
if [ -n "${ADMIN_SSH_PUBLIC_KEY:-}" ]; then
    install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 700 "/home/$DEPLOY_USER/.ssh"
    echo "$ADMIN_SSH_PUBLIC_KEY" > "/home/$DEPLOY_USER/.ssh/authorized_keys"
    chown "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh/authorized_keys"
    chmod 600 "/home/$DEPLOY_USER/.ssh/authorized_keys"
    info "Admin SSH key installed for $DEPLOY_USER."
else
    warn "ADMIN_SSH_PUBLIC_KEY not set — $DEPLOY_USER has no SSH keys; set it in Vault."
fi

# Passwordless sudo so deploy user can re-run deploy.sh (sudo bash deploy.sh)
cat > /etc/sudoers.d/deploy-admin << 'SUDOEOF'
deploy ALL=(ALL) NOPASSWD: ALL
SUDOEOF
chmod 440 /etc/sudoers.d/deploy-admin

# Allow deploy group to write /opt/forgejo so provision.sh scp works on re-runs
chown root:deploy "$WORKDIR"
chmod 775 "$WORKDIR"
info "Deploy admin user configured."

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
# -e SSH_ORIGINAL_COMMAND passes the git command (upload-pack/receive-pack) into
# the container so 'forgejo serv' knows which operation to perform.
exec /usr/bin/docker exec -i -e SSH_ORIGINAL_COMMAND -u git forgejo /usr/local/bin/forgejo "$@"
EOF
chmod 755 /usr/local/bin/forgejo
# forgejo keys outputs command="/usr/local/bin/gitea serv key-N" (legacy Gitea path).
# The host needs this path too so sshd can invoke it for Git-over-SSH sessions.
ln -sf /usr/local/bin/forgejo /usr/local/bin/gitea

info "Setting file permissions..."
chmod 600 "$WORKDIR/.env" "$WORKDIR/app.ini"
chmod 644 "$WORKDIR/docker-compose.yml" "$WORKDIR/nginx.conf" "$WORKDIR/nginx-http.conf"
chmod 755 "$WORKDIR/certbot-renew.sh"
# app.ini and ca.pub are bind-mounted :ro into the Forgejo container (UID 1000).
# The entrypoint tries chown but fails on :ro mounts, so set ownership here.
chown 1000:1000 "$WORKDIR/app.ini" "$WORKDIR/ca.pub"

# ── 5. sudoers: allow nobody to run forgejo key lookup via Docker ─────────────
info "Configuring sudoers for forgejo-keys..."
cat > /etc/sudoers.d/forgejo-keys << 'EOF'
# Allow sshd AuthorizedKeysCommand (runs as nobody) to query Forgejo for keys.
nobody ALL=(root) NOPASSWD: /usr/bin/docker exec -u git forgejo forgejo keys *
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

# Certbot log capture: mount both /var/log/letsencrypt (persistent log) and
# /tmp (certbot's session log lives at /tmp/certbot-log-<rand>/log and is
# otherwise lost when the --rm container exits).
CERTBOT_LOG_DIR="/tmp/certbot-logs"
CERTBOT_TMP_DIR="/tmp/certbot-tmp"
mkdir -p "$CERTBOT_LOG_DIR" "$CERTBOT_TMP_DIR"

certbot_dump_logs() {
    find "$CERTBOT_LOG_DIR" "$CERTBOT_TMP_DIR" \
        \( -name "letsencrypt.log" -o -name "log" \) 2>/dev/null | sort \
    | while read -r f; do
        warn "━━━ $f ━━━"
        cat "$f" 2>/dev/null || true
    done
}

CERTBOT_EXTRA=""
if [ -n "${CERTBOT_STAGING:-}" ]; then
    CERTBOT_EXTRA="--staging --force-renewal -v"
    warn "Certbot staging mode — certificate will NOT be browser-trusted."
fi

# In staging mode always run (--force-renewal handles idempotency).
# In production skip if a valid cert directory already exists.
if [ -n "${CERTBOT_STAGING:-}" ] || [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    # Use 'docker compose run' (not bare 'docker run') so certbot shares the same
    # compose project-scoped volumes as nginx. A bare 'docker run -v certbot-webroot:...'
    # would create a different volume than the compose-managed 'forgejo_certbot-webroot'
    # that nginx mounts, causing ACME challenge 404s.
    docker compose -f "$WORKDIR/docker-compose.yml" \
        --env-file "$WORKDIR/.env" \
        --project-directory "$WORKDIR" \
        run --rm \
        --entrypoint="" \
        --volume "$CERTBOT_LOG_DIR:/var/log/letsencrypt" \
        --volume "$CERTBOT_TMP_DIR:/tmp" \
        certbot \
        certbot certonly \
            --webroot \
            --webroot-path=/var/www/certbot \
            --logs-dir /var/log/letsencrypt \
            --email "$CERTBOT_EMAIL" \
            --agree-tos \
            --no-eff-email \
            --non-interactive \
            --preferred-profile shortlived \
            $CERTBOT_EXTRA \
            --ip-address "$DOMAIN" \
    || {
        warn "Certbot failed. All captured logs:"
        certbot_dump_logs
        error "Certbot failed for $DOMAIN. Ensure port 80 is reachable from the internet."
    }
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

# Reload nginx with TLS config. Test first so errors are visible.
NGINX_CTR="$(docker compose -f "$WORKDIR/docker-compose.yml" --project-directory "$WORKDIR" ps -q nginx)"
info "Testing nginx TLS config..."
docker exec "$NGINX_CTR" nginx -t \
    || error "nginx config test failed — check the TLS config and cert paths above"
info "Reloading nginx..."
docker exec "$NGINX_CTR" nginx -s reload \
    || error "nginx reload failed"

# Wait until port 443 is actually accepting connections (reload is async).
info "Waiting for nginx to accept connections on port 443..."
ATTEMPTS=0
until curl -sk -o /dev/null --max-time 3 https://localhost 2>/dev/null; do
    ATTEMPTS=$((ATTEMPTS + 1))
    [ "$ATTEMPTS" -lt 15 ] || error "nginx did not start listening on port 443 after 30s"
    sleep 2
done
info "nginx is accepting TLS connections on port 443."

# Smoke-test HTTPS locally on the VPS (avoids any external routing issues).
info "Smoke-testing HTTPS endpoint..."
HTTP_CODE="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "https://localhost" || true)"
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    info "HTTPS smoke test passed (HTTP $HTTP_CODE)."
else
    warn "HTTPS smoke test returned code: $HTTP_CODE — verbose output:"
    curl -vvv -k --max-time 10 "https://localhost" 2>&1 || true
fi

# ── 10. Wait for Forgejo to be ready ──────────────────────────────────────────
info "Waiting for Forgejo web UI..."
ATTEMPTS=0
until curl -sf --max-time 5 "http://localhost:3000" -o /dev/null; do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ "$ATTEMPTS" -ge 24 ]; then
        warn "━━━ docker ps ━━━"
        docker ps -a
        warn "━━━ forgejo container state ━━━"
        docker inspect forgejo --format \
            'Status={{.State.Status}} ExitCode={{.State.ExitCode}} Error={{.State.Error}}'
        warn "━━━ forgejo logs (last 60 lines) ━━━"
        docker logs --tail 60 forgejo 2>&1 || true
        warn "━━━ db logs (last 20 lines) ━━━"
        docker compose -f "$WORKDIR/docker-compose.yml" --project-directory "$WORKDIR" \
            logs --tail 20 db 2>&1 || true
        warn "━━━ curl verbose ━━━"
        curl -v --max-time 5 "http://localhost:3000" 2>&1 || true
        error "Forgejo did not become healthy after 120s"
    fi
    sleep 5
done
info "Forgejo is responding."

# ── 11. Create Forgejo admin user ─────────────────────────────────────────────
FORGEJO_CONTAINER="$(docker compose -f "$WORKDIR/docker-compose.yml" --project-directory "$WORKDIR" ps -q forgejo)"

if ! docker exec "$FORGEJO_CONTAINER" \
        forgejo admin user list 2>/dev/null | grep -q "^1 "; then
    info "Creating Forgejo admin user '$FORGEJO_ADMIN_USER'..."
    CREATE_OUT="$(docker exec -u git "$FORGEJO_CONTAINER" \
        /usr/local/bin/forgejo admin user create \
            --username "$FORGEJO_ADMIN_USER" \
            --email "$FORGEJO_ADMIN_EMAIL" \
            --admin \
            --random-password \
            2>&1 || true)"
    # Forgejo prints: generated random password is '<password>'
    ADMIN_PASS="$(echo "$CREATE_OUT" | grep -oP "generated random password is '\K[^']+"  || true)"
    if [ -n "$ADMIN_PASS" ]; then
        warn "Admin one-time password: $ADMIN_PASS  (change this immediately after login)"
        warn "To reset: docker exec -u git forgejo /usr/local/bin/forgejo admin user change-password --username $FORGEJO_ADMIN_USER --password <newpass>"
    else
        warn "Admin user create output: $CREATE_OUT"
        warn "To set password: docker exec -u git forgejo /usr/local/bin/forgejo admin user change-password --username $FORGEJO_ADMIN_USER --password <newpass>"
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
ExecStart=/usr/bin/docker compose -f $WORKDIR/docker-compose.yml \
  --env-file $WORKDIR/.env \
  --project-directory $WORKDIR \
  run --rm --entrypoint="" \
  certbot \
  certbot renew --quiet --webroot --webroot-path=/var/www/certbot \
  --preferred-profile shortlived
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

# ── 14. Docker image update timer ────────────────────────────────────────────
# Pulls latest image digests daily and recreates any container whose image changed.
# Runs at 09:00 UTC (1 hour after unattended-upgrades reboot window) to avoid
# restarting containers while a kernel reboot may be in progress.
if [ ! -f /etc/systemd/system/docker-pull.timer ]; then
    info "Installing Docker image update timer..."
    cat > /etc/systemd/system/docker-pull.service << SVCEOF
[Unit]
Description=Pull latest Docker images and recreate changed containers
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=$WORKDIR
ExecStart=/usr/bin/docker compose -f $WORKDIR/docker-compose.yml \\
    --env-file $WORKDIR/.env --project-directory $WORKDIR \\
    pull --quiet
ExecStartPost=/usr/bin/docker compose -f $WORKDIR/docker-compose.yml \\
    --env-file $WORKDIR/.env --project-directory $WORKDIR \\
    up -d --remove-orphans
SVCEOF

    cat > /etc/systemd/system/docker-pull.timer << 'TIMEREOF'
[Unit]
Description=Daily Docker image update check

[Timer]
OnCalendar=*-*-* 09:00 UTC
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
TIMEREOF

    systemctl daemon-reload
    systemctl enable --now docker-pull.timer
    info "Docker image update timer installed (daily at 09:00 UTC)."
fi

# ── 15. Harden main sshd — disable root login (runs LAST) ────────────────────
# Runs at the very end so root access is available throughout deploy.
# After this step, only the 'deploy' user can SSH on port 22.
info "Hardening main SSH daemon (disabling root login)..."

mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-hardening.conf << 'SSHDEOF'
# Forgejo deployment hardening — managed by deploy.sh
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
PubkeyAuthentication yes
AllowUsers deploy
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
MaxAuthTries 3
LoginGraceTime 30
SSHDEOF

# Validate before reload — a broken config would lock everyone out
sshd -t || error "sshd config test failed — check /etc/ssh/sshd_config.d/99-hardening.conf"

# reload preserves existing SSH sessions (unlike restart)
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
    || kill -HUP "$(pgrep -o sshd)" 2>/dev/null || true

info "SSH hardened: root login disabled, only 'deploy' user allowed on port 22."
warn "Verify: ssh -p 22 deploy@${DOMAIN} before closing this session."

# ── Done ──────────────────────────────────────────────────────────────────────
echo
info "Deploy complete."
echo "  Forgejo URL  : https://${DOMAIN}"
echo "  Git SSH port : 2222"
echo "  Admin SSH    : ssh deploy@${DOMAIN}"
echo

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
warn "Additional hardening recommendations:"
echo
echo "  1. FAIL2BAN  Blocks SSH brute-force attempts:"
echo "       apt install fail2ban"
echo "       configure /etc/fail2ban/jail.local with [sshd] ban settings"
echo
echo "  2. AUDITD    Syscall-level audit log for intrusion forensics:"
echo "       apt install auditd"
echo "       auditctl -a always,exit -F arch=b64 -S execve -k exec_log"
echo
echo "  3. DOCKER SOCKET PROXY  Limit container access to the Docker socket"
echo "       using Tecnativa/docker-socket-proxy rather than raw /var/run/docker.sock"
echo
echo "  4. SSH PORT  Move admin SSH to a non-standard port (e.g. 2223):"
echo "       update Port in /etc/ssh/sshd_config.d/99-hardening.conf"
echo "       ufw allow 2223/tcp; ufw delete allow 22/tcp"
echo "       update provision.sh SSH_OPTS and cloud firewall group"
echo
echo "  5. WAF / CDN  Place Forgejo behind Cloudflare Tunnel or a WAF"
echo "       to filter malicious HTTP before it reaches nginx"
echo
echo "  6. FILE INTEGRITY  AIDE detects unauthorized file changes:"
echo "       apt install aide; aideinit"
echo "       run 'aide --check' periodically (schedule via systemd timer)"
echo
echo "  7. ROOTLESS DOCKER  Eliminate the docker=root equivalence:"
echo "       https://docs.docker.com/engine/security/rootless/"
echo "       Requires updated docker-compose.yml volume paths"
echo
echo "  8. NGINX TLS HARDENING  Enforce TLS 1.2+, HSTS, and OCSP stapling"
echo "       in nginx.conf.tmpl; test with https://www.ssllabs.com/ssltest/"
echo
echo "  9. IPv6  Disable if unused to reduce attack surface:"
echo "       echo 'net.ipv6.conf.all.disable_ipv6=1' >> /etc/sysctl.d/99-local.conf"
echo "       sysctl --system"
echo
echo " 10. SECRETS ROTATION  Rotate Vault unseal key after any suspected"
echo "       compromise. CA rotation invalidates all issued user certificates."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
