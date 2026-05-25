# Design: DigitalOcean Provider + Credential Lifecycle Refactor

**Date:** 2026-05-25  
**Branch:** feature/provider-digitalocean  
**Status:** Approved — ready for implementation

---

## Overview

Two parallel tracks:

1. **Credential lifecycle refactor** — extract a `lib/credential-manager.sh` library that gives every provider a consistent file-first / Vault-backup credential flow. Refactors all five existing providers.
2. **DigitalOcean provider** — adds full DigitalOcean support following the existing provider contract, including `terraform/modules/providers/digitalocean/`, `terraform/digitalocean/` root, and integration into `provision.sh`.

---

## Track 1: `lib/credential-manager.sh`

### Purpose

Single source of truth for how provider credentials are loaded. Replaces ad-hoc file checks and `vget` calls scattered across `provision.sh`.

### API

```bash
# Load a plain-text credential (token, API key). Strips whitespace.
# Sets $VAR_NAME. File wins over Vault when both are present.
load_credential VAR_NAME filename vault_field

# Load a JSON credential (Azure, Google). Preserves content exactly.
# Sets $VAR_NAME to the raw JSON string.
load_credential_json VAR_NAME filename vault_field

# Print end-of-run reminders for credential files loaded from disk this run.
# Called once at the bottom of the Done banner.
print_credential_reminders
```

### Internal flow (both functions)

