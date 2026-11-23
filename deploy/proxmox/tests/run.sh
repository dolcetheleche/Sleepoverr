#!/usr/bin/env bash
# Tests for sleepoverr.sh (host side) and sleepoverr-ctl.sh (container side).
# They run both scripts against fake pct/pveam/pvesh/pvesm/docker commands that only record what
# they were asked to do, so no Proxmox or Docker is needed. They check the logic and the exact
# commands, not that real Proxmox or Docker accept them.
#
#   deploy/proxmox/tests/run.sh

# shellcheck disable=SC2015,SC2016,SC2034,SC2153  # test idioms: pass/fail chains, literal $ in fixtures, vars read by sourced code
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)"
HOST="$SRC/sleepoverr.sh"
CTL="$SRC/sleepoverr-ctl.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=0
FAIL=0

fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL: %s\n' "$*"
}
pass() { PASS=$((PASS + 1)); }
section() { printf '%s\n' "$*"; }

assert_contains() { # FILE TEXT
  if grep -qF -- "$2" "$1"; then pass; else
    fail "expected '$2' in $(basename "$1")"
    sed 's/^/        | /' "$1" | tail -n 15
  fi
}
assert_not_contains() { # FILE TEXT
  if grep -qF -- "$2" "$1"; then fail "did not expect '$2' in $(basename "$1")"; else pass; fi
}
assert_eq() { # EXPECTED ACTUAL MESSAGE
  if [[ $1 == "$2" ]]; then pass; else fail "$3: expected '$1', got '$2'"; fi
}
assert_rc() { # EXPECTED ACTUAL MESSAGE
  if [[ $1 -eq $2 ]]; then pass; else fail "$3: exit code expected $1, got $2"; fi
}
# Order of two lines in a log: A must appear before B.
assert_before() { # FILE A B
  local a b
  a="$(grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1)"
  b="$(grep -nF -- "$3" "$1" | head -n 1 | cut -d: -f1)"
  if [[ -n $a && -n $b ]] && ((a < b)); then pass; else fail "expected '$2' before '$3' in $(basename "$1")"; fi
}

# ------------------------------------------------------------------ fake commands

BIN="$T/bin"
STUB="$T/stub"
mkdir -p "$BIN" "$STUB"
export STUB_DIR="$STUB" STUB_LOG="$T/calls.log"

cat >"$BIN/id" <<'EOF'
#!/bin/sh
if [ "$1" = "-u" ]; then echo 0; else exec /usr/bin/id "$@"; fi
EOF
cat >"$BIN/pveversion" <<'EOF'
#!/bin/sh
echo "pve-manager/9.0.0 (fake)"
EOF
cat >"$BIN/pct" <<'EOF'
#!/bin/sh
echo "pct $*" >>"$STUB_LOG"
case "$1" in
  list) echo "VMID Status Lock Name"; cat "$STUB_DIR/cts" 2>/dev/null ;;
  config) [ -f "$STUB_DIR/config-$2" ] && cat "$STUB_DIR/config-$2" || exit 2 ;;
  status) echo "status: running" ;;
  push) cp "$3" "$STUB_DIR/pushed-$(basename "$4")" ;;
  listsnapshot) cat "$STUB_DIR/snapshots" 2>/dev/null ;;
  snapshot) [ -f "$STUB_DIR/snapshot-fails" ] && exit 1 ;;
  start) [ -f "$STUB_DIR/start-fails" ] && exit 1 ;;
  exec)
    shift 2
    [ "$1" = "--" ] && shift
    case "$1" in hostname) echo "192.168.1.77" ;; esac
    ;;
esac
exit 0
EOF
cat >"$BIN/pvesh" <<'EOF'
#!/bin/sh
echo "pvesh $*" >>"$STUB_LOG"
want=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--vmid" ]; then want="$2"; fi
  shift
done
if [ -n "$want" ]; then
  for u in $STUB_USED; do [ "$u" = "$want" ] && exit 1; done
  exit 0
