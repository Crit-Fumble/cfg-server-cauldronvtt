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
# All four run as the uid this container was started with, and this script never
# changes user or ownership: there is no root step. That uid is www-data (82) by
# default and anything else under `docker run --user`, with or without a passwd
# entry. /data must belong to it. Everything else it writes goes in
# /tmp/cauldron, which this script makes at start, mode 0700, as that uid.
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
#   CAULDRON_EDGE_KEY        — the key the platform's edge signs its identity
#                              header with (cfg-identity.php). Unset: nobody signs
#                              in that way, only with a password.
#   CAULDRON_ADMIN_CERT_SERIAL — the host's serial, which signs the host in as the
#                              admin through that header (cfg-seats.php)
#   CAULDRON_SEATS           — the members who hold a seat, one
#                              '<serial> <username> <full name>' line each; their
#                              accounts are made, kept active or deactivated to
#                              match at every boot (cfg-seats.php)

set -euo pipefail

APP_DIR=/var/www/cauldron
DATA_DIR=/data
MYSQL_DIR="$DATA_DIR/mysql"
RUN_DIR=/tmp/cauldron
SETTINGS_DIST=/usr/share/cauldron/settings
SOCKET="$RUN_DIR/mysqld/mysqld.sock"

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
# container replacement lives here; the app tree itself is disposable. The
# image links public/files and public/resources to the two dirs made here.
prepare_filesystem() {
  # MariaDB refuses to start as root without being told which user to become,
  # and nothing here does that any more. Say so, rather than fail on its message.
  [ "$(id -u)" != 0 ] || die "this image does not run as root — start it as www-data (the default) or any other uid with --user"
  # No chown: this uid owns what it creates, and cannot take what it does not.
  [ -w "$DATA_DIR" ] || die "/data is not writable by uid $(id -u) — the mount must belong to the user the container runs as"
  mkdir -p "$MYSQL_DIR" "$DATA_DIR/files" "$DATA_DIR/resources"

  # Owner-only: the DB socket and the settings (which hold the DB password)
  # are for this container's one uid. A restarted container finds its own dir
  # again; one that belongs to anybody else is not used.
  mkdir -p -m 0700 "$RUN_DIR"
  [ -O "$RUN_DIR" ] || die "$RUN_DIR belongs to another uid"
  mkdir -p -m 0700 "$RUN_DIR/mysqld" "$RUN_DIR/php" "$RUN_DIR/nginx" "$RUN_DIR/sessions" "$RUN_DIR/settings" "$RUN_DIR/logfiles"
}

# ── Config templating ───────────────────────────────────────────────────────
# Edit the shipped conf files in place rather than writing our own from
# scratch: upstream adds settings between releases and a hand-rolled file
# would silently drop them.
write_config() {
  local db_pass="$1"
  # The app reads these three at $APP_DIR/settings/, where the image links them
  # to $RUN_DIR/settings. Start from the shipped copies on every boot, so a
  # restarted container never edits its own previous edit.
  cp "$SETTINGS_DIST/banshee.conf" "$SETTINGS_DIST/cauldron.conf" "$SETTINGS_DIST/public_modules.conf" "$RUN_DIR/settings/"
  local banshee="$RUN_DIR/settings/banshee.conf"
  local cauldron="$RUN_DIR/settings/cauldron.conf"
  local modules="$RUN_DIR/settings/public_modules.conf"

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

  # No self-registration: members get their accounts from the platform
  # (cfg-seats.php), and the host makes any other in Cauldron's user admin.
  # Registered, a visitor would start a group of their own on the host's server.
  if grep -qx "register" "$modules"; then
    sed -i '/^register$/d' "$modules"
    log "disabled self-registration"
  fi
}

# ── The platform's sign-in ──────────────────────────────────────────────────
# cfg-identity.php reads the edge key from a file only this uid can read: php-fpm
# hands its workers no environment.
write_edge_key() {
  local key_file="$RUN_DIR/edge.key"
  rm -f "$key_file"
  if [ -z "${CAULDRON_EDGE_KEY:-}" ]; then
    log "no edge key: members sign in with a password only"
    return
  fi
  [[ "$CAULDRON_EDGE_KEY" =~ ^[A-Za-z0-9]{32,128}$ ]] || die "CAULDRON_EDGE_KEY must be 32 to 128 letters and digits"
  (umask 077 && printf '%s' "$CAULDRON_EDGE_KEY" > "$key_file")
  unset CAULDRON_EDGE_KEY
  log "edge sign-in on"
}

