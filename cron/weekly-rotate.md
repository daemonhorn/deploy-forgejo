# cron/weekly-rotate.sh

Performs a rolling Forgejo instance rotation: provisions a fresh cloud VPS, mirrors recently-active repositories to it, verifies it is healthy, and destroys the old instance.

Invoked by the crontab installed from `crontab.example` (Sunday 04:00 UTC by default).

## Configuration

Set in the environment (typically in `crontab.example`):

| Variable | Default | Description |
|---|---|---|
| `ROTATE_PROVIDER` | `vultr` | Cloud provider for the new instance |
| `ROTATE_REGION` | `ewr` | Provider region |
| `ROTATE_PLAN` | `vc2-1c-0.5gb` | Instance plan |

## Workflow

1. **Snapshot** the current workspace name and IP from Terraform state
2. **Mirror**: call `mirror-git.sh --non-interactive` to provision a new instance and sync repos updated in the last 7 days
3. **Identify** the new workspace by reading the most recent `provision` event in `.provision-log.json`
4. **Verify** the new instance returns HTTP 200 or 302 on its HTTPS endpoint (30-second timeout)
5. **Destroy** the old instance — only if step 4 passed
6. **Switch** the active Terraform workspace to the new one so auto-detection in `export-git.sh`, `sign-user-key.sh`, and `provision.sh` targets the correct IP

## Failure handling

- `set -euo pipefail` means any unexpected error aborts the script immediately
- The old instance is **never destroyed** unless the health check in step 4 explicitly passes
- `.provision-log.json` always records what was provisioned, so orphaned new instances can be destroyed manually:
  ```bash
  ./provision.sh --destroy --workspace mirror-YYYYMMDD-HHMMSS --non-interactive
  ```
- If the health check fails, the script restores the Terraform workspace context to the old instance before exiting

## Installing the crontab

```bash
crontab < crontab.example
```

Edit `crontab.example` to set `ROTATE_PROVIDER`, `ROTATE_REGION`, and `ROTATE_PLAN` before installing.

## Manual invocation

```bash
ROTATE_PROVIDER=vultr ROTATE_REGION=ewr ROTATE_PLAN=vc2-1c-1gb \
    ./cron/weekly-rotate.sh
```

The script logs each step with UTC timestamps. Redirect stderr to a log file if running manually:

```bash
./cron/weekly-rotate.sh 2>&1 | tee /tmp/rotate.log
```

## Post-rotation

After a successful rotation:

- The new instance is active at a new IP address
- `.last-provider` and the active Terraform workspace both point to the new instance
- Users need a new SSH certificate (the Yubikey CA key does not change, but the VPS host key changes — existing known_hosts entries for the old IP are harmless)
- The certbot certificate on the new instance covers the new IP; the old cert is deleted with the old instance

If you serve Forgejo via a domain name (not a bare IP), update your DNS record to point to the new IP.

## Orphaned instances

If the script fails between step 2 (provision) and step 5 (destroy), both the old and new instances may exist simultaneously. To clean up:

```bash
# List all active instances
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

# Destroy the unwanted one by workspace name
./provision.sh --destroy --workspace mirror-YYYYMMDD-HHMMSS --non-interactive
```

## Increasing the mirror window

The default `--days 7` mirrors repos with activity in the past week. For a fuller safety net:

Edit `weekly-rotate.sh` and add `--days 30` to the `mirror-git.sh` invocation. Longer windows increase migration time proportionally.

## See also

- `mirror-git.md` — mirror-git.sh documentation
- `cron/daily-export.md` — daily backup documentation
- `provision.md` — manual provisioning and destroy operations
