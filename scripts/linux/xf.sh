#!/usr/bin/env bash
#
# XenForo + Elasticsearch dev stack — Linux / macOS helper.
#
# Usage:  ./xf.sh <command> [args]
#         ./xf.sh help
#
# Feature-equivalent to scripts/windows/xf.ps1. Written to run on the bash 3.2
# that macOS still ships as /bin/bash, as well as on bash 4 and 5. Avoid
# bash-4-only features (associative arrays, ${var,,}, mapfile) and never expand
# an array that may be empty while `set -u` is on: bash older than 4.4 treats
# "${empty[@]}" as an unbound variable and exits.

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
# Two explicit branches rather than an optional "-u www-data" array: an empty
# array expansion aborts the script under `set -u` on bash < 4.4 (macOS).
in_container() {
    if [[ "${1:-}" == "--root" ]]; then
        shift
        compose exec -T xenforo "$@"
    else
        compose exec -T -u www-data xenforo "$@"
    fi
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

# Sets KEY=VALUE in .env, replacing an existing line or appending one.
#
# .env holds the generated secrets, so it is kept at mode 0600. The rewrite
# goes through a temp file, and a freshly created file gets the user's default
# mode (usually 0644 - readable by every local account), which `mv` would then
# put in place of the original. So the temp file is created under umask 077,
# before anything is written into it, and the result is chmod-ed again.
env_set() {
    local key="$1" val="$2" tmp
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$ENV_FILE"; then
        tmp="$(umask 077 && mktemp "$ENV_FILE.XXXXXX")"
        # -i differs between GNU and BSD/macOS sed, so write via a temp file.
        sed "s|^[[:space:]]*${key}[[:space:]]*=.*|${key}=${val}|" "$ENV_FILE" > "$tmp"
        mv "$tmp" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
    fi
    chmod 600 "$ENV_FILE"
}

gen_secret() {
    # Alphanumeric only: '/', '+' and '=' need escaping in .env, in connection
    # strings and in shell arguments. Not worth the trouble.
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-32}"
}

# Warns about any container port published on an address other than loopback.
# Docker lists ports as "127.0.0.1:80->80/tcp, 9200/tcp": entries with "->"
# are published, the rest are only exposed inside the network. For each
# published entry the address before ":<port>->" must be 127.0.0.1 or [::1].
# That catches 0.0.0.0 and [::] (all interfaces) and also a specific LAN
# address, which is just as reachable from the network.
assert_no_public_bind() {
    local bad
    bad="$(docker ps --format '{{.Names}}|{{.Ports}}' | awk -F'|' '{
        n = split($2, parts, ", ")
        for (i = 1; i <= n; i++) {
            if (parts[i] !~ /->/) continue
            addr = parts[i]; sub(/:[0-9]+(-[0-9]+)?->.*/, "", addr)
            if (addr != "127.0.0.1" && addr != "[::1]") { print; next }
        }
    }' || true)"
    if [[ -n "$bad" ]]; then
        printf '%sWARNING: container ports are published beyond loopback:%s\n' "$RED" "$NC" >&2
        printf '%s    %s%s\n' "$RED" "$bad" "$NC" >&2
        printf '%s  Bind them to 127.0.0.1 in docker-compose.yml, then: ./xf.sh down && ./xf.sh up%s\n' "$RED" "$NC" >&2
        printf '%s  Read docs/SECURITY.md before continuing.%s\n' "$RED" "$NC" >&2
    fi
}

# Minimum Docker Engine that keeps loopback-bound ports private. Engine 28.0
# stopped other hosts on the same network from reaching ports published on
# 127.0.0.1; 28.2.0-28.3.2 then reopened them after a firewalld reload
# (CVE-2025-54388), fixed in 28.3.3. Rule 1 in docs/SECURITY.md depends on it.
MIN_ENGINE=28.3.3

