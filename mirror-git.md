# mirror-git.sh

Mirrors recently-active Forgejo repositories to a new instance. Used for:

- **Weekly rotation** (`cron/weekly-rotate.sh`): spin up a fresh VPS, sync repos, destroy old one
- **Manual migration**: move data to a different provider or region
- **Warm standby**: keep a second instance in sync

All repositories updated within the last N days (default 7) are mirrored. All branches and tags are transferred via `git push --mirror`.

## Quick reference

```bash
# Interactive: provision new instance on Vultr, mirror from current instance
./mirror-git.sh --dest-provider vultr --dest-region ewr --dest-plan vc2-1c-1gb

# Target an existing destination instance
./mirror-git.sh --dest-url https://DEST_IP --dest-token TOKEN

# Fully unattended (both instances pre-existing, supply tokens manually)
./mirror-git.sh \
  --src-url https://SRC_IP  --src-token SRC_TOKEN \
  --dest-url https://DEST_IP --dest-token DEST_TOKEN \
  --quiet

# Mirror all repos regardless of age
./mirror-git.sh --days 0 --dest-provider vultr --dest-region ewr --dest-plan vc2-1c-1gb

# Mirror last 14 days, skip archived repos and wikis
./mirror-git.sh --days 14 --no-archived --no-wikis \
  --dest-url https://DEST_IP --dest-token TOKEN
```

## Options

### Source

| Flag | Description |
|---|---|
| `--src-url URL` | Source Forgejo URL (auto-detect from Terraform if omitted) |
| `--src-token TOKEN` | Source admin token (auto-generate via SSH if omitted) |
| `--src-workspace NAME` | Terraform workspace for source lookup (default: `default`) |
| `--src-provider NAME` | Provider for source Terraform lookup (default: reads `.last-provider`) |

### Destination

| Flag | Description |
|---|---|
| `--dest-url URL` | Target an existing instance; skip provisioning |
| `--dest-token TOKEN` | Destination admin token (auto-generate via SSH if omitted) |
| `--dest-workspace NAME` | Workspace name for new instance (default: `mirror-YYYYMMDD-HHMMSS`) |
| `--dest-provider NAME` | Cloud provider for new instance |
| `--dest-region REGION` | Region for new instance |
| `--dest-plan PLAN` | Instance plan for new instance |

### Filtering

| Flag | Description |
|---|---|
| `--days N` | Mirror repos with activity in the last N days (default: 7; 0 = all) |
| `--no-wikis` | Skip wiki repositories |
| `--no-archived` | Exclude archived repositories |

### Other

| Flag | Description |
|---|---|
| `--ssh-key FILE` | SSH private key for token auto-generation (default: `~/.ssh/id_ed25519`) |
| `--insecure` | Skip TLS certificate verification |
| `--quiet` | Suppress progress output (errors still go to stderr) |

## Token lookup

Tokens are auto-generated via SSH when Vault is running locally. To supply one manually:

```bash
# Get the admin username from Vault
vault kv get -field=forgejo_admin_user secret/forgejo/deploy

# Generate a short-lived token via SSH (expires automatically after 1 hour)
ssh deploy@<ip> \
  "docker exec -u git forgejo /usr/local/bin/forgejo admin user \
   generate-access-token --username <admin-user> --token-name mirror \
   --token-expiry 1h --raw"

# Or get the admin password from Vault and create a token in the web UI
# (User Settings → Applications → Generate Token)
vault kv get -field=admin_password secret/forgejo/instances/vultr-default
```

Replace `vultr-default` with `<provider>-<workspace>` for non-default instances.

To list all known instances:

```bash
cat .provision-log.json | python3 -c "
import json, sys
events = {}
for line in sys.stdin:
    r = json.loads(line)
    events[(r['provider'], r['workspace'])] = r
for r in events.values():
    if r['action'] == 'provision':
        print(f\"{r['provider']}/{r['workspace']}  {r['ip'] or r.get('ipv6','')}  {r['ts']}\")
"
```

## What gets mirrored

- All repos with `updated_at` within the last `--days` days
- All branches and tags (`git push --mirror`)
- Wiki repos (unless `--no-wikis`)
- User and org accounts are created on the destination if absent
- Org visibility (public/private) is propagated from source

**Not mirrored:** issues, pull requests, releases, webhooks, deploy keys, or user settings. This is a git-layer mirror only.

## Source equals destination guard

The script refuses to run if the source and destination URLs resolve to the same host. This prevents accidental self-mirroring.

## Provisioning behavior

When `--dest-url` is omitted, `mirror-git.sh` calls `provision.sh --non-interactive` with the provider/region/plan you specify. The new instance gets a workspace named `mirror-YYYYMMDD-HHMMSS`.

After mirroring, the new instance is left running. To destroy it:

```bash
./provision.sh --destroy --workspace mirror-20260516-040000
```

Or use `cron/weekly-rotate.sh` which destroys the old instance automatically after verifying the new one is healthy.

## See also

- `export-git.md` — full archive backup (includes issues, releases metadata)
- `cron/weekly-rotate.md` — automated weekly rotation using this script
- `provision.md` — manual provisioning
