#!/usr/bin/env bash
# export-git.sh — Export all Forgejo repositories to a zstd-compressed archive.
#
# Each repository is cloned with git clone --mirror, capturing all branches,
# tags, and Forgejo internal refs (PR refs).  Wiki repos are included where
# the Forgejo API reports a wiki is enabled.
#
# USAGE
#   ./export-git.sh [OPTIONS]
#
# REQUIRED FOR UNATTENDED USE
#   --forgejo-url URL        Forgejo base URL (e.g. https://1.2.3.4)
#   --admin-token TOKEN      Forgejo admin API token
#
# ALL OPTIONS
#   --forgejo-url URL        Forgejo base URL (auto-detect from Terraform if omitted)
#   --admin-token TOKEN      Forgejo admin API token (auto-generate via SSH if omitted)
#   --output FILE            Output archive path
#                            (default: ./archive/forgejo-export-YYYYMMDD-HHMMSS.tar.zst)
#   --ssh-key FILE           SSH key for auto-token generation
#                            (default: ~/.ssh/id_ed25519)
#   --compression LEVEL      zstd compression level 1-19 (default: 3)
#   --no-wikis               Skip wiki repositories
#   --no-archived            Exclude archived repositories
#   --insecure               Skip TLS certificate verification
#   --quiet                  Suppress progress output (errors still go to stderr;
#                            suitable for cron)
#   --help                   Show this help text
#
# ENVIRONMENT VARIABLES
#   FORGEJO_URL              Override --forgejo-url
#   FORGEJO_ADMIN_TOKEN      Override --admin-token
#   ADMIN_SSH_KEY            Override --ssh-key
#
# CRON EXAMPLE
#   0 3 * * * FORGEJO_ADMIN_TOKEN=<token> /path/to/export-git.sh \
#       --forgejo-url https://<ip> \
#       --output /backups/forgejo-$(date +\%Y\%m\%d).tar.zst \
#       --quiet
#
# ARCHIVE LAYOUT
#   forgejo-export-<timestamp>/
#     metadata.json            Export info (time, server URL, repo count)
#     repositories.json        Full repository index with metadata
#     repos/
#       <owner>/<repo>.git/    Bare mirror clone (all branches and tags)
#       <owner>/<repo>.wiki.git/  Wiki repo (when present)
#
# RESTORING TO A NEW FORGEJO INSTANCE
#   tar -I zstd -xf forgejo-export-<timestamp>.tar.zst
#   cd forgejo-export-<timestamp>/repos
#   # Create the user/org accounts in the new Forgejo first, then:
#   for repo in */*.git; do
#     owner="${repo%%/*}"
#     name="${repo#*/}"
#     new_url="https://<new-host>/${owner}/${name}"
#     git -C "$repo" remote set-url origin "$new_url"
#     git -C "$repo" push --mirror
#     # Note: refs/pull/* are included; they are safe to push to Forgejo but
#     # may appear as orphan refs until PRs are recreated.
#   done
#
# SECURITY NOTE
#   The admin token is passed to git via -c http.extraHeader=..., which is
#   visible in the process list (/proc/<pid>/cmdline) during each clone.  On a
#   shared multi-user host, prefer setting FORGEJO_ADMIN_TOKEN via a secrets
#   manager and run the script as a dedicated user.
#
# REQUIREMENTS
#   git (>= 2.17), curl, tar, zstd, python3
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { [[ "$QUIET" == "true" ]] && return 0; echo -e "${GREEN}[export]${NC} $*"; }
warn()  { echo -e "${YELLOW}[export]${NC} $*" >&2; }
error() { echo -e "${RED}[export]${NC} $*" >&2; exit 1; }

# ── Defaults ──────────────────────────────────────────────────────────────────
FORGEJO_URL="${FORGEJO_URL:-}"
ADMIN_TOKEN="${FORGEJO_ADMIN_TOKEN:-}"
SSH_KEY="${ADMIN_SSH_KEY:-$HOME/.ssh/id_ed25519}"
OUTPUT_FILE=""
COMPRESSION_LEVEL=3
INCLUDE_WIKIS=true
INCLUDE_ARCHIVED=true
INSECURE=false
QUIET=false

