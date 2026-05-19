# Security Hardening Reference

This document describes the complete security design of the git-deploy Forgejo
deployment stack: authentication layers, firewalls, secret management, and the
features that are explicitly disabled to reduce attack surface.

---

## 1. Authentication

### 1.1 Git-over-SSH (port 2222) — certificate-only

All Git operations travel over SSH on port 2222, handled by a dedicated
`sshd-forgejo.service` instance (separate from the admin sshd on port 22).

**Two-factor gate**: a connection is accepted only when **both** conditions hold:
1. The client presents a **CA-signed certificate** (issued by `sign-user-key.sh`
   via the Yubikey PIV key in slot 9d).
2. The certificate's embedded base public key is **registered in Forgejo** for
   the target username.

**How it works** (`files/sshd_forgejo.conf` + `files/forgejo-keys.sh`):

- `AuthorizedKeysFile none` — no flat `authorized_keys` file is consulted.
- `TrustedUserCAKeys` is **intentionally absent**. If set, sshd validates the
  cert directly and skips `AuthorizedKeysCommand`, so the `command="forgejo serv
  key-N"` restriction from Forgejo is never enforced and any key signed by the
  CA would be accepted. Omitting it forces every connection through the script.
- `AuthorizedKeysCommand /usr/local/bin/forgejo-keys.sh %u %t %k` runs on
  every connection as `nobody`.
- When the client presents a **certificate** (`*-cert-v01@openssh.com` key
  type):
  1. `forgejo-cert-extract.py` parses the cert blob to recover the embedded
     base public key (binary SSH wire format, no external deps).
  2. Forgejo is queried via `docker exec` for the `command="forgejo serv key-N"`
     line associated with that base key.
  3. The script emits `cert-authority,command="..." <CA-pubkey>` so sshd
     validates the CA signature **and** enforces the per-key command in one step.
- When the client presents a **raw public key** (no cert), the script logs the
  attempt with the fingerprint and exits 1 — authentication is denied
  unconditionally, even if the key is registered in Forgejo.

**Audit log**: every auth attempt (cert success, cert failure, raw-key denial,
docker-exec error) is written to syslog with tag `forgejo-auth`. View with:
```
journalctl -t forgejo-auth
```

**CA key material**: the signing key never leaves the Yubikey (PIV slot 9d).
`ca.pub` is the SSH-format public key; it is committed to the repository and
deployed to `/etc/ssh/forgejo_ca.pub` on the VPS. `ca_public.pem` is gitignored
and can be regenerated any time: `ykman piv keys export 9d ca_public.pem`.

**Certificate validity**: default `+365d` (overridable with `CERT_VALIDITY`).
Certs embed principal `git` and are scoped to that Unix account.

### 1.2 Web UI — password derived from SSH key

Web login uses Forgejo password authentication (`ENABLE_BASIC_AUTHENTICATION =
true`). Passwords are **not chosen by users**; they are derived deterministically
by `sign-user-key.sh --web-password`:

```
challenge = "webapp-password:<instance_ip>:v1"
signature = ssh-keygen -Y sign -f <ed25519_privkey> -n password-derivation
password  = base64url(sha256(signature_bytes))[:32]
```

Properties:
- Passwords require possession of the private Ed25519 key.
- Tied to the instance IP: passwords change on every weekly rotation (the
  instance IP changes), forcing a `--web-password` rerun. This invalidates
  stolen/cached credentials automatically.
- `--web-password` namespace (`password-derivation`) is separate from the SSH
  signing namespace, so a signature obtained for web login cannot be replayed
  for git operations.
- Passwords are never stored locally; they are derived on demand or retrieved
  from the Forgejo API response.

**Self-registration is disabled** (`DISABLE_REGISTRATION = true`). All user
accounts are created by the admin via `sign-user-key.sh`.

### 1.3 Admin SSH (port 22) — key-only, no root, single user

The main sshd on port 22 is hardened by `deploy.sh` (written to
`/etc/ssh/sshd_config.d/99-hardening.conf`):

```
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
AllowUsers deploy
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
MaxAuthTries 3
LoginGraceTime 30
```

Only the `deploy` system user can connect. The `deploy` user's authorized key
is injected by `provision.sh` from Vault (`secret/forgejo/deploy
→ admin_ssh_public_key`). Root login is disabled last in `deploy.sh` so root
access is available throughout the provisioning run.

### 1.4 Forgejo git-user SSH (port 2222) — no shell, no TTY

The `git` system user used for Git-over-SSH is created with:
- Shell `/bin/bash` (required by `forgejo serv` dispatch) but `PermitTTY no`
  prevents interactive sessions.
