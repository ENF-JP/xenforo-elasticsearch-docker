#!/usr/bin/env bash
#
# XenForo + Elasticsearch dev stack — Linux / macOS helper.
#
# Usage:  ./xf.sh <command> [args]
#         ./xf.sh help
#
# Feature-equivalent to scripts/windows/xf.ps1. Requires bash 4+ (macOS ships
# bash 3.2, so install a newer one with `brew install bash`, or run this with
# `bash ./xf.sh` after installing — the shebang picks up the newer one via env).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd -- "$SCRIPT_DIR/../../stack" && pwd)"
ENV_FILE="$STACK_DIR/.env"

RED=$'\033[31m'; YEL=$'\033[33m'; NC=$'\033[0m'

die() { printf '%s\n' "$*" >&2; exit 1; }

# ---- docker ----------------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "docker not found on PATH. See docs/platform-linux.md."

compose() { (cd "$STACK_DIR" && docker compose "$@"); }

# Runs a command in the web container as www-data unless FIRST arg is --root.
in_container() {
    local user=(-u www-data)
    if [[ "${1:-}" == "--root" ]]; then user=(); shift; fi
    compose exec -T "${user[@]}" xenforo "$@"
}

assert_running() {
    compose ps --services --filter status=running 2>/dev/null | grep -qx xenforo \
        || die "The web container is not running. Start it with: ./xf.sh up"
}

# ---- .env ------------------------------------------------------------------
env_get() {
    [[ -f "$ENV_FILE" ]] || die ".env not found at $ENV_FILE — run: ./xf.sh setup"
    # Trailing-whitespace tolerant; returns empty for an unset or blank key.
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(.*\)$/\1/p" "$ENV_FILE" | head -n1 | sed 's/[[:space:]]*$//'
}

env_set() {
    local key="$1" val="$2"
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$ENV_FILE"; then
        # -i differs between GNU and BSD/macOS sed, so write via a temp file.
        sed "s|^[[:space:]]*${key}[[:space:]]*=.*|${key}=${val}|" "$ENV_FILE" > "$ENV_FILE.tmp"
        mv "$ENV_FILE.tmp" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
    fi
}

gen_secret() {
    # Alphanumeric only: '/', '+' and '=' need escaping in .env, in connection
    # strings and in shell arguments. Not worth the trouble.
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-32}"
}

assert_no_public_bind() {
    local bad
    bad="$(docker ps --format '{{.Names}}|{{.Ports}}' | grep -E '0\.0\.0\.0:|\[::\]:' || true)"
    if [[ -n "$bad" ]]; then
        printf '%sWARNING: container ports are published on ALL interfaces:%s\n' "$RED" "$NC" >&2
        printf '%s    %s%s\n' "$RED" "$bad" "$NC" >&2
        printf '%s  Bind them to 127.0.0.1 in docker-compose.yml, then: ./xf.sh down && ./xf.sh up%s\n' "$RED" "$NC" >&2
        printf '%s  Read docs/SECURITY.md before continuing.%s\n' "$RED" "$NC" >&2
    fi
}

