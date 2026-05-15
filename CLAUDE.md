# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Automates deployment of a [Forgejo](https://forgejo.org/) container instance on Vultr (cloud-provider agnostic via Terraform provider modules). Secrets are managed by a local-only HashiCorp Vault (file backend). The SSH CA is backed by a Yubikey PIV key in slot 9d; all SSH certificate signing requires physical Yubikey presence.

## Workflow

**First time only:**
```
./setup.sh          # Yubikey PIV key gen → Vault init → store secrets (certbot email, SSH key, admin user)
```

**Deploy / reprovision:**
```
./provision.sh      # Vault → prompt provider/region/plan (menus) → write tfvars → terraform apply → deploy.sh on VPS
./provision.sh --workspace <name>                         # deploy a second instance in its own Terraform workspace
./provision.sh --non-interactive --provider vultr \
    --region ewr --plan vc2-1c-1gb                        # unattended/cron (no interactive prompts)
```

**Destroy an instance:**
```
./provision.sh --destroy                     # picker if multiple active instances; else destroys current
./provision.sh --destroy --workspace <name>  # destroy a specific workspace
./provision.sh --destroy --destroy-ip <ip>   # destroy by IP (looked up in .provision-log.json)
./provision.sh --destroy --destroy-all       # destroy every active instance for the current provider
```

**Issue SSH cert to a user:**
```
./sign-user-key.sh <forgejo-username> <user-key.pub>
```

**Mirror recently-active repositories to a new instance:**
```
./mirror-git.sh \
    --dest-provider vultr --dest-region ewr --dest-plan vc2-1c-1gb
    # provisions new instance, mirrors repos updated in last 7 days

./mirror-git.sh --dest-url https://DEST_IP --days 14
    # target existing instance, mirror repos from last 14 days

./mirror-git.sh \
    --src-url https://SRC_IP --src-token TOKEN \
    --dest-url https://DEST_IP --dest-token TOKEN \
    --quiet                                              # unattended/cron
```

**Export / backup all repositories:**
```
./export-git.sh                          # auto-detects URL + token; interactive
./export-git.sh --output backup.tar.zst  # explicit output file
./export-git.sh --forgejo-url https://IP --admin-token TOKEN --output backup.tar.zst  # unattended/cron
```

## Architecture

### Cloud-Provider Abstraction

`terraform/modules/providers/<name>/` implements the provider contract:
- **Inputs**: `ssh_public_key`, `region`, `plan`, `hostname`, `firewall_ports`
- **Outputs**: `public_ipv4`, `ssh_user`, `instance_id`

Each provider has a dedicated Terraform root under `terraform/<name>/`. Adding a new provider = new module directory + new `terraform/<name>/` root; no other files change.

### Secret Flow

```
Yubikey slot 9d (CA private key, never leaves device)
     ↓ ykman piv + ssh-keygen -D (during setup.sh)
ca_public.pem  ←  local only (gitignored)
ca.pub         ←  committed; deployed to VPS as TrustedUserCAKeys

Vault (local, file backend in .vault-data/)
  secret/forgejo/config   → db_password, db_user, db_name, ssh_ca_pubkey
  secret/forgejo/cloud    → vultr_api_key
  secret/forgejo/deploy   → certbot_email, admin_ssh_public_key, ...
     ↓ provision.sh reads at deploy time; DOMAIN derived from Terraform IP output
VPS: /opt/forgejo/{.env, app.ini, ca.pub}
```

### VPS Service Layout

| Service | How | Port |
|---|---|---|
| Forgejo web | Docker Compose (internal port 3000) | — |
| nginx | Docker Compose | 80, 443 |
| PostgreSQL | Docker Compose (internal) | — |
| certbot | Docker Compose (renewal loop) | — |
| Forgejo Git SSH | Host sshd (`sshd-forgejo.service`) | 2222 |

Forgejo's **built-in SSH server is disabled** (`START_SSH_SERVER = false`). A separate sshd instance on port 2222 handles Git-over-SSH with:
- `TrustedUserCAKeys /etc/ssh/forgejo_ca.pub`
- `AuthorizedKeysCommand /usr/local/bin/forgejo-keys.sh %u %t %k`

`forgejo-keys.sh` handles both raw keys and certificates. For cert auth it calls `files/forgejo-cert-extract.py` to extract the base public key from the cert blob (binary SSH cert parsing) before querying Forgejo.

### Auth Policy

- Web login: password auth disabled (`ENABLE_BASIC_AUTHENTICATION = false`)
- Self-registration: disabled (`DISABLE_REGISTRATION = true`)
- Git SSH: requires a CA-signed certificate AND the base public key registered in Forgejo

## Critical Files

