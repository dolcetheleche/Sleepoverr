#!/usr/bin/env bash
# sleepoverr-ctl: installs, updates and backs up Sleepoverr on the machine it runs on.
#
# Normally it runs INSIDE the LXC that deploy/proxmox/sleepoverr.sh creates on your Proxmox
# host (installed there as /usr/local/bin/sleepoverr-ctl). It also works as-is on any
# Debian/Ubuntu machine or VM where you are root.
#
#   sleepoverr-ctl install        first install (Docker, compose file, .env, start)
#   sleepoverr-ctl update         back up, update this script, pull/build the new version, restart
#   sleepoverr-ctl backup         stop briefly, archive the data volumes and .env, start again
#   sleepoverr-ctl restore FILE   put a backup's data back (asks first; -y skips the question)
#   sleepoverr-ctl status | logs | restart | setup-code | version | self-update | help
#   sleepoverr-ctl reset          (test profile only) delete the test data and start over
#
# SLEEPOVERR_PROFILE=test installs the test environment instead (Sleepoverr built from source
# plus a mock RomM, see dev/README.md): no backups, data is disposable.

set -Eeuo pipefail

CTL_VERSION="0.1.0"

CONF_FILE="${SLEEPOVERR_CONF:-/etc/sleepoverr-ctl.conf}"
APP_DIR="${SLEEPOVERR_DIR:-/opt/sleepoverr}"
BACKUP_DIR="${SLEEPOVERR_BACKUP_DIR:-/var/backups/sleepoverr}"
KEEP_BACKUPS="${SLEEPOVERR_KEEP_BACKUPS:-5}"
INSTALL_ENV="${SLEEPOVERR_INSTALL_ENV:-/root/sleepoverr-install.env}"
SELF_PATH="${SLEEPOVERR_CTL_PATH:-/usr/local/bin/sleepoverr-ctl}"
CONTAINER="sleepoverr"
# Compose project name is fixed to "sleepoverr" by docker-compose.yml, so volumes are these.
VOL_DB="sleepoverr_db-data"
VOL_UPLOADS="sleepoverr_uploads-data"

info() { printf '\033[1;34m[..]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31m[xx]\033[0m %s\n' "$*" >&2
  exit 1
}

# Settings come from, in order of priority: the environment, /etc/sleepoverr-ctl.conf (written
# at install), built-in defaults. Only SLEEPOVERR_* keys are read from the file, as plain text.
load_conf() {
  local key value
  if [[ -f $CONF_FILE ]]; then
    while IFS='=' read -r key value; do
      if [[ $key =~ ^SLEEPOVERR_[A-Z_]+$ && -z ${!key:-} ]]; then
        printf -v "$key" '%s' "$value"
        export "${key?}"
      fi
    done <"$CONF_FILE"
  fi
  : "${SLEEPOVERR_REPO:=dolcetheleche/Sleepoverr}"
  : "${SLEEPOVERR_REF:=master}"
  : "${SLEEPOVERR_TAG:=latest}"
: "${SLEEPOVERR_PROFILE:=prod}"
  : "${SLEEPOVERR_RAW_ROOT:=https://raw.githubusercontent.com/${SLEEPOVERR_REPO}/${SLEEPOVERR_REF}}"
  return 0
}