webroot_path() {
    local rel; rel="$(env_get XF_WEBROOT)"; [[ -n "$rel" ]] || rel="./webroot"
    case "$rel" in
        /*) printf '%s' "$rel" ;;
        *)  printf '%s/%s' "$STACK_DIR" "${rel#./}" ;;
    esac
}

board_url() {
    local port; port="$(env_get HTTP_PORT)"; [[ -n "$port" ]] || port=80
    if [[ "$port" == "80" ]]; then printf 'http://localhost'; else printf 'http://localhost:%s' "$port"; fi
}

# ---- commands --------------------------------------------------------------
cmd="${1:-help}"; shift || true

case "$cmd" in

help)
cat <<'EOF'
XenForo + Elasticsearch dev stack (Linux / macOS)

  First run
    setup                 Generate .env, build the image, start, install XenForo
    reset                 Destroy containers, volumes and webroot, then set up again

  Lifecycle
    up | down | restart   Start / stop / restart
    status                Container and health status
    build                 Rebuild the PHP image (after editing Dockerfile)

  XenForo
    cli <args...>         php cmd.php <args>   e.g.  cli xf:addon-list
    addon install|upgrade|enable|disable|uninstall <Vendor/Id>
    import <Vendor/Id>    xf-dev:import --addon=<Vendor/Id>
    export <Vendor/Id>    xf-addon:export <Vendor/Id>
    rebuild               xf-dev:rebuild-caches
    reindex               xf-rebuild:search  (full Elasticsearch reindex)
    defaultaddon <V/Id>   Set development.defaultAddOn in config.php

  Diagnostics
    doctor                Check ports, PHP extensions, DB, Elasticsearch, HTTP
    errors [n]            Show the last n XenForo errors (default 5)
    log                   Tail the Apache error log
    shell                 Bash shell in the web container
    db                    MariaDB client
    es [path]             Query Elasticsearch  (default: _cat/indices?v)
    xdebug on|off         Toggle Xdebug (off is roughly twice as fast)
    creds                 Show the ACP URL and admin credentials

  Every published port binds to 127.0.0.1 only. See docs/SECURITY.md.
EOF
;;

setup)
    # ---- .env --------------------------------------------------------
    if [[ ! -f "$ENV_FILE" ]]; then
        cp "$STACK_DIR/.env.example" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        echo "Created stack/.env from .env.example"
    fi

    for k in MARIADB_ROOT_PASSWORD MARIADB_PASSWORD XF_ADMIN_PASSWORD; do
        if [[ -z "$(env_get "$k")" ]]; then
            len=32; [[ "$k" == "XF_ADMIN_PASSWORD" ]] && len=24
            env_set "$k" "$(gen_secret $len)"
            echo "Generated $k"
        fi
    done
    [[ -n "$(env_get XF_ADMIN_USER)" ]] || env_set XF_ADMIN_USER admin

    # ---- host uid/gid (Linux bind-mount ownership) --------------------
    # Harmless on macOS, where Docker Desktop translates ownership anyway.
    env_set PUID "$(id -u)"
    env_set PGID "$(id -g)"

    # ---- webroot ------------------------------------------------------
    WEBROOT="$(webroot_path)"
    if [[ ! -d "$WEBROOT" ]]; then
        SRC="$(env_get XF_SOURCE)"
        [[ -n "$SRC" ]] || die "$(cat <<'EOF'
XF_SOURCE is not set in stack/.env.

XenForo is commercial software and is not distributed with this repo. Point
XF_SOURCE at your own licensed copy — either an unpacked directory containing
src/ and cmd.php, or a XenForo release zip:

    XF_SOURCE=/home/you/xenforo_2.3.12/upload
EOF
)"
        [[ -e "$SRC" ]] || die "XF_SOURCE path does not exist: $SRC"

        if [[ -d "$SRC" ]]; then
            [[ -f "$SRC/cmd.php" ]] || die "XF_SOURCE does not look like a XenForo webroot (no cmd.php): $SRC"
            echo "Copying XenForo source -> $WEBROOT (one-time, ~65 MB)..."
            mkdir -p "$WEBROOT"
            cp -a "$SRC/." "$WEBROOT/"
        elif [[ "$SRC" == *.zip ]]; then
            command -v unzip >/dev/null 2>&1 || die "unzip is required to use a .zip XF_SOURCE."
            echo "Extracting $SRC -> $WEBROOT ..."
            TMP="$(mktemp -d)"
            unzip -q "$SRC" -d "$TMP"
            mkdir -p "$WEBROOT"
            # A XenForo release zip wraps everything in upload/.
            if [[ -d "$TMP/upload" ]]; then cp -a "$TMP/upload/." "$WEBROOT/"; else cp -a "$TMP/." "$WEBROOT/"; fi
            rm -rf "$TMP"
        else
            die "XF_SOURCE must be a directory or a .zip file: $SRC"
        fi
    else
        echo "Webroot already exists; leaving it alone."
    fi

    [[ -f "$WEBROOT/src/config.php" ]] || {
        cp "$STACK_DIR/config.php.template" "$WEBROOT/src/config.php"
        echo "Installed development config.php"
    }
    mkdir -p "$WEBROOT/data" "$WEBROOT/internal_data"

    # ---- build and start ----------------------------------------------
    echo
    echo "Building image (first build takes a few minutes)..."
    compose build

    echo
    echo "Starting containers..."
    compose up -d

    echo
    echo "Waiting for MariaDB and Elasticsearch to report healthy..."
    prefix="$(env_get COMPOSE_PREFIX)"; [[ -n "$prefix" ]] || prefix=xf
    for svc in "$prefix-mariadb" "$prefix-elasticsearch"; do
        ok=0
        for _ in $(seq 1 90); do
            if [[ "$(docker inspect -f '{{.State.Health.Status}}' "$svc" 2>/dev/null)" == "healthy" ]]; then ok=1; break; fi
            sleep 2
        done
        [[ $ok -eq 1 ]] || die "$svc did not become healthy. Check: ./xf.sh status"
        echo "  $svc healthy"
    done

    in_container --root chown -R www-data:www-data /var/www/html/data /var/www/html/internal_data

    # The database lives in a Docker volume but internal_data/ lives on the
    # host, so destroying the volume leaves install-lock.php behind and XenForo
    # then refuses to install. Decide from the DATABASE whether this is a fresh
    # install — never from the lock file alone, or re-running setup could wipe a
    # working install.
    DB_USER="$(env_get MARIADB_USER)"; [[ -n "$DB_USER" ]] || DB_USER=xenforo
    DB_NAME="$(env_get MARIADB_DATABASE)"; [[ -n "$DB_NAME" ]] || DB_NAME=xenforo
    DB_PASS="$(env_get MARIADB_PASSWORD)"
    TABLES="$(compose exec -T mariadb mariadb "-u$DB_USER" "-p$DB_PASS" "$DB_NAME" -e 'SHOW TABLES' 2>/dev/null | grep -v '^Tables_in_' | grep -c . || true)"

    if [[ "${TABLES:-0}" -gt 0 ]]; then
        echo
        echo "XenForo is already installed ($TABLES tables) — skipping install."
        echo "To start over: ./xf.sh reset"
    else
        if [[ -f "$WEBROOT/internal_data/install-lock.php" ]]; then
            echo
            echo "Database is empty but install-lock.php exists (left by a previous"
            echo "install whose volume was destroyed). Clearing stale install state..."
            rm -f "$WEBROOT/internal_data/install-lock.php"
            rm -rf "$WEBROOT/internal_data/code_cache" "$WEBROOT/internal_data/temp"
        fi
        echo
        echo "Installing XenForo..."
        in_container php cmd.php xf:install "--user=$(env_get XF_ADMIN_USER)" "--password=$(env_get XF_ADMIN_PASSWORD)" --clear \
            || die "xf:install failed. Inspect with: ./xf.sh log"
    fi

    assert_no_public_bind
    echo
    echo "Done. $(board_url)/admin.php"
    echo "Credentials: ./xf.sh creds"
    echo "Next: mount an add-on in stack/docker-compose.yml, then ./xf.sh addon install Vendor/AddonId"
;;

reset)
    printf '%sThis destroys the containers, all volumes (database AND search index), and the webroot.%s\n' "$YEL" "$NC"
    read -r -p "Type RESET to confirm: " confirm
    [[ "$confirm" == "RESET" ]] || { echo "Aborted."; exit 0; }
    compose down -v
    rm -rf "$(webroot_path)"
    exec "$0" setup
;;

up)      compose up -d; compose ps; assert_no_public_bind ;;
down)    compose down ;;
restart) compose restart ;;
build)   compose build ;;
status)  compose ps ;;

cli)     assert_running; in_container php cmd.php "$@" ;;

addon)
    assert_running
    [[ $# -ge 2 ]] || die "Usage: ./xf.sh addon install|upgrade|enable|disable|uninstall <Vendor/Id>"
    case "$1" in
        install)   xfcmd=xf:addon-install ;;
        upgrade)   xfcmd=xf:addon-upgrade ;;
        enable)    xfcmd=xf:addon-enable ;;
        disable)   xfcmd=xf:addon-disable ;;
        uninstall) xfcmd=xf:addon-uninstall ;;
        *) die "Unknown action '$1'." ;;
    esac
    in_container php cmd.php "$xfcmd" "$2"
;;

import)  assert_running; [[ $# -ge 1 ]] || die "Usage: ./xf.sh import <Vendor/Id>"; in_container php cmd.php xf-dev:import "--addon=$1" ;;
export)  assert_running; [[ $# -ge 1 ]] || die "Usage: ./xf.sh export <Vendor/Id>"; in_container php cmd.php xf-addon:export "$1" ;;
rebuild) assert_running; in_container php cmd.php xf-dev:rebuild-caches ;;

reindex)
    # The command is xf-rebuild:search. AbstractRebuildCommand builds every
    # rebuild command as xf-rebuild:<name>; there is no xf:rebuild-search.
    assert_running; in_container php cmd.php xf-rebuild:search "$@"
;;

defaultaddon)
    [[ $# -ge 1 ]] || die "Usage: ./xf.sh defaultaddon <Vendor/Id>"
    CFG="$(webroot_path)/src/config.php"
    sed "s|\(\$config\['development'\]\['defaultAddOn'\][[:space:]]*=[[:space:]]*'\)[^']*\('\)|\1$1\2|" "$CFG" > "$CFG.tmp"
    mv "$CFG.tmp" "$CFG"
    echo "development.defaultAddOn = $1"
;;

creds)
    echo "URL      : $(board_url)/admin.php"
    echo "Username : $(env_get XF_ADMIN_USER)"
    echo "Password : $(env_get XF_ADMIN_PASSWORD)"
;;

doctor)
    echo "=== containers ==="
    compose ps

    echo
    echo "=== port exposure ==="
    assert_no_public_bind
    echo "  (no warning above = every published port is loopback-only)"

    echo
    echo "=== PHP extensions XenForo 2.3 needs ==="
    have="$(compose exec -T xenforo php -m || true)"
    missing=0
    for e in mysqli gd json pcre ctype iconv mbstring openssl SimpleXML filter hash session zip intl curl zlib; do
        if printf '%s\n' "$have" | grep -qix "$e"; then
            printf '  ok      %s\n' "$e"
        else
            printf '%s  MISSING %s%s\n' "$RED" "$e" "$NC"; missing=$((missing+1))
        fi
    done
    [[ $missing -eq 0 ]] || printf '%s  -> %d missing; add to the Dockerfile and run: ./xf.sh build%s\n' "$RED" "$missing" "$NC"

    echo
    echo "=== PHP version ==="
    compose exec -T xenforo php -v | head -n1

    echo
    echo "=== database ==="
    DB_USER="$(env_get MARIADB_USER)"; [[ -n "$DB_USER" ]] || DB_USER=xenforo
    DB_NAME="$(env_get MARIADB_DATABASE)"; [[ -n "$DB_NAME" ]] || DB_NAME=xenforo
    count="$(compose exec -T mariadb mariadb "-u$DB_USER" "-p$(env_get MARIADB_PASSWORD)" "$DB_NAME" -e 'SHOW TABLES' 2>/dev/null | grep -v '^Tables_in_' | grep -c . || true)"
    if [[ "${count:-0}" -gt 0 ]]; then echo "  ok      $count tables in '$DB_NAME'"
    else printf '%s  no tables found — has XenForo been installed?%s\n' "$RED" "$NC"; fi

    echo
    echo "=== Elasticsearch ==="
    # Queried from inside the web container on purpose: Elasticsearch is not
    # published to the host and must never be.
    health="$(compose exec -T xenforo curl -fsS http://elasticsearch:9200/_cluster/health 2>/dev/null || true)"
    if [[ -n "$health" ]]; then
        status="$(printf '%s' "$health" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')"
        case "$status" in
            # yellow is normal for a single node: replica shards stay unassigned.
            green|yellow)
                echo "  ok      cluster status $status"
                c="$(compose exec -T xenforo curl -fsS http://elasticsearch:9200/xf/_count 2>/dev/null || true)"
                n="$(printf '%s' "$c" | sed -n 's/.*"count"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"
                if [[ -n "$n" ]]; then echo "  ok      index 'xf' holds $n document(s)"
                else printf '%s  index '\''xf'\'' not found — run the XFES setup wizard in the ACP%s\n' "$YEL" "$NC"; fi
                ;;
            *) printf '%s  cluster unhealthy: %s%s\n' "$RED" "$health" "$NC" ;;
        esac
    else
        printf '%s  not reachable — XFES will fall back to MySQL search%s\n' "$YEL" "$NC"
    fi

    echo
    echo "=== HTTP ==="
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$(board_url)/" || true)"
    if [[ "$code" == "200" ]]; then echo "  $(board_url) -> $code"
    else printf '%s  %s -> %s%s\n' "$RED" "$(board_url)" "${code:-no response}" "$NC"; fi

    echo
    echo "=== installed add-ons ==="
    in_container php cmd.php xf:addon-list
;;

errors)
    n="${1:-5}"
    LOG="$(webroot_path)/internal_data/error_log.php"
    [[ -f "$LOG" ]] || { echo "No error_log.php yet — nothing has errored."; exit 0; }
    # XenForo writes each entry as a PHP block; show the tail of the raw file.
    tail -n "$((n * 12))" "$LOG"
;;

log)   compose logs --tail 80 -f xenforo ;;
shell) assert_running; compose exec -u www-data xenforo bash ;;

db)
    DB_USER="$(env_get MARIADB_USER)"; [[ -n "$DB_USER" ]] || DB_USER=xenforo
    DB_NAME="$(env_get MARIADB_DATABASE)"; [[ -n "$DB_NAME" ]] || DB_NAME=xenforo
    compose exec mariadb mariadb "-u$DB_USER" "-p$(env_get MARIADB_PASSWORD)" "$DB_NAME"
;;

es)
    # Queried through the web container because Elasticsearch has no published
    # port and must not get one — it is unauthenticated.
    assert_running
    path="${1:-_cat/indices?v}"
    in_container curl -fsS "http://elasticsearch:9200/${path#/}"
    echo
;;

xdebug)
    [[ $# -ge 1 ]] || die "Usage: ./xf.sh xdebug on|off"
    dir=/usr/local/etc/php/conf.d
    if [[ "$1" == "on" ]]; then
        in_container --root sh -c "cp $dir/zz-xdebug.ini.disabled $dir/zz-xdebug.ini"
        echo "Xdebug ON (client port 9003)"
    else
        in_container --root sh -c "rm -f $dir/zz-xdebug.ini"
        echo "Xdebug OFF"
    fi
    compose restart xenforo
;;

*) die "Unknown command '$cmd'. Run: ./xf.sh help" ;;
esac
