#!/usr/bin/env bash
#
# cfg-server-cauldronvtt entrypoint.
#
# Brings up four processes in one container and supervises them:
#   mariadb   — Cauldron's only supported DB driver is mysqli (Banshee ships
#               exactly one connection class), so this is not optional
#   php-fpm   — the application
#   nginx     — serves static files, routes everything else to index.php, and
#               proxies /websocket to cauldrond so the container needs ONE port
#   cauldrond — the realtime daemon (wsServer); stays in the foreground because
#               it only daemonizes when started as root (see cauldrond.c main())
#
# tini is PID 1. This script traps SIGTERM and shuts MariaDB down cleanly —
# a SIGKILLed MariaDB replays its redo log on next boot and repeated hard kills
# can corrupt InnoDB.
#
# Supervision contract: `wait -n` returns as soon as ANY child exits, at which
# point we tear the rest down and exit non-zero. Docker's restart policy then
# recreates the container. A half-dead container that still answers the
# healthcheck is worse than a restart loop, because nobody notices it.
#
# Env (set by core-server's launcher; defaults suit standalone `docker run`):
#   CAULDRON_ADMIN_PASSWORD  — REQUIRED, no default. Sets the seeded admin
#                              account's password on first boot. Upstream seeds
#                              this user with the literal string 'none', which
#                              is not a valid hash, so the account is unusable
#                              until this runs — that is the safe default and
#                              we keep it that way.
#   CAULDRON_ADMIN_USERNAME  — default 'admin' (the seeded row)
#   CAULDRON_ADMIN_EMAIL     — default 'admin@localhost'
#   CAULDRON_WEBSOCKET_PORT  — port the BROWSER connects to, not the daemon's.
#                              443 behind the platform's TLS terminator.
#   CAULDRON_DB_NAME/USER    — database name and user, both default 'cauldron'
#   CAULDRON_ENABLE_MARKET   — 'yes'/'no', gates the adventure/map market

set -euo pipefail

APP_DIR=/var/www/cauldron
DATA_DIR=/data
MYSQL_DIR="$DATA_DIR/mysql"
SOCKET=/run/mysqld/mysqld.sock
RUN_AS=www-data

DB_NAME="${CAULDRON_DB_NAME:-cauldron}"
DB_USER="${CAULDRON_DB_USER:-cauldron}"
ADMIN_USER="${CAULDRON_ADMIN_USERNAME:-admin}"
ADMIN_EMAIL="${CAULDRON_ADMIN_EMAIL:-admin@localhost}"
WS_PORT="${CAULDRON_WEBSOCKET_PORT:-443}"
ENABLE_MARKET="${CAULDRON_ENABLE_MARKET:-no}"

log() { echo "[cfg-server-cauldronvtt] $*"; }
die() { echo "[cfg-server-cauldronvtt] FATAL: $*" >&2; exit 1; }

[ -n "${CAULDRON_ADMIN_PASSWORD:-}" ] || \
  die "CAULDRON_ADMIN_PASSWORD is required — refusing to boot an install nobody can log into."

# The DB password is never supplied from outside: nothing but this container
# talks to this MariaDB (it listens on a unix socket only, see my.cnf.d). A
# generated per-boot secret is strictly better than an env var that would show
# up in `docker inspect`. Persisted so it survives restarts.
DB_PASS_FILE="$DATA_DIR/.dbpass"

# ── Filesystem layout ───────────────────────────────────────────────────────
# /data is the per-installation bind mount. Everything that must survive a
# container replacement lives here; the app tree itself is disposable.
prepare_filesystem() {
  mkdir -p "$MYSQL_DIR" "$DATA_DIR/files" "$DATA_DIR/resources"

  # The host dir arrives owned by the platform's per-install gid, so take
  # ownership of the contents we manage. Ignore failures on read-only or
  # already-correct trees rather than crash-looping.
  chown -R "$RUN_AS:$RUN_AS" "$DATA_DIR" 2>/dev/null || true
  chown -R "$RUN_AS:$RUN_AS" /run/mysqld /run/php 2>/dev/null || true

  # Cauldron writes uploads into public/files and public/resources. Those were
  # removed from the image so these symlinks always win.
  ln -sfn "$DATA_DIR/files" "$APP_DIR/public/files"
  ln -sfn "$DATA_DIR/resources" "$APP_DIR/public/resources"
}

# ── Config templating ───────────────────────────────────────────────────────
# Edit the shipped conf files in place rather than writing our own from
# scratch: upstream adds settings between releases and a hand-rolled file
# would silently drop them.
write_config() {
  local db_pass="$1"
  local banshee="$APP_DIR/settings/banshee.conf"
  local cauldron="$APP_DIR/settings/cauldron.conf"
  local modules="$APP_DIR/settings/public_modules.conf"

  sed -i \
    -e "s|^DB_HOSTNAME[[:space:]]*=.*|DB_HOSTNAME = localhost|" \
    -e "s|^DB_DATABASE[[:space:]]*=.*|DB_DATABASE = ${DB_NAME}|" \
    -e "s|^DB_USERNAME[[:space:]]*=.*|DB_USERNAME = ${DB_USER}|" \
    -e "s|^DB_PASSWORD[[:space:]]*=.*|DB_PASSWORD = ${db_pass}|" \
    -e "s|^DEBUG_MODE[[:space:]]*=.*|DEBUG_MODE = no|" \
    "$banshee"

  sed -i \
    -e "s|^WEBSOCKET_PORT[[:space:]]*=.*|WEBSOCKET_PORT = ${WS_PORT}|" \
    -e "s|^ENABLE_MARKET[[:space:]]*=.*|ENABLE_MARKET = ${ENABLE_MARKET}|" \
    "$cauldron"

  # INSTALL step 2: the setup module must not remain reachable once the
  # database exists — it is an unauthenticated installer.
  if grep -qx "setup" "$modules"; then
    sed -i '/^setup$/d' "$modules"
    log "disabled the setup module"
  fi
}