# The host's serial and the members' seats, before the app takes its first request.
sync_seats() {
  if [ -z "${CAULDRON_SEATS+set}" ] && [ -z "${CAULDRON_ADMIN_CERT_SERIAL:-}" ]; then
    return
  fi
  php83 /usr/share/cauldron/cfg-seats.php || die "the seat sync failed"
  unset CAULDRON_SEATS
}

# ── Database ────────────────────────────────────────────────────────────────
start_mariadb() {
  if [ ! -d "$MYSQL_DIR/mysql" ]; then
    log "initialising MariaDB data directory (first boot)"
    # `normal`, not `socket`: socket auth admits an OS user by NAME, and a uid
    # given with --user has none. The DB root account therefore has no password.
    # What guards it is the socket itself: no network listener (my.cnf.d), in a
    # dir only this container's one uid can enter.
    mariadb-install-db --datadir="$MYSQL_DIR" --auth-root-authentication-method=normal --skip-test-db >/dev/null
  fi

  run_mariadbd
  root_is_admin || repair_root_login
  root_is_admin || die "cannot sign in to the database in $MYSQL_DIR as root, even after moving root to a password login"
}

run_mariadbd() {
  log "starting MariaDB${1:+ ($1)}"
  mariadbd --datadir="$MYSQL_DIR" "$@" &
  MARIADB_PID=$!

  # Poll rather than sleep: first-boot InnoDB creation is much slower than a
  # warm start, so any fixed sleep is either flaky or wasteful. `ping` answers
  # before any login, so it waits on the server, not on root.
  local waited=0
  until mariadb-admin --socket="$SOCKET" -uroot ping >/dev/null 2>&1; do
    kill -0 "$MARIADB_PID" 2>/dev/null || die "MariaDB exited during startup"
    sleep 1
    waited=$((waited + 1))
    [ "$waited" -lt 90 ] || die "MariaDB did not become ready within 90s"
  done
  log "MariaDB ready after ${waited}s"
}

# The account a `-uroot` login lands on. Asked rather than inferred from a
# successful `select 1`: with no root@localhost account, an anonymous one
# answers that login too, and cannot create the database.
root_is_admin() {
  [ "$(mariadb --socket="$SOCKET" -uroot -N -e 'select current_user()' 2>/dev/null)" = 'root@localhost' ]
}

# A datadir an earlier image initialised, as root with socket auth and a test
# database, admits root only for the OS user `root`. This uid is not that user,
# so start once without the grant tables (the socket stays the only way in, as
# for root's empty password) and leave the accounts this image initialises:
# root by password, no anonymous or www-data account, no test database.
repair_root_login() {
  log "the database admits no root login for uid $(id -u) — a volume an earlier image set up; moving root to a password login"
  kill -TERM "$MARIADB_PID" || die "cannot stop MariaDB to repair its root login"
  wait "$MARIADB_PID" || true
  run_mariadbd --skip-grant-tables
  mariadb --socket="$SOCKET" -uroot <<-SQL || die "repairing the root login failed"
	FLUSH PRIVILEGES;
	CREATE USER IF NOT EXISTS 'root'@'localhost';
	ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('');
	GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
	DELETE FROM mysql.global_priv WHERE User = '';
	DROP USER IF EXISTS 'www-data'@'localhost';
	DELETE FROM mysql.db WHERE User = 'PUBLIC' AND Db LIKE 'test%';
	DROP DATABASE IF EXISTS test;
	FLUSH PRIVILEGES;
	SQL
  mariadb-admin --socket="$SOCKET" -uroot shutdown || die "cannot stop MariaDB after repairing its root login"
  wait "$MARIADB_PID" || true
  run_mariadbd
}

seed_database() {
  local db_pass="$1"

  if mariadb --socket="$SOCKET" -uroot -e "use ${DB_NAME}; select 1 from users limit 1;" >/dev/null 2>&1; then
    log "database already provisioned — skipping seed"
    return
  fi

  log "creating database and importing schema"
  mariadb --socket="$SOCKET" -uroot <<-SQL
	CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
	CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${db_pass}';
	GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
	FLUSH PRIVILEGES;
	SQL

  # Upstream's dump seeds organisations, users, roles, pages, menu, settings and
  # rule_systems. What /setup would still do is the admin login
  # (set_admin_password) and the resources key and site secret
  # (provision_resources), which the dump leaves empty.
  mariadb --socket="$SOCKET" -uroot "$DB_NAME" < "$APP_DIR/database/mysql.sql"
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

  # ⛔ status MUST be 2. Banshee's constants (banshee.php): USER_STATUS_DISABLED
  # = 0, USER_STATUS_CHANGEPWD = 1, USER_STATUS_ACTIVE = 2 — and its login query
  # is `... where (username=%s or email=%s) and status != USER_STATUS_DISABLED`
  # (libraries/banshee/core/user.php:138), so a status-0 row is never FOUND and
  # every login answers "Login incorrect" no matter the password. Upstream's dump
  # seeds the admin as 0 because it expects /setup to activate it; copying that
  # would re-disable the admin on EVERY start (cs#349). Not 1: the platform derives
  # and re-applies the password each boot, so a forced change would be undone.
  mariadb --socket="$SOCKET" -uroot "$DB_NAME" <<-SQL
	UPDATE users SET password = '${hash}', email = '${ADMIN_EMAIL}', status = 2
	WHERE username = '${ADMIN_USER}';
	SQL
  log "admin password set for '${ADMIN_USER}'"
}

