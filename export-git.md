# export-git.sh

Exports all Forgejo repositories to a single zstd-compressed tar archive. Each repository is captured as a bare mirror clone — all branches, tags, and Forgejo internal refs (PR refs) are included.

Used by `cron/daily-export.sh` twice daily and by `cron/weekly-rotate.sh` before rotation.

## Quick reference

```bash
# Auto-detect instance from Terraform state; generate admin token via SSH
./export-git.sh

# Specify instance and token explicitly
./export-git.sh --forgejo-url https://1.2.3.4 --admin-token TOKEN

# Custom output path
./export-git.sh --output /backups/forgejo-$(date +%Y%m%d).tar.zst

# Unattended / cron
./export-git.sh \
  --forgejo-url https://1.2.3.4 \
  --admin-token TOKEN \
  --output /var/backups/forgejo/$(date +%Y%m%d).tar.zst \
  --quiet
```

## Options

| Flag | Description |
|---|---|
| `--forgejo-url URL` | Forgejo base URL (auto-detect from Terraform if omitted) |
| `--admin-token TOKEN` | Admin API token (auto-generate via SSH if omitted) |
| `--output FILE` | Output path (default: `./archive/forgejo-export-YYYYMMDD-HHMMSS.tar.zst`) |
| `--ssh-key FILE` | SSH key for token auto-generation (default: `~/.ssh/id_ed25519`) |
| `--compression LEVEL` | zstd compression level 1–19 (default: 3) |
| `--no-wikis` | Skip wiki repositories |
| `--no-archived` | Exclude archived repositories |
| `--insecure` | Skip TLS certificate verification |
| `--quiet` | Suppress progress output (errors still go to stderr) |

Environment variable overrides: `FORGEJO_URL`, `FORGEJO_ADMIN_TOKEN`, `ADMIN_SSH_KEY`.

## Token lookup

Tokens are auto-generated via SSH when Vault and SSH connectivity are available. To supply one manually:

```bash
# Get the admin username
vault kv get -field=forgejo_admin_user secret/forgejo/deploy

# Generate a short-lived token via SSH (expires automatically after 1 hour)
ssh deploy@<ip> \
  "docker exec -u git forgejo /usr/local/bin/forgejo admin user \
   generate-access-token --username <admin-user> --token-name export \
   --token-expiry 1h --raw"

# Or retrieve the admin password from Vault and create a long-lived token in the web UI
# (User Settings → Applications → Generate Token)
vault kv get -field=admin_password secret/forgejo/instances/vultr-default
```

Replace `vultr-default` with `<provider>-<workspace>` for non-default instances.

## Archive layout

```
forgejo-export-YYYYMMDD-HHMMSS/
  metadata.json              Export timestamp, server URL, repo count
  repositories.json          Full repo index with metadata
  repos/
    <owner>/<repo>.git/      Bare mirror clone
    <owner>/<repo>.wiki.git/ Wiki repo (when present and non-empty)
```

## Restoring to a new Forgejo instance

```bash
# Extract
tar -I zstd -xf forgejo-export-20260516-040000.tar.zst
cd forgejo-export-20260516-040000/repos

# Create user and org accounts in the new Forgejo first, then push each repo
for repo in */*.git; do
    git -C "$repo" remote set-url origin https://<new-ip>/${repo%.git}.git
    git -C "$repo" push --mirror
done
```

Note: `refs/pull/*` (PR refs) are included and safe to push to Forgejo, but they appear as orphan refs until PRs are recreated.

The `repositories.json` file contains full metadata (description, topics, visibility, default branch) to help recreate repo settings manually or via the Forgejo API.

## What is NOT in the archive

Issues, pull requests, releases, webhooks, user accounts, org settings, deploy keys, and access tokens are not exported. This is a git-layer backup only.

For a complete migration (including metadata), Forgejo's built-in admin backup (`forgejo admin dump`) captures everything but requires direct access to the VPS.

## Output directory

Archives written to the default location (`./archive/`) are gitignored. The `./archive/` directory itself (with a `.gitkeep`) is tracked so the directory exists after a fresh clone.

## See also

- `cron/daily-export.md` — automated twice-daily export with retention pruning
- `mirror-git.md` — live mirror to a running second instance
- `provision.md` — deploy or re-provision the Forgejo instance
