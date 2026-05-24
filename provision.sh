#!/usr/bin/env bash
# provision.sh — Provision the VPS and deploy Forgejo.
#
# Reads all secrets from local Vault (started by setup.sh).
# Runs: terraform apply → wait for SSH → render templates → scp files → deploy.sh
#
# Safe to re-run: Terraform reconciles drift; deploy.sh is idempotent.
# Requires: setup.sh to have been run at least once this Vault session.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
CACHE_DIR="${SCRIPT_DIR}/.cache"
CACHE_TTL=86400  # seconds — refresh provider data at most once per day

_START_TS=$SECONDS

info()    { echo -e "${GREEN}[provision]${NC} $*"; }
warn()    { echo -e "${YELLOW}[provision]${NC} $*"; }
error()   { echo -e "${RED}[provision]${NC} $*" >&2; exit 1; }
_elapsed() { local s=$(( SECONDS - _START_TS )); (( s >= 60 )) && printf '%dm %ds' $(( s/60 )) $(( s%60 )) || printf '%ds' "$s"; }

# ── Region / plan helpers ─────────────────────────────────────────────────────

# Read a field from a terraform.tfvars file (returns empty string if file/field absent)
tfvars_get() {
    local file="$1" var="$2"
    [[ -f "$file" ]] || return 0
    grep -E "^\s*${var}\s*=" "$file" 2>/dev/null \
        | head -1 | sed 's/.*=\s*"\(.*\)".*/\1/' | tr -d '[:space:]' || true
}

# Read an HCL list field from tfvars and return comma-separated values.
# Handles:  allowed_cidrs = ["a/b", "c/d"]
tfvars_get_list() {
    local file="$1" var="$2"
    [[ -f "$file" ]] || return 0
    python3 - "$file" "$var" <<'PY'
import re, sys
content = open(sys.argv[1]).read()
m = re.search(r'^\s*' + re.escape(sys.argv[2]) + r'\s*=\s*\[([^\]]*)\]', content, re.MULTILINE)
if m:
    items = re.findall(r'"([^"]+)"', m.group(1))
    print(','.join(items))
PY
}

# Auto-detect admin network CIDRs from icanhazip.com.
# IPv4: single-host /32.  IPv6: /64 subnet (whole /64 the admin is on).
# Fails with a clear error if detection fails and --admin-cidrs was not given.
detect_admin_cidrs() {
    local _v4 _v6 _v6_net _cidrs=""

    _v4="$(curl -s --max-time 5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]')" || true
    _v6="$(curl -s --max-time 5 https://ipv6.icanhazip.com 2>/dev/null | tr -d '[:space:]')" || true

    if [[ -n "$_v4" ]] && [[ "$_v4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        _cidrs="${_v4}/32"
    fi

    if [[ -n "$_v6" ]] && [[ "$_v6" == *:* ]]; then
        _v6_net="$(python3 -c "
import ipaddress, sys
try:
    net = ipaddress.ip_network('${_v6}/64', strict=False)
    print(str(net))
except Exception as e:
    sys.exit(1)
" 2>/dev/null)" || true
        if [[ -n "$_v6_net" ]]; then
            [[ -n "$_cidrs" ]] && _cidrs="${_cidrs},"
            _cidrs="${_cidrs}${_v6_net}"
        fi
    fi

    if [[ -z "$_cidrs" ]]; then
        error "Could not auto-detect admin network address. Pass --admin-cidrs <cidr,...> explicitly."
    fi

    # Fail hard if ip_stack=ipv6 but no IPv6 CIDR was detected — admin would be locked out.
    if [[ "$IP_STACK" == "ipv6" ]] && [[ "$_cidrs" != *:* ]]; then
        error "ip_stack=ipv6 but no IPv6 admin address detected — admin would be locked out. Pass --admin-cidrs with an IPv6 CIDR."
    fi

    # In dual mode with only IPv4 detected: IPv6 admin ports (22, 2222) will be
    # blocked for all IPv6 sources (no allow rule = provider default-deny).
    if [[ "$IP_STACK" == "dual" ]] && [[ "$_cidrs" != *:* ]]; then
        warn "No IPv6 admin CIDR detected — admin ports (22, 2222) will be blocked for all IPv6 in dual mode. Pass --admin-cidrs with an IPv6 CIDR to allow IPv6 admin access."
    fi

    printf '%s' "$_cidrs"
}

# Interactive numbered menu. Items are "code:description" strings.
# Writes the selected code into global _MENU_RESULT (avoids subshell capture).
_MENU_RESULT=""
show_menu() {
    local header="$1" default="$2"; shift 2
    local -a items=("$@")
    local n="${#items[@]}" i code desc mark _sel _item
    echo
    info "$header"
    for ((i=0; i<n; i++)); do
        code="${items[$i]%%:*}"
        desc="${items[$i]#*:}"
        mark=""
        [[ "$code" == "$default" ]] && mark=" [default]"
        printf "    %2d) %-24s %s%s\n" "$((i+1))" "$code" "$desc" "$mark"
    done
    echo
    _MENU_RESULT=""
    while [[ -z "$_MENU_RESULT" ]]; do
        read -rp "    Select [${default}]: " _sel
        _sel="${_sel:-$default}"
        if [[ "$_sel" =~ ^[0-9]+$ ]] && (( _sel >= 1 && _sel <= n )); then
            _MENU_RESULT="${items[$((_sel-1))]%%:*}"
        else
            for _item in "${items[@]}"; do
                [[ "${_item%%:*}" == "$_sel" ]] && { _MENU_RESULT="$_sel"; break; }
            done
        fi
        [[ -n "$_MENU_RESULT" ]] \
            || warn "Invalid selection '${_sel}'. Enter a number (1-${n}) or a valid code."
    done
}

# ── Cache helpers ─────────────────────────────────────────────────────────────

# Return the 'ts' field from a JSON cache file, or 0 if missing/unparseable.
cache_ts() {
    python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('ts',0))" "$1" 2>/dev/null || echo 0
}

# Return true if cache file exists AND is younger than CACHE_TTL seconds.
cache_fresh() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    local ts now
    ts=$(cache_ts "$file"); now=$(date +%s)
    (( now - ts < CACHE_TTL ))
}

# Populate caller's array (nameref $1) with "code:desc" lines from cache file $2.
load_cache_items() {
    local -n _lci_arr="$1"; local file="$2"
    mapfile -t _lci_arr < <(python3 - "$file" <<'PY'
import json, sys
for it in json.load(open(sys.argv[1])).get('items', []):
    print(it['code'] + ':' + it['desc'])
PY
    )
}

# Return a human-readable string describing how fresh the cache file is.
cache_age_str() {
    [[ -f "$1" ]] || { echo "static"; return; }
    local ts now age
    ts=$(cache_ts "$1"); now=$(date +%s); age=$(( now - ts ))
    if   (( age < 3600  )); then printf "live, cached %dm ago" $(( age / 60 ))
    elif (( age < 86400 )); then printf "live, cached %dh ago" $(( age / 3600 ))
    else                         printf "live, stale (%dd old; use --refresh)" $(( age / 86400 ))
    fi
}

# ── Provider data fetch functions ─────────────────────────────────────────────
# Each writes .cache/<provider>-<type>.json with {"ts": epoch, "items": [...]}

fetch_vultr_regions() {
    local file="$CACHE_DIR/vultr-regions.json"
    mkdir -p "$CACHE_DIR"
    if python3 - "$file" <<'PY'
import json, sys, time, urllib.request
try:
    with urllib.request.urlopen("https://api.vultr.com/v2/regions", timeout=10) as r:
        data = json.load(r)
    items = []
    for reg in sorted(data.get('regions', []), key=lambda x: x.get('id', '')):
        items.append({
            'code': reg['id'],
            'desc': f"{reg.get('city', '')} - {reg.get('country', '')} ({reg.get('continent', '')})"
        })
    json.dump({'ts': int(time.time()), 'items': items}, open(sys.argv[1], 'w'))
    sys.exit(0)
except Exception as e:
    print(f"[provision] warning: failed to fetch Vultr regions: {e}", file=sys.stderr)
    sys.exit(1)
PY
    then
        info "Fetched Vultr regions from API."
    else
        return 1
    fi
}

fetch_vultr_plans() {
    local file="$CACHE_DIR/vultr-plans.json"
    mkdir -p "$CACHE_DIR"
    if python3 - "$file" <<'PY'
import json, sys, time, urllib.request
try:
    with urllib.request.urlopen("https://api.vultr.com/v2/plans?type=vc2&per_page=500", timeout=10) as r:
        data = json.load(r)
    plans = []
    for p in data.get('plans', []):
        vcpu = p.get('vcpu_count', '?')
        ram  = p.get('ram', 0)
        disk = p.get('disk', 0)
        cost = p.get('monthly_cost', 0)
        pid  = p.get('id', '')
        ram_str = f"{ram}MB" if ram < 1024 else f"{ram // 1024}GB"
        desc = f"{vcpu}C/{ram_str}/{disk}GB NVMe  ${cost:.2f}/mo"
        if ram < 1024:
            desc += "  (not recommended: too small for Forgejo+Postgres)"
        elif ram == 1024 and vcpu == 1:
            desc += "  (recommended minimum)"
        plans.append({'code': pid, 'desc': desc})
    plans.sort(key=lambda x: x['code'])
    json.dump({'ts': int(time.time()), 'items': plans}, open(sys.argv[1], 'w'))
    sys.exit(0)
except Exception as e:
    print(f"[provision] warning: failed to fetch Vultr plans: {e}", file=sys.stderr)
    sys.exit(1)
PY
    then
        info "Fetched Vultr plans from API."
    else
        return 1
    fi
}