| File | Purpose |
|---|---|
| `setup.sh` | Yubikey PIV keygen + Vault init + secret bootstrap |
| `provision.sh` | Orchestrates terraform + deploy; reads all secrets from Vault |
| `deploy.sh` | Remote: installs Docker, configures host sshd, issues cert, starts services |
| `sign-user-key.sh` | Signs a user SSH key with the Yubikey CA via PKCS#11 |
| `export-git.sh` | Exports all Forgejo repositories to a portable tar.zst archive (cron-safe) |
| `mirror-git.sh` | Mirrors recently-active repos to a new Forgejo instance (cron-safe) |
| `files/forgejo-keys.sh` | Deployed to VPS; called by sshd AuthorizedKeysCommand |
| `files/forgejo-cert-extract.py` | Parses SSH cert binary to extract base public key |
| `files/sshd_forgejo.conf` | sshd config for port-2222 Forgejo SSH daemon |
| `files/templates/app.ini.tmpl` | Forgejo config; sets `SSH_TRUSTED_USER_CA_KEYS_FILENAME` |
| `terraform/modules/providers/vultr/main.tf` | Vultr resources (instance, firewall, SSH key) |
| `.provision-log.json` | Append-only NDJSON log of every provision/destroy event |

## Local Dependencies

Before running `setup.sh`:
- `ykman` — `pip install yubikey-manager` or distro package
- `vault` — from HashiCorp (file-backend mode, not dev mode)
- `ykcs11` — `apt install ykcs11` (provides `libykcs11.so` for PKCS#11 signing)
- `terraform` — from HashiCorp (>= 1.5)
- `envsubst`, `openssl`, `uuidgen` — standard packages
- `zstd` — `apt install zstd`; required by `export-git.sh` for archive compression

## Secrets and Security

- `vultr_api_key` file: gitignored; read once by `setup.sh` into Vault
- `.vault.token`, `.vault-keys`, `.vault-data/`: gitignored; the unseal key in `.vault-keys` must be backed up — loss means Vault cannot be unsealed after reboot
- `ca_public.pem`: gitignored (regenerate from Yubikey anytime: `ykman piv keys export 9d ca_public.pem`)
- `ca.pub`: **committed** — it's the CA public key, deployed to VPS
- Terraform state (`terraform/<provider>/*.tfstate`): gitignored; no secrets (DB password is Vault-owned)
- VPS: `/opt/forgejo/.env` and `app.ini` chmod 600; contain DB password at rest

## Adding a New Cloud Provider

1. Create `terraform/modules/providers/<name>/` with `main.tf`, `variables.tf`, `outputs.tf`
2. Implement the same input variable names and output names as `vultr/` and `azure/`
3. Create `terraform/<name>/` root with `main.tf`, `variables.tf`, `outputs.tf`, `terraform.tfvars.example`
4. Add a `<name>)` case to `provision.sh` (credential loading + `TF_DIR` assignment)
5. Update `sign-user-key.sh` provider check for the new `terraform/<name>/` Terraform output directory
6. No changes to `deploy.sh` or any file under `files/`

## Supported Cloud Providers

| Provider | Credentials file | Terraform root | Default plan |
|---|---|---|---|
| `vultr` | `vultr_api_key` | `terraform/vultr/` | `vc2-1c-0.5gb` |
| `aws` | `aws_access_key` + `aws_secret_access_key` | `terraform/aws/` | `t3.micro` |
| `azure` | `azure_credentials` (JSON) | `terraform/azure/` | `Standard_B1s` |

## Multiple Instances (Terraform Workspaces)

`provision.sh` supports Terraform workspaces so two instances can coexist under the same provider with isolated state files.

- Default workspace (`default`) uses `terraform.tfvars` and hostname `forgejo`.
- Non-default workspace `<name>` uses `terraform.<name>.tfvars` and hostname `forgejo-<name>` (required for Azure, where the resource group IS named after the hostname).
- Use `--workspace <name>` on both `provision.sh` and `--destroy` to target a specific workspace.

### `--non-interactive` flag

Skips all interactive menus. Requires `--provider`, `--region`, and `--plan`. Used by `mirror-git.sh` when auto-provisioning a destination instance.

### Provision log (`.provision-log.json`)

Every `provision.sh` run appends one JSON object per line (NDJSON, append-only):

```json
{"action":"provision","ts":"2026-05-14T03:00:00Z","provider":"vultr","workspace":"default","ip":"1.2.3.4","region":"ewr","plan":"vc2-1c-1gb"}
{"action":"destroy","ts":"2026-05-14T04:00:00Z","provider":"vultr","workspace":"default","ip":"1.2.3.4","region":"","plan":""}
```

Active instances = those where the latest event per `(provider, workspace)` has `action = "provision"`.

`--destroy` reads this log to build the instance picker. If the log is absent or has no entries for the current provider, it falls back to reading `terraform output` from the current workspace.

## TLS / Domain

No DNS setup required. `DOMAIN` is set to the VPS public IP directly (`DOMAIN="$IP"` in `provision.sh`). Let's Encrypt issues an IP certificate using the short-lived profile (`--preferred-profile shortlived`, 160-hour validity). IP certs are required to use this profile. The certbot renewal systemd timer runs every 12 hours to keep it current.

## Known Verification Steps

After deploy, run these to confirm correct configuration:
1. `ssh-keygen -l -f ca.pub` — fingerprint must match `ykman piv info` slot 9d certificate
2. Password login attempt at `https://<ip>` → must be rejected
3. `./sign-user-key.sh testuser test_key.pub` → cert issued; Git clone with cert succeeds
4. Git clone with raw (unsigned) key → rejected by sshd-forgejo (no authorized_keys entry without cert)