fi
echo 100
EOF
cat >"$BIN/pvesm" <<'EOF'
#!/bin/sh
echo "Name Type Status Total Used Available %"
echo "local dir active 100 1 99 1%"
[ "$3" = "rootdir" ] && echo "local-lvm lvmthin active 100 1 99 1%"
exit 0
EOF
cat >"$BIN/pveam" <<'EOF'
#!/bin/sh
echo "pveam $*" >>"$STUB_LOG"
case "$1" in
  available)
    echo "system          debian-12-standard_12.7-1_amd64.tar.zst"
    echo "system          debian-12-standard_12.7-1_arm64.tar.zst"
    echo "system          debian-13-standard_13.1-1_amd64.tar.zst"
    echo "system          debian-13-standard_13.6-1_arm64.tar.zst"
    echo "system          ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
    ;;
  list) [ -f "$STUB_DIR/template-present" ] && echo "local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst 120MB" ;;
esac
exit 0
EOF
cat >"$BIN/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >>"$STUB_LOG"
case "$1" in
  inspect)
    case "$*" in
      *State*) cat "$STUB_DIR/state" 2>/dev/null || echo healthy ;;
      *Image*) cat "$STUB_DIR/image" 2>/dev/null || echo sha256:old ;;
    esac
    ;;
  compose)
    case "$*" in *" pull"*) echo sha256:new >"$STUB_DIR/image" ;; esac
    ;;
  run)
    [ -f "$STUB_DIR/run-fails" ] && exit 1
    dest=""; bdir=""; prev=""
    for a in "$@"; do
      case "$a" in *:/backup) bdir="${a%%:/backup}" ;; esac
      [ "$prev" = czf ] && dest="$a"
      prev="$a"
    done
    [ -n "$dest" ] && echo fake >"$bdir/$(basename "$dest")"
    ;;
  pull) [ -f "$STUB_DIR/pull-fails" ] && exit 1 ;;
esac
exit 0
EOF
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
export SLEEPOVERR_ARCH=amd64