fetch_aws_regions() {
    local file="$CACHE_DIR/aws-regions.json"
    mkdir -p "$CACHE_DIR"
    if python3 - "$file" <<'PY'
import json, sys, time, subprocess
LABELS = {
    'us-east-1':      'N. Virginia - US East',
    'us-east-2':      'Ohio - US East',
    'us-west-1':      'N. California - US West',
    'us-west-2':      'Oregon - US West',
    'ca-central-1':   'Canada Central - Montreal',
    'eu-west-1':      'Ireland - EU',
    'eu-west-2':      'London - EU',
    'eu-west-3':      'Paris - EU',
    'eu-central-1':   'Frankfurt - EU',
    'eu-north-1':     'Stockholm - EU',
    'ap-southeast-1': 'Singapore - AP',
    'ap-southeast-2': 'Sydney - AP',
    'ap-northeast-1': 'Tokyo - AP',
    'ap-northeast-2': 'Seoul - AP',
    'ap-south-1':     'Mumbai - AP',
    'sa-east-1':      'Sao Paulo - SA',
    'af-south-1':     'Cape Town - Africa',
    'me-south-1':     'Bahrain - Middle East',
}
try:
    import shutil
    if shutil.which('aws') is None:
        raise RuntimeError("aws CLI not installed — run: sudo apt install awscli")
    out = subprocess.run(
        ['aws', 'ec2', 'describe-regions', '--output', 'json'],
        capture_output=True, text=True, timeout=15
    )
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip())
    data = json.loads(out.stdout)
    items = []
    for r in sorted(data.get('Regions', []), key=lambda x: x.get('RegionName', '')):
        name = r['RegionName']
        items.append({'code': name, 'desc': LABELS.get(name, name)})
    json.dump({'ts': int(time.time()), 'items': items}, open(sys.argv[1], 'w'))
    sys.exit(0)
except Exception as e:
    print(f"[provision] warning: failed to fetch AWS regions: {e}", file=sys.stderr)
    sys.exit(1)
PY
    then
        info "Fetched AWS regions via CLI."
    else
        return 1
    fi
}

# Fetch AWS EC2 instance availability for a specific region (uses AWS CLI credentials).
# Pricing is approximate/static — the AWS pricing API requires complex auth; availability is the key value here.
fetch_aws_plans() {
    local region="$1"
    local file="$CACHE_DIR/aws-plans-${region}.json"
    mkdir -p "$CACHE_DIR"
    if python3 - "$file" "$region" <<'PY'
import json, sys, time, subprocess
TARGET = ['t4g.micro', 't3a.micro', 't3.micro', 't3.small', 't3.medium']
STATIC = {
    't4g.micro':  ('2C ARM/1GB',   '~$6/mo',   '(cheapest; Graviton ARM architecture)'),
    't3a.micro':  ('2C AMD/1GB',   '~$7/mo',   ''),
    't3.micro':   ('2C Intel/1GB', '~$8/mo',   '(free-tier eligible)'),
    't3.small':   ('2C Intel/2GB', '~$15/mo',  ''),
    't3.medium':  ('2C Intel/4GB', '~$30/mo',  ''),
}
file, region = sys.argv[1], sys.argv[2]
try:
    import shutil
    if shutil.which('aws') is None:
        raise RuntimeError("aws CLI not installed — run: sudo apt install awscli")
    out = subprocess.run(
        ['aws', 'ec2', 'describe-instance-type-offerings',
         '--location-type', 'region',
         '--filters', f'Name=instance-type,Values={",".join(TARGET)}',
         '--region', region, '--output', 'json'],
        capture_output=True, text=True, timeout=30
    )
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip())
    available = {o['InstanceType'] for o in json.loads(out.stdout).get('InstanceTypeOfferings', [])}
    items = []
    for t in TARGET:
        if t not in available:
            continue
        spec, cost, note = STATIC[t]
        desc = f"{spec}  {cost}"
        if note:
            desc += f"  {note}"
        items.append({'code': t, 'desc': desc})
    json.dump({'ts': int(time.time()), 'items': items, 'region': region}, open(file, 'w'))
    sys.exit(0)
except Exception as e:
    print(f"[provision] warning: failed to fetch AWS plans for {region}: {e}", file=sys.stderr)
    sys.exit(1)
PY
    then
        info "Fetched AWS instance availability for ${region}."
    else
        return 1
    fi
}

# Fetch Azure B-series VM availability and region-specific pricing (uses ARM service principal).
fetch_azure_plans() {
    local region="$1"
    local file="$CACHE_DIR/azure-plans-${region}.json"
    mkdir -p "$CACHE_DIR"
    info "Fetching Azure VM sizes for ${region} via az vm list-skus (may take 1-2 minutes)..."
    if python3 - "$file" "$region" <<'PY'
import json, sys, time, subprocess, urllib.request, urllib.parse
file, region = sys.argv[1], sys.argv[2]
try:
    out = subprocess.run(
        ['az', 'vm', 'list-skus', '--location', region,
         '--resource-type', 'virtualMachines', '--output', 'json'],
        capture_output=True, text=True, timeout=300
    )
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or 'az vm list-skus failed')

    # Collect available B-series VMs with specs from capabilities field
    available = {}  # name -> {vcpu, mem_gb}
    for sku in json.loads(out.stdout):
        name = sku.get('name', '')
        if 'Standard_B' not in name:
            continue
        if any(r.get('type') == 'Location' for r in sku.get('restrictions', [])):
            continue
        caps = {c['name']: c['value'] for c in sku.get('capabilities', [])}
        try:
            vcpu   = int(caps.get('vCPUs', 0))
            mem_gb = float(caps.get('MemoryGB', 0))
        except (ValueError, TypeError):
            continue
        if vcpu > 0 and mem_gb > 0:
            available[name] = {'vcpu': vcpu, 'mem_gb': mem_gb}

    # Fetch region-specific pricing (public API, no auth); chunk to stay under URL limits
    prices = {}
    names  = list(available)
    for i in range(0, len(names), 10):
        parts = [f"armSkuName eq '{n}'" for n in names[i:i+10]]
        filt  = "(" + " or ".join(parts) + f") and armRegionName eq '{region}' and priceType eq 'Consumption'"
        url   = "https://prices.azure.com/api/retail/prices?$filter=" + urllib.parse.quote(filt)
        with urllib.request.urlopen(url, timeout=30) as r:
            pdata = json.load(r)
        for item in pdata.get('Items', []):
            sku  = item.get('armSkuName', '')
            sname = item.get('skuName', '')
            if sku in available and 'Spot' not in sname and 'Low Priority' not in sname:
                cost = item.get('retailPrice', 0)
                if sku not in prices or cost < prices[sku]:
                    prices[sku] = cost

    # Sort by memory then vCPU; annotate smallest usable size as recommended minimum
    sorted_skus = sorted(available.items(), key=lambda x: (x[1]['mem_gb'], x[1]['vcpu']))
    items = []
    recommended_shown = False
    for name, specs in sorted_skus:
        vcpu, mem_gb = specs['vcpu'], specs['mem_gb']
        mem_str = f"{int(mem_gb)}GB" if mem_gb == int(mem_gb) else f"{mem_gb}GB"
        cost    = prices.get(name, 0)
        desc    = f"{vcpu}C/{mem_str}"
        if cost > 0:
            desc += f"  ~${cost * 730:.0f}/mo"
        if mem_gb < 2:
            desc += "  (not recommended: OOM risk with Forgejo+Postgres)"
        elif not recommended_shown:
            desc += "  (recommended minimum)"
            recommended_shown = True
        items.append({'code': name, 'desc': desc})

    json.dump({'ts': int(time.time()), 'items': items, 'region': region}, open(file, 'w'))
    sys.exit(0)
except Exception as e:
    print(f"[provision] warning: failed to fetch Azure plans for {region}: {e}", file=sys.stderr)
    sys.exit(1)
PY
    then
        info "Fetched Azure VM availability for ${region}."
    else
        return 1
    fi
}

