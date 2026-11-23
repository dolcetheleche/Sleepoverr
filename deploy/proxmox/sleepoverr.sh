#!/usr/bin/env bash
# Sleepoverr for Proxmox VE: creates an LXC container, installs Sleepoverr in it, and updates it later.
# Run as root in the shell of your Proxmox VE host (not inside a container or VM).
#
#   curl -fsSL https://raw.githubusercontent.com/dolcetheleche/Sleepoverr/master/deploy/proxmox/sleepoverr.sh | bash -s -- install
#   ... | bash -s -- install --test-env      guest 1000, 2 cores, 4 GB RAM: Sleepoverr + mock RomM
#   ... | bash -s -- update [CTID]           snapshot, then update the container's Sleepoverr
#
# Options:  -y/--yes  accept all defaults, never ask     --dry-run  print what would change
# Every answer can also be given as an environment variable (CT_ID, CT_CORES, CT_RAM, CT_DISK,
# CT_STORAGE, CT_BRIDGE, CT_IP, CT_GW, IGDB_CLIENT_ID, ...); see deploy/proxmox/README.md.

set -Eeuo pipefail

HOST_VERSION="0.1.0"
REPO="${SLEEPOVERR_REPO:-dolcetheleche/Sleepoverr}"
REF="${SLEEPOVERR_REF:-master}"
USER_REF="${SLEEPOVERR_REF:-}"
RAW_ROOT="${SLEEPOVERR_RAW_ROOT:-https://raw.githubusercontent.com/${REPO}/${REF}}"
CTL_DEST="/usr/local/bin/sleepoverr-ctl"
SNAPSHOT_PREFIX="sleepoverr-pre-update-"
SNAPSHOTS_KEPT=3

ASSUME_YES=0
DRY_RUN=0
NO_SNAPSHOT=0
PROFILE="prod"
CMD=""
ARGS=()

info() { printf '\033[1;34m[..]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31m[xx]\033[0m %s\n' "$*" >&2
  exit 1
}

# Mutating commands go through run, so --dry-run can print them instead.
run() {
  if ((DRY_RUN)); then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

parse_args() {
  while (($#)); do
    case "$1" in
      -y | --yes) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --no-snapshot) NO_SNAPSHOT=1 ;;
      --test-env | --test) PROFILE="test" ;;
      -h | --help) CMD=help ;;
      install | update | help | version) [[ -z $CMD ]] && CMD="$1" ;;
      -*) die "Unknown option: $1 (try: help)" ;;
      *) ARGS+=("$1") ;;
    esac
    shift
  done
}

interactive() {
  ((ASSUME_YES)) && return 1
  { : </dev/tty; } 2>/dev/null
}

# ask VAR "question" default: an already-set environment variable wins, then the answer, then the default.
ask() {
  local var="$1" prompt="$2" def="${3:-}" reply=""
  [[ -n ${!var:-} ]] && return 0
  if interactive; then
    read -r -p "$prompt [$def]: " reply </dev/tty || true
  fi
  printf -v "$var" '%s' "${reply:-$def}"
}

ask_secret() {
  local var="$1" prompt="$2" reply=""
  [[ -n ${!var:-} ]] && return 0
  if interactive; then
    read -r -s -p "$prompt (hidden, Enter to skip): " reply </dev/tty || true
    echo
  fi
  printf -v "$var" '%s' "$reply"
}

need_pve() {
  [[ $(id -u) -eq 0 ]] || die "Run this as root."
  if ! command -v pveversion >/dev/null 2>&1 || ! command -v pct >/dev/null 2>&1; then
    die "This must run in the shell of a Proxmox VE host (pveversion/pct not found)."
  fi
}

list_storages() { # list_storages CONTENT: names of active storages that can hold that content type
  pvesm status --content "$1" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}'
}

pick_storage() { # pick_storage CONTENT PREFERRED...
  local content="$1" avail pref
  shift
  avail="$(list_storages "$content")"
  for pref in "$@"; do
    if grep -qx "$pref" <<<"$avail"; then
      printf '%s' "$pref"
      return 0
    fi
  done
  head -n 1 <<<"$avail"
}

# Fails with the list of valid names, so a typo or a number typed at the wrong prompt is caught
# before anything is downloaded or created.
require_storage() { # require_storage CONTENT NAME VARIABLE
  if ! list_storages "$1" | grep -qx -- "$2"; then
    die "'$2' is not a storage that can hold '$1' on this host (set $3). Available: $(list_storages "$1" | tr '\n' ' ')"
  fi
}

