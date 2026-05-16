# sign-user-key.sh

Issues CA-signed SSH certificates for Forgejo users. Requires the Yubikey with the CA key in PIV slot 9d.

## How SSH auth works on this instance

Forgejo's built-in SSH server is disabled. A separate `sshd` on port 2222 handles Git-over-SSH and requires:

1. A CA-signed certificate (signed by the key in Yubikey slot 9d)
2. The user's raw public key registered in Forgejo (User Settings → SSH Keys)

Both conditions must be met. `sign-user-key.sh` handles both in one step unless `--no-register` is passed.

## Single-user mode

```bash
./sign-user-key.sh <forgejo-username> <user-public-key-file>
```

Produces `<user-public-key-file>-cert.pub` alongside the input file.

### Example

```bash
./sign-user-key.sh alice alice_id_ed25519.pub
```

Alice places `alice_id_ed25519-cert.pub` as `~/.ssh/id_ed25519-cert.pub` (alongside her private key). SSH picks it up automatically — no `~/.ssh/config` change needed.

### Options (single-user)

| Flag | Description |
|---|---|
| `--forgejo-url URL` | Forgejo base URL (auto-detected from Terraform if omitted) |
| `--admin-token TOKEN` | Admin API token (auto-generated via SSH if omitted) |
| `--no-register` | Sign the cert only; skip creating the Forgejo user and registering the key |

## Batch mode

```bash
./sign-user-key.sh --batch users.csv [--output-dir ./keys]
```

CSV format (one user per line):

```
# username[,key]
alice
bob,/home/admin/bob_id_ed25519.pub
carol,ssh-ed25519 AAAA...
diana                          # no key → a new ed25519 keypair is auto-generated
```

- Blank lines and `#` comments are ignored
- A header row `username,key` is skipped automatically
- If no key is provided, a new ed25519 keypair is generated in `--output-dir/<username>/`

Output per user: `keys/<username>/id_ed25519`, `id_ed25519.pub`, `id_ed25519-cert.pub`

Auto-generated private keys must be delivered to users via a secure channel (encrypted email, password manager share, etc.).

### Options (batch)

| Flag | Description |
|---|---|
| `--output-dir DIR` | Directory for generated keys and certs (default: `./keys`) |
| `--forgejo-url URL` | Forgejo base URL |
| `--admin-token TOKEN` | Admin API token |
| `--no-register` | Sign only; skip Forgejo registration |

## Certificate validity

Default: `+365d` (1 year). Override with the `CERT_VALIDITY` environment variable:

```bash
CERT_VALIDITY=+90d ./sign-user-key.sh alice alice.pub
```

## Getting an admin token

Tokens are auto-generated via SSH when Vault is available. To supply one manually:

```bash
# Get the admin username from Vault
vault kv get -field=forgejo_admin_user secret/forgejo/deploy

# Generate a token via SSH
ssh deploy@<ip> \
  "docker exec -u git forgejo /usr/local/bin/forgejo admin user \
   generate-access-token --username <admin-user> --token-name sign --raw"

# Or get the admin password from Vault and create a token in the web UI
# (User Settings → Applications → Generate Token)
vault kv get -field=admin_password secret/forgejo/instances/vultr-default
```

## Yubikey touch

The signing operation requires a physical touch on the Yubikey. In batch mode, touch is cached for 15 seconds after the first signing — you may need to touch once per signing session, not once per user.

## What to send to the user

**Single-user:** the `*-cert.pub` file only. The user places it alongside their existing private key as `~/.ssh/<keyname>-cert.pub`.

**Batch (auto-generated keys):** both the private key (`id_ed25519`) and the cert (`id_ed25519-cert.pub`). The private key is sensitive — send via encrypted channel.

**Clone URL format:**

```
git clone ssh://git@<ip>:2222/<username>/<repo>.git
```

## Revoking access

SSH certificates have a fixed expiry and no online revocation mechanism. To revoke before expiry:

1. Remove the user's public key from Forgejo (User Settings → SSH Keys, or via admin API)
2. The `AuthorizedKeysCommand` on the VPS will then reject the cert even if it hasn't expired

## See also

- `provision.md` — deploying the instance
- `setup.md` — generating the CA key
