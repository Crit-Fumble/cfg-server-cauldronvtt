# syntax=docker/dockerfile:1.7
#
# cfg-server-cauldronvtt — container around Cauldron VTT, a PHP/MySQL virtual
# tabletop. Unlike Terraria/Factorio this is not a single binary: Cauldron needs
# a webserver, PHP, a MySQL-compatible database, and its own websocket daemon.
# All four run in ONE container because KindAdapter.provision() returns a single
# ServerHandle — a per-install DB sidecar is exactly the pattern the platform
# rejects (docs/agent/spacebar-shared-platform.md).
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

# Pinned to the commit of the CAULDRON_VERSION release tag, NOT the tag and NOT
# a tarball checksum: GitLab's auto-generated archives are not byte-stable, so a
# sha256 pin on /-/archive/ would spuriously fail. A commit SHA is immutable; a
# tag is not.
ARG CAULDRON_COMMIT=e7217c10a45916d703d962a894c8902f6e1c2402
ARG CAULDRON_VERSION=4.1

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

# Both re-declared here: an ARG from an earlier stage is out of scope after
# FROM, and an undeclared ${VAR} expands to empty — a silently blank label.
ARG CAULDRON_VERSION
ARG CAULDRON_COMMIT
LABEL org.opencontainers.image.title="cfg-server-cauldronvtt"
LABEL org.opencontainers.image.description="Crit-Fumble Cauldron VTT server container"
LABEL org.opencontainers.image.source="https://github.com/Crit-Fumble/cfg-server-cauldronvtt"
LABEL org.opencontainers.image.licenses="AGPL-3.0-only"
# ⚠️ `org.opencontainers.image.version` does NOT survive to the published image:
# docker/metadata-action emits its own OCI label set and `--label` last-wins, so
# the release workflow overwrites this with the git tag (e.g. v0.1.0). Auditing
# "what upstream is in here?" via the OCI label therefore reads back OUR tag. Kept
# for `docker build` users, who do get the real value; the cfg.* labels below are
# the ones that survive publishing because the metadata action never emits that
# namespace.
LABEL org.opencontainers.image.version="${CAULDRON_VERSION}"
LABEL cfg.upstream.version="${CAULDRON_VERSION}"
LABEL cfg.upstream.commit="${CAULDRON_COMMIT}"

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

# Nothing in this image starts as root, and the uid it does start as may be one
# the image has never heard of (`docker run --user`; the platform runs each
# member's server as that member's own uid). So everything a process writes is
# in one of two places:
#   /data          the per-installation mount; it must belong to that uid.
#   /tmp/cauldron  sockets, pid files, nginx temp, PHP sessions and the three
#                  settings files the entrypoint fills in. It is NOT in the
#                  image: the entrypoint makes it at start, mode 0700, owned by
#                  the uid it runs as. The image adds nothing writable by
#                  "anyone" to what its base already has.
# The rest of the tree is read-only application code owned by root. The app
# reads its settings and writes its uploads at fixed paths inside that tree, so
# those paths are links made here, once, to where the real files will be:
#   settings/{banshee,cauldron,public_modules}.conf → /tmp/cauldron/settings/
#     (the shipped copies move to /usr/share/cauldron/settings as templates)
#   public/files, public/resources → /data
# php-fpm's own log goes to stderr: its default file is root's to write.
RUN mkdir -p /data /usr/share/cauldron/settings && \
    chown www-data:www-data /data && \
    for f in banshee.conf cauldron.conf public_modules.conf; do \
      mv "/var/www/cauldron/settings/$f" /usr/share/cauldron/settings/ && \
      ln -s "/tmp/cauldron/settings/$f" "/var/www/cauldron/settings/$f" || exit 1; \
    done && \
    rm -rf /var/www/cauldron/public/files /var/www/cauldron/public/resources && \
    ln -s /data/files /var/www/cauldron/public/files && \
    ln -s /data/resources /var/www/cauldron/public/resources && \
    sed -i 's|^;*error_log = .*|error_log = /dev/stderr|' /etc/php83/php-fpm.conf && \
    grep -q '^error_log = /dev/stderr$' /etc/php83/php-fpm.conf

# uid 82. Docker takes HOME from /etc/passwd, where www-data's is a dir that
# does not exist and a uid given with `--user` has no entry at all.
USER www-data
ENV HOME=/tmp
EXPOSE 80/tcp
# Activity-probe endpoint (nginx stub_status) — host-published, not Caddy-routed.
EXPOSE 8080/tcp

ENV CAULDRON_DB_NAME=cauldron \
    CAULDRON_DB_USER=cauldron \
    CAULDRON_ADMIN_USERNAME=admin \
    CAULDRON_ADMIN_EMAIL=admin@localhost \
    CAULDRON_WEBSOCKET_PORT=443 \
    CAULDRON_ENABLE_MARKET=no

# The homepage only serves once the entrypoint's readiness barrier has cleared
# (cauldrond bound to :2001, then nginx), so a passing check means the app AND
# websocket are up — core-server's status/proxy gate on this `healthy` signal
# instead of guessing from container state. 10s interval so "ready" tracks
# actual readiness closely rather than lagging a full 30s behind it.
HEALTHCHECK --interval=10s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://127.0.0.1/ >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
