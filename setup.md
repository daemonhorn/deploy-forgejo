# setup.sh

One-time initialization. Run before the first `provision.sh`. Safe to re-run — Vault and PIV key generation steps are guarded and prompt before overwriting existing state.

## What it does

1. Generates (or reuses) an ECCP384 SSH CA key in Yubikey PIV slot 9d
2. Exports the public key as `ca.pub` (committed) and `ca_public.pem` (gitignored)
3. Initializes a local HashiCorp Vault instance (file backend in `.vault-data/`)
4. Stores all deployment secrets in Vault

## Prerequisites

| Tool | Install |
|---|---|
| `ykman` | `pip install yubikey-manager` or `apt install yubikey-manager` |
| `vault` | HashiCorp release — file-backend mode, not dev mode |
| `ykcs11` | `apt install ykcs11` |
| `ssh-keygen`, `openssl` | standard packages |
| Yubikey | inserted and detected (`ykman info`) |

Cloud API key files must be present in the repo root before running (or you will be prompted):

- `vultr_api_key` — plain text, no newline required
- `aws_access_key` + `aws_secret_access_key` — if using AWS
- `azure_credentials` — JSON service principal

All of these are gitignored.

## Usage

```bash
./setup.sh
```

No flags. Interactive prompts collect:

| Prompt | Vault path | Field |
|---|---|---|
| Let's Encrypt email | `secret/forgejo/deploy` | `certbot_email` |
| Admin SSH public key | `secret/forgejo/deploy` | `admin_ssh_public_key` |
| Forgejo admin username | `secret/forgejo/deploy` | `forgejo_admin_user` |
| Forgejo admin email | `secret/forgejo/deploy` | `forgejo_admin_email` |
| Vultr API key | `secret/forgejo/cloud` | `vultr_api_key` |

## Secrets written to Vault

| Path | Fields |
|---|---|
| `secret/forgejo/cloud` | `vultr_api_key` |
| `secret/forgejo/config` | `db_password`, `db_user`, `db_name`, `ssh_ca_pubkey`, `secret_key`, `internal_token` |
| `secret/forgejo/deploy` | `certbot_email`, `admin_ssh_public_key`, `forgejo_admin_user`, `forgejo_admin_email` |

`secret/forgejo/instances/<provider>-<workspace>` is written by `provision.sh`, not `setup.sh`.

## Files produced

| File | Committed | Notes |
|---|---|---|
| `ca.pub` | yes | SSH-format CA public key; deployed to every VPS |
| `ca_public.pem` | no | PEM-format; used by `sign-user-key.sh` |
| `.ykcs11_lib` | no | Path to the PKCS#11 library detected at setup time |
| `.vault-data/` | no | Vault file backend; back up the whole directory |
| `.vault-keys` | no | Single unseal key — **back this up securely** |
| `.vault.token` | no | Root token for Vault API access |

## Critical: back up `.vault-keys`

The unseal key in `.vault-keys` is the only way to unseal Vault after a reboot. Loss of this file means all secrets are inaccessible and you must re-run `setup.sh` from scratch (destroying all stored secrets).

Recommended: copy to an encrypted password manager or secure USB.

## Vault lifecycle

Vault must be running and unsealed for `provision.sh`, `export-git.sh`, `mirror-git.sh`, and `sign-user-key.sh` to auto-detect credentials. `setup.sh` starts it and leaves it running.

On reboot, restart and unseal manually:

```bash
vault server -config vault.hcl > /tmp/vault.log 2>&1 &
echo $! > .vault.pid
vault operator unseal "$(cat .vault-keys)"
```

Or add Vault startup to your login shell or a systemd user unit.

## Re-running after a new Yubikey / lost CA

Generating a new CA key automatically destroys all existing Vault secrets (they reference the old CA public key). Every previously-issued SSH certificate will stop working. Re-run `setup.sh`, then re-provision all instances and re-sign all user keys.

## Reading secrets manually

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN="$(cat .vault.token)"

vault kv get secret/forgejo/deploy
vault kv get secret/forgejo/config
vault kv get -field=admin_password secret/forgejo/instances/vultr-default
```

## Next step

```bash
./provision.sh
```