# ── CLI arguments ─────────────────────────────────────────────────────────────
CERTBOT_STAGING=""
PROVIDER=""
FORCE_REFRESH=false
DESTROY=false
WORKSPACE="default"
NON_INTERACTIVE=false
REGION_ARG=""
PLAN_ARG=""
DESTROY_IP=""
DESTROY_ALL=false
LOG_FILE="${SCRIPT_DIR}/.provision-log.json"
IP_STACK="ipv4"
_IP_STACK_EXPLICIT=false
ADMIN_CIDRS=""
_ADMIN_CIDRS_EXPLICIT=false
USER_CIDRS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)
            DEBUG=1
            shift ;;
        --debug-certbot)
            CERTBOT_STAGING=1
            warn "Certbot staging mode: certificate will be issued by the staging CA (not browser-trusted)."
            shift ;;
        --provider)
            [[ $# -ge 2 ]] || error "--provider requires a value (vultr|aws|azure|linode|google)"
            PROVIDER="$2"
            shift 2 ;;
        --refresh)
            FORCE_REFRESH=true
            shift ;;
        --destroy)
            DESTROY=true
            shift ;;
        --destroy-ip)
            [[ $# -ge 2 ]] || error "--destroy-ip requires an IP address"
            DESTROY_IP="$2"; DESTROY=true; shift 2 ;;
        --destroy-all)
            DESTROY_ALL=true; DESTROY=true; shift ;;
        --workspace)
            [[ $# -ge 2 ]] || error "--workspace requires a value"
            WORKSPACE="$2"; shift 2 ;;
        --non-interactive)
            NON_INTERACTIVE=true; shift ;;
        --region)
            [[ $# -ge 2 ]] || error "--region requires a value"
            REGION_ARG="$2"; shift 2 ;;
        --plan)
            [[ $# -ge 2 ]] || error "--plan requires a value"
            PLAN_ARG="$2"; shift 2 ;;
        --ip-stack)
            [[ $# -ge 2 ]] || error "--ip-stack requires ipv4|ipv6|dual"
            IP_STACK="$2"
            [[ "$IP_STACK" =~ ^(ipv4|ipv6|dual)$ ]] || error "--ip-stack must be 'ipv4', 'ipv6', or 'dual'"
            _IP_STACK_EXPLICIT=true
            shift 2 ;;
        --admin-cidrs)
            [[ $# -ge 2 ]] || error "--admin-cidrs requires a value (comma-separated CIDRs)"
            ADMIN_CIDRS="$2"
            _ADMIN_CIDRS_EXPLICIT=true
            shift 2 ;;
        --user-cidrs)
            [[ $# -ge 2 ]] || error "--user-cidrs requires a value (comma-separated CIDRs)"
            USER_CIDRS="$2"
            shift 2 ;;
        *)
            error "Unknown argument: $1. Usage: $0 [--provider vultr|aws|azure|linode|google] [--refresh] [--destroy] [--destroy-ip <ip>] [--destroy-all] [--workspace <name>] [--non-interactive] [--region <r>] [--plan <p>] [--ip-stack ipv4|ipv6|dual] [--admin-cidrs <cidr,...>] [--user-cidrs <cidr,...>] [--debug] [--debug-certbot]" ;;
    esac
done

# Activate debug mode after argument parsing so set -x only traces main logic.
[[ "${DEBUG}" == 1 ]] && { export DEBUG; set -x; }

if [[ -n "$PROVIDER" && "$PROVIDER" != "vultr" && "$PROVIDER" != "aws" && "$PROVIDER" != "azure" && "$PROVIDER" != "linode" && "$PROVIDER" != "google" ]]; then
    error "Invalid provider '$PROVIDER'. Use vultr, aws, azure, linode, or google."
fi

# If not specified, default to last used provider (or prompt)
if [[ -z "$PROVIDER" ]]; then
    if $NON_INTERACTIVE; then
        error "--non-interactive requires --provider <vultr|aws|azure|linode|google>"
    fi
    DEFAULT_PROVIDER="vultr"
    if [[ -f .last-provider ]]; then
        DEFAULT_PROVIDER="$(cat .last-provider | tr -d '[:space:]')"
    fi

    read -rp "[provision] Cloud provider (vultr/aws/azure/linode/google) [${DEFAULT_PROVIDER}]: " _prov
    PROVIDER="${_prov:-$DEFAULT_PROVIDER}"
    [[ "$PROVIDER" == "vultr" || "$PROVIDER" == "aws" || "$PROVIDER" == "azure" || "$PROVIDER" == "linode" || "$PROVIDER" == "google" ]] \
        || error "Invalid provider '$PROVIDER'. Use vultr, aws, azure, linode, or google."
fi

info "Provider: $PROVIDER"

# ── Prerequisites ─────────────────────────────────────────────────────────────
validate_external_utils vault terraform ssh scp ssh-keyscan envsubst curl python3

[ -f .vault.token ] || error ".vault.token not found. Run ./setup.sh first."
[ -f .vault-keys ]  || error ".vault-keys not found. Run ./setup.sh first."
[ -f ca.pub ]       || error "ca.pub not found. Run ./setup.sh first."

# ── Vault: start and unseal if needed ────────────────────────────────────────
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="$(cat .vault.token)"

if ! vault status &>/dev/null; then
    info "Starting Vault..."
    vault server -config vault.hcl > /tmp/vault.log 2>&1 &
    echo $! > .vault.pid
    sleep 3
fi

if vault status 2>/dev/null | grep -q "Sealed.*true"; then
    info "Unsealing Vault..."
    vault operator unseal "$(cat .vault-keys)"
fi

vault status | grep -q "Initialized.*true" || error "Vault not initialized. Run ./setup.sh first."

# ── Read secrets from Vault ───────────────────────────────────────────────────
info "Reading secrets from Vault..."

vget() { vault kv get -field="$1" "$2"; }

DB_PASSWORD="$(vget db_password secret/forgejo/config)"
DB_USER="$(vget db_user secret/forgejo/config)"
DB_NAME="$(vget db_name secret/forgejo/config)"
FORGEJO_SECRET_KEY="$(vget secret_key secret/forgejo/config 2>/dev/null || true)"
FORGEJO_INTERNAL_TOKEN="$(vget internal_token secret/forgejo/config 2>/dev/null || true)"
# Generate and persist if setup.sh pre-dates these fields
if [ -z "$FORGEJO_SECRET_KEY" ] || [ -z "$FORGEJO_INTERNAL_TOKEN" ]; then
    warn "Forgejo secrets missing from Vault — generating and storing now..."
    FORGEJO_SECRET_KEY="$(openssl rand -hex 32)"
    FORGEJO_INTERNAL_TOKEN="$(openssl rand -base64 32 | tr -d '=/+')"
    vault kv patch secret/forgejo/config \
        secret_key="$FORGEJO_SECRET_KEY" \
        internal_token="$FORGEJO_INTERNAL_TOKEN"
fi

CERTBOT_EMAIL="$(vget certbot_email secret/forgejo/deploy)"
ADMIN_SSH_PUBLIC_KEY="$(vget admin_ssh_public_key secret/forgejo/deploy)"
FORGEJO_ADMIN_USER="$(vget forgejo_admin_user secret/forgejo/deploy)"
FORGEJO_ADMIN_EMAIL="$(vget forgejo_admin_email secret/forgejo/deploy)"

# Per-instance admin password keyed by provider+workspace so multiple active
# instances have independent credentials.  Rotated on any run where the stored
# password is missing or older than 7 days; Vault is always authoritative.
_INST_SECRET="secret/forgejo/instances/${PROVIDER}-${WORKSPACE}"
FORGEJO_ADMIN_PASSWORD="$(vget admin_password "$_INST_SECRET" 2>/dev/null || true)"
_pw_ts="$(vget admin_password_ts "$_INST_SECRET" 2>/dev/null || true)"
_now="$(date +%s)"
if [[ -z "$FORGEJO_ADMIN_PASSWORD" ]] || \
   [[ -z "$_pw_ts" ]] || \
   (( _now - _pw_ts >= 604800 )); then
    info "Rotating Forgejo admin password for ${PROVIDER}/${WORKSPACE}..."
    FORGEJO_ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -d '+/=')"
    vault kv put "$_INST_SECRET" \
        admin_password="$FORGEJO_ADMIN_PASSWORD" \
        admin_password_ts="$_now" \
        provider="$PROVIDER" \
        workspace="$WORKSPACE"
    info "Admin password stored: $_INST_SECRET (field: admin_password)"
fi

# ── Provider credentials ──────────────────────────────────────────────────────
export TF_VAR_admin_ssh_public_key="$ADMIN_SSH_PUBLIC_KEY"

case "$PROVIDER" in
    vultr)
        export TF_VAR_vultr_api_key="$(vget vultr_api_key secret/forgejo/cloud)"
        TF_DIR="$SCRIPT_DIR/terraform/vultr"
        ;;
    aws)
        [ -f aws_access_key ]        || error "aws_access_key file not found in $SCRIPT_DIR"
        [ -f aws_secret_access_key ] || error "aws_secret_access_key file not found in $SCRIPT_DIR"
        export AWS_ACCESS_KEY_ID="$(tr -d '[:space:]' < aws_access_key)"
        export AWS_SECRET_ACCESS_KEY="$(tr -d '[:space:]' < aws_secret_access_key)"
        TF_DIR="$SCRIPT_DIR/terraform/aws"
        ;;
    linode)
        [ -f linode_api_key ] || error "linode_api_key file not found in $SCRIPT_DIR"
        export LINODE_TOKEN="$(tr -d '[:space:]' < linode_api_key)"
        TF_DIR="$SCRIPT_DIR/terraform/linode"
        ;;
    google)
        [ -f google_credentials ] || error "google_credentials file not found in $SCRIPT_DIR"
        # Parse service account JSON to extract project_id and export credentials.
        # Write exports to a temp file and source it — eval "$(python3 ...)" masks Python's
        # exit code (eval "" returns 0 even when python3 exits 1), causing silent failures.
        _google_env="$(mktemp)"
        python3 - "$_google_env" <<'PY' || error "Cannot load google_credentials — see error above."
import json, sys, shlex
try:
    d = json.load(open("google_credentials"))
except Exception as e:
    sys.exit(f"Cannot parse google_credentials: {e}")