need_root() { [[ $(id -u) -eq 0 ]] || die "Run this as root."; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ghcr.io/<lowercased owner>/sleepoverr:<tag>, the name release.yml publishes under.
image_ref() { printf 'ghcr.io/%s/sleepoverr:%s' "$(lower "${SLEEPOVERR_REPO%%/*}")" "$SLEEPOVERR_TAG"; }

# Wrapper so every compose call uses the same files.
compose() {
  docker compose --project-directory "$APP_DIR" \
    -f "$APP_DIR/docker-compose.yml" -f "$APP_DIR/docker-compose.override.yml" "$@"
}

app_mode() { cat "$APP_DIR/.mode" 2>/dev/null || echo image; }

container_status() {
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
    "$CONTAINER" 2>/dev/null || echo missing
}

wait_healthy() {
  local waited=0 limit="${1:-180}" state
  info "Waiting for Sleepoverr to report healthy (up to ${limit}s)..."
  while ((waited < limit)); do
    state="$(container_status)"
    case "$state" in
      healthy | running)
        # "running" only appears when the image defines no healthcheck.
        ok "Sleepoverr is up ($state)."
        return 0
        ;;
      unhealthy | exited | dead | missing)
        warn "Container state: $state"
        docker logs --tail 40 "$CONTAINER" 2>&1 || true
        return 1
        ;;
    esac
    sleep 3
    waited=$((waited + 3))
  done
  warn "Timed out waiting for Sleepoverr (last state: $(container_status))."
  docker logs --tail 40 "$CONTAINER" 2>&1 || true
  return 1
}

fetch() { curl -fsSL --retry 3 --connect-timeout 15 -o "$2" "$1"; }

# ---------------------------------------------------------------------------- install

install_prereqs() {
  info "Installing base packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg openssl git tar >/dev/null
  if [[ $SLEEPOVERR_PROFILE == test ]]; then
    apt-get install -y -qq python3 >/dev/null # dev/test-env.sh init uses it for the placeholder library
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker with the compose plugin is already installed."
  else
    info "Installing Docker from Docker's apt repository..."
    local distro codename
    distro="$(. /etc/os-release && echo "$ID")"
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    [[ $distro == debian || $distro == ubuntu ]] || die "Only Debian and Ubuntu are supported (found: $distro)."
    install -m 0755 -d /etc/apt/keyrings
    fetch "https://download.docker.com/linux/${distro}/gpg" /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
      "$(dpkg --print-architecture)" "$distro" "$codename" >/etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
  fi
  # Keep container logs from filling a small container disk.
  if [[ ! -f /etc/docker/daemon.json ]]; then
    install -d /etc/docker
    printf '{\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "10m", "max-file": "3" }\n}\n' \
      >/etc/docker/daemon.json
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker info >/dev/null 2>&1 || die "Docker does not run here. In an LXC the container needs the options nesting=1 and keyctl=1 (Options -> Features in the Proxmox UI), and an unprivileged container on a recent kernel."
}

fetch_compose() {
  info "Fetching docker-compose.yml (${SLEEPOVERR_REPO}@${SLEEPOVERR_REF})..."
  local tmp
  tmp="$(mktemp)"
  if fetch "${SLEEPOVERR_RAW_ROOT}/docker-compose.yml" "$tmp"; then
    if [[ -f $APP_DIR/docker-compose.yml ]] && ! cmp -s "$tmp" "$APP_DIR/docker-compose.yml"; then
      info "docker-compose.yml changed upstream; replacing it."
    fi
    install -m 0644 "$tmp" "$APP_DIR/docker-compose.yml"
    rm -f "$tmp"
  else
    rm -f "$tmp"
    [[ -f $APP_DIR/docker-compose.yml ]] || die "Could not download docker-compose.yml and none exists yet."
    warn "Could not download docker-compose.yml; keeping the current one."
  fi
}

# Writes the compose override that pins the image name (so forks work) and, in source mode,
# builds from the checked-out source.
write_override() {
  {
    printf 'services:\n  app:\n    image: %s\n' "$(image_ref)"
    if [[ $(app_mode) == source ]]; then
      printf '    build:\n      context: ./src\n      dockerfile: Dockerfile\n'
    fi
  } >"$APP_DIR/docker-compose.override.yml"
}

# Reads KEY=VALUE lines the host script pushed, literally (never sourced or evaluated).
read_install_env() {
  [[ -f $INSTALL_ENV ]] || return 0
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      IGDB_CLIENT_ID | IGDB_CLIENT_SECRET | ROMM_URL | ROMM_API_TOKEN | STEAM_API_KEY | TZ | APP_PORT)
        printf -v "$key" '%s' "${value%$'\r'}"
        export "${key?}"
        ;;
    esac
  done <"$INSTALL_ENV"
  rm -f "$INSTALL_ENV"
  return 0
}

env_line() { # env_line KEY VALUE -> "KEY=VALUE", or a commented placeholder when VALUE is empty
  if [[ -n ${2:-} ]]; then printf '%s=%s\n' "$1" "$2"; else printf '# %s=\n' "$1"; fi
}

write_env() {
  local file="$APP_DIR/.env"
  if [[ -f $file ]]; then
    ok ".env already exists; leaving your settings and secrets as they are."
    return 0
  fi
  info "Creating .env with fresh secrets..."
  (
    umask 077
    {
      printf '# Created by sleepoverr-ctl on %s. Edit, then run: sleepoverr-ctl restart\n' "$(date -u +%FT%TZ)"
      printf 'JWT_SECRET_KEY=%s\n' "$(openssl rand -hex 32)"
      printf '# Code asked for by the first-run "create admin" form: sleepoverr-ctl setup-code\n'
      printf 'SETUP_CODE=%s\n' "$(openssl rand -hex 6)"
      env_line IGDB_CLIENT_ID "${IGDB_CLIENT_ID:-}"
      env_line IGDB_CLIENT_SECRET "${IGDB_CLIENT_SECRET:-}"
      env_line STEAM_API_KEY "${STEAM_API_KEY:-}"
      printf '# RomM sync settings (read once the RomM module ships; harmless until then)\n'
      env_line ROMM_URL "${ROMM_URL:-}"
      env_line ROMM_API_TOKEN "${ROMM_API_TOKEN:-}"
      env_line TZ "${TZ:-}"
      env_line APP_PORT "${APP_PORT:-}"
    } >"$file"
  )
  chmod 600 "$file"
}

choose_mode() {
  local mode="${SLEEPOVERR_MODE:-auto}"
  case "$mode" in
    image | source) ;;
    auto)
      info "Trying to pull $(image_ref)..."
      if docker pull "$(image_ref)" >/dev/null 2>&1; then
        mode=image
      else
        warn "No pullable image yet (not released, or the package is private); building from source instead."
        mode=source
      fi
      ;;
    *) die "SLEEPOVERR_MODE must be image, source or auto (got: $mode)." ;;
  esac
  printf '%s\n' "$mode" >"$APP_DIR/.mode"
}

sync_source() {
  local url="https://github.com/${SLEEPOVERR_REPO}.git"
  if [[ -d $APP_DIR/src/.git ]]; then
    info "Updating source checkout (${SLEEPOVERR_REF})..."
    git -C "$APP_DIR/src" fetch --depth 1 origin "$SLEEPOVERR_REF"
    git -C "$APP_DIR/src" reset --hard FETCH_HEAD
  else
    info "Cloning ${url} (${SLEEPOVERR_REF})..."
    git clone --depth 1 --branch "$SLEEPOVERR_REF" "$url" "$APP_DIR/src"
  fi
}

save_conf() {
  {
    printf 'SLEEPOVERR_REPO=%s\n' "$SLEEPOVERR_REPO"
    printf 'SLEEPOVERR_REF=%s\n' "$SLEEPOVERR_REF"
    printf 'SLEEPOVERR_TAG=%s\n' "$SLEEPOVERR_TAG"
    printf 'SLEEPOVERR_PROFILE=%s\n' "$SLEEPOVERR_PROFILE"
  } >"$CONF_FILE"
}

install_self() {
  # Keep a copy at SELF_PATH when running from somewhere else (e.g. curl | bash on a plain VM).
  if [[ -f ${BASH_SOURCE[0]} && $(readlink -f "${BASH_SOURCE[0]}") != "$(readlink -f "$SELF_PATH" 2>/dev/null || echo)" ]]; then
    install -m 0755 "${BASH_SOURCE[0]}" "$SELF_PATH"
  fi
}

host_url() {
  local ip port
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  port="$(grep -E '^APP_PORT=' "$APP_DIR/.env" 2>/dev/null | cut -d= -f2 || true)"
  printf 'http://%s:%s' "${ip:-<this-machine>}" "${port:-8000}"
}

# ---------------------------------------------------------------------------- test profile

# Runs dev/test-env.sh (from the repo checkout) with the given arguments.
te() { (cd "$APP_DIR/src" && sh ./dev/test-env.sh "$@"); }

# set_env_value FILE KEY VALUE: replace KEY=... in FILE (or append it). Values are passed through
# the environment so no character in them is treated as escape or pattern syntax.
set_env_value() {
  local file="$1" tmp
  tmp="$(mktemp)"
  KEY="$2" VAL="$3" awk 'BEGIN { FS = OFS = "="; k = ENVIRON["KEY"]; v = ENVIRON["VAL"] }
    $1 == k { print k "=" v; found = 1; next }
    { print }
    END { if (!found) print k "=" v }' "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

test_port() {
  local port
  port="$(sed -n 's/^SLEEPOVERR_PORT=//p' "$APP_DIR/src/dev/.env.test" 2>/dev/null | tail -n 1)"
  printf '%s' "${port:-8000}"
}

wait_http() { # wait_http URL [seconds]
  local waited=0 limit="${2:-180}"
  info "Waiting for $1 (up to ${limit}s)..."
  while ((waited < limit)); do
    if curl -fsS -o /dev/null --max-time 5 "$1"; then
      ok "$1 answers."
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  warn "Timed out waiting for $1"
  return 1
}

cmd_install_test() {
  need_root
  load_conf
  read_install_env
  install_prereqs
  install_docker
  install -d "$APP_DIR"
  sync_source
  te init
  # Optional IGDB credentials go into the test env file (it is gitignored, mode 600).
  local env_file="$APP_DIR/src/dev/.env.test"
  [[ -n ${IGDB_CLIENT_ID:-} ]] && set_env_value "$env_file" IGDB_CLIENT_ID "$IGDB_CLIENT_ID"
  [[ -n ${IGDB_CLIENT_SECRET:-} ]] && set_env_value "$env_file" IGDB_CLIENT_SECRET "$IGDB_CLIENT_SECRET"
  [[ -n ${TZ:-} ]] && set_env_value "$env_file" TZ "$TZ"
  save_conf
  install_self
  info "Building and starting the test environment (first build takes several minutes)..."
  te up
  wait_http "http://127.0.0.1:$(test_port)/healthz" 180 || die "Sleepoverr did not answer. Check: sleepoverr-ctl logs"
  echo
  ok "Test environment is running (Sleepoverr + mock RomM)."
  echo "   Update:  sleepoverr-ctl update       Start over:  sleepoverr-ctl reset"
  echo "   Docs:    $APP_DIR/src/dev/README.md"
}

cmd_update_test() {
  need_root
  load_conf
  [[ -d $APP_DIR/src/.git ]] || die "The test environment is not installed. Run: SLEEPOVERR_PROFILE=test sleepoverr-ctl install"
  self_update update "$@"
  sync_source
  info "Rebuilding and restarting (the test data is kept)..."
  te up
  wait_http "http://127.0.0.1:$(test_port)/healthz" 180 || die "Sleepoverr did not answer. Check: sleepoverr-ctl logs"
  ok "Test environment updated."
  cmd_version
}

is_test() { [[ $SLEEPOVERR_PROFILE == test ]]; }

cmd_install() {
  load_conf
  if is_test; then cmd_install_test; return; fi
  need_root
  read_install_env
  install_prereqs
  install_docker
  install -d "$APP_DIR" "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  fetch_compose
  write_env
  choose_mode
  [[ $(app_mode) == source ]] && sync_source
  write_override
  save_conf
  install_self
  info "Starting Sleepoverr (the first start can take a few minutes while images build or download)..."
  if [[ $(app_mode) == source ]]; then compose up -d --build; else compose up -d; fi
  wait_healthy 300 || die "Sleepoverr did not become healthy. Check: sleepoverr-ctl logs"
  echo
  ok "Sleepoverr is installed ($(app_mode) mode)."
  echo "   Open:        $(host_url)"
  echo "   Setup code:  $(grep -E '^SETUP_CODE=' "$APP_DIR/.env" | cut -d= -f2)   (asked for by the first-run admin form)"
  echo "   Settings:    $APP_DIR/.env   then: sleepoverr-ctl restart"
  echo "   Update:      sleepoverr-ctl update"
  if ! grep -qE '^IGDB_CLIENT_ID=.+' "$APP_DIR/.env"; then
    warn "IGDB credentials are not set yet. Add IGDB_CLIENT_ID and IGDB_CLIENT_SECRET to $APP_DIR/.env, then run: sleepoverr-ctl restart"
  fi
}

# ---------------------------------------------------------------------------- backup / restore

prune_backups() {
  # shellcheck disable=SC2012  # file names are generated by this script (no odd characters)
  ls -1t "$BACKUP_DIR"/sleepoverr-*.tar.gz 2>/dev/null | tail -n "+$((KEEP_BACKUPS + 1))" | xargs -r rm -f
}

cmd_backup() {
  load_conf
  if is_test; then die "No backups in the test profile: its data is disposable. Use: sleepoverr-ctl reset"; fi
  need_root
  [[ -d $APP_DIR ]] || die "Sleepoverr is not installed in $APP_DIR."
  install -d -m 700 "$BACKUP_DIR"
  local stamp dest was_running=0
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="sleepoverr-${stamp}.tar.gz"
  [[ $(container_status) == "missing" || $(container_status) == "exited" ]] || was_running=1
  info "Backing up to $BACKUP_DIR/$dest (Sleepoverr is stopped for a few seconds so the database is consistent)..."
  if ((was_running)); then compose stop app >/dev/null; fi
  local rc=0
  docker run --rm --entrypoint tar \
    -v "${VOL_DB}:/data/db:ro" -v "${VOL_UPLOADS}:/data/uploads:ro" \
    -v "$APP_DIR/.env:/data/env:ro" -v "$BACKUP_DIR:/backup" \
    "$(image_ref)" czf "/backup/$dest" -C /data db uploads env || rc=$?
  if ((was_running)); then compose start app >/dev/null || warn "Could not restart Sleepoverr; run: sleepoverr-ctl restart"; fi
  ((rc == 0)) || die "The backup failed (docker run exit code $rc). Sleepoverr was started again."
  chmod 600 "$BACKUP_DIR/$dest"
  prune_backups
  ok "Backup written: $BACKUP_DIR/$dest (keeping the newest $KEEP_BACKUPS)."
}

cmd_restore() {
  load_conf
  if is_test; then die "No backups in the test profile: its data is disposable. Use: sleepoverr-ctl reset"; fi
  need_root
  local assume_yes=0 file=""
  for arg in "$@"; do
    case "$arg" in
      -y | --yes) assume_yes=1 ;;
      *) file="$arg" ;;
    esac
  done
  [[ -n $file ]] || die "Usage: sleepoverr-ctl restore [-y] BACKUP.tar.gz"
  [[ -f $file ]] || file="$BACKUP_DIR/$file"
  [[ -f $file ]] || die "Backup not found: $file"
  file="$(readlink -f "$file")"
  if ((!assume_yes)); then
    read -r -p "This REPLACES the current Sleepoverr database and uploads with $(basename "$file"). Continue? [y/N] " reply
    [[ $reply == [yY]* ]] || die "Cancelled."
  fi
  info "Stopping Sleepoverr..."
  compose stop app >/dev/null 2>&1 || true
  docker run --rm --entrypoint sh \
    -v "${VOL_DB}:/data/db" -v "${VOL_UPLOADS}:/data/uploads" \
    -v "$(dirname "$file"):/backup:ro" \
    "$(image_ref)" -c "find /data/db /data/uploads -mindepth 1 -delete && tar xzf '/backup/$(basename "$file")' -C /data db uploads"
  compose up -d >/dev/null
  wait_healthy 180 || die "Restored the data but Sleepoverr is not healthy. Check: sleepoverr-ctl logs"
  ok "Restored from $(basename "$file"). The .env inside the archive was not applied; see: tar -xzOf <file> env"
}

# ---------------------------------------------------------------------------- update

self_update() {
  [[ -n ${SLEEPOVERR_NO_SELF_UPDATE:-} || -n ${SLEEPOVERR_SELF_UPDATED:-} ]] && return 0
  local tmp
  tmp="$(mktemp)"
  if fetch "${SLEEPOVERR_RAW_ROOT}/deploy/proxmox/sleepoverr-ctl.sh" "$tmp" && bash -n "$tmp" 2>/dev/null; then
    if ! cmp -s "$tmp" "$SELF_PATH"; then
      info "Updating sleepoverr-ctl itself..."
      install -m 0755 "$tmp" "$SELF_PATH"
      rm -f "$tmp"
      SLEEPOVERR_SELF_UPDATED=1 exec "$SELF_PATH" "$@"
    fi
  else
    warn "Could not check for a newer sleepoverr-ctl; continuing with this one."
  fi
  rm -f "$tmp"
  return 0
}

image_id() { docker inspect -f '{{.Image}}' "$CONTAINER" 2>/dev/null || echo none; }

cmd_update() {
  load_conf
  if is_test; then cmd_update_test "$@"; return; fi
  need_root
  [[ -d $APP_DIR ]] || die "Sleepoverr is not installed in $APP_DIR. Run: sleepoverr-ctl install"
  local do_backup=1 arg
  for arg in "$@"; do [[ $arg == --no-backup ]] && do_backup=0; done
  self_update update "$@"
  ((do_backup)) && cmd_backup
  fetch_compose
  write_override
  local before
  before="$(image_id)"
  if [[ $(app_mode) == source ]]; then
    sync_source
    info "Building the new image (this can take a few minutes)..."
    compose build --pull
  else
    info "Pulling $(image_ref)..."
    compose pull
  fi
  compose up -d
  if ! wait_healthy 240; then
    warn "The updated version did not become healthy. Your data backup is in $BACKUP_DIR."
    warn "Roll back the data with: sleepoverr-ctl restore <newest file in $BACKUP_DIR>"
    warn "Or restore the Proxmox snapshot taken by the host script before the update (pct rollback)."
    exit 1
  fi
  if [[ $before == "$(image_id)" ]]; then ok "Already up to date (image unchanged)."; else ok "Updated to a new image."; fi
  docker image prune -f >/dev/null 2>&1 || true
  cmd_version
}

# ---------------------------------------------------------------------------- small commands

cmd_status() {
  load_conf
  [[ -d $APP_DIR ]] || die "Sleepoverr is not installed in $APP_DIR."
  if is_test; then
    te status
    te urls
    return
  fi
  echo "State:    $(container_status)"
  echo "URL:      $(host_url)"
  echo "Mode:     $(app_mode)  (${SLEEPOVERR_REPO}@${SLEEPOVERR_REF})"
  echo "Backups:  $(find "$BACKUP_DIR" -maxdepth 1 -name 'sleepoverr-*.tar.gz' 2>/dev/null | wc -l) in $BACKUP_DIR"
  compose ps
}

cmd_logs() {
  load_conf
  if is_test; then te logs; return; fi
  compose logs -f --tail 100 app
}

cmd_restart() {
  load_conf
  if is_test; then te restart; return; fi
  compose up -d --force-recreate app
  wait_healthy 180
}

cmd_setup_code() {
  load_conf
  if is_test; then sed -n 's/^SETUP_CODE=//p' "$APP_DIR/src/dev/.env.test"; return; fi
  grep -E '^SETUP_CODE=' "$APP_DIR/.env" | cut -d= -f2
}

cmd_version() {
  load_conf
  if is_test; then
    echo "sleepoverr-ctl ${CTL_VERSION}  (${SLEEPOVERR_REPO}@${SLEEPOVERR_REF}, test profile)"
    git -C "$APP_DIR/src" log -1 --format='source: %h %s' 2>/dev/null || true
    return 0
  fi
  echo "sleepoverr-ctl ${CTL_VERSION}  (${SLEEPOVERR_REPO}@${SLEEPOVERR_REF}, $(app_mode) mode)"
  docker exec "$CONTAINER" grep -m1 '"version"' /app/package.json 2>/dev/null | sed 's/^ *//' | sed 's/^/app: /' || true
}

cmd_reset() {
  need_root
  load_conf
  is_test || die "reset only exists in the test profile (it deletes all test data)."
  te reset -y
  te init
  te up
  ok "Test environment reset and restarted."
}

cmd_help() {
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    install) cmd_install "$@" ;;
    update) cmd_update "$@" ;;
    backup) cmd_backup "$@" ;;
    restore) cmd_restore "$@" ;;
    status) cmd_status "$@" ;;
    logs) cmd_logs "$@" ;;
    restart) cmd_restart "$@" ;;
    reset) cmd_reset "$@" ;;
    setup-code) cmd_setup_code "$@" ;;
    version | --version) cmd_version "$@" ;;
    self-update)
      need_root
      load_conf
      self_update self-update
      ok "sleepoverr-ctl is current."
      ;;
    help | -h | --help) cmd_help ;;
    *) die "Unknown command: $cmd (try: sleepoverr-ctl help)" ;;
  esac
}

# Run only when executed, not when sourced (the tests source this file).
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