# Succeeds if dotted version $1 >= $2. Pure bash so it works on macOS, where
# `sort -V` is not guaranteed. Compares the first three numeric parts only.
version_ge() {
    local i a b
    # read -a splits on the dots without globbing; it exists in bash 3.2.
    IFS=. read -r -a a <<< "$1"
    IFS=. read -r -a b <<< "$2"
    for i in 0 1 2; do
        if (( 10#${a[i]:-0} > 10#${b[i]:-0} )); then return 0; fi
        if (( 10#${a[i]:-0} < 10#${b[i]:-0} )); then return 1; fi
    done
    return 0
}

# Warns, never fails: Podman and other engines report their own version
# numbering, so a warning there is a prompt to check, not a verdict.
check_engine_version() {
    local v
    v="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
    # Strip suffixes such as "-rd" or "+dfsg1" before comparing.
    v="${v%%-*}"; v="${v%%+*}"
    if [[ ! "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        printf '%s  could not read the Docker Engine version (%s)%s\n' "$YEL" "${v:-none}" "$NC"
    elif version_ge "$v" "$MIN_ENGINE"; then
        echo "  ok      Docker Engine $v"
    else
        printf '%s  Docker Engine %s is older than %s. Older engines can expose ports bound to 127.0.0.1 to the local network. Upgrade - see docs/SECURITY.md (Rule 1).%s\n' "$RED" "$v" "$MIN_ENGINE" "$NC"
    fi
}

# Runs the MariaDB client in the mariadb container without putting the
# password on any command line. Command-line arguments are visible to every
# local user through `ps` - including those of processes inside a container,
# which on Linux are ordinary host processes. The password travels in the
# MYSQL_PWD environment variable instead, readable only by the process owner
# and root. `-e MYSQL_PWD` (a name, no value) copies it from this subshell's
# environment into the container, so it never appears as an argument.
#   db_client [--tty] [mariadb args...]   (--tty for an interactive prompt)
db_client() {
    local user name
    user="$(env_get MARIADB_USER)"; [[ -n "$user" ]] || user=xenforo
    name="$(env_get MARIADB_DATABASE)"; [[ -n "$name" ]] || name=xenforo
    if [[ "${1:-}" == "--tty" ]]; then
        shift
        ( MYSQL_PWD="$(env_get MARIADB_PASSWORD)"; export MYSQL_PWD
          compose exec -e MYSQL_PWD mariadb mariadb "-u$user" "$name" "$@" )
    else
        ( MYSQL_PWD="$(env_get MARIADB_PASSWORD)"; export MYSQL_PWD
          compose exec -T -e MYSQL_PWD mariadb mariadb "-u$user" "$name" "$@" )
    fi
}

# Refuses to let `reset` delete a directory that is not a disposable XenForo
# webroot. XF_WEBROOT can be any path, and `reset` removes it recursively, so
# a mistaken value (the pristine XF_SOURCE copy, a home directory, /) would
# otherwise be deleted without further question.
assert_safe_webroot() {
    local w="$1" src
    [[ -e "$w" ]] || return 0
    case "$w" in
        /|"$HOME"|"$HOME/"|"$STACK_DIR"|"$STACK_DIR/") die "Refusing to delete $w: XF_WEBROOT points at a directory that is not a webroot." ;;
    esac
    [[ -f "$w/src/XF.php" ]] || die "Refusing to delete $w: it does not contain src/XF.php, so it does not look like a XenForo webroot. Check XF_WEBROOT in stack/.env."
    # Resolve symlinks on both sides, and fail CLOSED: if a directory cannot be
    # entered, an empty result must stop the reset, not compare as "different".
    local real_w real_src
    real_w="$(cd "$w" 2>/dev/null && pwd -P)" || real_w=""
    [[ -n "$real_w" ]] || die "Refusing to delete $w: cannot resolve its real path."
    # A symlinked webroot is refused, as on Windows: the prompt would show the
    # link's name, but `rm -rf link/` (with a trailing slash) deletes the
    # target's contents - a tree the user never saw named.
    [[ ! -L "${w%/}" ]] || die "Refusing to delete $w: it is a symbolic link (to $real_w). Point XF_WEBROOT at a real directory."
    src="$(env_get XF_SOURCE)"
    if [[ -n "$src" && -d "$src" ]]; then
        real_src="$(cd "$src" 2>/dev/null && pwd -P)" || real_src=""
        [[ -n "$real_src" ]] || die "Refusing to delete $w: cannot resolve XF_SOURCE ($src) to compare with it."
        # Equal, or one inside the other: deleting the webroot would take
        # XF_SOURCE with it (or the webroot IS part of XF_SOURCE).
        case "$real_src/" in "$real_w/"*) die "Refusing to delete $w: XF_SOURCE ($src) is inside it." ;; esac
        case "$real_w/" in "$real_src/"*) die "Refusing to delete $w: it is inside XF_SOURCE ($src), your reference copy of XenForo." ;; esac
    fi
}

# defaultaddon writes its argument into config.php inside a PHP string, via
# sed. Restricting it to an add-on id shape keeps a quote from ending the PHP
# string and keeps sed's special characters (& | \) out of the replacement.
valid_addon_id() { [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_]*(/[A-Za-z][A-Za-z0-9_]*)?$ ]]; }

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
    addon install|upgrade|rebuild|enable|disable|uninstall <Vendor/Id>
                          (rebuild = re-import the add-on's _data/ XML)
    import <Vendor/Id>    _output/ dev files -> database   (xf-dev:import)
    export <Vendor/Id>    database -> _data/ XML           (xf-addon:export)
    rebuild               xf-dev:rebuild-caches
    reindex               xf-rebuild:search  (full Elasticsearch reindex)
    defaultaddon <V/Id>   Set development.defaultAddOn in config.php

  Diagnostics
    doctor                Check engine, ports, PHP extensions, DB, Elasticsearch, HTTP
    errors [n]            Show the last n XenForo errors (default 5)
    log                   Tail the Apache error log
    shell                 Bash shell in the web container
    db ["SQL"]            MariaDB client, or run one query
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

    XF_SOURCE=/home/you/xenforo_2.3.x/upload
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
    # Before anything is published: an engine below the minimum can expose
    # the 127.0.0.1 ports to the local network.
    echo
    check_engine_version

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
    TABLES="$(db_client -e 'SHOW TABLES' 2>/dev/null | grep -v '^Tables_in_' | grep -c . || true)"

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
        # Every value xf:install would otherwise ask for is passed explicitly,
        # so setup runs unattended (CI, an AI agent, a script). Without them
        # the installer stops to prompt, and with no input it aborts.
        # --skip-statistics: never opt a dev board into sending usage
        # statistics to XenForo. That prompt defaults to "yes", so accepting
        # defaults non-interactively would have switched it on.
        # --url: must include HTTP_PORT, or generated links point at port 80.
        # The password is NOT passed as --password: command-line arguments
        # are visible to every local user through `ps`, inside the container
        # too. With no --password, xf:install reads it from stdin twice (entry
        # and confirmation); with no terminal attached it reads plain lines.
        email="$(env_get XF_ADMIN_EMAIL)"; [[ -n "$email" ]] || email=admin@example.com
        title="$(env_get XF_BOARD_TITLE)"; [[ -n "$title" ]] || title="XenForo Dev"
        pass="$(env_get XF_ADMIN_PASSWORD)"
        [[ -n "$pass" ]] || die "XF_ADMIN_PASSWORD is not set in stack/.env"
        printf '%s\n%s\n' "$pass" "$pass" | in_container php cmd.php xf:install \
            "--user=$(env_get XF_ADMIN_USER)" \
            "--email=$email" "--title=$title" "--url=$(board_url)" \
            --skip-statistics --clear \
            || die "xf:install failed. Inspect with: ./xf.sh log"
        unset pass
    fi

    assert_no_public_bind
    echo
    echo "Done. $(board_url)/admin.php"
    echo "Credentials: ./xf.sh creds"
    echo "Next: mount an add-on in stack/docker-compose.yml, then ./xf.sh addon install Vendor/AddonId"
;;

reset)
    WEBROOT="$(webroot_path)"
    assert_safe_webroot "$WEBROOT"
    printf '%sThis destroys the containers, all volumes (database AND search index), and the webroot:%s\n' "$YEL" "$NC"
    printf '%s    %s%s\n' "$YEL" "$WEBROOT" "$NC"
    read -r -p "Type RESET to confirm: " confirm
    [[ "$confirm" == "RESET" ]] || { echo "Aborted."; exit 0; }
    compose down -v
    rm -rf "$WEBROOT"
    exec "$0" setup
;;

# The engine check runs before `up -d` so the warning comes before any port
# is published, not after.
up)      check_engine_version; compose up -d; compose ps; assert_no_public_bind ;;
down)    compose down ;;
restart) compose restart ;;
build)   compose build ;;
status)  compose ps ;;