project_id = d.get("project_id", "")
if not project_id:
    sys.exit("google_credentials: missing 'project_id'. Ensure this is a valid GCP service account key JSON.")
cred_type = d.get("type", "")
if cred_type not in ("service_account", "authorized_user", "external_account"):
    sys.exit(f"google_credentials: unexpected type '{cred_type}'. Expected service_account JSON from GCP console.")
with open(sys.argv[1], 'w') as f:
    f.write(f"export GOOGLE_PROJECT={shlex.quote(project_id)}\n")
    f.write(f"export GOOGLE_CREDENTIALS={shlex.quote(json.dumps(d))}\n")
PY
        # shellcheck disable=SC1090
        source "$_google_env"
        rm -f "$_google_env"
        TF_DIR="$SCRIPT_DIR/terraform/google"
        ;;
    azure)
        [ -f azure_credentials ] || error "azure_credentials file not found in $SCRIPT_DIR"
        # Parse JSON credentials; support both az-cli field names (appId/password/tenant)
        # and SDK-auth aliases (clientId/clientSecret/tenantId/subscriptionId).
        # Write exports to a temp file and source it — eval "$(python3 ...)" masks Python's
        # exit code (eval "" returns 0 even when python3 exits 1), causing silent failures.
        _azure_env="$(mktemp)"
        python3 - "$_azure_env" <<'PY' || error "Cannot load azure_credentials — see error above."
import json, sys, shlex
try:
    d = json.load(open("azure_credentials"))
except Exception as e:
    sys.exit(f"Cannot parse azure_credentials: {e}")
def require(key, *aliases):
    for k in (key,) + aliases:
        if k in d and d[k]:
            return d[k]
    if key == "subscriptionId":
        import subprocess
        try:
            r = subprocess.run(['az', 'account', 'show', '--query', 'id', '-o', 'tsv'],
                               capture_output=True, text=True, timeout=10)
            if r.returncode == 0 and r.stdout.strip():
                return r.stdout.strip()
        except Exception:
            pass
        checked = ', '.join((key,) + aliases)
        sys.exit(f"azure_credentials: missing '{key}' and 'az account show' failed.\n"
                 f"  Add it manually: {{\"subscriptionId\": \"<id>\", ...}}\n"
                 f"  Find your subscription ID with: az account show --query id -o tsv")
    checked = ', '.join((key,) + aliases)
    sys.exit(f"azure_credentials: missing required field '{key}' (checked: {checked})")
pairs = [
    ("ARM_CLIENT_ID",       require("clientId",       "appId")),
    ("ARM_CLIENT_SECRET",   require("clientSecret",   "password")),
    ("ARM_SUBSCRIPTION_ID", require("subscriptionId", "subscription_id", "subscription")),
    ("ARM_TENANT_ID",       require("tenantId",       "tenant")),
]
with open(sys.argv[1], 'w') as f:
    for k, v in pairs:
        f.write(f"export {k}={shlex.quote(v)}\n")
PY
        # shellcheck disable=SC1090
        source "$_azure_env"
        rm -f "$_azure_env"
        TF_DIR="$SCRIPT_DIR/terraform/azure"
        ;;
esac

# ── Workspace, hostname, and workspace-specific tfvars ────────────────────────
if [[ "$WORKSPACE" == "default" ]]; then
    HOSTNAME="forgejo"
    _ws_tfvars="${TF_DIR}/terraform.tfvars"
else
    HOSTNAME="forgejo-${WORKSPACE}"
    _ws_tfvars="${TF_DIR}/terraform.${WORKSPACE}.tfvars"
fi

# ── Provision log helpers ──────────────────────────────────────────────────────
_log_event() { printf '%s\n' "$1" >> "$LOG_FILE"; }

# Returns JSON array of active instances for the current provider.
# Active = latest event per (provider, workspace) has action="provision".
_active_instances_json() {
    [[ -f "$LOG_FILE" ]] || { echo "[]"; return; }
    python3 - "$LOG_FILE" "$PROVIDER" <<'PY'
import json, sys
log_file, provider = sys.argv[1], sys.argv[2]
latest = {}
with open(log_file) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        if rec.get("provider") != provider: continue
        ws = rec.get("workspace", "default")
        ts = rec.get("ts", "")
        if ws not in latest or ts > latest[ws]["ts"]:
            latest[ws] = rec
active = [r for r in latest.values() if r.get("action") == "provision"]
print(json.dumps(active))
PY
}

# Destroy a single Terraform workspace (init + select + destroy + workspace delete + log).
_destroy_workspace() {
    local ws="$1" ip="$2" ipv6="${3:-}" ip_stack="${4:-}" confirmed ts destroy_args wsfile

    if [[ "$ws" == "default" ]]; then
        wsfile="${TF_DIR}/terraform.tfvars"
    else
        wsfile="${TF_DIR}/terraform.${ws}.tfvars"
    fi

    local _display_addr="${ip:-${ipv6:-unknown}}"
    warn "This will permanently destroy $PROVIDER infrastructure for workspace '${ws}' (IP: ${_display_addr})."
    if ! $NON_INTERACTIVE; then
        read -rp "[provision] Type 'yes' to confirm: " confirmed </dev/tty
        [[ "$confirmed" == "yes" ]] || { warn "Skipped workspace '${ws}'."; return 0; }
    fi

    cd "$TF_DIR"
    terraform init -input=false >/dev/null
    if ! terraform workspace select "$ws" 2>/dev/null; then
        warn "Workspace '${ws}' not found in Terraform state; skipping."
        cd "$SCRIPT_DIR"
        return 0
    fi

    info "Destroying $PROVIDER infrastructure for workspace '${ws}' (IP: ${_display_addr})..."
    destroy_args=(-auto-approve -input=false)
    [[ "$ws" != "default" && -f "$wsfile" ]] && destroy_args+=(-var-file="$wsfile")
    local _tf_rc=0
    _run terraform destroy "${destroy_args[@]}" || _tf_rc=$?
    if [[ $_tf_rc -ne 0 ]]; then
        warn "terraform destroy for '${ws}' exited rc=${_tf_rc} — resources may already be gone."
        warn "Resetting local state for '${ws}' (terraform state rm module.infra)..."
        terraform state rm 'module.infra' 2>/dev/null || true
        info "Local state reset complete for '${ws}'."
    fi

    # Write log entry before workspace delete so the record exists even if delete fails.
    # Write even on terraform failure so the workspace is not retried by --destroy-all.
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _log_event "$(printf '{"action":"destroy","ts":"%s","provider":"%s","workspace":"%s","ip":"%s","ipv6":"%s","ip_stack":"%s","region":"","plan":""}' \
        "$ts" "$PROVIDER" "$ws" "$ip" "$ipv6" "$ip_stack")"

    if [[ "$ws" != "default" ]]; then
        terraform workspace select default 2>/dev/null || true
        terraform workspace delete "$ws" 2>/dev/null \
            || warn "Could not delete Terraform workspace '${ws}' — manual cleanup: terraform -chdir=${TF_DIR} workspace delete ${ws}"
        rm -f "$wsfile"
    fi

    # Remove the per-instance Vault secret so stale credentials don't linger.
    vault kv metadata delete "secret/forgejo/instances/${PROVIDER}-${ws}" 2>/dev/null \
        || warn "Could not remove Vault secret for '${ws}' — manual cleanup: vault kv metadata delete secret/forgejo/instances/${PROVIDER}-${ws}"

    cd "$SCRIPT_DIR"
    if [[ $_tf_rc -ne 0 ]]; then
        warn "Workspace '${ws}' cleanup attempted despite destroy error (rc=${_tf_rc})."
        return 1
    fi
    info "Destroy complete for workspace '${ws}'."
}

# ── Destroy mode (early exit before region/plan/deploy) ───────────────────────
if $DESTROY; then
    _instances_json="$(_active_instances_json)"
    _instance_count="$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$_instances_json" 2>/dev/null || echo 0)"

    if $DESTROY_ALL; then
        if [[ "$_instance_count" -eq 0 ]]; then
            warn "No active $PROVIDER instances in provision log; attempting current workspace."
            cd "$TF_DIR"; terraform init -input=false >/dev/null
            _existing_ip="$(terraform output -raw public_ipv4 2>/dev/null || true)"
            _existing_ipv6="$(terraform output -raw public_ipv6 2>/dev/null || true)"
            cd "$SCRIPT_DIR"
            _destroy_workspace "$WORKSPACE" "${_existing_ip:-unknown}" "$_existing_ipv6"
        else
            info "Destroying all active $PROVIDER instances:"
            python3 -c "
import json, sys
for r in json.loads(sys.argv[1]):
    ip_str = r.get('ip','') or r.get('ipv6','unknown')
    print('  workspace={:<20} ip={:<45} region={:<15} plan={}'.format(
        r.get('workspace','default'), ip_str,
        r.get('region',''), r.get('plan','')))