# ── Database ────────────────────────────────────────────────────────────────
start_mariadb() {
  if [ ! -d "$MYSQL_DIR/mysql" ]; then
    log "initialising MariaDB data directory (first boot)"
    mariadb-install-db --user="$RUN_AS" --datadir="$MYSQL_DIR" --auth-root-authentication-method=socket >/dev/null
  fi

  log "starting MariaDB"
  su -s /bin/sh -c "mariadbd --user=$RUN_AS --datadir=$MYSQL_DIR" "$RUN_AS" &
  MARIADB_PID=$!

  # Poll rather than sleep: first-boot InnoDB creation is much slower than a
  # warm start, so any fixed sleep is either flaky or wasteful.
  local waited=0
  until mariadb-admin --socket="$SOCKET" ping >/dev/null 2>&1; do
    kill -0 "$MARIADB_PID" 2>/dev/null || die "MariaDB exited during startup"
    sleep 1
    waited=$((waited + 1))
    [ "$waited" -lt 90 ] || die "MariaDB did not become ready within 90s"
  done
  log "MariaDB ready after ${waited}s"
}

seed_database() {
  local db_pass="$1"

  if mariadb --socket="$SOCKET" -e "use ${DB_NAME}; select 1 from users limit 1;" >/dev/null 2>&1; then
    log "database already provisioned — skipping seed"
    return
  fi

  log "creating database and importing schema"
  mariadb --socket="$SOCKET" <<-SQL
	CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
	CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${db_pass}';
	GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
	FLUSH PRIVILEGES;
	SQL

  # Upstream's dump is self-sufficient: it seeds organisations, users, roles,
  # pages, menu, settings and rule_systems. There is no need to run /setup.
  mariadb --socket="$SOCKET" "$DB_NAME" < "$APP_DIR/database/mysql.sql"
  log "schema imported"
}

set_admin_password() {
  # Hash with PHP so the algorithm tracks Banshee's PASSWORD_ALGORITHM
  # (currently PASSWORD_ARGON2I, banshee.php:16) instead of being pinned here
  # and silently diverging on an upstream bump.
  local hash
  hash=$(CFG_PW="$CAULDRON_ADMIN_PASSWORD" php83 -r '
    require "/var/www/cauldron/libraries/banshee/core/banshee.php";
    echo password_hash(getenv("CFG_PW"), PASSWORD_ALGORITHM);
  ') || die "failed to hash the admin password"

  [ -n "$hash" ] || die "password hashing produced an empty result"

  mariadb --socket="$SOCKET" "$DB_NAME" <<-SQL
	UPDATE users SET password = '${hash}', email = '${ADMIN_EMAIL}', status = 0
	WHERE username = '${ADMIN_USER}';
	SQL
  log "admin password set for '${ADMIN_USER}'"
}

# ── Shutdown ────────────────────────────────────────────────────────────────
shutdown() {
  log "shutting down"
  [ -n "${NGINX_PID:-}" ] && kill -QUIT "$NGINX_PID" 2>/dev/null || true
  [ -n "${CAULDROND_PID:-}" ] && kill -TERM "$CAULDROND_PID" 2>/dev/null || true
  [ -n "${PHPFPM_PID:-}" ] && kill -QUIT "$PHPFPM_PID" 2>/dev/null || true
  if [ -n "${MARIADB_PID:-}" ]; then
    mariadb-admin --socket="$SOCKET" shutdown >/dev/null 2>&1 || kill -TERM "$MARIADB_PID" 2>/dev/null || true
    wait "$MARIADB_PID" 2>/dev/null || true
  fi
  exit 0
}
trap shutdown TERM INT

# ── Boot ────────────────────────────────────────────────────────────────────
prepare_filesystem

log "preparing /data"

if [ ! -f "$DB_PASS_FILE" ]; then
  # Every stage of this pipeline must terminate on its own. The obvious
  # `tr -dc … </dev/urandom | head -c 32` deadlocks differently: head closes
  # the pipe, tr takes SIGPIPE, and with `set -e -o pipefail` the entrypoint
  # dies at exit 141 before writing a single log line. Reading a bounded
  # 32 bytes and finishing with `cut` (which consumes all input) avoids it.
  # Alphanumerics only, so the value can never break the sed that writes it
  # into banshee.conf.
  head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-32 > "$DB_PASS_FILE"
  chmod 600 "$DB_PASS_FILE"
  chown "$RUN_AS:$RUN_AS" "$DB_PASS_FILE"
fi
DB_PASS=$(cat "$DB_PASS_FILE")

start_mariadb
seed_database "$DB_PASS"
write_config "$DB_PASS"
set_admin_password

log "starting php-fpm"
php-fpm83 --nodaemonize &
PHPFPM_PID=$!

log "starting cauldrond (websocket, 127.0.0.1:2001 — proxied by nginx)"
su -s /bin/sh -c "/usr/sbin/cauldrond" "$RUN_AS" &
CAULDROND_PID=$!

log "starting nginx"
nginx -g 'daemon off;' &
NGINX_PID=$!

log "ready — Cauldron VTT ${CAULDRON_VERSION:-4.0} listening on :80"

# Exit as soon as anything dies so the restart policy can act.
wait -n
die "a managed process exited — tearing down the container"