# ── CLI arguments ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --forgejo-url)
            [[ $# -ge 2 ]] || error "--forgejo-url requires a value"
            FORGEJO_URL="$2"; shift 2 ;;
        --admin-token)
            [[ $# -ge 2 ]] || error "--admin-token requires a value"
            ADMIN_TOKEN="$2"; shift 2 ;;
        --output)
            [[ $# -ge 2 ]] || error "--output requires a value"
            OUTPUT_FILE="$2"; shift 2 ;;
        --ssh-key)
            [[ $# -ge 2 ]] || error "--ssh-key requires a value"
            SSH_KEY="$2"; shift 2 ;;
        --compression)
            [[ $# -ge 2 ]] || error "--compression requires a value"
            COMPRESSION_LEVEL="$2"; shift 2 ;;
        --no-wikis)      INCLUDE_WIKIS=false;    shift ;;
        --no-archived)   INCLUDE_ARCHIVED=false; shift ;;
        --insecure)      INSECURE=true;          shift ;;
        --quiet)         QUIET=true;             shift ;;
        --help|-h)
            sed -n '/^# USAGE/,/^# REQUIREMENTS/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *)
            error "Unknown argument: $1. Use --help for usage." ;;
    esac
done

# ── Prerequisites ─────────────────────────────────────────────────────────────
for _cmd in git curl python3 tar zstd; do
    command -v "$_cmd" &>/dev/null || error "Required tool not found: $_cmd (install it and retry)"
done

# ── Output path ───────────────────────────────────────────────────────────────
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
[[ -z "$OUTPUT_FILE" ]] && OUTPUT_FILE="${SCRIPT_DIR}/archive/forgejo-export-${TIMESTAMP}.tar.zst"

_out_dir="$(dirname "$OUTPUT_FILE")"
mkdir -p "$_out_dir" || error "Cannot create output directory: $_out_dir"

# Guard against overwriting an existing archive
[[ ! -e "$OUTPUT_FILE" ]] || error "Output file already exists: $OUTPUT_FILE"

# ── SSL flag (needed by both token validation and curl calls later) ───────────
_ssl_flag=""
$INSECURE && _ssl_flag="--insecure"

# ── Resolve Forgejo URL ───────────────────────────────────────────────────────
if [[ -z "$FORGEJO_URL" ]]; then
    _ip=""
    if command -v terraform &>/dev/null; then
        _last_provider=""
        [[ -f "$SCRIPT_DIR/.last-provider" ]] \
            && _last_provider="$(tr -d '[:space:]' < "$SCRIPT_DIR/.last-provider")"
        _tf_dirs=("$SCRIPT_DIR/terraform/vultr")
        [[ -n "$_last_provider" ]] && \
            _tf_dirs=("$SCRIPT_DIR/terraform/$_last_provider" "$SCRIPT_DIR/terraform/vultr")
        for _dir in "${_tf_dirs[@]}"; do
            [[ -d "$_dir" ]] || continue
            _ip="$(cd "$_dir" && terraform output -raw public_ipv4 2>/dev/null || true)"
            [[ -n "$_ip" ]] && break
        done
    fi
    [[ -n "$_ip" ]] \
        || error "Cannot determine Forgejo URL. Pass --forgejo-url URL or set FORGEJO_URL."
    FORGEJO_URL="https://${_ip}"
    info "Forgejo URL (from Terraform): $FORGEJO_URL"
fi

FORGEJO_URL="${FORGEJO_URL%/}"  # strip trailing slash

# ── Resolve admin token ───────────────────────────────────────────────────────
if [[ -z "$ADMIN_TOKEN" ]]; then
    _ip="${FORGEJO_URL#https://}"; _ip="${_ip#http://}"; _ip="${_ip%%/*}"
    _ip="${_ip#[}"; _ip="${_ip%]}"   # strip brackets from IPv6 literals
    _admin_user="gitadmin"

    if [[ -f "$SCRIPT_DIR/.vault.token" ]]; then
        export VAULT_ADDR="http://127.0.0.1:8200"
        export VAULT_TOKEN
        VAULT_TOKEN="$(cat "$SCRIPT_DIR/.vault.token")"
        if vault status &>/dev/null 2>&1; then
            _vu="$(vault kv get -field=forgejo_admin_user secret/forgejo/deploy 2>/dev/null || true)"
            [[ -n "$_vu" ]] && _admin_user="$_vu"
        fi
    fi

    _kh="$SCRIPT_DIR/known_hosts.deploy"
    _ssh_opts="-i $SSH_KEY -o CanonicalizeHostname=no -o ConnectTimeout=15 -o BatchMode=yes"
    [[ -f "$_kh" ]] \
        && _ssh_opts="$_ssh_opts -o UserKnownHostsFile=$_kh -o StrictHostKeyChecking=yes" \
        || _ssh_opts="$_ssh_opts -o StrictHostKeyChecking=no"

    info "Generating admin API token via SSH as deploy@$_ip (user: $_admin_user)..."
    # shellcheck disable=SC2086
    ADMIN_TOKEN="$(ssh $_ssh_opts "deploy@$_ip" \
        "docker exec -u git forgejo /usr/local/bin/forgejo admin user \
         generate-access-token --username $_admin_user \
         --token-name export-$(date +%s) --raw 2>&1" 2>/dev/null || true)"
    [[ -n "$ADMIN_TOKEN" ]] \
        || error "Could not obtain admin token. Pass --admin-token TOKEN or set FORGEJO_ADMIN_TOKEN."

    # Validate: SSH token generation silently returns error text on failure
    _api_status="$(curl -sf --max-time 10 ${_ssl_flag:+"$_ssl_flag"} \
        -H "Authorization: token $ADMIN_TOKEN" \
        -o /dev/null -w "%{http_code}" \
        "$FORGEJO_URL/api/v1/user" 2>/dev/null || true)"
    [[ "$_api_status" == "200" ]] \
        || error "Admin token validation failed (HTTP $_api_status). Check admin user name and SSH connectivity."
    info "Admin token obtained."
fi

# ── Enumerate repositories ────────────────────────────────────────────────────
# Enumerate via admin/users + admin/orgs to guarantee completeness.
# repos/search with admin token does not reliably return all private repos
# across all owners in all Forgejo versions.
info "Enumerating repositories via Forgejo admin API..."

REPOS_JSON="$(python3 - \
    "$FORGEJO_URL" "$ADMIN_TOKEN" \
    "$INCLUDE_ARCHIVED" "$INCLUDE_WIKIS" \
    "$_ssl_flag" \
<<'PY'
import json, sys, urllib.request, ssl

url_base          = sys.argv[1]
token             = sys.argv[2]
include_archived  = sys.argv[3].lower() == "true"
include_wikis     = sys.argv[4].lower() == "true"
insecure          = len(sys.argv) > 5 and sys.argv[5] == "--insecure"

ctx = ssl.create_default_context()
if insecure:
    ctx.check_hostname = False
    ctx.verify_mode    = ssl.CERT_NONE

def api_get(path):
    """Return JSON from a single API call."""
    req = urllib.request.Request(
        f"{url_base}{path}",
        headers={"Authorization": f"token {token}", "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, context=ctx, timeout=30) as r:
        return json.load(r)

def paginate(path, list_key=None):
    """Yield all items from a paginated Forgejo list endpoint."""
    page = 1
    while True:
        sep  = "&" if "?" in path else "?"
        data = api_get(f"{path}{sep}limit=50&page={page}")
        items = data.get(list_key, data) if list_key else data
        if not items:
            break
        yield from items
        if len(items) < 50:
            break
        page += 1

def repo_record(repo):
    full_name = repo["full_name"]
    base_url  = repo.get("clone_url", f"{url_base}/{full_name}.git")
    rec = {
        "full_name":      full_name,
        "clone_url":      base_url,
        "private":        repo.get("private",  False),
        "archived":       repo.get("archived", False),
        "description":    repo.get("description", ""),
        "topics":         repo.get("topics",   []),
        "owner":          repo["owner"]["login"],
        "name":           repo["name"],
        "default_branch": repo.get("default_branch", "main"),
        "is_wiki":        False,
    }
    return rec

def wiki_has_pages(owner, name):
    """Return True only if the wiki git repo has at least one page.
    has_wiki=True means the wiki feature is enabled, not that any pages exist.
    Cloning an uninitialised wiki repo fails with HTTP 404."""
    try:
        pages = api_get(f"/api/v1/repos/{owner}/{name}/wiki/pages?limit=1")
        return bool(pages)
    except Exception:
        return False

all_repos = {}   # full_name -> record (dedup across user+org enumeration)

# Users
try:
    for user in paginate("/api/v1/admin/users"):
        uname = user["login"]
        try:
            for repo in paginate(f"/api/v1/users/{uname}/repos"):
                if not include_archived and repo.get("archived", False):
                    continue
                rec = repo_record(repo)
                all_repos[rec["full_name"]] = rec

                # Wiki: separate bare repo, not returned by repos/search
                if include_wikis and repo.get("has_wiki", False) and wiki_has_pages(rec["owner"], rec["name"]):
                    wiki_rec = {
                        **rec,
                        "full_name": f"{rec['full_name']}.wiki",
                        "clone_url": rec["clone_url"].removesuffix(".git") + ".wiki.git",
                        "is_wiki":   True,
                        "description": f"Wiki for {rec['full_name']}",
                    }
                    all_repos[wiki_rec["full_name"]] = wiki_rec
        except Exception as e:
            print(f"Warning: could not list repos for user {uname}: {e}", file=sys.stderr)
except Exception as e:
    print(f"Warning: could not list users via admin API: {e}", file=sys.stderr)
    print("Falling back to repos/search endpoint...", file=sys.stderr)
    for repo in paginate("/api/v1/repos/search", list_key="data"):
        if not include_archived and repo.get("archived", False):
            continue
        rec = repo_record(repo)
        all_repos[rec["full_name"]] = rec
        if include_wikis and repo.get("has_wiki", False) and wiki_has_pages(rec["owner"], rec["name"]):
            wiki_rec = {
                **rec,
                "full_name": f"{rec['full_name']}.wiki",
                "clone_url": rec["clone_url"].removesuffix(".git") + ".wiki.git",
                "is_wiki":   True,
                "description": f"Wiki for {rec['full_name']}",
            }
            all_repos[wiki_rec["full_name"]] = wiki_rec

# Orgs
try:
    for org in paginate("/api/v1/admin/orgs"):
        oname = org.get("username") or org.get("name", "")
        if not oname:
            continue
        try:
            for repo in paginate(f"/api/v1/orgs/{oname}/repos"):
                if not include_archived and repo.get("archived", False):
                    continue
                rec = repo_record(repo)
                all_repos[rec["full_name"]] = rec

                if include_wikis and repo.get("has_wiki", False) and wiki_has_pages(rec["owner"], rec["name"]):
                    wiki_rec = {
                        **rec,
                        "full_name": f"{rec['full_name']}.wiki",
                        "clone_url": rec["clone_url"].removesuffix(".git") + ".wiki.git",
                        "is_wiki":   True,
                        "description": f"Wiki for {rec['full_name']}",
                    }
                    all_repos[wiki_rec["full_name"]] = wiki_rec
        except Exception as e:
            print(f"Warning: could not list repos for org {oname}: {e}", file=sys.stderr)
except Exception as e:
    print(f"Warning: could not enumerate orgs: {e}", file=sys.stderr)

print(json.dumps(list(all_repos.values())))
PY
)"

REPO_COUNT="$(echo "$REPOS_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")"
info "Found $REPO_COUNT repositories (including wikis where enabled)."

if [[ "$REPO_COUNT" -eq 0 ]]; then
    warn "No repositories found. Nothing to export."
    exit 0
fi

# ── Working directory ─────────────────────────────────────────────────────────
WORK_DIR="$(mktemp -d /tmp/forgejo-export-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

EXPORT_NAME="forgejo-export-${TIMESTAMP}"
EXPORT_DIR="$WORK_DIR/$EXPORT_NAME"
mkdir -p "$EXPORT_DIR/repos"

# ── metadata.json ─────────────────────────────────────────────────────────────
_version="$(curl -sf --max-time 10 ${_ssl_flag:+"$_ssl_flag"} \
    -H "Authorization: token $ADMIN_TOKEN" \
    "$FORGEJO_URL/api/v1/version" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('version','unknown'))" \
    2>/dev/null || echo "unknown")"

python3 -c "
import json, sys, datetime
url, version, count, ts = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
try:
    dt = datetime.datetime.strptime(ts, '%Y%m%d-%H%M%S')
    iso_ts = dt.strftime('%Y-%m-%dT%H:%M:%SZ')
except Exception:
    iso_ts = ts
json.dump({
    'export_time':       iso_ts,
    'forgejo_url':       url,
    'forgejo_version':   version,
    'repository_count':  count,
    'format':            'git-mirror',
    'restore_hint':      (
        'Each repos/<owner>/<name>.git is a bare mirror clone. '
        'Restore: for each repo directory, run: '
        'git remote set-url origin <new-forgejo-url>/<owner>/<name>.git && git push --mirror'
    ),
}, open('$EXPORT_DIR/metadata.json', 'w'), indent=2)
" "$FORGEJO_URL" "$_version" "$REPO_COUNT" "$TIMESTAMP"

# ── Clone repositories ────────────────────────────────────────────────────────
mapfile -t _REPO_NAMES < <(echo "$REPOS_JSON" | python3 -c "
import json, sys
for r in json.load(sys.stdin):
    print(r['full_name'])
")

mapfile -t _REPO_URLS < <(echo "$REPOS_JSON" | python3 -c "
import json, sys
for r in json.load(sys.stdin):
    print(r['clone_url'])
")

mapfile -t _REPO_WIKIS < <(echo "$REPOS_JSON" | python3 -c "
import json, sys
for r in json.load(sys.stdin):
    print('true' if r.get('is_wiki') else 'false')
")

# Build git auth config options (token in -c avoids putting credentials in the
# clone URL while remaining compatible with git >= 2.17).
_GIT_OPTS=(-c "http.extraHeader=Authorization: token ${ADMIN_TOKEN}")
$INSECURE && _GIT_OPTS+=(-c "http.sslVerify=false")

SUCCEEDED=0
SUCCEEDED_WIKIS=0
FAILED=()

for _i in "${!_REPO_NAMES[@]}"; do
    _full_name="${_REPO_NAMES[$_i]}"
    _clone_url="${_REPO_URLS[$_i]}"
    _is_wiki="${_REPO_WIKIS[$_i]}"
    _dest="$EXPORT_DIR/repos/${_full_name}.git"

    mkdir -p "$(dirname "$_dest")"
    info "  Cloning ${_full_name} ..."

    if GIT_TERMINAL_PROMPT=0 \
        git "${_GIT_OPTS[@]}" clone --mirror --quiet "$_clone_url" "$_dest" 2>&1; then
        SUCCEEDED=$((SUCCEEDED + 1))
        [[ "$_is_wiki" == "true" ]] && SUCCEEDED_WIKIS=$((SUCCEEDED_WIKIS + 1))
    else
        # Wiki repos are often empty (no pages yet) — warn but don't fail the export.
        if [[ "$_is_wiki" == "true" ]]; then
            warn "  Skipped wiki ${_full_name} (likely empty or not initialized)"
        else
            warn "  Failed to clone ${_full_name}"
            FAILED+=("$_full_name")
        fi
        rm -rf "$_dest"
    fi
done

# ── repositories.json ─────────────────────────────────────────────────────────
echo "$REPOS_JSON" | python3 -c "
import json, sys
print(json.dumps({'repositories': json.load(sys.stdin)}, indent=2))
" > "$EXPORT_DIR/repositories.json"

# ── Create archive ────────────────────────────────────────────────────────────
info "Compressing archive (zstd level $COMPRESSION_LEVEL, multithreaded)..."
tar -C "$WORK_DIR" -cf - "$EXPORT_NAME" \
    | zstd -T0 "-${COMPRESSION_LEVEL}" --force -o "$OUTPUT_FILE"

_size="$(du -sh "$OUTPUT_FILE" | cut -f1)"

# ── Summary ───────────────────────────────────────────────────────────────────
_regular=$((SUCCEEDED - SUCCEEDED_WIKIS))

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}[export]${NC} Export complete"
echo "  Repositories : ${_regular} repos, ${SUCCEEDED_WIKIS} wikis (${SUCCEEDED} total)"
echo "  Archive      : $OUTPUT_FILE"
echo "  Size         : $_size"
[[ ${#FAILED[@]} -eq 0 ]] || warn "  Failed       : ${FAILED[*]}"
echo
echo "  To list contents:"
echo "    tar -I zstd -tf $(basename "$OUTPUT_FILE")"
echo
echo "  To restore on a new Forgejo instance:"
echo "    tar -I zstd -xf $(basename "$OUTPUT_FILE")"
echo "    cd ${EXPORT_NAME}/repos"
echo "    for repo in */*.git; do"
echo "      git -C \"\$repo\" remote set-url origin https://<new-host>/\${repo%.git}.git"
echo "      git -C \"\$repo\" push --mirror"
echo "    done"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ ${#FAILED[@]} -eq 0 ]] || exit 1