" "$_instances_json"
            _failed_ws=()
            while IFS= read -r _rec; do
                _ws="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('workspace','default'))" "$_rec")"
                _ip="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('ip',''))" "$_rec")"
                _ipv6="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('ipv6',''))" "$_rec")"
                _ip_stack="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('ip_stack',''))" "$_rec")"
                _destroy_workspace "$_ws" "$_ip" "$_ipv6" "$_ip_stack" \
                    || _failed_ws+=("$_ws")
            done < <(python3 -c "import json,sys; [print(json.dumps(r)) for r in json.loads(sys.argv[1])]" "$_instances_json")
            if [[ ${#_failed_ws[@]} -gt 0 ]]; then
                warn "Destroy errors for workspace(s): ${_failed_ws[*]} — see warnings above."
            fi
        fi
        info "All destroy operations complete."
        info "Elapsed: $(_elapsed)"
        exit 0
    fi

    if [[ -n "$DESTROY_IP" ]]; then
        _target="$(python3 -c "
import json, sys
recs = json.loads(sys.argv[1])
matches = [r for r in recs if r.get('ip') == sys.argv[2] or r.get('ipv6') == sys.argv[2]]
print(json.dumps(matches[0]) if matches else '')
" "$_instances_json" "$DESTROY_IP")"
        if [[ -z "$_target" ]]; then
            warn "IP ${DESTROY_IP} not found in provision log; attempting destroy of workspace '${WORKSPACE}'."
            _destroy_workspace "$WORKSPACE" "$DESTROY_IP"
        else
            _ws="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('workspace','default'))" "$_target")"
            _ipv6="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('ipv6',''))" "$_target")"
            _ip_stack="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('ip_stack',''))" "$_target")"
            _destroy_workspace "$_ws" "$DESTROY_IP" "$_ipv6" "$_ip_stack"
        fi
        info "Elapsed: $(_elapsed)"
        exit 0
    fi

    # Plain --destroy: if user named an explicit workspace, use it; otherwise
    # show picker when multiple instances exist (interactive only).
    if [[ "$WORKSPACE" != "default" ]]; then
        # Explicit workspace targeted via --workspace
        _target_rec="$(python3 -c "
import json, sys
recs = json.loads(sys.argv[1])
matches = [r for r in recs if r.get('workspace') == sys.argv[2]]
print(json.dumps(matches[0]) if matches else '{}')
" "$_instances_json" "$WORKSPACE")"
        _target_ip="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('ip','unknown'))" "$_target_rec")"
        _target_ipv6="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('ipv6',''))" "$_target_rec")"
        _target_stack="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('ip_stack',''))" "$_target_rec")"
        _destroy_workspace "$WORKSPACE" "$_target_ip" "$_target_ipv6" "$_target_stack"
    elif [[ "$_instance_count" -gt 1 ]] && ! $NON_INTERACTIVE; then
        info "Multiple active $PROVIDER instances — select one to destroy:"
        _ws_list=(); _ip_list=(); _ipv6_list=(); _stack_list=(); _i=1
        while IFS= read -r _rec; do
            _ws="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('workspace','default'))" "$_rec")"
            _ip="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('ip',''))" "$_rec")"
            _ipv6="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('ipv6',''))" "$_rec")"
            _ip_stack="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('ip_stack',''))" "$_rec")"
            _region="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('region',''))" "$_rec")"
            _plan="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('plan',''))" "$_rec")"
            _display_ip="${_ip:-${_ipv6:-unknown}}"
            printf "  %d) workspace=%-20s ip=%-45s region=%-15s plan=%s\n" \
                "$_i" "$_ws" "$_display_ip" "$_region" "$_plan"
            _ws_list+=("$_ws"); _ip_list+=("$_ip"); _ipv6_list+=("$_ipv6"); _stack_list+=("$_ip_stack")
            _i=$((_i + 1))
        done < <(python3 -c "import json,sys; [print(json.dumps(r)) for r in json.loads(sys.argv[1])]" "$_instances_json")
        read -rp "[provision] Enter number to destroy (1-$((_i-1))): " _choice
        [[ "$_choice" =~ ^[0-9]+$ && "$_choice" -ge 1 && "$_choice" -le $((_i-1)) ]] \
            || error "Invalid selection: $_choice"
        _idx=$((_choice - 1))
        _destroy_workspace "${_ws_list[$_idx]}" "${_ip_list[$_idx]}" "${_ipv6_list[$_idx]}" "${_stack_list[$_idx]}"
    else
        # Single instance, no log, or non-interactive: destroy current workspace.
        if [[ "$_instance_count" -eq 0 ]]; then
            [[ -f "${TF_DIR}/terraform.tfvars" ]] \
                || error "No terraform.tfvars at ${TF_DIR}/terraform.tfvars — has '$PROVIDER' been provisioned yet?"
        fi
        cd "$TF_DIR"; terraform init -input=false >/dev/null
        _existing_ip="$(terraform output -raw public_ipv4 2>/dev/null || true)"
        _existing_ipv6="$(terraform output -raw public_ipv6 2>/dev/null || true)"
        cd "$SCRIPT_DIR"
        _destroy_workspace "$WORKSPACE" "${_existing_ip:-unknown}" "$_existing_ipv6"
    fi

    info "Elapsed: $(_elapsed)"
    exit 0
fi

# ── Region & plan selection ───────────────────────────────────────────────────
# Prefer workspace-specific tfvars; fall back to default terraform.tfvars.
_tfvars_for_read="$_ws_tfvars"
[[ -f "$_tfvars_for_read" ]] || _tfvars_for_read="${TF_DIR}/terraform.tfvars"
CURRENT_REGION="$(tfvars_get "$_tfvars_for_read" region)"
CURRENT_PLAN="$(tfvars_get "$_tfvars_for_read" plan)"
# Preserve ip_stack across re-runs; only override if --ip-stack was explicitly passed.
if ! $_IP_STACK_EXPLICIT; then
    _saved_ip_stack="$(tfvars_get "$_tfvars_for_read" ip_stack)"
    [[ -n "$_saved_ip_stack" ]] && IP_STACK="$_saved_ip_stack"
fi
# Restore allowed_cidrs from a previous run if --admin-cidrs was not passed.
if ! $_ADMIN_CIDRS_EXPLICIT; then
    _saved_cidrs="$(tfvars_get_list "$_tfvars_for_read" allowed_cidrs)"
    if [[ -n "$_saved_cidrs" ]]; then
        ADMIN_CIDRS="$_saved_cidrs"
        info "Admin CIDRs restored from tfvars: $ADMIN_CIDRS"
    else
        info "Auto-detecting admin network address..."
        ADMIN_CIDRS="$(detect_admin_cidrs)"
        info "Admin CIDRs detected: $ADMIN_CIDRS"
    fi
else
    info "Admin CIDRs (explicit): $ADMIN_CIDRS"
fi

mkdir -p "$CACHE_DIR"