pick_template() {
  local os tmpl
  for os in debian-13-standard debian-12-standard; do
    tmpl="$(pveam available --section system 2>/dev/null | awk -v p="$os" '$2 ~ "^" p {print $2}' | sort -V | tail -n 1)"
    if [[ -n $tmpl ]]; then
      printf '%s' "$tmpl"
      return 0
    fi
  done
  return 1
}

in_use() { pvesh get /cluster/nextid --vmid "$1" >/dev/null 2>&1 && return 1 || return 0; }

gather_settings() {
  local def_id def_ram def_name
  if [[ $PROFILE == test ]]; then
    def_id=1000 def_ram=4096 def_name=sleepoverr-test
  else
    def_id="$(pvesh get /cluster/nextid 2>/dev/null || echo 100)" def_ram=2048 def_name=sleepoverr
  fi
  ask CT_ID "Container ID" "$def_id"
  ask CT_HOSTNAME "Hostname" "$def_name"
  ask CT_CORES "CPU cores" 2
  ask CT_RAM "RAM in MB" "$def_ram"
  ask CT_SWAP "Swap in MB" 512
  ask CT_DISK "Disk size in GB" 20
  ask CT_STORAGE "Storage name for the disk (one of: $(list_storages rootdir | tr '\n' ' '))" "$(pick_storage rootdir local-lvm local-zfs local)"
  ask CT_TEMPLATE_STORAGE "Storage name holding templates (one of: $(list_storages vztmpl | tr '\n' ' '))" "$(pick_storage vztmpl local)"
  ask CT_BRIDGE "Network bridge" vmbr0
  ask CT_IP "IP address (dhcp or CIDR like 192.168.1.50/24)" dhcp
  # shellcheck disable=SC2153  # CT_IP is assigned by the ask call above
  if [[ $CT_IP != dhcp ]]; then ask CT_GW "Gateway" ""; fi
  ask CT_VLAN "VLAN tag (empty for none)" ""

  [[ $CT_ID =~ ^[0-9]+$ && $CT_CORES =~ ^[0-9]+$ && $CT_RAM =~ ^[0-9]+$ && $CT_SWAP =~ ^[0-9]+$ && $CT_DISK =~ ^[0-9]+$ ]] ||
    die "CT_ID, CT_CORES, CT_RAM, CT_SWAP and CT_DISK must be numbers."
  ((CT_ID >= 100)) || die "Container IDs start at 100."
  [[ -n $CT_STORAGE ]] || die "No storage that can hold container disks was found; set CT_STORAGE."
  [[ -n $CT_TEMPLATE_STORAGE ]] || die "No storage for templates was found; set CT_TEMPLATE_STORAGE."
  require_storage rootdir "$CT_STORAGE" CT_STORAGE
  require_storage vztmpl "$CT_TEMPLATE_STORAGE" CT_TEMPLATE_STORAGE
  if [[ $CT_IP != dhcp ]]; then
    [[ $CT_IP =~ ^[0-9.]+/[0-9]+$ ]] || die "CT_IP must be 'dhcp' or an address like 192.168.1.50/24."
    [[ -n ${CT_GW:-} ]] || die "A static IP needs CT_GW (the gateway)."
  fi
  if in_use "$CT_ID"; then
    die "ID $CT_ID is already used by another guest. Nothing was changed. Pick another with CT_ID=..., or update it with: update $CT_ID"
  fi

  if [[ $PROFILE == prod ]]; then
    ask ROMM_URL "RomM URL (optional, e.g. http://192.168.1.20:8080)" ""
    ask_secret ROMM_API_TOKEN "RomM Client API Token (optional, read scopes only)"
  fi
  ask IGDB_CLIENT_ID "IGDB (Twitch) client id (optional, can be added later)" ""
  ask_secret IGDB_CLIENT_SECRET "IGDB client secret"
  TZ="${TZ:-$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || true)}"
}

ensure_template() {
  local tmpl
  run pveam update >/dev/null 2>&1 || true
  tmpl="$(pick_template)" || die "No Debian 12/13 container template is available (pveam available)."
  if ! pveam list "$CT_TEMPLATE_STORAGE" 2>/dev/null | awk '{print $1}' | grep -q "/${tmpl}\$"; then
    info "Downloading template $tmpl..."
    run pveam download "$CT_TEMPLATE_STORAGE" "$tmpl"
  fi
  TEMPLATE_VOLID="${CT_TEMPLATE_STORAGE}:vztmpl/${tmpl}"
}