# 32 alphanumerics, the shape of upstream's random_string(32). Bounded input and a
# `cut` that drains it, for the SIGPIPE reason given at the DB password below.
random_key() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-32; }

# The resources half of upstream's /setup, which this image disables (write_config).
# Its import step gives each organisation a resources_key and the site a
# secret_website_code (models/setup.php import_sql), then makes
# resources/<key>/<dir> for every USER_SUB_DIRECTORIES entry (create_directories).
# The dump seeds both values empty. Without a key every vault upload path is
# resources//tokens/ and the upload fails, so a new table can get no tokens or
# maps. Without the secret, the websocket group key (an HMAC of the adventure
# title keyed by that secret) is computable from the title alone, and cauldrond
# admits any client that names a group to it. Only empty values are filled, so
# an install that has a key or secret keeps it; the directories are re-made on
# every boot, which also repairs one that went missing.
provision_resources() {
  local org key dir dirs
  for org in $(mariadb --socket="$SOCKET" -uroot -N "$DB_NAME" -e "select id from organisations where resources_key = ''"); do
    key=$(random_key)
    [ "${#key}" -eq 32 ] || die "could not generate a resources key"
    mariadb --socket="$SOCKET" -uroot "$DB_NAME" -e "update organisations set resources_key = '${key}' where id = ${org} and resources_key = ''"
    log "set the resources key for organisation ${org}"
  done

  key=$(random_key)
  [ "${#key}" -eq 32 ] || die "could not generate the site secret"
  local set_secret="update settings set value = '${key}' where \`key\` = 'secret_website_code' and value = ''; select row_count()"
  if [ "$(mariadb --socket="$SOCKET" -uroot -N "$DB_NAME" -e "$set_secret")" = 1 ]; then
    log "set the site secret"
  fi

  # Read the list from the app, as set_admin_password reads the hash algorithm,
  # so an upstream bump that adds a resource type cannot drift from a copy here.
  dirs=$(php83 -r 'require "/var/www/cauldron/libraries/cauldron.php"; echo implode(" ", USER_SUB_DIRECTORIES);') \
    || die "could not read the resource directories from the app"
  [ -n "$dirs" ] || die "the app lists no resource directories"
  for key in $(mariadb --socket="$SOCKET" -uroot -N "$DB_NAME" -e "select resources_key from organisations where resources_key != ''"); do
    for dir in $dirs; do
      mkdir -p "$DATA_DIR/resources/$key/$dir"
    done
  done
}

# ── php-fpm sizing ──────────────────────────────────────────────────────────
# The shipped pool sets memory_limit for the nano tier (128M). A token or portrait
# upload decodes the whole image in one PHP worker (banshee/image.php): 4096x4096
# takes about 64 MB, 8192x8192 about 256 MB, and past the limit PHP dies
# mid-request with a blank 500. A map is only measured, from its header
# (patches/map-dimensions-from-header.patch). So the limit follows the container: the share
# of the cgroup's memory limit left for php-fpm's children after the rest of the
# stack (MariaDB, nginx, cauldrond: under 128 MB together), never below the
# shipped 128M and never above 1024M, in 16M steps. nano stays at 128M, micro
# gets 288M, small 640M, medium and up 1024M. With no cgroup limit (a plain
# `docker run`) the shipped value stands.
#
# php-fpm's pool files live in the image, which this uid cannot edit, so the
# shipped php-fpm.conf and www.conf are copied to $RUN_DIR/php and edited there,
# the way write_config treats Banshee's files, and php-fpm starts on that copy.
PHP_FPM_CONF="$RUN_DIR/php/php-fpm.conf"

