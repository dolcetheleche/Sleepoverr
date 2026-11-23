#!/bin/sh
# Sleepoverr test environment helper. POSIX sh. See dev/README.md.
#
#   dev/test-env.sh init [-f]     create dev/.env.test (random secrets) + placeholder library
#   dev/test-env.sh up            start sleepoverr + mock-romm
#   dev/test-env.sh up-real       also start a real, throwaway RomM (profile real-romm)
#   dev/test-env.sh down          stop everything (keeps volumes/data)
#   dev/test-env.sh restart [svc] restart services (e.g. after editing mock fixtures)
#   dev/test-env.sh reset [-y]    stop and DELETE volumes + dev/data (asks first unless -y)
#   dev/test-env.sh logs [svc]    follow logs
#   dev/test-env.sh status        list containers and health
#   dev/test-env.sh urls          print URLs and the mock client token
#   dev/test-env.sh test-mock     run the mock-romm pytest suite (local python or container)
set -eu

DEV_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPOSE_FILE="$DEV_DIR/docker-compose.test.yml"
ENV_FILE="$DEV_DIR/.env.test"
ENV_EXAMPLE="$DEV_DIR/.env.test.example"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '%s\n' "$*"
}

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

# --- docker compose detection ------------------------------------------------------------
COMPOSE=""
detect_compose() {
    if [ -n "$COMPOSE" ]; then
        return 0
    fi
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        COMPOSE="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE="docker-compose"
    else
        die "neither 'docker compose' (v2 plugin) nor 'docker-compose' was found. Install Docker Engine + the compose plugin: https://docs.docker.com/engine/install/"
    fi
}

require_env() {
    [ -f "$ENV_FILE" ] || die "$ENV_FILE not found - run '$0 init' first."
}

dc() {
    detect_compose
    require_env
    # $COMPOSE is intentionally unquoted: it is either "docker compose" or "docker-compose".
    # shellcheck disable=SC2086
    $COMPOSE -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

# Same, with the real-romm profile enabled, so down/logs/status also cover romm + romm-db.
dc_all() {
    dc --profile real-romm "$@"
}

# --- secrets -------------------------------------------------------------------------------
rand_hex() { # $1 = number of random bytes
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$1"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import secrets, sys; print(secrets.token_hex(int(sys.argv[1])))" "$1"
    else
        die "need openssl or python3 to generate secrets"
    fi
}

env_get() { # $1 = variable name; prints its value from .env.test (last match wins)
    sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1
}

cmd_init() {
    force=0
    [ "${1:-}" = "-f" ] && force=1
    [ -f "$ENV_EXAMPLE" ] || die "$ENV_EXAMPLE is missing"
    if [ -f "$ENV_FILE" ] && [ "$force" -ne 1 ]; then
        info "$ENV_FILE already exists - keeping it (use 'init -f' to regenerate all secrets)."
    else
        tmp="$ENV_FILE.tmp.$$"
        umask 077
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                *=__GENERATE_RMM__) printf '%s=rmm_%s\n' "${line%%=*}" "$(rand_hex 32)" ;;
                *=__GENERATE__) printf '%s=%s\n' "${line%%=*}" "$(rand_hex 32)" ;;
                *) printf '%s\n' "$line" ;;
            esac
        done <"$ENV_EXAMPLE" >"$tmp"
        mv "$tmp" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        info "Created $ENV_FILE with fresh random secrets (gitignored - do not commit it)."
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 "$DEV_DIR/seed/make_placeholder_roms.py"
    else
        info "warning: python3 not found - skipped the placeholder library (only needed for up-real)."
    fi
}

cmd_reset() {
    if [ "${1:-}" != "-y" ]; then
        printf 'This stops the test stack and DELETES its volumes (Sleepoverr test DB, RomM DB/resources) and %s. Continue? [y/N] ' "$DEV_DIR/data"
        read -r answer || answer=""
        case "$answer" in
            y | Y | yes | YES) ;;
            *)
                info "Aborted."
                return 0
                ;;
        esac
    fi
    dc_all down -v --remove-orphans
    rm -rf -- "$DEV_DIR/data"
    info "Reset done. Run '$0 init' to recreate the placeholder library."
}

cmd_urls() {
    require_env
    host="localhost"
    if command -v hostname >/dev/null 2>&1; then
        lan=$(hostname -I 2>/dev/null | awk '{print $1}') || lan=""
        [ -n "$lan" ] && host="$lan"
    fi
    sp=$(env_get SLEEPOVERR_PORT)
    mp=$(env_get MOCK_ROMM_PORT)
    rp=$(env_get ROMM_PORT_TEST)
    info "Sleepoverr:         http://$host:${sp:-8000}/   (health: /healthz)"
    info "Mock RomM API:      http://$host:${mp:-8081}/api/heartbeat   docs: http://$host:${mp:-8081}/api/docs"
    info "Real RomM (opt.):   http://$host:${rp:-8082}/   (only with 'up-real')"
    info ""
    info "Mock user/password: $(env_get MOCK_ROMM_USER) / $(env_get MOCK_ROMM_PASSWORD)"
    info "Mock client token:  $(env_get MOCK_ROMM_CLIENT_TOKEN)"
    info "Sleepoverr SETUP_CODE (first-run admin form): $(env_get SETUP_CODE)"
    info ""
    info "Try:  curl -H \"Authorization: Bearer \$TOKEN\" 'http://$host:${mp:-8081}/api/roms?limit=5'"
}

cmd_test_mock() {
    mock="$DEV_DIR/mock-romm"
    for py in "$mock/.venv/bin/python" "${VIRTUAL_ENV:+$VIRTUAL_ENV/bin/python}" python3; do
        [ -n "$py" ] || continue
        if command -v "$py" >/dev/null 2>&1 &&
            "$py" -c "import fastapi, jwt, multipart, pytest, respx" >/dev/null 2>&1; then
            info "Running mock-romm tests with $py"
            cd "$mock" && exec "$py" -m pytest -q
        fi
    done
    command -v docker >/dev/null 2>&1 ||
        die "no local python with the mock's dev deps (pip install -r dev/mock-romm/requirements-dev.txt) and no docker"
    info "No suitable local python - running the tests in a python:3.12-slim container."
    exec docker run --rm -e PYTHONDONTWRITEBYTECODE=1 -v "$mock:/src:ro" -w /src python:3.12-slim \
        sh -c "pip install -q --root-user-action=ignore -r requirements-dev.txt && python -m pytest -q -p no:cacheprovider"
}

main() {
    cmd="${1:-help}"
    [ $# -gt 0 ] && shift
    case "$cmd" in
        init) cmd_init "$@" ;;
        up) dc up -d --build "$@" && cmd_urls ;;
        up-real) dc_all up -d --build "$@" && cmd_urls ;;
        down) dc_all down --remove-orphans "$@" ;;
        restart) dc_all restart "$@" ;;
        reset) cmd_reset "$@" ;;
        logs) dc_all logs -f --tail=200 "$@" ;;
        status | ps) dc_all ps "$@" ;;
        urls) cmd_urls ;;
        test-mock) cmd_test_mock ;;
        help | -h | --help) usage ;;
        *)
            usage >&2
            die "unknown command: $cmd"
            ;;
    esac
}

main "$@"