create_ct() {
  local net="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},firewall=0"
  [[ $CT_IP == dhcp ]] || net+=",gw=${CT_GW}"
  [[ -z ${CT_VLAN:-} ]] || net+=",tag=${CT_VLAN}"
  info "Creating container $CT_ID ($CT_CORES cores, ${CT_RAM} MB RAM, ${CT_DISK} GB on ${CT_STORAGE})..."
  run pct create "$CT_ID" "$TEMPLATE_VOLID" \
    --hostname "$CT_HOSTNAME" --cores "$CT_CORES" --memory "$CT_RAM" --swap "$CT_SWAP" \
    --rootfs "${CT_STORAGE}:${CT_DISK}" --net0 "$net" \
    --unprivileged 1 --features nesting=1,keyctl=1 --onboot 1 --ostype debian \
    --tags "sleepoverr;${PROFILE}" \
    --description "Sleepoverr (${PROFILE}) - created by deploy/proxmox/sleepoverr.sh. Update: re-run the script with 'update ${CT_ID}'."
  run pct start "$CT_ID"
}

wait_for_network() {
  ((DRY_RUN)) && return 0
  info "Waiting for the container's network..."
  for _ in $(seq 1 30); do
    if pct exec "$CT_ID" -- getent hosts download.docker.com >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "The container has no working network or DNS after 60 s. Check the bridge/VLAN/IP settings; the container $CT_ID was left in place."
}

push_ctl() {
  local tmp
  tmp="$(mktemp)"
  if [[ -n ${SLEEPOVERR_CTL_FILE:-} ]]; then
    cp "$SLEEPOVERR_CTL_FILE" "$tmp"
  else
    curl -fsSL --retry 3 -o "$tmp" "${RAW_ROOT}/deploy/proxmox/sleepoverr-ctl.sh" ||
      die "Could not download sleepoverr-ctl.sh from ${RAW_ROOT}. If the branch is not merged yet, set SLEEPOVERR_REF to the branch name."
  fi
  bash -n "$tmp" || die "The downloaded sleepoverr-ctl.sh does not parse."
  run pct push "$CT_ID" "$tmp" "$CTL_DEST" --perms 0755
  rm -f "$tmp"
}

push_install_env() {
  local tmp key value
  tmp="$(mktemp)"
  chmod 600 "$tmp"
  for key in IGDB_CLIENT_ID IGDB_CLIENT_SECRET ROMM_URL ROMM_API_TOKEN TZ; do
    value="${!key:-}"
    [[ -z $value ]] && continue
    [[ $value == *$'\n'* || $value == *$'\r'* ]] && die "$key contains a line break."
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
  done
  run pct push "$CT_ID" "$tmp" /root/sleepoverr-install.env --perms 0600
  rm -f "$tmp"
}

cmd_install() {
  need_pve
  gather_settings
  ensure_template
  create_ct
  wait_for_network
  push_ctl
  push_install_env
  local envargs=(SLEEPOVERR_REPO="$REPO" SLEEPOVERR_REF="$REF" SLEEPOVERR_PROFILE="$PROFILE")
  [[ -z ${SLEEPOVERR_MODE:-} ]] || envargs+=(SLEEPOVERR_MODE="$SLEEPOVERR_MODE")
  [[ -z ${SLEEPOVERR_TAG:-} ]] || envargs+=(SLEEPOVERR_TAG="$SLEEPOVERR_TAG")
  info "Installing inside the container (Docker, then Sleepoverr). This takes a while..."
  run pct exec "$CT_ID" -- env "${envargs[@]}" "$CTL_DEST" install
  if ((!DRY_RUN)); then
    local ip
    ip="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')"
    echo
    ok "Done. Container $CT_ID (${CT_HOSTNAME}) is at ${ip:-its DHCP address}."
    echo "   Update later:        re-run this script with: update $CT_ID"
    echo "   Inside the container: pct enter $CT_ID   then   sleepoverr-ctl status | logs | update | backup"
  fi
}

# --------------------------------------------------------------------------- update

list_cts() {
  local id
  pct list | awk 'NR>1 {print $1}' | while read -r id; do
    if pct config "$id" 2>/dev/null | grep -qE '^tags:.*sleepoverr'; then echo "$id"; fi
  done
}