case "$PROVIDER" in
    vultr)
        [[ -z "$CURRENT_REGION" ]] && CURRENT_REGION="ewr"
        [[ -z "$CURRENT_PLAN" ]]   && CURRENT_PLAN="vc2-1c-1gb"

        REG_CACHE="$CACHE_DIR/vultr-regions.json"
        PLAN_CACHE="$CACHE_DIR/vultr-plans.json"

        if $FORCE_REFRESH || ! cache_fresh "$REG_CACHE";  then fetch_vultr_regions || true; fi
        if $FORCE_REFRESH || ! cache_fresh "$PLAN_CACHE"; then fetch_vultr_plans   || true; fi

        REGIONS=()
        [[ -f "$REG_CACHE"  ]] && load_cache_items REGIONS "$REG_CACHE"
        if [[ ${#REGIONS[@]} -eq 0 ]]; then
            REGIONS=(
                "ewr:Piscataway, NJ - US East"
                "lax:Los Angeles, CA - US West"
                "ord:Chicago, IL - US Central"
                "dfw:Dallas, TX - US South"
                "sea:Seattle, WA - US West"
                "mia:Miami, FL - US South"
                "atl:Atlanta, GA - US South"
                "fra:Frankfurt - EU"
                "ams:Amsterdam - EU"
                "lhr:London - EU"
                "syd:Sydney - AU"
                "sin:Singapore - AP"
                "nrt:Tokyo - AP"
                "icn:Seoul - AP"
                "blr:Bangalore - AP"
            )
        fi

        PLANS=()
        [[ -f "$PLAN_CACHE" ]] && load_cache_items PLANS "$PLAN_CACHE"
        if [[ ${#PLANS[@]} -eq 0 ]]; then
            PLANS=(
                "vc2-1c-0.5gb:1C/512MB/10GB NVMe   ~\$2.50/mo  (not recommended: too small for Forgejo+Postgres)"
                "vc2-1c-1gb:1C/1GB/25GB NVMe        ~\$6/mo     (recommended minimum)"
                "vc2-1c-2gb:1C/2GB/55GB NVMe        ~\$12/mo"
                "vc2-2c-4gb:2C/4GB/80GB NVMe        ~\$24/mo"
            )
        fi

        if $NON_INTERACTIVE; then
            [[ -n "$REGION_ARG" ]] || error "--non-interactive requires --region for vultr"
            [[ -n "$PLAN_ARG"   ]] || error "--non-interactive requires --plan for vultr"
            REGION="$REGION_ARG"; PLAN="$PLAN_ARG"
        else
            show_menu "Vultr regions ($(cache_age_str "$REG_CACHE"); verify at vultr.com/features/datacenter-locations/):" \
                "$CURRENT_REGION" "${REGIONS[@]}"
            REGION="$_MENU_RESULT"
            show_menu "Vultr instance plans ($(cache_age_str "$PLAN_CACHE"); verify at vultr.com/pricing/):" \
                "$CURRENT_PLAN" "${PLANS[@]}"
            PLAN="$_MENU_RESULT"
        fi
        ;;
    aws)
        [[ -z "$CURRENT_REGION" ]] && CURRENT_REGION="us-east-1"
        [[ -z "$CURRENT_PLAN" ]]   && CURRENT_PLAN="t3.micro"

        REG_CACHE="$CACHE_DIR/aws-regions.json"
        if $FORCE_REFRESH || ! cache_fresh "$REG_CACHE"; then fetch_aws_regions || true; fi

        REGIONS=()
        [[ -f "$REG_CACHE" ]] && load_cache_items REGIONS "$REG_CACHE"
        if [[ ${#REGIONS[@]} -eq 0 ]]; then
            REGIONS=(
                "us-east-1:N. Virginia - US East"
                "us-east-2:Ohio - US East"
                "us-west-1:N. California - US West"
                "us-west-2:Oregon - US West"
                "ca-central-1:Canada Central - Montreal"
                "eu-west-1:Ireland - EU"
                "eu-west-2:London - EU"
                "eu-central-1:Frankfurt - EU"
                "ap-southeast-1:Singapore - AP"
                "ap-southeast-2:Sydney - AP"
                "ap-northeast-1:Tokyo - AP"
                "ap-south-1:Mumbai - AP"
                "sa-east-1:Sao Paulo - SA"
            )
        fi

        if $NON_INTERACTIVE; then
            [[ -n "$REGION_ARG" ]] || error "--non-interactive requires --region for aws"
            [[ -n "$PLAN_ARG"   ]] || error "--non-interactive requires --plan for aws"
            REGION="$REGION_ARG"; PLAN="$PLAN_ARG"
        else
            show_menu "AWS regions ($(cache_age_str "$REG_CACHE"); see aws.amazon.com/ec2/pricing/):" \
                "$CURRENT_REGION" "${REGIONS[@]}"
            REGION="$_MENU_RESULT"

            # Fetch instance availability for the selected region (keyed per-region)
            PLAN_CACHE="$CACHE_DIR/aws-plans-${REGION}.json"
            if $FORCE_REFRESH || ! cache_fresh "$PLAN_CACHE"; then fetch_aws_plans "$REGION" || true; fi

            PLANS=()
            [[ -f "$PLAN_CACHE" ]] && load_cache_items PLANS "$PLAN_CACHE"
            if [[ ${#PLANS[@]} -eq 0 ]]; then
                warn "Could not verify instance availability in ${REGION}; showing all types (some may be unavailable)."
                PLANS=(
                    "t4g.micro:2C ARM/1GB    ~\$6/mo   (cheapest; Graviton ARM architecture)"
                    "t3a.micro:2C AMD/1GB    ~\$7/mo"
                    "t3.micro:2C Intel/1GB   ~\$8/mo   (free-tier eligible)"
                    "t3.small:2C Intel/2GB   ~\$15/mo"
                    "t3.medium:2C Intel/4GB  ~\$30/mo"
                )
            fi
            # Reset default if prior plan is not available in the new region
            _plan_ok=false
            for _p in "${PLANS[@]}"; do [[ "${_p%%:*}" == "$CURRENT_PLAN" ]] && { _plan_ok=true; break; }; done
            $_plan_ok || CURRENT_PLAN="${PLANS[0]%%:*}"

            show_menu "AWS EC2 instance types available in ${REGION} ($(cache_age_str "$PLAN_CACHE"); pricing approx):" \
                "$CURRENT_PLAN" "${PLANS[@]}"
            PLAN="$_MENU_RESULT"
        fi
        ;;
    azure)
        [[ -z "$CURRENT_REGION" ]] && CURRENT_REGION="eastus"
        [[ -z "$CURRENT_PLAN" ]]   && CURRENT_PLAN=""

        # Azure regions: no free unauthenticated list API; use static list
        REGIONS=(
            "eastus:East US - Virginia"
            "eastus2:East US 2 - Virginia"
            "westus2:West US 2 - Washington"
            "centralus:Central US - Iowa"
            "canadacentral:Canada Central - Toronto"
            "northeurope:North Europe - Ireland"
            "westeurope:West Europe - Netherlands"
            "uksouth:UK South - London"
            "germanywestcentral:Germany West Central - Frankfurt"
            "francecentral:France Central - Paris"
            "australiaeast:Australia East - New South Wales"
            "southeastasia:Southeast Asia - Singapore"
            "japaneast:Japan East - Tokyo"
            "koreacentral:Korea Central - Seoul"
            "centralindia:Central India - Pune"
            "brazilsouth:Brazil South - Sao Paulo"
        )

        if $NON_INTERACTIVE; then
            [[ -n "$REGION_ARG" ]] || error "--non-interactive requires --region for azure"
            [[ -n "$PLAN_ARG"   ]] || error "--non-interactive requires --plan for azure"
            REGION="$REGION_ARG"; PLAN="$PLAN_ARG"
        else
            show_menu "Azure regions (static; see azure.microsoft.com/pricing/details/virtual-machines/linux/):" \
                "$CURRENT_REGION" "${REGIONS[@]}"
            REGION="$_MENU_RESULT"

            # Fetch available VM sizes and region-specific pricing (authenticated, keyed per-region)
            PLAN_CACHE="$CACHE_DIR/azure-plans-${REGION}.json"
            if $FORCE_REFRESH || ! cache_fresh "$PLAN_CACHE"; then fetch_azure_plans "$REGION" || true; fi

            PLANS=()
            [[ -f "$PLAN_CACHE" ]] && load_cache_items PLANS "$PLAN_CACHE"
            [[ ${#PLANS[@]} -gt 0 ]] \
                || error "No Azure VM sizes retrieved for ${REGION}. Ensure 'az' is logged in and retry with --refresh."
            # Reset default if prior plan is not available in the new region
            _plan_ok=false
            for _p in "${PLANS[@]}"; do [[ "${_p%%:*}" == "$CURRENT_PLAN" ]] && { _plan_ok=true; break; }; done
            $_plan_ok || CURRENT_PLAN="${PLANS[0]%%:*}"

            show_menu "Azure VM sizes available in ${REGION} - B-series burstable ($(cache_age_str "$PLAN_CACHE"); capacity limits not checkable in advance — try another size/region if SkuNotAvailable):" \
                "$CURRENT_PLAN" "${PLANS[@]}"
            PLAN="$_MENU_RESULT"
        fi
        ;;
    linode)
        [[ -z "$CURRENT_REGION" ]] && CURRENT_REGION="us-east"
        [[ -z "$CURRENT_PLAN" ]]   && CURRENT_PLAN="g6-nanode-1"

        # Linode regions: static list (no unauthenticated list API with useful labels)
        REGIONS=(
            "us-east:Newark, NJ - US East"
            "us-southeast:Atlanta, GA - US Southeast"
            "us-central:Dallas, TX - US Central"
            "us-west:Fremont, CA - US West"
            "us-lax:Los Angeles, CA - US West"
            "us-sea:Seattle, WA - US Northwest"
            "us-mia:Miami, FL - US South"
            "ca-central:Toronto, Canada"
            "eu-west:London, UK"
            "eu-central:Frankfurt, Germany"
            "ap-south:Singapore"
            "ap-southeast:Sydney, Australia"
            "ap-northeast:Tokyo, Japan"
            "jp-osa:Osaka, Japan"
            "in-maa:Chennai, India"
            "br-gru:São Paulo, Brazil"
        )

        PLANS=(
            "g6-nanode-1:1C/1GB/25GB SSD    ~\$5/mo   (recommended minimum)"
            "g6-standard-1:1C/2GB/50GB SSD  ~\$10/mo"
            "g6-standard-2:2C/4GB/80GB SSD  ~\$20/mo"
            "g6-standard-4:4C/8GB/160GB SSD ~\$40/mo"
        )

        if $NON_INTERACTIVE; then
            [[ -n "$REGION_ARG" ]] || error "--non-interactive requires --region for linode"
            [[ -n "$PLAN_ARG"   ]] || error "--non-interactive requires --plan for linode"
            REGION="$REGION_ARG"; PLAN="$PLAN_ARG"
        else
            show_menu "Linode regions (static; verify at linode.com/global-infrastructure/):" \
                "$CURRENT_REGION" "${REGIONS[@]}"
            REGION="$_MENU_RESULT"
            show_menu "Linode instance plans (verify at linode.com/pricing/):" \
                "$CURRENT_PLAN" "${PLANS[@]}"
            PLAN="$_MENU_RESULT"
        fi
        ;;
    google)
        [[ -z "$CURRENT_REGION" ]] && CURRENT_REGION="us-east1-b"
        [[ -z "$CURRENT_PLAN" ]]   && CURRENT_PLAN="e2-micro"

        # GCP zones: static list of common zones (provision.sh uses zone as region for GCP).
        REGIONS=(
            "us-east1-b:US East - South Carolina"
            "us-central1-a:US Central - Iowa"
            "us-west1-b:US West - Oregon"
            "us-west2-a:US West - Los Angeles"
            "northamerica-northeast1-b:Canada - Montreal"
            "europe-west1-b:Europe West - Belgium"
            "europe-west2-a:Europe West - London"
            "europe-west3-b:Europe West - Frankfurt"
            "europe-west4-a:Europe West - Netherlands"
            "asia-east1-b:Asia East - Taiwan"
            "asia-northeast1-b:Asia Northeast - Tokyo"
            "asia-southeast1-b:Asia Southeast - Singapore"
            "australia-southeast1-b:Australia Southeast - Sydney"
            "southamerica-east1-b:South America East - São Paulo"
        )

        PLANS=(
            "e2-micro:2C shared/1GB    ~\$6/mo   (cheapest; burstable)"
            "e2-small:2C shared/2GB    ~\$13/mo"
            "e2-medium:2C shared/4GB   ~\$27/mo"
            "n2-standard-2:2C/8GB      ~\$62/mo"
        )

        if $NON_INTERACTIVE; then
            [[ -n "$REGION_ARG" ]] || error "--non-interactive requires --region for google (use a zone, e.g. us-east1-b)"
            [[ -n "$PLAN_ARG"   ]] || error "--non-interactive requires --plan for google"
            REGION="$REGION_ARG"; PLAN="$PLAN_ARG"
        else
            show_menu "GCP zones (static; see cloud.google.com/compute/docs/regions-zones):" \
                "$CURRENT_REGION" "${REGIONS[@]}"
            REGION="$_MENU_RESULT"
            show_menu "GCP machine types (pricing approx; verify at cloud.google.com/compute/vm-instance-pricing):" \
                "$CURRENT_PLAN" "${PLANS[@]}"
            PLAN="$_MENU_RESULT"
        fi
        ;;
esac

info "Selected: region=${REGION}  plan=${PLAN}"

# Build HCL list string for allowed_cidrs from comma-separated ADMIN_CIDRS.
_allowed_cidrs_hcl="$(python3 -c "
import sys
cidrs = [c.strip() for c in '${ADMIN_CIDRS}'.split(',') if c.strip()]
print('[' + ', '.join('\"' + c + '\"' for c in cidrs) + ']')
")"

# user_cidrs: not persisted to tfvars; exported as a JSON array for TF_VAR.
_user_cidrs_json="$(python3 -c "
import json
cidrs = [c.strip() for c in '${USER_CIDRS}'.split(',') if c.strip()]
print(json.dumps(cidrs))
")"
export TF_VAR_user_cidrs="$_user_cidrs_json"
[[ -n "$USER_CIDRS" ]] && info "User CIDRs (not persisted): $USER_CIDRS"

# Write provider-specific tfvars (workspace-specific file for non-default workspaces).
case "$PROVIDER" in
    vultr)
        cat > "$_ws_tfvars" <<EOF
region        = "${REGION}"
plan          = "${PLAN}"
hostname      = "${HOSTNAME}"
ip_stack      = "${IP_STACK}"
allowed_cidrs = ${_allowed_cidrs_hcl}
EOF
        ;;
    aws|azure|linode|google)
        cat > "$_ws_tfvars" <<EOF
region        = "${REGION}"
plan          = "${PLAN}"
hostname      = "${HOSTNAME}"
ip_stack      = "${IP_STACK}"
allowed_cidrs = ${_allowed_cidrs_hcl}
EOF
        ;;
esac
info "tfvars written (${_ws_tfvars})."

# ── SSH key for connecting to VPS ────────────────────────────────────────────
SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
[ -f "$SSH_KEY" ] || error "SSH key not found: $SSH_KEY. Set SSH_KEY_PATH to override."

# ── Terraform ─────────────────────────────────────────────────────────────────
info "Running Terraform ($PROVIDER)..."
cd "$TF_DIR"

# On reprovisioning runs the old resource group may still exist.  Terraform cannot
# create resources inside a group that is being deleted (409 Conflict) or that
# already exists with the same name (conflict on RG create).  Delete it first if
# present, then wait for Azure to finish the deletion before starting apply.
if [[ "$PROVIDER" == "azure" ]]; then
    _rg_name="$HOSTNAME"
    if [[ -n "$_rg_name" ]]; then
        _rg_state="$(az group show --name "$_rg_name" --query properties.provisioningState -o tsv 2>/dev/null || echo "Deleted")"
        if [[ "$_rg_state" != "Deleted" ]]; then
            if [[ "$_rg_state" != "Deleting" ]]; then
                info "Deleting existing resource group '$_rg_name' (state: ${_rg_state}) before reprovisioning..."
                az group delete --name "$_rg_name" --yes --no-wait
            else
                info "Resource group '$_rg_name' is already being deleted; waiting..."
            fi
            for _i in $(seq 1 60); do
                sleep 10
                _rg_state="$(az group show --name "$_rg_name" --query properties.provisioningState -o tsv 2>/dev/null || echo "Deleted")"
                [[ "$_rg_state" == "Deleted" ]] && break
                info "  still deleting... (${_i}/60, state: ${_rg_state})"
            done
            [[ "$_rg_state" == "Deleted" ]] || error "Resource group '$_rg_name' still exists after 10 minutes (state: ${_rg_state}). Delete it manually: az group delete --name '$_rg_name' --yes"
            info "Resource group deleted. Proceeding with Terraform."
        fi
    fi
fi

terraform init -upgrade -input=false
terraform workspace select "$WORKSPACE" 2>/dev/null || terraform workspace new "$WORKSPACE"

# Pass workspace-specific var-file for non-default workspaces (default workspace
# uses terraform.tfvars which Terraform picks up automatically).
_apply_args=(-auto-approve -input=false)
[[ "$WORKSPACE" != "default" ]] && _apply_args+=(-var-file="$_ws_tfvars")
_run terraform apply "${_apply_args[@]}"

IP="$(terraform output -raw public_ipv4 2>/dev/null || true)"
IPV6="$(terraform output -raw public_ipv6 2>/dev/null || true)"
SSH_USER="$(terraform output -raw ssh_user)"

# Vultr assigns IPv6 addresses asynchronously after instance creation.
# Retry with a state refresh for up to 90 seconds if the address is still empty.
if [[ "$IP_STACK" != "ipv4" && -z "$IPV6" ]]; then
    info "Waiting for IPv6 address assignment (Vultr assigns asynchronously)..."
    for _v6_try in $(seq 1 9); do
        sleep 10
        terraform apply -refresh-only -auto-approve -input=false -no-color 2>/dev/null || true
        IPV6="$(terraform output -raw public_ipv6 2>/dev/null || true)"
        [[ -n "$IPV6" ]] && { info "IPv6 address obtained: $IPV6"; break; }
        info "  still waiting... (${_v6_try}/9)"
    done
    [[ -n "$IPV6" ]] || warn "IPv6 address still empty after 90s — continuing; may need to re-run."
fi

# Normalize IPv6 to compressed form (no leading zeros).  Certbot converts the
# address via Python's ipaddress.ip_address() before naming the cert directory,
# so DOMAIN must match that compressed form or nginx can't find the cert.
if [[ -n "$IPV6" ]]; then
    _v6_norm="$(python3 -c "import ipaddress; print(str(ipaddress.ip_address('${IPV6}')))" 2>/dev/null || true)"
    [[ -n "$_v6_norm" ]] && IPV6="$_v6_norm"
fi

cd "$SCRIPT_DIR"

# Append provision event to the log (one JSON object per line, append-only).
_log_event "$(printf '{"action":"provision","ts":"%s","provider":"%s","workspace":"%s","ip":"%s","ipv6":"%s","region":"%s","plan":"%s","ip_stack":"%s"}' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PROVIDER" "$WORKSPACE" "$IP" "$IPV6" "$REGION" "$PLAN" "$IP_STACK")"

# Persist provider selection so next run defaults to the same provider
echo "$PROVIDER" > .last-provider

# CONNECT_IP and DOMAIN: IPv6-only mode uses the IPv6 address; all other modes
# use IPv4. LE issues IP certificates under the 'shortlived' profile (160-hour
# validity) — both IPv4 and IPv6 IP addresses are supported by this profile.
if [[ "$IP_STACK" == "ipv6" ]]; then
    [[ -n "$IPV6" ]] || error "ip_stack=ipv6 but no IPv6 address in Terraform output"
    CONNECT_IP="$IPV6"
    DOMAIN="$IPV6"
else
    CONNECT_IP="$IP"
    DOMAIN="$IP"
fi

# ROOT_URL needs brackets around IPv6 literals in URLs (RFC 2732).
# nginx server_name and certbot -d accept bare IPv6 addresses without brackets.
if [[ "$CONNECT_IP" == *:* ]]; then
    ROOT_URL_HOST="[${CONNECT_IP}]"
else
    ROOT_URL_HOST="$CONNECT_IP"
fi

# ssh user@addr — bare IPv6 is fine; OpenSSH parses user@addr unambiguously.
# scp user@addr:path — brackets required to avoid the first colon being parsed
# as the host:path separator.
_ssh_host() { echo "$1"; }
_scp_host() { [[ "$1" == *:* ]] && echo "[${1}]" || echo "$1"; }

info "VPS  IPv4: ${IP:-none}  IPv6: ${IPV6:-none}  Connect: $CONNECT_IP  Provider: $PROVIDER"

# ── Wait for SSH ──────────────────────────────────────────────────────────────
info "Waiting for SSH to become available (this takes ~60-90 seconds)..."
: > known_hosts.deploy
ATTEMPTS=0
until ssh-keyscan -p 22 -T 5 "$CONNECT_IP" >> known_hosts.deploy 2>/dev/null; do
    ATTEMPTS=$((ATTEMPTS + 1))
    [ "$ATTEMPTS" -lt 30 ] || error "Timed out waiting for SSH on $CONNECT_IP"
    sleep 10
done
info "SSH port is up."

SSH_OPTS="-i $SSH_KEY -o UserKnownHostsFile=./known_hosts.deploy -o StrictHostKeyChecking=yes"
_SSH_HOST="$(_ssh_host "$CONNECT_IP")"
_SCP_HOST="$(_scp_host "$CONNECT_IP")"

# On AWS, user_data configures root access after sshd is already listening.
# Retry the actual login until it succeeds (up to 3 extra minutes).
# On re-runs after hardening, root login is disabled — fall back to deploy user.
info "Verifying SSH login as $SSH_USER (will retry as 'deploy' if root is disabled)..."
ATTEMPTS=0
until ssh $SSH_OPTS -o ConnectTimeout=10 -o BatchMode=yes "${SSH_USER}@${_SSH_HOST}" true 2>/dev/null; do
    ATTEMPTS=$((ATTEMPTS + 1))
    [ "$ATTEMPTS" -lt 18 ] || break
    sleep 10
done

if ! ssh $SSH_OPTS -o ConnectTimeout=5 -o BatchMode=yes "${SSH_USER}@${_SSH_HOST}" true 2>/dev/null; then
    info "Login as $SSH_USER failed; trying deploy user (post-hardening re-run)..."
    ATTEMPTS=0
    until ssh $SSH_OPTS -o ConnectTimeout=10 -o BatchMode=yes "deploy@${_SSH_HOST}" true 2>/dev/null; do
        ATTEMPTS=$((ATTEMPTS + 1))
        [ "$ATTEMPTS" -lt 6 ] || error "Cannot log in as ${SSH_USER} or deploy@${_SSH_HOST} — check SSH key and firewall"
        sleep 5
    done
    SSH_USER="deploy"
fi
info "SSH login confirmed as $SSH_USER."

# ── Render templates ──────────────────────────────────────────────────────────
info "Rendering configuration templates..."
TMPDIR="$(mktemp -d /tmp/forgejo-deploy-XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

# Export vars for envsubst.
# ROOT_URL_HOST wraps IPv6 addresses in brackets for valid URL syntax (RFC 2732);
# equals DOMAIN for IPv4 addresses.
export DOMAIN ROOT_URL_HOST DB_PASSWORD DB_USER DB_NAME FORGEJO_SECRET_KEY FORGEJO_INTERNAL_TOKEN

envsubst '${DOMAIN}' \
    < files/templates/nginx-http.conf.tmpl > "$TMPDIR/nginx-http.conf"
envsubst '${DOMAIN}' \
    < files/templates/nginx.conf.tmpl > "$TMPDIR/nginx.conf"
envsubst '${DOMAIN} ${ROOT_URL_HOST} ${DB_PASSWORD} ${DB_USER} ${DB_NAME} ${FORGEJO_SECRET_KEY} ${FORGEJO_INTERNAL_TOKEN}' \
    < files/templates/app.ini.tmpl > "$TMPDIR/app.ini"
envsubst '${DB_PASSWORD} ${DB_USER} ${DB_NAME}' \
    < files/templates/.env.tmpl > "$TMPDIR/.env"

# ── Copy files to VPS ─────────────────────────────────────────────────────────
info "Copying files to VPS (as $SSH_USER)..."
# shellcheck disable=SC2086

if [[ "$SSH_USER" == "root" ]]; then
    # First run: SSH as root, scp directly to /opt/forgejo
    ssh $SSH_OPTS "${SSH_USER}@${_SSH_HOST}" "mkdir -p /opt/forgejo"
    scp $SSH_OPTS \
        "$TMPDIR/nginx-http.conf" \
        "$TMPDIR/nginx.conf" \
        "$TMPDIR/app.ini" \
        "$TMPDIR/.env" \
        files/docker-compose.yml \
        files/certbot-renew.sh \
        files/forgejo-keys.sh \
        files/forgejo-cert-extract.py \
        files/sshd_forgejo.conf \
        ca.pub \
        "${SSH_USER}@${_SCP_HOST}:/opt/forgejo/"
    scp $SSH_OPTS deploy.sh "${SSH_USER}@${_SCP_HOST}:/opt/forgejo/deploy.sh"
else
    # Re-run after hardening: SSH as deploy; /opt/forgejo is chown root:deploy g+w
    # Stage to tmp first, then sudo-move into place
    STAGE_DIR="$(ssh $SSH_OPTS "deploy@${_SSH_HOST}" "mktemp -d")"
    trap 'ssh '"$SSH_OPTS"' "deploy@'"$_SSH_HOST"'" "rm -rf '"$STAGE_DIR"'" 2>/dev/null; rm -rf "$TMPDIR"' EXIT
    scp $SSH_OPTS \
        "$TMPDIR/nginx-http.conf" \
        "$TMPDIR/nginx.conf" \
        "$TMPDIR/app.ini" \
        "$TMPDIR/.env" \
        files/docker-compose.yml \
        files/certbot-renew.sh \
        files/forgejo-keys.sh \
        files/forgejo-cert-extract.py \
        files/sshd_forgejo.conf \
        ca.pub \
        deploy.sh \
        "deploy@${_SCP_HOST}:${STAGE_DIR}/"
    ssh $SSH_OPTS "deploy@${_SSH_HOST}" \
        "sudo mv ${STAGE_DIR}/* /opt/forgejo/ && sudo rm -rf ${STAGE_DIR}"
fi

# ── Run deploy.sh on VPS ──────────────────────────────────────────────────────
info "Running deploy.sh on VPS as $SSH_USER..."
# On re-runs as deploy user, sudo env passes the environment variables through.
SUDO_PREFIX=""
[[ "$SSH_USER" != "root" ]] && SUDO_PREFIX="sudo env"
# shellcheck disable=SC2086
_run ssh $SSH_OPTS "${SSH_USER}@${_SSH_HOST}" \
    "${SUDO_PREFIX} DOMAIN='${DOMAIN}' \
     IP_STACK='${IP_STACK}' \
     IPV6='${IPV6:-}' \
     ADMIN_CIDRS='${ADMIN_CIDRS}' \
     USER_CIDRS='${USER_CIDRS}' \
     CERTBOT_EMAIL='${CERTBOT_EMAIL}' \
     CERTBOT_STAGING='${CERTBOT_STAGING}' \
     DEBUG='${DEBUG}' \
     FORGEJO_ADMIN_USER='${FORGEJO_ADMIN_USER}' \
     FORGEJO_ADMIN_EMAIL='${FORGEJO_ADMIN_EMAIL}' \
     FORGEJO_ADMIN_PASSWORD='${FORGEJO_ADMIN_PASSWORD}' \
     ADMIN_SSH_PUBLIC_KEY='${ADMIN_SSH_PUBLIC_KEY}' \
     bash /opt/forgejo/deploy.sh"

# ── Verify HTTPS endpoint ─────────────────────────────────────────────────────
_HTTPS_URL="https://${ROOT_URL_HOST}"
info "Verifying HTTPS endpoint externally at ${_HTTPS_URL} ..."
HTTPS_HTTP_CODE="$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' "${_HTTPS_URL}" || true)"
if [ "$HTTPS_HTTP_CODE" = "200" ] || [ "$HTTPS_HTTP_CODE" = "302" ]; then
    info "External HTTPS check passed (HTTP $HTTPS_HTTP_CODE)."
else
    warn "External HTTPS check returned code: $HTTPS_HTTP_CODE — running verbose check from VPS:"
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${SSH_USER}@${_SSH_HOST}" \
        "curl -vvv -k --max-time 15 https://localhost 2>&1; echo; echo '--- nginx status ---'; docker ps --filter name=nginx --format '{{.Status}}'; docker exec \$(docker ps -qf name=nginx) nginx -t 2>&1 || true" \
        || true
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "Forgejo is live at ${_HTTPS_URL}  [${PROVIDER} / ${IP_STACK}]"
[[ -n "$IP"   ]] && echo "  IPv4 : ${IP}"
[[ -n "$IPV6" ]] && echo "  IPv6 : ${IPV6}"
echo
echo "  Admin SSH : ssh deploy@${_SSH_HOST}   (root login disabled after hardening)"
echo
echo "  Forgejo admin credentials:"
echo "    Username : ${FORGEJO_ADMIN_USER}"
echo "    Password : VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=\$(cat ${SCRIPT_DIR}/.vault.token) vault kv get -field=admin_password ${_INST_SECRET}"
echo
echo "  To add a user:"
echo "    ./sign-user-key.sh <username> /path/to/user_key.pub"
echo
echo "  ── Git SSH config ──────────────────────────"
echo "  Add to ~/.ssh/config:"
echo
echo "    Host forgejo"
echo "        HostName ${CONNECT_IP}"
echo "        Port 2222"
echo "        User git"
echo "        IdentityFile ~/.ssh/id_ed25519"
echo
echo "  Then clone with:  git clone git@forgejo:/<user>/<repo>.git"
echo
echo "  Or set a git URL alias (no SSH config needed):"
echo "    git config --global url.\"ssh://git@${CONNECT_IP}:2222/\".insteadOf \"forgejo:\""
echo "  Then clone with:  git clone forgejo:<user>/<repo>"
echo
echo "  Elapsed   : $(_elapsed)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