reset_stub() {
  rm -rf "${STUB:?}"/* "$STUB_LOG"
  : >"$STUB_LOG"
  STUB_USED=""
  export STUB_USED
}

# ------------------------------------------------------------------ host script

section "host: --test-env install (guest 1000, 2 cores, 4 GB)"
reset_stub
echo 'fake ctl' >"$T/ctl-copy.sh"
cp "$CTL" "$T/ctl-copy.sh"
out="$T/out1.txt"
SLEEPOVERR_CTL_FILE="$T/ctl-copy.sh" IGDB_CLIENT_ID=abc IGDB_CLIENT_SECRET='s3cr=et' TZ=Europe/Lisbon \
  bash "$HOST" install --test-env -y >"$out" 2>&1
assert_rc 0 $? "install --test-env"
assert_contains "$STUB_LOG" "pct create 1000 local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst"
assert_contains "$STUB_LOG" "--cores 2"
assert_contains "$STUB_LOG" "--memory 4096"
assert_contains "$STUB_LOG" "--features nesting=1,keyctl=1"
assert_contains "$STUB_LOG" "--unprivileged 1"
assert_contains "$STUB_LOG" "--rootfs local-lvm:20"
assert_contains "$STUB_LOG" "--tags sleepoverr;test"
assert_contains "$STUB_LOG" "--net0 name=eth0,bridge=vmbr0,ip=dhcp,firewall=0"
assert_contains "$STUB_LOG" "pveam download local debian-13-standard_13.1-1_amd64.tar.zst"
assert_contains "$STUB_LOG" "pct push 1000 "
assert_contains "$STUB_LOG" "/usr/local/bin/sleepoverr-ctl --perms 0755"
assert_contains "$STUB_LOG" "/root/sleepoverr-install.env --perms 0600"
assert_contains "$STUB_LOG" "SLEEPOVERR_PROFILE=test"
assert_contains "$STUB_LOG" "/usr/local/bin/sleepoverr-ctl install"
assert_before "$STUB_LOG" "pct create 1000" "pct start 1000"
assert_before "$STUB_LOG" "pct start 1000" "sleepoverr-ctl --perms 0755"
assert_before "$STUB_LOG" "sleepoverr-ctl --perms 0755" "sleepoverr-ctl install"
assert_contains "$STUB_DIR/pushed-sleepoverr-install.env" "IGDB_CLIENT_ID=abc"
assert_contains "$STUB_DIR/pushed-sleepoverr-install.env" "IGDB_CLIENT_SECRET=s3cr=et"
assert_contains "$STUB_DIR/pushed-sleepoverr-install.env" "TZ=Europe/Lisbon"
assert_not_contains "$STUB_DIR/pushed-sleepoverr-install.env" "ROMM"
assert_not_contains "$STUB_LOG" "IGDB_CLIENT_SECRET" # secrets travel in the pushed file, not on a command line
assert_contains "$out" "192.168.1.77"

section "host: the template matches the host architecture (never the other one)"
assert_not_contains "$STUB_LOG" "arm64"
reset_stub
SLEEPOVERR_ARCH=arm64 SLEEPOVERR_CTL_FILE="$T/ctl-copy.sh" bash "$HOST" install --test-env -y >"$out" 2>&1
assert_rc 0 $? "arm64 host install"
assert_contains "$STUB_LOG" "pveam download local debian-13-standard_13.6-1_arm64.tar.zst"
assert_not_contains "$STUB_LOG" "_amd64"
reset_stub
SLEEPOVERR_ARCH=riscv64 SLEEPOVERR_CTL_FILE="$T/ctl-copy.sh" bash "$HOST" install --test-env -y >"$out" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then pass; else fail "an architecture without templates should fail"; fi
assert_contains "$out" "for riscv64"
assert_not_contains "$STUB_LOG" "pct create"

section "host: refuses an ID that is already used"
reset_stub
STUB_USED="1000"
export STUB_USED
SLEEPOVERR_CTL_FILE="$T/ctl-copy.sh" bash "$HOST" install --test-env -y >"$out" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then pass; else fail "install on a used ID should fail"; fi
assert_not_contains "$STUB_LOG" "pct create"
assert_contains "$out" "already used"

section "host: production install with static IP, defaults, RomM settings"
reset_stub
touch "$STUB_DIR/template-present"
SLEEPOVERR_CTL_FILE="$T/ctl-copy.sh" CT_IP=192.168.1.50/24 CT_GW=192.168.1.1 CT_VLAN=20 \
  ROMM_URL=http://romm.lan:8080 ROMM_API_TOKEN=rmm_x \
  bash "$HOST" install -y >"$out" 2>&1
assert_rc 0 $? "install"
assert_contains "$STUB_LOG" "pct create 100 "
assert_contains "$STUB_LOG" "--memory 2048"
assert_contains "$STUB_LOG" "--tags sleepoverr;prod"
assert_contains "$STUB_LOG" "ip=192.168.1.50/24,firewall=0,gw=192.168.1.1,tag=20"
assert_not_contains "$STUB_LOG" "pveam download"
assert_contains "$STUB_DIR/pushed-sleepoverr-install.env" "ROMM_URL=http://romm.lan:8080"
assert_contains "$STUB_DIR/pushed-sleepoverr-install.env" "ROMM_API_TOKEN=rmm_x"
assert_contains "$STUB_LOG" "SLEEPOVERR_PROFILE=prod"

section "host: input validation"
reset_stub
SLEEPOVERR_CTL_FILE="$T/ctl-copy.sh" CT_IP=300.1/24 bash "$HOST" install -y >"$out" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then pass; else fail "a static IP without gateway should fail"; fi
SLEEPOVERR_CTL_FILE="$T/ctl-copy.sh" CT_CORES=two bash "$HOST" install -y >"$out" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then pass; else fail "non-numeric cores should fail"; fi
assert_not_contains "$STUB_LOG" "pct create"

section "host: a storage name that does not exist is rejected before anything is downloaded or created"
reset_stub
SLEEPOVERR_CTL_FILE="$T/ctl-copy.sh" CT_STORAGE=10 bash "$HOST" install --test-env -y >"$out" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then pass; else fail "CT_STORAGE=10 should be rejected"; fi
assert_contains "$out" "'10' is not a storage"
assert_contains "$out" "Available: local local-lvm"
assert_not_contains "$STUB_LOG" "pveam download"
assert_not_contains "$STUB_LOG" "pct create"
reset_stub
SLEEPOVERR_CTL_FILE="$T/ctl-copy.sh" CT_TEMPLATE_STORAGE=nope bash "$HOST" install --test-env -y >"$out" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then pass; else fail "an unknown template storage should be rejected"; fi
assert_not_contains "$STUB_LOG" "pct create"

section "host: a container that fails to start is reported with debug steps and nothing is installed"
reset_stub
touch "$STUB_DIR/start-fails"
SLEEPOVERR_CTL_FILE="$T/ctl-copy.sh" bash "$HOST" install --test-env -y >"$out" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then pass; else fail "a failed start should fail the install"; fi
assert_contains "$out" "did not start"
assert_contains "$out" "pct start 1000 --debug"
assert_not_contains "$STUB_LOG" "pct push"

section "host: --dry-run changes nothing"
reset_stub
SLEEPOVERR_CTL_FILE="$T/ctl-copy.sh" bash "$HOST" install --test-env -y --dry-run >"$out" 2>&1
assert_rc 0 $? "dry run"
assert_not_contains "$STUB_LOG" "pct create"
assert_not_contains "$STUB_LOG" "pct start"
assert_contains "$out" "[dry-run] pct create 1000"

section "host: update takes a snapshot, prunes old ones, then updates"
reset_stub
printf '100 running sleepoverr\n200 running other\n' >"$STUB_DIR/cts"
printf 'hostname: sleepoverr\ntags: sleepoverr;prod\n' >"$STUB_DIR/config-100"
printf 'hostname: other\ntags: web\n' >"$STUB_DIR/config-200"
{
  for d in 01 02 03 04 05; do printf '`-> sleepoverr-pre-update-202611%s-120000 2026-11-%s 12:00:00 before\n' "$d" "$d"; done
  echo '`-> current You are here!'
} >"$STUB_DIR/snapshots"
bash "$HOST" update -y >"$out" 2>&1
assert_rc 0 $? "update"
assert_contains "$STUB_LOG" "pct snapshot 100 sleepoverr-pre-update-"
assert_contains "$STUB_LOG" "pct delsnapshot 100 sleepoverr-pre-update-20261101-120000"
assert_contains "$STUB_LOG" "pct delsnapshot 100 sleepoverr-pre-update-20261102-120000"
assert_not_contains "$STUB_LOG" "pct delsnapshot 100 sleepoverr-pre-update-20261103-120000"
assert_contains "$STUB_LOG" "pct exec 100 -- env /usr/local/bin/sleepoverr-ctl update"
assert_before "$STUB_LOG" "pct snapshot 100" "pct exec 100 -- env"

section "host: update refuses a container that is not Sleepoverr's"
reset_stub
printf 'hostname: other\ntags: web\n' >"$STUB_DIR/config-200"
bash "$HOST" update 200 -y >"$out" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then pass; else fail "update of a foreign container should fail"; fi
assert_not_contains "$STUB_LOG" "pct snapshot"
assert_not_contains "$STUB_LOG" "pct exec"

section "host: update of the test container skips the snapshot; a failed snapshot only warns"
reset_stub
printf 'hostname: sleepoverr-test\ntags: sleepoverr;test\n' >"$STUB_DIR/config-1000"
bash "$HOST" update 1000 -y >"$out" 2>&1
assert_rc 0 $? "update test ct"
assert_not_contains "$STUB_LOG" "pct snapshot"
assert_contains "$STUB_LOG" "pct exec 1000 -- env /usr/local/bin/sleepoverr-ctl update"
reset_stub
printf 'hostname: sleepoverr\ntags: sleepoverr;prod\n' >"$STUB_DIR/config-100"
touch "$STUB_DIR/snapshot-fails"
bash "$HOST" update 100 -y >"$out" 2>&1
assert_rc 0 $? "update with failing snapshot"
assert_contains "$out" "Could not snapshot"
assert_contains "$STUB_LOG" "sleepoverr-ctl update"

# ------------------------------------------------------------------ ctl script: functions

section "ctl: helpers"
export SLEEPOVERR_DIR="$T/opt" SLEEPOVERR_BACKUP_DIR="$T/backups" SLEEPOVERR_CONF="$T/ctl.conf" \
  SLEEPOVERR_INSTALL_ENV="$T/install.env" SLEEPOVERR_CTL_PATH="$T/bin/sleepoverr-ctl"
mkdir -p "$SLEEPOVERR_DIR" "$SLEEPOVERR_BACKUP_DIR"

got="$( (
  SLEEPOVERR_REPO=Some-Owner/Sleepoverr SLEEPOVERR_TAG=v1.2.3
  # shellcheck source=/dev/null
  source "$CTL"
  image_ref
) )"
assert_eq "ghcr.io/some-owner/sleepoverr:v1.2.3" "$got" "image_ref lowercases the owner"

printf 'SLEEPOVERR_REF=from-conf\nSLEEPOVERR_TAG=conf-tag\nNOT_ALLOWED=x\n' >"$SLEEPOVERR_CONF"
got="$( (
  SLEEPOVERR_TAG=from-env
  # shellcheck source=/dev/null
  source "$CTL"
  load_conf
  echo "$SLEEPOVERR_REF $SLEEPOVERR_TAG ${NOT_ALLOWED:-unset}"
) )"
assert_eq "from-conf from-env unset" "$got" "load_conf: env beats conf, conf beats default, other keys ignored"
rm -f "$SLEEPOVERR_CONF"

section "ctl: .env creation"
rm -rf "$SLEEPOVERR_DIR" && mkdir -p "$SLEEPOVERR_DIR"
printf 'IGDB_CLIENT_ID=id=with=equals\nIGDB_CLIENT_SECRET=sec\nEVIL=$(touch %s/pwned)\nROMM_URL=http://r:1\n' "$T" >"$SLEEPOVERR_INSTALL_ENV"
(
  # shellcheck source=/dev/null
  source "$CTL"
  load_conf
  read_install_env
  write_env
) >/dev/null 2>&1
envf="$SLEEPOVERR_DIR/.env"
assert_contains "$envf" "IGDB_CLIENT_ID=id=with=equals"
assert_contains "$envf" "ROMM_URL=http://r:1"
assert_contains "$envf" "# STEAM_API_KEY="
assert_contains "$envf" "# ROMM_API_TOKEN="
assert_not_contains "$envf" "EVIL"
[[ -e "$T/pwned" ]] && fail "install env values must never be evaluated" || pass
[[ -e $SLEEPOVERR_INSTALL_ENV ]] && fail "install env file should be removed after reading" || pass
assert_eq "600" "$(stat -c %a "$envf" 2>/dev/null || stat -f %Lp "$envf")" ".env permissions"
jwt="$(sed -n 's/^JWT_SECRET_KEY=//p' "$envf")"
[[ $jwt =~ ^[0-9a-f]{64}$ ]] && pass || fail "JWT_SECRET_KEY should be 64 hex chars, got '$jwt'"
code="$(sed -n 's/^SETUP_CODE=//p' "$envf")"
[[ $code =~ ^[0-9a-f]{12}$ ]] && pass || fail "SETUP_CODE should be 12 hex chars, got '$code'"
before="$(cat "$envf")"
( # shellcheck source=/dev/null
  source "$CTL"
  load_conf
  IGDB_CLIENT_ID=other write_env
) >/dev/null 2>&1
assert_eq "$before" "$(cat "$envf")" "write_env must not overwrite an existing .env"

section "ctl: set_env_value keeps special characters"
f="$T/e.env"
printf 'A=1\nIGDB_CLIENT_ID=\nB=2\n' >"$f"
(
  # shellcheck source=/dev/null
  source "$CTL"
  set_env_value "$f" IGDB_CLIENT_ID 'a&b\c/d$e'
  set_env_value "$f" NEWKEY 'x=y'
)
assert_contains "$f" 'IGDB_CLIENT_ID=a&b\c/d$e'
assert_contains "$f" "NEWKEY=x=y"
assert_contains "$f" "A=1"

section "ctl: compose override"
(
  # shellcheck source=/dev/null
  source "$CTL"
  load_conf
  echo image >"$SLEEPOVERR_DIR/.mode"
  write_override
  cp "$SLEEPOVERR_DIR/docker-compose.override.yml" "$T/override-image.yml"
  echo source >"$SLEEPOVERR_DIR/.mode"
  write_override
  cp "$SLEEPOVERR_DIR/docker-compose.override.yml" "$T/override-source.yml"
)
assert_contains "$T/override-image.yml" "image: ghcr.io/dolcetheleche/sleepoverr:latest"
assert_not_contains "$T/override-image.yml" "build:"
assert_contains "$T/override-source.yml" "context: ./src"

section "ctl: backup retention"
rm -rf "$SLEEPOVERR_BACKUP_DIR" && mkdir -p "$SLEEPOVERR_BACKUP_DIR"
for i in 1 2 3 4 5 6 7 8; do
  touch -d "2026-11-0$i 10:00" "$SLEEPOVERR_BACKUP_DIR/sleepoverr-2026110$i-100000.tar.gz"
done
touch "$SLEEPOVERR_BACKUP_DIR/unrelated.txt"
(
  # shellcheck source=/dev/null
  source "$CTL"
  load_conf
  prune_backups
)
assert_eq "5" "$(find "$SLEEPOVERR_BACKUP_DIR" -name 'sleepoverr-*.tar.gz' | wc -l | tr -d ' ')" "5 backups are kept"
[[ -e "$SLEEPOVERR_BACKUP_DIR/sleepoverr-20261108-100000.tar.gz" && ! -e "$SLEEPOVERR_BACKUP_DIR/sleepoverr-20261101-100000.tar.gz" ]] && pass || fail "the newest are kept, the oldest removed"
[[ -e "$SLEEPOVERR_BACKUP_DIR/unrelated.txt" ]] && pass || fail "unrelated files are left alone"

# ------------------------------------------------------------------ ctl script: commands

setup_installed() {
  reset_stub
  rm -rf "$SLEEPOVERR_DIR" "$SLEEPOVERR_BACKUP_DIR" "$T/raw" "$T/ctl.conf"
  mkdir -p "$SLEEPOVERR_DIR" "$SLEEPOVERR_BACKUP_DIR" "$T/raw/deploy/proxmox"
  echo image >"$SLEEPOVERR_DIR/.mode"
  printf 'JWT_SECRET_KEY=x\nSETUP_CODE=abc\n' >"$SLEEPOVERR_DIR/.env"
  printf 'services:\n  app:\n    image: placeholder\n' >"$T/raw/docker-compose.yml"
  cp "$T/raw/docker-compose.yml" "$SLEEPOVERR_DIR/docker-compose.yml"
  cp "$CTL" "$T/raw/deploy/proxmox/sleepoverr-ctl.sh"
  cp "$CTL" "$SLEEPOVERR_CTL_PATH"
  chmod +x "$SLEEPOVERR_CTL_PATH"
  export SLEEPOVERR_RAW_ROOT="file://$T/raw"
}

section "ctl: backup stops the app, archives volumes and .env, restarts it"
setup_installed
bash "$CTL" backup >"$out" 2>&1
assert_rc 0 $? "backup"
assert_contains "$STUB_LOG" "stop app"
assert_contains "$STUB_LOG" "sleepoverr_db-data:/data/db:ro"
assert_contains "$STUB_LOG" "sleepoverr_uploads-data:/data/uploads:ro"
assert_contains "$STUB_LOG" "$SLEEPOVERR_DIR/.env:/data/env:ro"
assert_contains "$STUB_LOG" "czf /backup/sleepoverr-"
assert_contains "$STUB_LOG" "db uploads env"
assert_before "$STUB_LOG" "stop app" "czf /backup/"
assert_before "$STUB_LOG" "czf /backup/" "start app"
assert_eq "1" "$(find "$SLEEPOVERR_BACKUP_DIR" -name 'sleepoverr-*.tar.gz' | wc -l | tr -d ' ')" "one archive written"
assert_eq "600" "$(stat -c %a "$SLEEPOVERR_BACKUP_DIR"/sleepoverr-*.tar.gz 2>/dev/null || stat -f %Lp "$SLEEPOVERR_BACKUP_DIR"/sleepoverr-*.tar.gz)" "archive permissions"

section "ctl: a failing backup still restarts the app and reports the failure"
setup_installed
touch "$STUB_DIR/run-fails"
bash "$CTL" backup >"$out" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then pass; else fail "backup failure must give a non-zero exit"; fi
assert_contains "$STUB_LOG" "start app"
assert_contains "$out" "backup failed"

section "ctl: update (image mode): backup, pull, up, new image reported, old images pruned"
setup_installed
SLEEPOVERR_NO_SELF_UPDATE=1 bash "$CTL" update >"$out" 2>&1
assert_rc 0 $? "update"
assert_contains "$STUB_LOG" "pull"
assert_contains "$STUB_LOG" "up -d"
assert_contains "$STUB_LOG" "image prune -f"
assert_before "$STUB_LOG" "czf /backup/" " pull"
assert_before "$STUB_LOG" " pull" "up -d"
assert_contains "$out" "Updated to a new image"
assert_contains "$SLEEPOVERR_DIR/docker-compose.override.yml" "image: ghcr.io/dolcetheleche/sleepoverr:latest"

section "ctl: update with --no-backup skips the backup; an unchanged image says so"
setup_installed
echo sha256:new >"$STUB_DIR/image"
SLEEPOVERR_NO_SELF_UPDATE=1 bash "$CTL" update --no-backup >"$out" 2>&1
assert_rc 0 $? "update --no-backup"
assert_not_contains "$STUB_LOG" "czf /backup/"
assert_contains "$out" "Already up to date"

section "ctl: update that does not become healthy exits non-zero and says how to roll back"
setup_installed
echo unhealthy >"$STUB_DIR/state"
SLEEPOVERR_NO_SELF_UPDATE=1 bash "$CTL" update >"$out" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then pass; else fail "an unhealthy update must fail"; fi
assert_contains "$out" "sleepoverr-ctl restore"
assert_contains "$out" "pct rollback"

section "ctl: update replaces its own script, then carries on"
setup_installed
printf '\n# marker-for-self-update-test\n' >>"$T/raw/deploy/proxmox/sleepoverr-ctl.sh"
bash "$SLEEPOVERR_CTL_PATH" update --no-backup >"$out" 2>&1
assert_rc 0 $? "update with self-update"
assert_contains "$SLEEPOVERR_CTL_PATH" "marker-for-self-update-test"
assert_contains "$out" "Updating sleepoverr-ctl itself"
assert_contains "$STUB_LOG" " pull"

section "ctl: update when the script is already current does not re-exec"
setup_installed
bash "$SLEEPOVERR_CTL_PATH" update --no-backup >"$out" 2>&1
assert_rc 0 $? "update, current script"
assert_not_contains "$out" "Updating sleepoverr-ctl itself"

section "ctl: update refuses when nothing is installed"
setup_installed
rm -rf "$SLEEPOVERR_DIR"
SLEEPOVERR_NO_SELF_UPDATE=1 bash "$CTL" update >"$out" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then pass; else fail "update without an install must fail"; fi
assert_contains "$out" "not installed"

section "ctl: restore asks nothing with -y, replaces data, restarts"
setup_installed
echo fake >"$SLEEPOVERR_BACKUP_DIR/sleepoverr-20261101-100000.tar.gz"
bash "$CTL" restore -y sleepoverr-20261101-100000.tar.gz >"$out" 2>&1
assert_rc 0 $? "restore"
assert_contains "$STUB_LOG" "stop app"
assert_contains "$STUB_LOG" "sleepoverr_db-data:/data/db"
assert_contains "$STUB_LOG" "tar xzf '/backup/sleepoverr-20261101-100000.tar.gz' -C /data db uploads"
assert_before "$STUB_LOG" "stop app" "tar xzf"
assert_before "$STUB_LOG" "tar xzf" "up -d"
bash "$CTL" restore -y missing.tar.gz >"$out" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then pass; else fail "restore of a missing file must fail"; fi

section "ctl: test profile has no backups and reads the test port"
setup_installed
printf 'SLEEPOVERR_PROFILE=test\n' >"$SLEEPOVERR_CONF"
bash "$CTL" backup >"$out" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then pass; else fail "backup must be refused in the test profile"; fi
assert_contains "$out" "disposable"
mkdir -p "$SLEEPOVERR_DIR/src/dev"
printf 'SLEEPOVERR_PORT=8123\nSETUP_CODE=tc1\n' >"$SLEEPOVERR_DIR/src/dev/.env.test"
got="$(bash "$CTL" setup-code 2>&1)"
assert_eq "tc1" "$got" "setup-code in the test profile"
got="$( (
  # shellcheck source=/dev/null
  source "$CTL"
  load_conf
  test_port
) )"
assert_eq "8123" "$got" "test_port reads dev/.env.test"
rm -f "$SLEEPOVERR_CONF"

section "ctl: unknown command and help"
bash "$CTL" nonsense >"$out" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then pass; else fail "unknown commands must fail"; fi
bash "$CTL" help >"$out" 2>&1
assert_contains "$out" "sleepoverr-ctl update"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