- Password locked (`usermod -p '*'`) — `*` means no password but the account
  is not locked, allowing key/cert auth while blocking any password login.
- `AllowAgentForwarding no`, `AllowTcpForwarding no`, `X11Forwarding no`.
- `AllowUsers git` — no other user can connect on port 2222.

---

## 2. Firewalls

The system uses a **two-layer firewall model**. Each layer guards different ports.

### 2.1 Layer 1 — Cloud provider firewall (ports 22 and 2222)

Managed by Terraform (`terraform/modules/providers/<name>/`). SSH ports 22 and
2222 are restricted to `allowed_cidrs` (admin CIDRs) at the cloud network layer
before traffic even reaches the VPS NIC.

**Fail-closed default**: `allowed_cidrs` defaults to `[]` (empty). An empty
list blocks all admin access at the cloud level. `provision.sh` populates this
from `--admin-cidrs` or auto-detects the caller's public IPv4/IPv6 on each run.

Ports 80 and 443 are world-open at this layer (required for ACME HTTP-01
certificate issuance from Let's Encrypt).

### 2.2 Layer 2 — DOCKER-USER iptables chain (ports 80 and 443)

Docker bypasses UFW for container-mapped ports. The `DOCKER-USER` chain
(which Docker evaluates before its own forwarding rules) is used to restrict
inbound HTTP/HTTPS to admin CIDRs in steady state.

**Managed by** `/usr/local/bin/forgejo-fw-apply.sh`, which:
- Detects the external NIC via `ip route get 1.1.1.1` (e.g. `enp1s0`).
- Inserts RETURN rules for each admin CIDR on ports 80 and 443.
- Appends DROP rules **scoped to `-i $EXT_IFACE`** — this limits the drop to
  inbound external traffic only, so container-originated outbound HTTPS
  (e.g. Forgejo repo imports/migrations) is not blocked.
- Inserts ESTABLISHED/RELATED RETURN before everything so live sessions survive
  a rule flush.

**Applied on**:
- First provisioning (end of `deploy.sh`).
- Every boot via `forgejo-fw.service` (runs after `docker.service`, because
  Docker flushes iptables chains on daemon restart).
- After every certbot renewal via `certbot-renew.service ExecStartPost`.

**certbot renewal exception**: `forgejo-fw-open-http.sh` is called by
`certbot-renew.service ExecStartPre`. It inserts a world-RETURN rule for port
80 at position 1 (highest priority) so the ACME HTTP-01 challenge can reach
nginx from any IP. After renewal, `ExecStartPost` calls `forgejo-fw-apply.sh`
to restore the restriction. Port 443 is never opened beyond admin CIDRs.

**Admin CIDRs**: auto-detected from `ipv4.icanhazip.com` (as `/32`) and
`ipv6.icanhazip.com` (as `/64`) on each `provision.sh` run. Stored in
`/etc/forgejo-admin-cidrs` on the VPS (one CIDR per line, chmod 600) and in
`terraform.tfvars` locally (gitignored).

### 2.3 UFW (host INPUT chain)

UFW is configured by `deploy.sh` to allow ports 22, 80, 443, and 2222 from any
source on the host INPUT chain. These rules have **no practical effect** on
Docker-mapped ports (80/443), because Docker's PREROUTING DNAT intercepts those
packets before they reach INPUT. The UFW rules exist only for host-level service
compatibility and do not affect the container access policy.

### 2.4 IPv6 parity

All firewall rules are mirrored for `ip6tables`. The DOCKER-USER IPv6 chain
has identical RETURN/DROP rules for admin IPv6 CIDRs, and the cloud provider
firewalls use the same `allowed_cidrs` list for both families.

---

## 3. Secret Management (HashiCorp Vault)

Vault runs locally in file-backend mode (not dev mode). It is started before
provisioning and sealed after. The unseal key is in `.vault-keys` (gitignored);
loss of this file means Vault cannot be unsealed after a reboot.

### 3.1 Secret layout

| Path | Contents |
|---|---|
| `secret/forgejo/config` | `db_password`, `db_user`, `db_name`, `ssh_ca_pubkey` |
| `secret/forgejo/cloud` | `vultr_api_key` (or equivalent per provider) |
| `secret/forgejo/deploy` | `certbot_email`, `admin_ssh_public_key`, `forgejo_admin_user`, `forgejo_secret_key`, `forgejo_internal_token` |
| `secret/forgejo/instances/<provider>-<workspace>` | `admin_password`, `admin_password_ts`, `provider`, `workspace` |

### 3.2 Admin password rotation

`provision.sh` reads `admin_password_ts` from Vault. If the timestamp is absent
or the password is older than 7 days, a new password is generated
(`openssl rand -base64 32`), pushed to Forgejo via the admin API, and written
back to Vault. The old password is overwritten — Vault is always the source of
truth.

On `--destroy`, the instance secret at
`secret/forgejo/instances/<provider>-<workspace>` is deleted from Vault.

### 3.3 Forgejo app secrets

`FORGEJO_SECRET_KEY` and `FORGEJO_INTERNAL_TOKEN` are generated once during
`setup.sh` (via `openssl rand -hex 32`) and stored in Vault. They are injected
into `/opt/forgejo/.env` at deploy time (chmod 600, owned root:root). Forgejo
reads them at startup; they never appear in any process argument list or log.

### 3.4 Database credentials

PostgreSQL credentials are stored in Vault and injected into `/opt/forgejo/.env`
and `/opt/forgejo/app.ini` (both chmod 600). The database port is not mapped to
the host — it is only reachable within the Docker compose network
(`forgejo_internal`).

### 3.5 Admin API tokens

`sign-user-key.sh` generates a scoped short-lived admin API token on the fly via
`docker exec forgejo admin user generate-access-token --token-expiry 1h`. The
token is used in memory for the duration of the signing session and never written
to disk or Vault.

---

## 4. TLS / Certificate Issuance

- **No DNS required.** `DOMAIN` is set to the VPS public IP.
- Let's Encrypt issues an **IP SAN certificate** via ACME HTTP-01 using the
  `--preferred-profile shortlived` option (160-hour validity).
- Certbot runs inside a Docker container that shares compose project volumes with
  nginx, ensuring the webroot challenge path is the same volume nginx serves.
- A `certbot-renew.timer` fires every 12 hours (with 600-second random delay)
  to renew before the 160-hour certificate expires.
- In `dual` stack mode, the certificate covers both the IPv4 and IPv6 addresses
  as separate IP SANs so clients using either address get a valid cert.

---

## 5. Explicitly Disabled Features

The following are disabled specifically to reduce attack surface or enforce the
desired security posture.

### 5.1 In `app.ini` (Forgejo)

| Setting | Value | Reason |
|---|---|---|
| `DISABLE_HTTP_GIT` | `true` | All git operations must go over SSH; HTTP clone/push is blocked |
| `DISABLE_REGISTRATION` | `true` | Admin creates all accounts; prevents unauthorized account creation |
| `REQUIRE_SIGNIN_VIEW` | `true` | Unauthenticated users cannot browse any page |
| `DEFAULT_KEEP_EMAIL_PRIVATE` | `true` | Prevents email address harvesting |
| `START_SSH_SERVER` | `false` | Forgejo's built-in SSH server is disabled; host sshd handles SSH |
| `INSTALL_LOCK` | `true` | Prevents the web installer from running on first request |
| `GO_GET_CLONE_URL_PROTOCOL` | `SSH` | `go get` uses SSH clone URLs, consistent with HTTP git being disabled |
| `USE_COMPAT_SSH_URI` | `false` | Emits RFC-compliant `ssh://` URIs; port comes from SSH client config |
| `MAILER.ENABLED` | `false` | No email service configured; eliminates SMTP credential exposure |

### 5.2 In `sshd_forgejo.conf` (port 2222)

| Setting | Value | Reason |
|---|---|---|
| `PasswordAuthentication` | `no` | No password login on the git SSH port |
| `PermitRootLogin` | `no` | Root cannot connect on port 2222 |
| `AuthorizedKeysFile` | `none` | No flat key file; all auth via `AuthorizedKeysCommand` |
| `TrustedUserCAKeys` | absent | If set, sshd skips `AuthorizedKeysCommand` and the `command=` restriction from Forgejo would not be enforced |
| `PermitTTY` | `no` | The git user gets no interactive shell |
| `AllowAgentForwarding` | `no` | No agent forwarding on git SSH sessions |
| `AllowTcpForwarding` | `no` | No tunneling on git SSH sessions |
| `X11Forwarding` | `no` | No X11 on git SSH sessions |
| `UsePAM` | `no` | The git user has a locked password (`*`); PAM would block key auth for locked accounts |

### 5.3 In `99-hardening.conf` (port 22, admin sshd)

| Setting | Value | Reason |
|---|---|---|
| `PasswordAuthentication` | `no` | Key-only admin access |
| `KbdInteractiveAuthentication` | `no` | Blocks keyboard-interactive (e.g. OTP challenges that could be brute-forced) |
| `PermitRootLogin` | `no` | Root login disabled after provisioning is complete |
| `AllowUsers deploy` | (only `deploy`) | No other user can connect on port 22 |
| `MaxAuthTries` | `3` | Limits brute-force attempts per connection |
| `LoginGraceTime` | `30` | Disconnects unauthenticated connections after 30 s |
| `AllowAgentForwarding` | `no` | No agent forwarding for admin sessions |
| `AllowTcpForwarding` | `no` | No tunneling for admin sessions |
| `X11Forwarding` | `no` | No X11 for admin sessions |

### 5.4 Docker networking

- The Forgejo container (`172.19.0.x`, `forgejo_internal` network) is not
  directly reachable from outside; only nginx can reach it.
- The PostgreSQL port is not mapped to the host and is unreachable outside the
  `forgejo_internal` Docker bridge.
- Forgejo's internal API (port 3000) is mapped to `127.0.0.1:3000` only — not
  `0.0.0.0:3000`.

---

## 6. Host-Level Hardening

### 6.1 Kernel lockdown (integrity mode)

`deploy.sh` enables `lockdown=integrity` via the `LSM_LOCKDOWN` sysfs interface
at runtime and persists it in the GRUB cmdline. Integrity mode prevents writing
to kernel memory (kprobes, unsigned driver loading, etc.), blocking a class of
privilege-escalation techniques that require kernel code injection.

### 6.2 Unattended upgrades

A daily `apt-daily-upgrade.timer` applies Debian security updates at 08:00 UTC
with automatic reboot enabled. This keeps the kernel and base packages patched
without operator intervention.

### 6.3 Docker image updates

A daily `docker-pull.timer` at 09:00 UTC pulls the latest image digests for all
compose services and recreates any container whose image digest changed. This
keeps Forgejo, nginx, PostgreSQL, and certbot on current patch levels.

### 6.4 Sudoers scope

Two sudoers rules are installed:

- `/etc/sudoers.d/deploy-admin` — `deploy ALL=(ALL) NOPASSWD: ALL`. The deploy
  user requires broad sudo for provisioning operations (package install, systemd,
  iptables). This is accepted for a single-purpose admin account.
- `/etc/sudoers.d/forgejo-keys` — `nobody ALL=(root) NOPASSWD: /usr/bin/docker exec -u git forgejo forgejo keys *`. Scoped to exactly the command needed by `AuthorizedKeysCommand`.

### 6.5 File permissions

| File | Mode | Owner |
|---|---|---|
| `/opt/forgejo/.env` | 600 | root:root |
| `/opt/forgejo/app.ini` | 600 | 1000:1000 (Forgejo container UID) |
| `/etc/forgejo-admin-cidrs` | 600 | root:root |
| `/etc/ssh/forgejo_ca.pub` | 644 | root:root |
| `/usr/local/bin/forgejo-keys.sh` | 755 | root:root |
| `/usr/local/lib/forgejo-cert-extract.py` | 755 | root:root |
| `/etc/sudoers.d/*` | 440 | root:root |

---

## 7. Audit and Observability

- **SSH auth log** (`journalctl -t forgejo-auth`): every connection to port 2222
  emits a structured line: timestamp, username, key type, fingerprint, mode
  (cert/raw), and result (ok / denied:cert_required / err:extract_failed /
  err:key_not_registered).
- **Forgejo access log**: `app.ini` enables `ENABLE_ACCESS_LOG = true` with
  `ACCESS = console` and `ROUTER = console`. All HTTP requests and git operations
  appear in `docker logs forgejo`.
- **iptables counters**: `sudo iptables -L DOCKER-USER -n -v` shows per-rule
  packet/byte counts. DROP counters indicate blocked connection attempts.
- **UFW block log**: UFW logs blocked INPUT packets with `[UFW BLOCK]` prefix to
  the system journal.

---

## 8. Known Limitations and Accepted Risks

| Item | Risk | Accepted because |
|---|---|---|
| TOFU host key scanning (`sign-user-key.sh`) | First connection to a new instance could be MITM'd; subsequent connections are pinned | Admin workstation is trusted; IP is from Terraform output |
| `deploy ALL=(ALL) NOPASSWD: ALL` | If `deploy` is compromised, attacker has full root | Single-purpose server; deploy key is the sole admin credential |
| Web password derivation via `ssh-keygen -Y sign` | The `password-derivation` namespace is informal; a signed message could be replayed within that namespace | The challenge includes the instance IP and a version tag; reuse across instances is structurally prevented |
| Vault file backend on local disk | If the local machine is compromised, Vault data could be read | Vault is local-only; unseal key in `.vault-keys` is required and gitignored |
| Admin password stored in Vault | Vault compromise exposes Forgejo admin password | Password is rotated every 7 days; Forgejo admin has no SSH access |
| `forgejo-cert-extract.py` runs as nobody | Parsing untrusted cert blob as nobody | Script has no network access, no write access, and is pure Python with no C extensions |