write_php_fpm_config() {
  local dist_pool=/etc/php83/php-fpm.d/www.conf pool="$RUN_DIR/php/www.conf"
  cp /etc/php83/php-fpm.conf "$PHP_FPM_CONF"
  cp "$dist_pool" "$pool"
  sed -i "s|^include=.*|include=${pool}|" "$PHP_FPM_CONF"
  grep -q "^include=${pool}$" "$PHP_FPM_CONF" || die "could not point php-fpm.conf at $pool"

  local limit_file=/sys/fs/cgroup/memory.max limit children shipped mib
  [ -r "$limit_file" ] || limit_file=/sys/fs/cgroup/memory/memory.limit_in_bytes
  limit=$(cat "$limit_file" 2>/dev/null || echo max)
  case "$limit" in ''|*[!0-9]*) log "php-fpm memory_limit stays at the shipped value (no cgroup memory limit)"; return ;; esac

  children=$(sed -n 's/^pm\.max_children *= *\([0-9]*\).*/\1/p' "$pool")
  shipped=$(sed -n 's/^php_admin_value\[memory_limit\] *= *\([0-9]*\)M.*/\1/p' "$pool")
  [ -n "$children" ] && [ -n "$shipped" ] || die "www.conf no longer carries pm.max_children and memory_limit in the expected form"
  mib=$(( (limit / 1048576 - 128) / children / 16 * 16 ))
  [ "$mib" -gt "$shipped" ] || mib=$shipped
  [ "$mib" -le 1024 ] || mib=1024
  sed -i "s|^php_admin_value\[memory_limit\] *=.*|php_admin_value[memory_limit] = ${mib}M|" "$pool"
  grep -q "^php_admin_value\[memory_limit\] = ${mib}M$" "$pool" || die "could not set memory_limit in $pool"
  log "php-fpm memory_limit ${mib}M (container memory $((limit / 1048576)) MB, ${children} children)"
}

# ── Shutdown ────────────────────────────────────────────────────────────────
shutdown() {
  log "shutting down"
  [ -n "${NGINX_PID:-}" ] && kill -QUIT "$NGINX_PID" 2>/dev/null || true
  [ -n "${CAULDROND_PID:-}" ] && kill -TERM "$CAULDROND_PID" 2>/dev/null || true
  [ -n "${PHPFPM_PID:-}" ] && kill -QUIT "$PHPFPM_PID" 2>/dev/null || true
  if [ -n "${MARIADB_PID:-}" ]; then
    mariadb-admin --socket="$SOCKET" -uroot shutdown >/dev/null 2>&1 || kill -TERM "$MARIADB_PID" 2>/dev/null || true
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
fi
DB_PASS=$(cat "$DB_PASS_FILE")

start_mariadb
seed_database "$DB_PASS"
write_config "$DB_PASS"
set_admin_password
provision_resources
sync_seats
write_edge_key

write_php_fpm_config
log "starting php-fpm"
php-fpm83 --nodaemonize --fpm-config "$PHP_FPM_CONF" &
PHPFPM_PID=$!

log "starting cauldrond (websocket, 127.0.0.1:2001 — proxied by nginx)"
/usr/sbin/cauldrond &
CAULDROND_PID=$!

# Readiness BARRIER, not a fixed sleep: cauldrond binds :2001 a beat after it's
# forked, and nginx will happily start proxying /websocket to a port nobody is
# listening on yet — so a client (or CI) that connects the instant the homepage
# is up races the daemon and gets a 502. Block until :2001 is actually accepting
# before we start nginx, so "homepage up" deterministically implies "websocket
# up". Same poll-the-real-condition pattern as start_mariadb above (proceeds the
# moment it's ready; dies fast if the daemon crashes; bounded so it can't hang).
waited=0
# cauldrond binds 0.0.0.0:2001; match the port with a trailing-boundary so it
# can't hit :20010 etc. netstat is the tool present in the base image (no ss).
until netstat -ltn 2>/dev/null | grep -qE ':2001[[:space:]]'; do
  kill -0 "$CAULDROND_PID" 2>/dev/null || die "cauldrond exited before binding :2001"
  sleep 1
  waited=$((waited + 1))
  [ "$waited" -lt 30 ] || die "cauldrond did not bind :2001 within 30s"
done
log "cauldrond ready on :2001 after ${waited}s"

log "starting nginx"
# -e: nginx opens its compiled-in error log before it reads the config, and that
# default file is not this uid's to write.
nginx -e /dev/stderr -g 'daemon off;' &
NGINX_PID=$!

log "ready — Cauldron VTT ${CAULDRON_VERSION:-4.0} listening on :80"

# Exit as soon as anything dies so the restart policy can act.
wait -n
die "a managed process exited — tearing down the container"
