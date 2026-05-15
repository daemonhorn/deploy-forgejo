#!/usr/bin/env bash
# mirror-git.sh — Mirror recently-active Forgejo repositories to a new instance.
#
# All repositories updated within the last N days (default 7) are mirrored
# from the source Forgejo to a destination Forgejo instance.  By default,
# provision.sh is called to create the destination; pass --dest-url to target
# an existing instance instead.
#
# USAGE
#   ./mirror-git.sh [OPTIONS]
#
# QUICK START (interactive, provisions new instance)
#   ./mirror-git.sh --dest-provider vultr --dest-region ewr --dest-plan vc2-1c-1gb
#
# UNATTENDED / CRON (both instances pre-existing)
#   ./mirror-git.sh \
#     --src-url https://SRC_IP --src-token TOKEN \
#     --dest-url https://DEST_IP --dest-token TOKEN \
#     --quiet
#
# SOURCE OPTIONS
#   --src-url URL          Source Forgejo URL (default: auto-detect from Terraform)
#   --src-token TOKEN      Source admin token (default: auto-generate via SSH)
#   --src-workspace NAME   Terraform workspace for source (default: default)
#   --src-provider NAME    Provider for source Terraform lookup (default: .last-provider)
#
# DESTINATION OPTIONS
#   --dest-url URL         Target existing instance; skip provisioning
#   --dest-token TOKEN     Destination admin token (default: auto-generate via SSH)
#   --dest-workspace NAME  Terraform workspace for new instance (default: mirror-TIMESTAMP)
#   --dest-provider NAME   Cloud provider for new instance
#   --dest-region REGION   Region for new instance
#   --dest-plan PLAN       Instance plan for new instance
#
# FILTER OPTIONS
#   --days N               Mirror repos updated in last N days (default: 7)
#   --no-wikis             Skip wiki repositories
#   --no-archived          Exclude archived repositories
#
# OTHER OPTIONS
#   --ssh-key FILE         SSH private key for token generation (default: ~/.ssh/id_ed25519)
#   --insecure             Skip TLS certificate verification
#   --quiet                Suppress progress output (errors still go to stderr)
#   --help                 Show this help
#
# NOTES
#   updated_at reflects pushes and metadata edits (not pulls).
#   All branches and tags are mirrored (git push --mirror).
#   Owners (users and orgs) and repos are created on the destination if absent.
#   Org visibility is propagated from source.
#   Source and destination must differ (safety guard).
#
# REQUIREMENTS
#   git (>= 2.17), curl, python3, ssh, ssh-keyscan, terraform
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
QUIET=false
info()   { $QUIET && return 0; echo -e "${GREEN}[mirror]${NC} $*"; }
warn()   { echo -e "${YELLOW}[mirror]${NC} $*" >&2; }
error()  { echo -e "${RED}[mirror]${NC} $*" >&2; exit 1; }
header() { $QUIET && return 0; echo -e "${CYAN}[mirror]${NC} $*"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
DAYS=7
SRC_URL=""
SRC_TOKEN=""
SRC_WORKSPACE="default"
SRC_PROVIDER=""
DEST_URL=""
DEST_TOKEN=""
DEST_WORKSPACE="mirror-$(date +%Y%m%d-%H%M%S)"
DEST_PROVIDER=""
DEST_REGION=""
DEST_PLAN=""
INCLUDE_WIKIS=true
INCLUDE_ARCHIVED=true
INSECURE=false
SSH_KEY="${ADMIN_SSH_KEY:-$HOME/.ssh/id_ed25519}"
# Forgejo ≥7.0 requires explicit token scopes; enumerate them rather than relying on
# the 'all' shorthand, which has been unreliable in some Forgejo 15.x builds.
_FORGEJO_ADMIN_SCOPES="read:activitypub,write:activitypub,read:admin,write:admin,read:issue,write:issue,read:misc,write:misc,read:notification,write:notification,read:organization,write:organization,read:package,write:package,read:repository,write:repository,read:user,write:user"

# ── CLI arguments ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --days)           [[ $# -ge 2 ]] || error "--days requires a value"
                          DAYS="$2"; shift 2 ;;
        --src-url)        [[ $# -ge 2 ]] || error "--src-url requires a value"
                          SRC_URL="$2"; shift 2 ;;
        --src-token)      [[ $# -ge 2 ]] || error "--src-token requires a value"
                          SRC_TOKEN="$2"; shift 2 ;;
        --src-workspace)  [[ $# -ge 2 ]] || error "--src-workspace requires a value"
                          SRC_WORKSPACE="$2"; shift 2 ;;
        --src-provider)   [[ $# -ge 2 ]] || error "--src-provider requires a value"
                          SRC_PROVIDER="$2"; shift 2 ;;
        --dest-url)       [[ $# -ge 2 ]] || error "--dest-url requires a value"
                          DEST_URL="$2"; shift 2 ;;
        --dest-token)     [[ $# -ge 2 ]] || error "--dest-token requires a value"
                          DEST_TOKEN="$2"; shift 2 ;;
        --dest-workspace) [[ $# -ge 2 ]] || error "--dest-workspace requires a value"
                          DEST_WORKSPACE="$2"; shift 2 ;;
        --dest-provider)  [[ $# -ge 2 ]] || error "--dest-provider requires a value"
                          DEST_PROVIDER="$2"; shift 2 ;;
        --dest-region)    [[ $# -ge 2 ]] || error "--dest-region requires a value"
                          DEST_REGION="$2"; shift 2 ;;
        --dest-plan)      [[ $# -ge 2 ]] || error "--dest-plan requires a value"
                          DEST_PLAN="$2"; shift 2 ;;
        --ssh-key)        [[ $# -ge 2 ]] || error "--ssh-key requires a value"
                          SSH_KEY="$2"; shift 2 ;;
        --no-wikis)       INCLUDE_WIKIS=false; shift ;;
        --no-archived)    INCLUDE_ARCHIVED=false; shift ;;
        --insecure)       INSECURE=true; shift ;;
        --quiet)          QUIET=true; shift ;;
        --help|-h)
            sed -n '/^# USAGE/,/^# REQUIREMENTS/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *)  error "Unknown argument: $1. Use --help for usage." ;;
    esac
done

# ── Prerequisites ─────────────────────────────────────────────────────────────
for _cmd in git curl python3 ssh ssh-keyscan; do
    command -v "$_cmd" &>/dev/null || error "Required: $_cmd (install it and retry)"
done
[[ -f "$SSH_KEY" ]] || error "SSH key not found: $SSH_KEY (set --ssh-key or ADMIN_SSH_KEY)"

_ssl_flag=""
$INSECURE && _ssl_flag="--insecure"

# ── Resolve source URL ────────────────────────────────────────────────────────
if [[ -z "$SRC_URL" ]]; then
    _src_ip="" _src_ipv6=""
    if command -v terraform &>/dev/null; then
        _last="${SRC_PROVIDER:-}"
        [[ -z "$_last" && -f "$SCRIPT_DIR/.last-provider" ]] \
            && _last="$(tr -d '[:space:]' < "$SCRIPT_DIR/.last-provider")"
        _tf_dirs=("$SCRIPT_DIR/terraform/vultr")
        [[ -n "$_last" ]] \
            && _tf_dirs=("$SCRIPT_DIR/terraform/$_last" "$SCRIPT_DIR/terraform/vultr")
        for _dir in "${_tf_dirs[@]}"; do
            [[ -d "$_dir" ]] || continue
            _src_ip="$(cd "$_dir" && \
                terraform workspace select "$SRC_WORKSPACE" >/dev/null 2>&1 && \
                terraform output -raw public_ipv4 2>/dev/null || true)"
            _src_ipv6="$(cd "$_dir" && terraform output -raw public_ipv6 2>/dev/null || true)"
            [[ -n "$_src_ip" || -n "$_src_ipv6" ]] && break
        done
    fi
    if [[ -n "$_src_ip" ]]; then
        SRC_URL="https://${_src_ip}"
    elif [[ -n "$_src_ipv6" ]]; then
        SRC_URL="https://[${_src_ipv6}]"
    else
        error "Cannot determine source URL. Pass --src-url URL."
    fi
    info "Source (from Terraform): $SRC_URL"
fi
SRC_URL="${SRC_URL%/}"

# ── Resolve source admin token ────────────────────────────────────────────────
if [[ -z "$SRC_TOKEN" ]]; then
    _src_ip="${SRC_URL#https://}"; _src_ip="${_src_ip#http://}"; _src_ip="${_src_ip%%/*}"
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
    _ssh_opts="-i $SSH_KEY -o ConnectTimeout=15 -o BatchMode=yes"
    [[ -f "$_kh" ]] \
        && _ssh_opts="$_ssh_opts -o UserKnownHostsFile=$_kh -o StrictHostKeyChecking=yes" \
        || _ssh_opts="$_ssh_opts -o StrictHostKeyChecking=no"
    info "Generating source admin token via SSH as deploy@${_src_ip}..."
    # shellcheck disable=SC2086
    SRC_TOKEN="$(ssh $_ssh_opts "deploy@$_src_ip" \
        "docker exec -u git forgejo /usr/local/bin/forgejo admin user \
         generate-access-token --username $_admin_user \
         --token-name mirror-src-$(date +%s) --scopes $_FORGEJO_ADMIN_SCOPES --raw" \
        2>/dev/null || true)"
    # Take only the last line in case Forgejo emits log lines before the token.
    SRC_TOKEN="$(printf '%s\n' "$SRC_TOKEN" | tail -1 | tr -d '[:space:]')"
    [[ -n "$SRC_TOKEN" ]] \
        || error "Could not obtain source admin token. Pass --src-token TOKEN."
    _st="$(curl -sf --max-time 10 ${_ssl_flag:+"$_ssl_flag"} \
        -H "Authorization: token $SRC_TOKEN" -o /dev/null -w "%{http_code}" \
        "$SRC_URL/api/v1/user" 2>/dev/null || true)"
    if [[ "$_st" != "200" ]]; then
        if [[ "$_st" == "403" ]]; then
            warn "Source token validation: HTTP 403 (token accepted but insufficient scope)."
            warn "  Admin user: $_admin_user   Host: $_src_ip"
            warn "  Generate a token manually, then re-run with --src-token TOKEN:"
            warn "    ssh deploy@$_src_ip docker exec -u git forgejo /usr/local/bin/forgejo admin user generate-access-token --username $_admin_user --token-name manual-src --scopes '$_FORGEJO_ADMIN_SCOPES' --raw"
        elif [[ "$_st" == "401" ]]; then
            warn "Source token validation: HTTP 401 (token not recognised — may be malformed)."
            warn "  Admin user: $_admin_user   Host: $_src_ip"
            warn "  Check that the admin user exists: ssh deploy@$_src_ip docker exec -u git forgejo forgejo admin user list"
        else
            warn "Source token validation: HTTP ${_st:-no response}."
            warn "  Admin user: $_admin_user   Host: $_src_ip"
        fi
        error "Source token validation failed (HTTP ${_st:-no response})."
    fi
    info "Source admin token obtained."
fi

# ── Enumerate source repositories ─────────────────────────────────────────────
info "Enumerating repos updated in the last ${DAYS} day(s)..."

_repos_tmp="$(mktemp)"
trap 'rm -f "$_repos_tmp"' EXIT

python3 - "$SRC_URL" "$SRC_TOKEN" "$INCLUDE_ARCHIVED" "$INCLUDE_WIKIS" "$DAYS" "$_ssl_flag" \
    > "$_repos_tmp" \
<<'PY'
import json, sys, urllib.request, ssl
from datetime import datetime, timezone, timedelta

url_base         = sys.argv[1]
token            = sys.argv[2]
include_archived = sys.argv[3].lower() == "true"
include_wikis    = sys.argv[4].lower() == "true"
days             = int(sys.argv[5])
insecure         = len(sys.argv) > 6 and sys.argv[6] == "--insecure"

ctx = ssl.create_default_context()
if insecure:
    ctx.check_hostname = False
    ctx.verify_mode    = ssl.CERT_NONE

cutoff = datetime.now(timezone.utc) - timedelta(days=days)

def api_get(path):
    req = urllib.request.Request(
        f"{url_base}{path}",
        headers={"Authorization": f"token {token}", "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, context=ctx, timeout=30) as r:
        return json.load(r)

def paginate(path, list_key=None):
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

def within_window(repo):
    raw = repo.get("updated_at", "")
    if not raw:
        return True
    try:
        ts = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        return ts >= cutoff
    except Exception:
        return True

def repo_record(repo, owner_type, owner_visibility):
    full_name = repo["full_name"]
    clone_url = repo.get("clone_url", f"{url_base}/{full_name}.git")
    return {
        "full_name":        full_name,
        "clone_url":        clone_url,
        "private":          repo.get("private", False),
        "archived":         repo.get("archived", False),
        "description":      repo.get("description", "") or "",
        "default_branch":   repo.get("default_branch", "main"),
        "has_wiki":         repo.get("has_wiki", False),
        "owner":            repo["owner"]["login"],
        "name":             repo["name"],
        "is_wiki":          False,
        "owner_type":       owner_type,
        "owner_visibility": owner_visibility,
    }

all_repos  = {}
owner_info = {}

try:
    for user in paginate("/api/v1/admin/users"):
        uname = user["login"]
        owner_info[uname] = {"type": "user", "visibility": "public"}
        try:
            for repo in paginate(f"/api/v1/users/{uname}/repos"):
                if not include_archived and repo.get("archived", False):
                    continue
                if not within_window(repo):
                    continue
                rec = repo_record(repo, "user", "public")
                all_repos[rec["full_name"]] = rec
                if include_wikis and repo.get("has_wiki", False):
                    wiki = {**rec,
                        "full_name": f"{rec['full_name']}.wiki",
                        "clone_url": rec["clone_url"].removesuffix(".git") + ".wiki.git",
                        "is_wiki":   True, "has_wiki": False,
                        "description": f"Wiki for {rec['full_name']}"}
                    all_repos[wiki["full_name"]] = wiki
        except Exception as e:
            print(f"Warning: repos for user {uname}: {e}", file=sys.stderr)
except Exception as e:
    print(f"Warning: admin/users failed: {e}", file=sys.stderr)

try:
    for org in paginate("/api/v1/admin/orgs"):
        oname = org.get("username") or org.get("name", "")
        if not oname:
            continue
        vis = org.get("visibility", "public")
        owner_info[oname] = {"type": "org", "visibility": vis}
        try:
            for repo in paginate(f"/api/v1/orgs/{oname}/repos"):
                if not include_archived and repo.get("archived", False):
                    continue
                if not within_window(repo):
                    continue
                rec = repo_record(repo, "org", vis)
                all_repos[rec["full_name"]] = rec
                if include_wikis and repo.get("has_wiki", False):
                    wiki = {**rec,
                        "full_name": f"{rec['full_name']}.wiki",
                        "clone_url": rec["clone_url"].removesuffix(".git") + ".wiki.git",
                        "is_wiki":   True, "has_wiki": False,
                        "description": f"Wiki for {rec['full_name']}"}
                    all_repos[wiki["full_name"]] = wiki
        except Exception as e:
            print(f"Warning: repos for org {oname}: {e}", file=sys.stderr)
except Exception as e:
    print(f"Warning: admin/orgs failed: {e}", file=sys.stderr)

print(json.dumps({"repos": list(all_repos.values()), "owners": owner_info}))
PY

REPO_COUNT="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(len(d['repos']))" "$_repos_tmp")"
info "Found ${REPO_COUNT} repositories updated in the last ${DAYS} day(s)."

if [[ "$REPO_COUNT" -eq 0 ]]; then
    info "Nothing to mirror."
    exit 0
fi

# ── Provision destination (if no --dest-url given) ────────────────────────────
if [[ -z "$DEST_URL" ]]; then
    [[ -n "$DEST_PROVIDER" ]] \
        || error "No --dest-url and no --dest-provider given. Pass one."
    [[ -n "$DEST_REGION" ]] || error "--dest-region is required when provisioning"
    [[ -n "$DEST_PLAN" ]]   || error "--dest-plan is required when provisioning"
    info "Provisioning destination (provider=${DEST_PROVIDER} region=${DEST_REGION} plan=${DEST_PLAN} workspace=${DEST_WORKSPACE})..."
    "$SCRIPT_DIR/provision.sh" \
        --non-interactive \
        --provider  "$DEST_PROVIDER" \
        --region    "$DEST_REGION" \
        --plan      "$DEST_PLAN" \
        --workspace "$DEST_WORKSPACE"
    _dest_ip="$(cd "$SCRIPT_DIR/terraform/$DEST_PROVIDER" && \
        terraform workspace select "$DEST_WORKSPACE" >/dev/null 2>&1 && \
        terraform output -raw public_ipv4 2>/dev/null || true)"
    _dest_ipv6="$(cd "$SCRIPT_DIR/terraform/$DEST_PROVIDER" && \
        terraform output -raw public_ipv6 2>/dev/null || true)"
    if [[ -n "$_dest_ip" ]]; then
        DEST_URL="https://${_dest_ip}"
    elif [[ -n "$_dest_ipv6" ]]; then
        DEST_URL="https://[${_dest_ipv6}]"
    else
        error "Could not read destination IP from Terraform after provisioning."
    fi
    info "Destination provisioned: $DEST_URL"
fi
DEST_URL="${DEST_URL%/}"

# ── Safety guard: source ≠ destination ───────────────────────────────────────
_src_host="${SRC_URL#https://}"; _src_host="${_src_host#http://}"; _src_host="${_src_host%%/*}"
_dst_host="${DEST_URL#https://}"; _dst_host="${_dst_host#http://}"; _dst_host="${_dst_host%%/*}"
[[ "$_src_host" != "$_dst_host" ]] \
    || error "Source and destination resolve to the same host ($_src_host). Aborting."

# ── SSH known_hosts for destination ───────────────────────────────────────────
_dest_kh="$(mktemp)"
trap 'rm -f "$_repos_tmp" "$_dest_kh"' EXIT

# ssh-keyscan doesn't accept bracket notation; strip them for bare IPv6 addresses.
_bare_host() { local h="$1"; h="${h#[}"; h="${h%]}"; echo "$h"; }

info "Scanning destination SSH host key ($_dst_host)..."
_kh_tries=0
until ssh-keyscan -T 5 "$(_bare_host "$_dst_host")" >> "$_dest_kh" 2>/dev/null && [[ -s "$_dest_kh" ]]; do
    _kh_tries=$((_kh_tries + 1))
    [[ "$_kh_tries" -lt 12 ]] || error "Timed out waiting for SSH on destination $_dst_host"
    info "  waiting for SSH on destination... (${_kh_tries}/12)"
    sleep 10
done
_dst_ssh_opts="-i $SSH_KEY -o UserKnownHostsFile=$_dest_kh -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o BatchMode=yes"

# ── Resolve destination admin token ───────────────────────────────────────────
if [[ -z "$DEST_TOKEN" ]]; then
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
    info "Generating destination admin token via SSH as deploy@${_dst_host}..."
    # shellcheck disable=SC2086
    DEST_TOKEN="$(ssh $_dst_ssh_opts "deploy@$_dst_host" \
        "docker exec -u git forgejo /usr/local/bin/forgejo admin user \
         generate-access-token --username $_admin_user \
         --token-name mirror-dst-$(date +%s) --scopes $_FORGEJO_ADMIN_SCOPES --raw" \
        2>/dev/null || true)"
    # Take only the last line in case Forgejo emits log lines before the token.
    DEST_TOKEN="$(printf '%s\n' "$DEST_TOKEN" | tail -1 | tr -d '[:space:]')"
    [[ -n "$DEST_TOKEN" ]] \
        || error "Could not obtain destination admin token. Pass --dest-token TOKEN."
    _dt="$(curl -sf --max-time 10 ${_ssl_flag:+"$_ssl_flag"} \
        -H "Authorization: token $DEST_TOKEN" -o /dev/null -w "%{http_code}" \
        "$DEST_URL/api/v1/user" 2>/dev/null || true)"
    if [[ "$_dt" != "200" ]]; then
        if [[ "$_dt" == "403" ]]; then
            warn "Destination token validation: HTTP 403 (token accepted but insufficient scope)."
            warn "  Admin user: $_admin_user   Host: $_dst_host"
            warn "  Generate a token manually, then re-run with --dest-token TOKEN:"
            warn "    ssh deploy@$_dst_host docker exec -u git forgejo /usr/local/bin/forgejo admin user generate-access-token --username $_admin_user --token-name manual-dst --scopes '$_FORGEJO_ADMIN_SCOPES' --raw"
        elif [[ "$_dt" == "401" ]]; then
            warn "Destination token validation: HTTP 401 (token not recognised — may be malformed)."
            warn "  Admin user: $_admin_user   Host: $_dst_host"
            warn "  Check that the admin user exists: ssh deploy@$_dst_host docker exec -u git forgejo forgejo admin user list"
        else
            warn "Destination token validation: HTTP ${_dt:-no response}."
            warn "  Admin user: $_admin_user   Host: $_dst_host"
        fi
        error "Destination token validation failed (HTTP ${_dt:-no response})."
    fi
    info "Destination admin token obtained."
fi

# ── Mirror repositories ───────────────────────────────────────────────────────
header "Mirroring ${REPO_COUNT} repos: ${SRC_URL} → ${DEST_URL}"

python3 - "$SRC_URL" "$SRC_TOKEN" "$DEST_URL" "$DEST_TOKEN" "$_repos_tmp" \
    "$INSECURE" "$QUIET" \
<<'PY'
import json, os, shutil, subprocess, sys, tempfile, urllib.request, urllib.error, ssl

src_url    = sys.argv[1]
src_token  = sys.argv[2]
dest_url   = sys.argv[3]
dest_token = sys.argv[4]
repos_file = sys.argv[5]
insecure   = sys.argv[6].lower() == "true"
quiet      = sys.argv[7].lower() == "true"

GREEN  = "\033[0;32m"; YELLOW = "\033[1;33m"; RED = "\033[0;31m"; NC = "\033[0m"
def info(msg):
    if not quiet:
        print(f"{GREEN}[mirror]{NC} {msg}", flush=True)
def warn(msg):
    print(f"{YELLOW}[mirror]{NC} {msg}", file=sys.stderr, flush=True)

ctx = ssl.create_default_context()
if insecure:
    ctx.check_hostname = False
    ctx.verify_mode    = ssl.CERT_NONE

def api(method, path, payload=None):
    url = f"{dest_url}{path}"
    data = json.dumps(payload).encode() if payload else None
    req  = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"token {dest_token}",
        "Content-Type":  "application/json",
        "Accept":        "application/json",
    })
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=20) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, {}

d = json.load(open(repos_file))
repos       = d["repos"]
owner_types = {o: v for o, v in ((k, v["type"])       for k, v in d["owners"].items())}
owner_vis   = {o: v for o, v in ((k, v["visibility"])  for k, v in d["owners"].items())}

seen_owners = set()
work_dir = tempfile.mkdtemp(prefix="forgejo-mirror-")
try:
    ok = fail = 0
    for repo in repos:
        full_name  = repo["full_name"]
        clone_url  = repo["clone_url"]
        owner      = repo["owner"]
        name       = repo["name"]
        is_wiki    = repo["is_wiki"]
        priv       = repo.get("private", False)
        desc       = repo.get("description", "") or ""
        def_branch = repo.get("default_branch", "main")
        otype      = repo.get("owner_type", owner_types.get(owner, "user"))
        ovis       = repo.get("owner_visibility", owner_vis.get(owner, "public"))

        info(f"  → {full_name}")

        # Ensure owner exists on destination
        if owner not in seen_owners:
            code, _ = api("GET", f"/api/v1/users/{owner}")
            if code == 404:
                if otype == "org":
                    code, _ = api("POST", "/api/v1/orgs",
                                  {"username": owner, "visibility": ovis})
                    if code == 201:
                        info(f"    created org: {owner} (visibility: {ovis})")
                    else:
                        warn(f"    failed to create org '{owner}' (HTTP {code}); skipping {full_name}")
                        fail += 1; continue
                else:
                    import secrets, string
                    pw = "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(20))
                    code, _ = api("POST", "/api/v1/admin/users", {
                        "login_name": owner, "username": owner,
                        "email": f"{owner}@mirror.local",
                        "password": pw, "must_change_password": False, "source_id": 0,
                    })
                    if code == 201:
                        info(f"    created user: {owner}")
                    else:
                        warn(f"    failed to create user '{owner}' (HTTP {code}); skipping {full_name}")
                        fail += 1; continue
            elif code != 200:
                warn(f"    owner lookup returned HTTP {code}; skipping {full_name}")
                fail += 1; continue
            seen_owners.add(owner)

        # Ensure repo exists (wikis are created implicitly by git push --mirror)
        if not is_wiki:
            code, _ = api("GET", f"/api/v1/repos/{owner}/{name}")
            if code == 404:
                payload = {"name": name, "description": desc,
                           "private": priv, "default_branch": def_branch, "auto_init": False}
                create_path = f"/api/v1/orgs/{owner}/repos" if otype == "org" \
                              else f"/api/v1/admin/users/{owner}/repos"
                code, _ = api("POST", create_path, payload)
                if code != 201:
                    warn(f"    failed to create repo '{full_name}' on destination (HTTP {code}); skipping")
                    fail += 1; continue
            elif code != 200:
                warn(f"    dest repo lookup returned HTTP {code}; skipping {full_name}")
                fail += 1; continue

        # Clone --mirror from source, push --mirror to destination
        clone_dir  = os.path.join(work_dir, full_name.replace("/", "__") + ".git")
        dest_clone = f"{dest_url}/{full_name}.git"

        git_src  = ["git", "-c", f"http.extraHeader=Authorization: token {src_token}"]
        git_dest = ["git", "-c", f"http.extraHeader=Authorization: token {dest_token}"]
        if insecure:
            git_src  += ["-c", "http.sslVerify=false"]
            git_dest += ["-c", "http.sslVerify=false"]

        r = subprocess.run(git_src + ["clone", "--mirror", "--quiet", clone_url, clone_dir],
                           capture_output=True)
        if r.returncode != 0:
            warn(f"    clone failed: {clone_url}")
            shutil.rmtree(clone_dir, ignore_errors=True)
            fail += 1; continue

        r = subprocess.run(git_dest + ["-C", clone_dir, "push", "--mirror", "--quiet", dest_clone],
                           capture_output=True)
        shutil.rmtree(clone_dir, ignore_errors=True)
        if r.returncode != 0:
            warn(f"    push failed: {dest_clone}")
            fail += 1; continue

        info(f"    ✓ mirrored")
        ok += 1
finally:
    shutil.rmtree(work_dir, ignore_errors=True)

print(f"\033[0;36m[mirror]\033[0m Done: {ok} mirrored, {fail} failed.")
PY
