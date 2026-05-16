# provision.sh

Provisions a cloud VPS and deploys Forgejo. Safe to re-run — Terraform reconciles drift and `deploy.sh` is idempotent.

Reads all secrets from the local Vault instance started by `setup.sh`.

## Quick reference

```bash
# Interactive: prompts for provider, region, plan
./provision.sh

# Fully unattended (no interactive prompts)
./provision.sh --non-interactive --provider vultr --region ewr --plan vc2-1c-1gb

# IPv6-only instance
./provision.sh --ip-stack ipv6

# Dual-stack (IPv4 + IPv6, cert covers both)
./provision.sh --ip-stack dual

# Second instance in its own workspace
./provision.sh --workspace staging

# Destroy current instance
./provision.sh --destroy

# Destroy a specific workspace
./provision.sh --destroy --workspace staging

# Destroy all instances for the current provider
./provision.sh --destroy --destroy-all
```

## Options

| Flag | Description |
|---|---|
| `--provider NAME` | Cloud provider: `vultr`, `aws`, `azure` |
| `--region REGION` | Provider region code |
| `--plan PLAN` | Instance size/plan |
| `--workspace NAME` | Terraform workspace (default: `default`) |
| `--ip-stack MODE` | `ipv4` (default), `dual`, or `ipv6` |
| `--non-interactive` | Skip all interactive menus; requires `--provider`, `--region`, `--plan` |
| `--ssh-key FILE` | SSH private key for VPS login (default: `~/.ssh/id_ed25519`) |
| `--destroy` | Destroy the instance instead of provisioning |
| `--destroy-all` | Destroy every active instance for the current provider |
| `--destroy-ip IP` | Look up instance by IP in `.provision-log.json` and destroy it |
| `--workspace NAME` | Target a specific workspace for `--destroy` |

## IP stack modes

| Mode | IPv4 firewall | IPv6 firewall | TLS/provisioning | Notes |
|---|---|---|---|---|
| `ipv4` | open | closed | IPv4 | Default |
| `dual` | open | open | IPv4 | Cert covers both IPs as SANs |
| `ipv6` | closed | open | IPv6 | Vultr still has IPv4 at the network layer; firewall blocks it |

`ip_stack` is saved in `terraform.tfvars` and restored automatically on re-runs. You only need to pass `--ip-stack` on the first provision for a workspace.

## Providers

| Provider | Credentials | Default plan |
|---|---|---|
| `vultr` | `vultr_api_key` file | `vc2-1c-0.5gb` |
| `aws` | `aws_access_key` + `aws_secret_access_key` files | `t3.micro` |
| `azure` | `azure_credentials` file (JSON service principal) | `Standard_B1s` |

The last-used provider is remembered in `.last-provider` and used as the default on the next run.

## Workspaces

Each workspace has isolated Terraform state and its own `terraform.<name>.tfvars` file. This allows two instances to coexist under the same provider.

- Default workspace (`default`) uses `terraform.tfvars` and hostname `forgejo`
- Named workspace `<name>` uses `terraform.<name>.tfvars` and hostname `forgejo-<name>`

Azure resource group names are derived from the hostname, so named workspaces are required for any second Azure instance.

## What provision.sh does

1. Unseals Vault and reads secrets
2. Prompts for provider / region / plan (unless `--non-interactive`)
3. Writes `terraform.tfvars` (or `terraform.<workspace>.tfvars`)
4. Runs `terraform apply`
5. Waits for SSH to be available (polls `ssh-keyscan`)
6. Renders config templates (`nginx.conf`, `app.ini`, `.env`) from Vault secrets
7. `scp`s files to the VPS
8. Runs `deploy.sh` on the VPS via SSH
9. Appends a provision event to `.provision-log.json`

## Vault secrets used

| Path | Fields read |
|---|---|
| `secret/forgejo/cloud` | `vultr_api_key` (or AWS/Azure keys) |
| `secret/forgejo/config` | `db_password`, `db_user`, `db_name`, `ssh_ca_pubkey`, `secret_key`, `internal_token` |
| `secret/forgejo/deploy` | `certbot_email`, `admin_ssh_public_key`, `forgejo_admin_user`, `forgejo_admin_email` |
| `secret/forgejo/instances/<provider>-<workspace>` | `admin_password` (rotated if absent or >7 days old) |

The instance-specific secret is deleted from Vault when `--destroy` is run.

## Admin password rotation

On each provision run, `provision.sh` reads `admin_password` from `secret/forgejo/instances/<provider>-<workspace>`. If it is absent or older than 7 days, a new password is generated, stored, and set on the running Forgejo instance via the API.

To read the current admin password:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN="$(cat .vault.token)"
vault kv get -field=admin_password secret/forgejo/instances/vultr-default
```

## Provision log (`.provision-log.json`)

Every run appends one NDJSON line. Active instances are those where the most recent event for `(provider, workspace)` is `provision`.

```bash
# Show all events
cat .provision-log.json | python3 -m json.tool

# Show only active instances
python3 - <<'EOF'
import json
events = {}
for line in open('.provision-log.json'):
    r = json.loads(line)
    events[(r['provider'], r['workspace'])] = r
for r in events.values():
    if r['action'] == 'provision':
        print(f"{r['provider']}/{r['workspace']}  {r['ip'] or r.get('ipv6','')}  {r['ts']}")
EOF
```

## TLS certificates

Let's Encrypt issues IP certificates using the `shortlived` profile (160-hour validity). The certbot renewal systemd timer runs every 12 hours on the VPS to keep the cert current.

In `dual` mode the cert covers both the IPv4 and IPv6 addresses as separate IP SANs.

## Re-running on an existing instance

Re-runs skip the Terraform apply if there is no drift, re-render templates from current Vault secrets, and re-run `deploy.sh`. This is the correct way to update the admin password or nginx config without destroying the instance.

Root SSH login is disabled after the first deploy; subsequent runs connect as the `deploy` user automatically.

## See also

- `setup.md` — first-time Vault and Yubikey initialization
- `sign-user-key.md` — issue SSH certificates to users
- `export-git.md` — back up all repositories
