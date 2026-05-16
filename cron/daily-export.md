# cron/daily-export.sh

Cron wrapper around `export-git.sh`. Writes a timestamped archive to a backup directory, then prunes old archives to a configurable retention count.

Invoked by the crontab installed from `crontab.example` (twice daily by default).

## Configuration

All configuration is via environment variables, typically set in `crontab.example`:

| Variable | Default | Description |
|---|---|---|
| `FORGEJO_BACKUP_DIR` | `/var/backups/forgejo` | Directory where archives are written |
| `KEEP` | `14` | Number of archives to retain (at 2×/day = 7 days of history) |

To change retention, edit `KEEP` in the script or set it before calling:

```bash
KEEP=30 ./cron/daily-export.sh   # 15 days at 2×/day
```

## What it does

1. Calls `export-git.sh --output <BACKUP_DIR>/forgejo-YYYYMMDD-HHMM.tar.zst --quiet`
2. Logs start and completion with timestamps (UTC)
3. Prunes oldest archives if more than `KEEP` exist in `BACKUP_DIR`

Errors from `export-git.sh` are propagated to stderr and captured by the crontab redirect.

## Token and URL auto-detection

`export-git.sh` auto-detects the Forgejo URL from the last-used Terraform state (`.last-provider` + `terraform output public_ipv4`) and generates an admin token via SSH as `deploy@<ip>`.

For fully unattended operation on a machine without Terraform state (e.g. a separate backup host), pass URL and token explicitly. Edit `daily-export.sh` and replace the `export-git.sh` call:

```bash
"$SCRIPT_DIR/export-git.sh" \
    --forgejo-url https://<ip> \
    --admin-token <token> \
    --output "$ARCHIVE" \
    --quiet
```

Or set environment variables in the crontab:

```
FORGEJO_URL=https://<ip>
FORGEJO_ADMIN_TOKEN=<token>
```

To get a long-lived token for use in cron:

```bash
# Admin username from Vault
vault kv get -field=forgejo_admin_user secret/forgejo/deploy

# Generate token via SSH
ssh deploy@<ip> \
  "docker exec -u git forgejo /usr/local/bin/forgejo admin user \
   generate-access-token --username <admin-user> --token-name daily-export --raw"
```

Or log in to the Forgejo web UI and create a token under User Settings → Applications.

## Pruning logic

Archives are sorted by filesystem mtime. The oldest archives beyond the `KEEP` limit are deleted. This counts files rather than estimating age, so a skipped or paused cron run does not confuse retention.

## Manual invocation

```bash
./cron/daily-export.sh
```

Runs immediately, writes to `FORGEJO_BACKUP_DIR` (creates the directory if absent), and prunes old archives.

## Installing the crontab

```bash
crontab < crontab.example
```

The example crontab runs `daily-export.sh` at 03:00 and 15:00 UTC and `weekly-rotate.sh` on Sunday at 04:00 UTC.

## Troubleshooting

- **"Could not obtain admin token"**: Vault is not running or SSH to the VPS is failing. Check `vault status` and `ssh deploy@<ip> true`.
- **"Cannot determine Forgejo URL"**: `.last-provider` is missing or Terraform state is absent. Pass `--forgejo-url` explicitly.
- **Archive directory not writable**: `FORGEJO_BACKUP_DIR` doesn't exist or wrong permissions. Run `mkdir -p /var/backups/forgejo` as root.

## See also

- `export-git.md` — full export script documentation
- `cron/weekly-rotate.md` — weekly rotation using mirror-git.sh
