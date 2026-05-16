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
| `--web-password` | Derive and set a deterministic web UI password from the user's Ed25519 key (see below) |
| `--private-key FILE` | Ed25519 private key for web password derivation; defaults to stripping `.pub` from the pubkey path |

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
| `--no-web-password` | Skip web UI password derivation (default: on for Ed25519 keys) |

## Web UI password

In batch mode web UI password derivation is **on by default**. Pass `--no-web-password` to skip it.

The script derives a deterministic 32-character password from each user's Ed25519 private key and the current instance's IP address, then sets it in Forgejo via the admin API. This enables users to log into the web UI with a stable, re-derivable password.

**Password policy:**
- Requires an Ed25519 key (RSA and ECDSA are not deterministically signable)
- Tied to the instance IP — password changes with each weekly rotation (new instance = new IP)
- After a rotation, re-run `sign-user-key.sh --batch` against the new instance to push updated passwords
- Users can re-derive their password at any time without contacting the admin (see below)

**In single-user mode**, pass `--web-password` explicitly; the private key is auto-discovered by stripping `.pub` from the pubkey path:
```bash
# alice_id_ed25519 and alice_id_ed25519.pub are in the same directory
./sign-user-key.sh alice alice_id_ed25519.pub --web-password

# Or pass the private key explicitly
./sign-user-key.sh alice alice_id_ed25519.pub --web-password --private-key /path/to/private_key
```

**In batch mode** (default behaviour, suppress with `--no-web-password`), passwords are derived for:
- Auto-generated key users (the private key is generated locally, always available)
- File-path users where an adjacent private key exists (same path without `.pub`)
- Users with inline public keys are skipped with a warning (no private key available)

### User re-derivation recipe

Users can re-derive their password at any time without the admin:

```bash
INSTANCE_IP="<current-instance-ip>"
CHALLENGE="webapp-password:${INSTANCE_IP}:v1"
echo -n "$CHALLENGE" | ssh-keygen -Y sign -f ~/.ssh/id_ed25519 \
    -n password-derivation 2>/dev/null | grep -v '^-----' | base64 -d | \
    sha256sum | python3 -c "import sys, base64; d=bytes.fromhex(sys.stdin.read().split()[0]); \
    print(base64.urlsafe_b64encode(d[:24]).decode().rstrip('='), end='')"
```

The password output from this command is the web UI login password. Update `INSTANCE_IP` after a weekly rotation (the admin will provide the new IP).

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

# Generate a short-lived token via SSH (expires automatically after 1 hour)
ssh deploy@<ip> \
  "docker exec -u git forgejo /usr/local/bin/forgejo admin user \
   generate-access-token --username <admin-user> --token-name sign \
   --token-expiry 1h --raw"

# Or get the admin password from Vault and create a token in the web UI
# (User Settings → Applications → Generate Token)
vault kv get -field=admin_password secret/forgejo/instances/vultr-default
```

## Yubikey touch

The signing operation requires a physical touch on the Yubikey. In batch mode, touch is cached for 15 seconds after the first signing — you may need to touch once per signing session, not once per user.

## What to send to the user

**Single-user:** the `*-cert.pub` file only. The user places it alongside their existing private key as `~/.ssh/<keyname>-cert.pub`.

**Batch (auto-generated keys):** both the private key (`id_ed25519`) and the cert (`id_ed25519-cert.pub`). The private key is sensitive — send via encrypted channel.

**If `--web-password` was used:** also send the web UI password and the re-derivation recipe above.

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