cli)     assert_running; in_container php cmd.php "$@" ;;

addon)
    assert_running
    [[ $# -ge 2 ]] || die "Usage: ./xf.sh addon install|upgrade|rebuild|enable|disable|uninstall <Vendor/Id>"
    case "$1" in
        install)   xfcmd=xf:addon-install ;;
        upgrade)   xfcmd=xf:addon-upgrade ;;
        # Re-imports the add-on's _data/ XML into the database without a
        # version bump - what you need after editing _data/ by hand.
        rebuild)   xfcmd=xf:addon-rebuild ;;
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
    valid_addon_id "$1" || die "Not an add-on id: '$1'. Expected Vendor/AddonId (letters, digits, underscore)."
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
    echo "=== Docker Engine ==="
    check_engine_version

    echo
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
    # XenForo's installer requires mysqli, gd, iconv, ctype, pcre, json, curl,
    # mbstring, dom and SimpleXML. The rest are ones this image adds because
    # add-ons and XenForo features commonly use them.
    for e in mysqli gd json pcre ctype iconv mbstring openssl SimpleXML dom filter hash session zip intl curl zlib; do
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
    DB_NAME="$(env_get MARIADB_DATABASE)"; [[ -n "$DB_NAME" ]] || DB_NAME=xenforo
    count="$(db_client -e 'SHOW TABLES' 2>/dev/null | grep -v '^Tables_in_' | grep -c . || true)"
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
    # -L: XenForo answers "/" with a 301 to index.php, so without following
    # redirects a healthy board reports 301 - shown in red as a failure. A
    # few hops are plenty; xf.ps1's Invoke-WebRequest follows them too.
    code="$(curl -s -L --max-redirs 3 -o /dev/null -w '%{http_code}' --max-time 15 "$(board_url)/" || true)"
    if [[ "$code" == "200" ]]; then echo "  $(board_url) -> $code"
    else printf '%s  %s -> %s%s\n' "$RED" "$(board_url)" "${code:-no response}" "$NC"; fi

    echo
    echo "=== installed add-ons ==="
    in_container php cmd.php xf:addon-list
