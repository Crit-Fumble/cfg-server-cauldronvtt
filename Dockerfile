# syntax=docker/dockerfile:1.7
#
# cfg-server-cauldronvtt — container around Cauldron VTT, a PHP/MySQL virtual
# tabletop. Unlike Terraria/Factorio this is not a single binary: Cauldron needs
# a webserver, PHP, a MySQL-compatible database, and its own websocket daemon.
# All four run in ONE container because KindAdapter.provision() returns a single
# ServerHandle — a per-install DB sidecar is exactly the pattern the Spacebar
# pivot discarded (docs/agent/spacebar-shared-platform.md).
#
# Upstream is NOT vendored — it is fetched at build time pinned to a commit, the
# same shape as cfg-server-terraria fetching the official server zip. That keeps
# this repo's own sources AGPL-3.0 (like its siblings) while the built image
# contains GPL-2.0-or-later software. See README "Licensing".
#
# Why alpine and not php:8.3-apache: this is sized to fit the `nano` tier
# (0.25 thread / 512 MB) and MariaDB sets the memory floor. nginx + php-fpm on
# musl costs ~25-40 MB against Apache+mod_php's ~60-90 MB, which is the
# difference between comfortable and OOM-under-load. See README "Sizing".
#
# Build:
#   docker build -t cfg-server-cauldronvtt:local .
#
# Run (local test — CAULDRON_ADMIN_PASSWORD is required, there is no default):
#   docker run --rm -p 8090:80 -v /tmp/cauldron-data:/data \
#     -e CAULDRON_ADMIN_PASSWORD=changeme cfg-server-cauldronvtt:local
#
# CFG-hosted: core-server provisions one container per user installation via the
# Server Manager kind-registry (kinds/cauldronvtt.ts → services/cauldronvtt/launch.ts).

# Pinned to the v4.0 tag's commit, NOT the tag and NOT a tarball checksum:
# GitLab's auto-generated archives are not byte-stable, so a sha256 pin on
# /-/archive/ would spuriously fail. A commit SHA is immutable; a tag is not.
ARG CAULDRON_COMMIT=c5606f1c451349e11db0a7004567f0076078286d
ARG CAULDRON_VERSION=4.0

# ── Build stage: fetch upstream + compile the websocket daemon ───────────────
FROM alpine:3.21 AS build

ARG CAULDRON_COMMIT

RUN apk add --no-cache git cmake make gcc musl-dev tar

WORKDIR /build
RUN git clone --no-checkout https://gitlab.com/hsleisink/cauldron.git src && \
    git -C src checkout --detach "$CAULDRON_COMMIT" && \
    rm -rf src/.git

# cauldrond ships as a tarball inside the repo. It is wsServer (GPL-3.0) with a
# Cauldron-specific main(); CMakeLists bakes PORT/UID/GID in at compile time, so
# they are set here rather than configured at runtime.
#
# UID/GID 82 is alpine's www-data — the same account nginx and php-fpm run as,
# so all three agree on who owns public/files and public/resources.
#
# CMAKE_POLICY_VERSION_MINIMUM: upstream declares cmake_minimum_required(3.0),
# which CMake >= 4 refuses outright and 3.31 deprecates. Pinning the policy
# floor keeps this building as the base image's CMake moves forward.
RUN tar xzf src/extra/cauldrond.tar.gz -C /build && \
    cd /build/cauldrond && \
    sed -i 's|^set(UID .*|set(UID 82)|; s|^set(GID .*|set(GID 82)|' CMakeLists.txt && \
    cmake -S . -B build -DCMAKE_POLICY_VERSION_MINIMUM=3.5 && \
    make -C build && \
    strip build/cauldrond

# ── Runtime image ───────────────────────────────────────────────────────────
FROM alpine:3.21

ARG CAULDRON_VERSION
LABEL org.opencontainers.image.title="cfg-server-cauldronvtt"
LABEL org.opencontainers.image.description="Crit-Fumble Cauldron VTT server container"
LABEL org.opencontainers.image.source="https://github.com/Crit-Fumble/cfg-server-cauldronvtt"
LABEL org.opencontainers.image.licenses="AGPL-3.0-only"
LABEL org.opencontainers.image.version="${CAULDRON_VERSION}"

# bash is not cosmetic: the supervisor uses `wait -n` to exit as soon as ANY
# managed process dies, so Docker's restart policy can do its job. busybox ash
# has no `wait -n` and would silently keep a half-dead container "running".
#
# tini is PID 1 to reap zombies and forward SIGTERM — MariaDB needs a clean
# shutdown or it replays the redo log (slow) and can corrupt on repeat SIGKILL.
RUN apk add --no-cache \
      bash tini \
      nginx \
      mariadb mariadb-client \
      php83 php83-fpm php83-mysqli php83-gd php83-xml php83-xsl \
      php83-session php83-mbstring php83-opcache php83-ctype php83-fileinfo \
    && rm -rf /var/cache/apk/* \
    # Alpine ships NO www-data user (only, on some images, the group). nginx,
    # php-fpm and cauldrond must all agree on one account or they cannot share
    # the upload dirs — and cauldrond's uid is compiled in at 82, so 82 it is.
    && (getent group www-data >/dev/null || addgroup -g 82 -S www-data) \
    && (getent passwd www-data >/dev/null || adduser -u 82 -S -D -H -G www-data -s /sbin/nologin www-data)

COPY --from=build /build/src /var/www/cauldron
COPY --from=build /build/cauldrond/build/cauldrond /usr/sbin/cauldrond
COPY rootfs/ /
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/sbin/cauldrond

# public/files and public/resources are user-writable and must survive restarts,
# so they are symlinked to /data by the entrypoint. Everything else in the tree
# is read-only application code owned by root.
#
# /run/mysqld and /run/php are tmpfs-ish socket dirs recreated per boot.
RUN mkdir -p /data /run/mysqld /run/php /run/nginx /tmp/php-sessions /var/lib/nginx/tmp && \
    chown -R www-data:www-data /data /run/mysqld /run/php /run/nginx /tmp/php-sessions /var/lib/nginx && \
    rm -rf /var/www/cauldron/public/files /var/www/cauldron/public/resources

# Runs as root so the entrypoint can chown the bind-mounted /data (whose host
# ownership is set by the platform's per-install gid) before dropping each
# managed process to www-data. Nothing listens as root: nginx workers, php-fpm
# pools and cauldrond all run as uid 82.
EXPOSE 80/tcp

ENV CAULDRON_DB_NAME=cauldron \
    CAULDRON_DB_USER=cauldron \
    CAULDRON_ADMIN_USERNAME=admin \
    CAULDRON_ADMIN_EMAIL=admin@localhost \
    CAULDRON_WEBSOCKET_PORT=443 \
    CAULDRON_ENABLE_MARKET=no

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://127.0.0.1/ >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