choose_ct() {
  local ids count pick
  mapfile -t ids < <(list_cts)
  count="${#ids[@]}"
  ((count > 0)) || die "No container tagged 'sleepoverr' was found. Give the ID: update CTID"
  if ((count == 1)); then
    printf '%s' "${ids[0]}"
    return 0
  fi
  interactive || die "Several Sleepoverr containers found (${ids[*]}). Give the ID: update CTID"
  echo "Sleepoverr containers:" >&2
  for pick in "${ids[@]}"; do echo "  $pick  $(pct config "$pick" | awk '/^hostname:/ {print $2}')" >&2; done
  read -r -p "Update which container ID? " pick </dev/tty
  printf '%s' "$pick"
}

prune_snapshots() {
  local id="$1" name
  pct listsnapshot "$id" 2>/dev/null | grep -o "${SNAPSHOT_PREFIX}[0-9]\{8\}-[0-9]\{6\}" | sort | head -n "-${SNAPSHOTS_KEPT}" |
    while read -r name; do run pct delsnapshot "$id" "$name"; done
}

cmd_update() {
  need_pve
  local id="${ARGS[0]:-}"
  [[ -n $id ]] || id="$(choose_ct)"
  [[ $id =~ ^[0-9]+$ ]] || die "Container ID must be a number."
  pct config "$id" 2>/dev/null | grep -qE '^tags:.*sleepoverr' ||
    die "Container $id is not tagged 'sleepoverr'; refusing to touch it."
  if ! pct status "$id" | grep -q running; then
    info "Starting container $id..."
    run pct start "$id"
    CT_ID="$id"
    wait_for_network
  fi
  # A Proxmox snapshot is the one-step rollback for the whole container (production profile only;
  # the test environment's data is disposable).
  if ((!NO_SNAPSHOT)) && ! pct config "$id" | grep -qE '^tags:.*test'; then
    local snap
    snap="${SNAPSHOT_PREFIX}$(date +%Y%m%d-%H%M%S)"
    info "Taking snapshot $snap (roll back with: pct rollback $id $snap)..."
    if run pct snapshot "$id" "$snap" --description "before sleepoverr-ctl update"; then
      prune_snapshots "$id"
    else
      warn "Could not snapshot (this storage may not support it). Continuing; sleepoverr-ctl still backs up the data."
    fi
  fi
  local envargs=()
  [[ -z $USER_REF ]] || envargs+=(SLEEPOVERR_REF="$USER_REF")
  [[ -z ${SLEEPOVERR_TAG:-} ]] || envargs+=(SLEEPOVERR_TAG="$SLEEPOVERR_TAG")
  run pct exec "$id" -- env "${envargs[@]}" "$CTL_DEST" update
}

cmd_help() {
  cat <<'HELP'
Sleepoverr for Proxmox VE. Run as root in the shell of your Proxmox VE host.

  sleepoverr.sh install                 create an LXC and install Sleepoverr in it
  sleepoverr.sh install --test-env      guest 1000, 2 cores, 4 GB RAM: Sleepoverr + mock RomM
  sleepoverr.sh update [CTID]           snapshot, then update that container's Sleepoverr

  -y/--yes        accept all defaults, never ask
  --dry-run       print the changes instead of making them
  --no-snapshot   skip the pre-update snapshot

Answers can be given as environment variables (CT_ID, CT_CORES, CT_RAM, CT_DISK, CT_STORAGE,
CT_BRIDGE, CT_IP, CT_GW, IGDB_CLIENT_ID, ...). See deploy/proxmox/README.md.
HELP
}

main() {
  parse_args "$@"
  if [[ -z $CMD ]]; then
    if interactive; then
      echo "Sleepoverr for Proxmox VE (script ${HOST_VERSION})"
      echo "  1) Install a new Sleepoverr container"
      echo "  2) Install the test environment (guest 1000, 2 cores, 4 GB RAM)"
      echo "  3) Update an existing container"
      read -r -p "Choose [1]: " choice </dev/tty || true
      case "${choice:-1}" in
        2) CMD="install" PROFILE="test" ;;
        3) CMD=update ;;
        *) CMD=install ;;
      esac
    else
      CMD=install
    fi
  fi
  case "$CMD" in
    install) cmd_install ;;
    update) cmd_update ;;
    version) echo "sleepoverr.sh ${HOST_VERSION}" ;;
    help) cmd_help ;;
  esac
}

if [[ ${BASH_SOURCE[0]:-$0} == "$0" ]]; then
  main "$@"
fi