;;

errors)
    n="${1:-5}"
    # Must be checked BEFORE the arithmetic below. Bash evaluates a variable's
    # contents as an arithmetic expression, and array subscripts inside it
    # undergo command substitution: `errors 'a[$(any command)]'` would run the
    # command. This subcommand is on the documented agent allowlist, so that
    # would be command execution without a prompt.
    [[ "$n" =~ ^[0-9]{1,4}$ ]] || die "Usage: ./xf.sh errors [n]   (n = a number of entries, default 5)"
    LOG="$(webroot_path)/internal_data/error_log.php"
    [[ -f "$LOG" ]] || { echo "No error_log.php yet — nothing has errored."; exit 0; }
    # XenForo writes each entry as a PHP block; show the tail of the raw file.
    # 10# forces base 10, so a value such as 08 is not rejected as bad octal.
    tail -n "$((10#$n * 12))" "$LOG"
;;

log)   compose logs --tail 80 -f xenforo ;;
shell) assert_running; compose exec -u www-data xenforo bash ;;

# `./xf.sh db "SELECT ..."` runs one query (same form as xf.ps1); arguments
# starting with "-" go to the client unchanged, so `db -e "..."` works too.
db)
    if [[ $# -gt 0 && "$1" != -* ]]; then db_client --tty -e "$*"; else db_client --tty "$@"; fi
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