1. **File present** → read value → `vault kv patch secret/forgejo/cloud "<field>=<value>"` (if patch exits non-zero AND `vault kv metadata get secret/forgejo/cloud` confirms the path doesn't exist, fall back to `vault kv put`; any other patch failure is a hard error) → append filename to `_CRED_FILES_USED[]`
2. **No file** → `vault kv get -field=<field> secret/forgejo/cloud` → hard `error` if missing from both

`vault kv patch` merges individual fields; multiple providers' credentials coexist under `secret/forgejo/cloud` without overwriting each other.

### `print_credential_reminders`

Iterates `_CRED_FILES_USED[]`. If non-empty, prints after the Done banner:

```
── Credential file(s) backed up to Vault ───────────────
  Vault path : secret/forgejo/cloud
  Backed up  : vultr_api_key  →  field: vultr_api_key
  Safe to delete: rm /path/to/vultr_api_key
```

One block per file. Only fires when at least one credential was read from disk this run.

### Call-site shape in `provision.sh`

| Provider | Call(s) |
|---|---|
| `vultr` | `load_credential _tok vultr_api_key vultr_api_key` → `export TF_VAR_vultr_api_key="$_tok"` |
| `aws` | `load_credential AWS_ACCESS_KEY_ID aws_access_key aws_access_key` + `load_credential AWS_SECRET_ACCESS_KEY aws_secret_access_key aws_secret_access_key` |
| `linode` | `load_credential LINODE_TOKEN linode_api_key linode_api_key` |
| `google` | `load_credential_json _json google_credentials google_credentials` → write `$_json` to `$TMPDIR/google_credentials.json` → Python parses that tmpfile |
| `azure` | `load_credential_json _json azure_credentials azure_credentials` → write `$_json` to `$TMPDIR/azure_credentials.json` → Python parses that tmpfile |
| `digitalocean` | `load_credential DIGITALOCEAN_TOKEN digitalocean_personal_token digitalocean_token` |

For Google and Azure: the existing Python parsing blocks currently do `open("google_credentials")` / `open("azure_credentials")`. Change: write `$_json` to a file inside `$TMPDIR` (already trap-cleaned on EXIT), pass that path as `sys.argv[2]` to the Python heredoc. One-line Python change per block: `open("google_credentials")` → `open(sys.argv[2])`; no parsing logic changes.

---

## Track 2: DigitalOcean Provider

### Terraform module: `terraform/modules/providers/digitalocean/`

**`variables.tf`** — identical variable names and types as all other provider modules. No provider-specific additions.

**`outputs.tf`** — standard four outputs:
- `public_ipv4` — `digitalocean_droplet.main.ipv4_address` (empty string when `ip_stack = "ipv6"`)
- `public_ipv6` — `digitalocean_droplet.main.ipv6_address` (empty string when `ip_stack = "ipv4"`); bare address, no `/128` suffix (unlike Linode — no stripping needed)
- `ssh_user` — `"root"` (DigitalOcean Debian droplets boot with root SSH key access)
- `instance_id` — `digitalocean_droplet.main.id`

**`main.tf`** — three resources:

**`digitalocean_ssh_key.admin`** — uploads `var.ssh_public_key`; referenced on the droplet by fingerprint.

**`digitalocean_droplet.main`**:
```hcl
image  = "debian-12-x64"
region = var.region
size   = var.plan
ipv6   = var.ip_stack != "ipv4"
ssh_keys = [digitalocean_ssh_key.admin.fingerprint]
```

**`digitalocean_firewall.main`** — uses `dynamic "inbound_rule"` blocks; same ip_stack-aware CIDR filtering pattern as the Google module (mixed IPv4/IPv6 in `source_addresses`):

- Public ports (80): `source_addresses` = `["0.0.0.0/0"]` / `["0.0.0.0/0", "::/0"]` / `["::/0"]` per ip_stack
- Admin ports (22, 2222, 443): `source_addresses` = filtered `allowed_cidrs` per ip_stack; rule omitted entirely when list is empty (fail-closed)
- User ports (2222, 443): `source_addresses` = filtered `user_cidrs` per ip_stack; rule omitted when empty (fail-closed)
- Outbound: three static rules allowing all TCP, UDP, ICMP to `["0.0.0.0/0", "::/0"]` — required; DigitalOcean Cloud Firewall blocks all egress by default without explicit outbound rules

### Terraform root: `terraform/digitalocean/`

Mirrors the Linode root structure exactly:
- `main.tf` — `provider "digitalocean" {}` (token from `DIGITALOCEAN_TOKEN` env); module call passing all vars
- `variables.tf` — default `region = "nyc1"`, default `plan = "s-1vcpu-1gb"`
- `outputs.tf` — passthrough of module outputs
- `terraform.tfvars.example` — region/plan example with comments

### `provision.sh` — five touch-points

**1. Library source** — `source "$SCRIPT_DIR/lib/credential-manager.sh"` after `source lib/common.sh`.

**2. Provider validation** — three string-match checks gain `digitalocean`.

**3. Credential case** — `digitalocean)` arm added; all other arms refactored to use `load_credential` / `load_credential_json`.

**4. Region/plan case** — `digitalocean)` arm with static lists:

Regions:
```
nyc1  New York 1         nyc3  New York 3
sfo3  San Francisco 3    ams3  Amsterdam 3
sgp1  Singapore          lon1  London
fra1  Frankfurt          tor1  Toronto
blr1  Bangalore          syd1  Sydney
```

Plans:
```
s-1vcpu-1gb   1C/1GB/25GB    ~$6/mo   (recommended minimum)
s-1vcpu-2gb   1C/2GB/50GB    ~$12/mo
s-2vcpu-2gb   2C/2GB/60GB    ~$18/mo
s-2vcpu-4gb   2C/4GB/80GB    ~$24/mo
```

Default: region `nyc1`, plan `s-1vcpu-1gb`.  
No live API cache (token required); static list same as Linode.

The tfvars-writing case appends `digitalocean` alongside `aws|azure|linode|google` (no special tfvars format needed).

**5. Done banner** — `print_credential_reminders` inserted before the closing `━━━` line.

---

## Other File Changes

### `.gitignore`

Credentials block gains:
```
digitalocean_personal_token
```

Terraform cache block gains:
```
terraform/digitalocean/.terraform/
terraform/digitalocean/.terraform.lock.hcl
```

### `sign-user-key.sh`

No structural change. The `_tf_dirs` / `_ch_dirs` arrays already resolve via `.last-provider`, which handles `digitalocean` automatically. Add `digitalocean` to the provider-name validation guard if one exists.

### `CLAUDE.md`

Provider table gains:
```
| `digitalocean` | `digitalocean_personal_token` | `terraform/digitalocean/` | `s-1vcpu-1gb` |
```

Credential-flow section gains a note: credentials are loaded file-first; if a file is present it is immediately backed up to `secret/forgejo/cloud` and the admin is reminded to delete it after a successful run.

---

## Constraints and Non-Goals

- `deploy.sh` and everything under `files/` require zero changes (provider-agnostic).
- `setup.sh` is unchanged: it still bootstraps Vault and pre-populates `secret/forgejo/cloud` with `vultr_api_key` if `vultr_api_key` file is present at setup time. The new library's fallback to Vault means existing Vault state is transparently consumed.
- DigitalOcean does not support a static IPv4 address resource (unlike GCP); the droplet's IPv4 address is ephemeral but stable for the droplet lifetime — the same model as Vultr and Linode.
- IPv6 note: not all DigitalOcean regions support IPv6. The static region list only includes regions known to support it; the `ip_stack` variable follows the same semantics as every other provider.
