# cfg-server-cauldronvtt

Container image for [Cauldron VTT](https://gitlab.com/hsleisink/cauldron) — a lightweight,
licence-free virtual tabletop — hosted per user by Crit-Fumble's Server Manager.

Cauldron exists in the platform to close a specific gap: **a user with no FoundryVTT licence cannot
use VTT hosting at all.** Cauldron needs no licence, so the only cost to the user is compute.

It is deliberately a different product from Foundry, not a cheaper clone. No character sheets, no
spell lists, no module ecosystem — a map, tokens, dice and Fog of War. Best for groups who want to
start playing in under a minute.

## What's in the image

Four processes in one container, supervised by `entrypoint.sh` under `tini`:

| Process | Role |
|---|---|
| **nginx** | serves static files, routes everything else to `index.php`, proxies `/websocket` to cauldrond |
| **php-fpm 8.3** | the application (Banshee framework) |
| **MariaDB** | Banshee ships exactly one DB driver — `mysqli` — so this is not optional |
| **cauldrond** | the realtime daemon (wsServer), listening on `127.0.0.1:2001` |

They share one container because `KindAdapter.provision()` returns a single `ServerHandle`.

**One routed port (80).** nginx proxies the websocket internally, so the platform's TLS terminator
needs exactly one upstream. Port `8080` serves only nginx `stub_status`, published to the Docker host
for core-server's activity probe and never routed by Caddy.

## Upstream is fetched, not vendored

The Dockerfile clones upstream at build time pinned to a **commit SHA**.

The pin lives only in the Dockerfile (`ARG CAULDRON_COMMIT` + `CAULDRON_VERSION`) — read it there
rather than restating it here.

> Pin the commit, never the tag or an archive checksum. Tags are mutable, and GitLab's
> `/-/archive/` tarballs are **not byte-stable** — a `sha256` pin on one will fail spuriously.

## Licensing

This repository's own sources (Dockerfile, entrypoint, configs) are **AGPL-3.0-only**, like its
`cfg-server-*` siblings. Upstream is not vendored here, so nothing in this repo is under another
licence.

The **built image** contains:

- **Cauldron VTT** — GPL-2.0-or-later, © Hugo Leisink
- **cauldrond**, derived from [wsServer](https://github.com/Theldus/wsServer) — GPL-3.0, © Davidson Francis

Both are copyleft and compatible with our AGPL-3.0 posture, and neither has network copyleft, so
hosting alone creates no source-disclosure obligation. Do not strip their `LICENSE` files or
headers from the image.

## Configuration

| Env | Default | Notes |
|---|---|---|
| `CAULDRON_ADMIN_PASSWORD` | — | **Required.** No default; the container refuses to boot without it |
| `CAULDRON_ADMIN_USERNAME` | `admin` | The seeded account |
| `CAULDRON_ADMIN_EMAIL` | `admin@localhost` | |
| `CAULDRON_WEBSOCKET_PORT` | `443` | The port the **browser** connects to, not the daemon's |
| `CAULDRON_DB_NAME` / `CAULDRON_DB_USER` | `cauldron` | |
| `CAULDRON_ENABLE_MARKET` | `no` | Gates the adventure/map market |
| `CAULDRON_EDGE_KEY` | — | The key the platform's edge signs its identity header with ([Sign-in](#sign-in)). Unset: password sign-in only |
| `CAULDRON_ADMIN_CERT_SERIAL` | — | The host's serial, which signs the host in as the admin |
| `CAULDRON_SEATS` | — | The members with a seat, one `<serial> <username> <full name>` line each. Unset: no account but the admin's is touched |

The database password is **generated in-container** on first boot and persisted to `/data/.dbpass`.
It is deliberately not an env var: nothing outside the container can reach MariaDB (it listens on a
unix socket only, `skip-networking`), so an env var would only leak it into `docker inspect`.

Upstream seeds the admin account with the literal string `none` as its password — not a valid hash —
**and** with `status = 0`, which Banshee defines as `USER_STATUS_DISABLED` (its login query excludes
disabled rows). Either alone keeps the account unusable. The entrypoint applies
`CAULDRON_ADMIN_PASSWORD` **and** sets `status = 2` (`USER_STATUS_ACTIVE`) on every boot.

### Sign-in

Nobody types a password on a CFG-hosted server. Banshee has a client-certificate login: with
`HTTPS` on and `TLS_CERT_SERIAL` matching an account's `cert_serial`, it signs that account in and
makes its own session. No certificate reaches the container. The platform's edge vouches for the
member instead, with one header on each request it forwards:

```
X-Cfg-Kind-Identity: v1.<serial>.<expires>.<mac>
```

`<mac>` is the hex HMAC-SHA256 of `v1.<serial>.<expires>` under `CAULDRON_EDGE_KEY`, and
`<expires>` a Unix time at most five minutes ahead. `cfg-identity.php`, which php-fpm prepends to
every PHP request, checks both and only then sets `TLS_CERT_SERIAL`. Without the key a header
signs nobody in, so neither a client nor another container can forge one.

The host signs in as the admin (`CAULDRON_ADMIN_CERT_SERIAL`). A member with a seat has an account
of their own, a Player in the admin's group, which `cfg-seats.php` writes from `CAULDRON_SEATS` at
every boot, before the app starts:

- a seat with no account gets one, with no password that verifies;
- a deactivated account whose seat is back is active again, characters and all (accounts match by
  serial);
- an account that carries a serial and is no longer a seat is deactivated, never deleted.

Names, roles and characters are the host's to change, in Cauldron; the sync writes nothing else.
A malformed list stops the boot. Self-registration is off: a registered visitor would start a
group of their own on the host's server.

### Volume

`/data` is the per-installation mount:

```
/data/mysql/       MariaDB datadir
/data/files/       Cauldron's own files and user uploads → symlinked to public/files
/data/resources/   user resources    → symlinked to public/resources
/data/.dbpass      generated DB password (0600)
```

The files Cauldron ships in `public/files` (the default adventure image, the empty map, the
effects, brushes and the rest, about 17 MiB) are kept in the image at `/usr/share/cauldron/files`.
Each boot copies any of them that `/data/files` lacks, one file at a time, and never replaces a
file that is already there, so a host's own file under the same name stays. A shipped file the host
deleted comes back at the next boot. A file that cannot be copied (a full disk) is logged and the
server boots without it.

Nothing in the container runs as root. It starts as `www-data` (uid 82), or as any uid given with
`--user`, and every process in it runs as that one uid. `/data` must belong to it: the entrypoint
never changes ownership, and it refuses to start on a mount it cannot write. The MariaDB `root`
account has no password; it is reachable only through a unix socket in a directory that uid alone
can enter. A volume created by an earlier, root-based image works for any uid: its first boot here
moves that root to the same login and drops the anonymous and `www-data` accounts and the test
database that image left.

## Sizing

Fits the **`nano`** tier (0.25 thread / 512 MB). Measured idle: **80 MiB**.

Two choices in the image earn that, and both should be understood before changing them:

- **nginx + php-fpm on musl, not Apache + mod_php.** Saves ~40 MB, which is the difference between
  comfortable and OOM-under-load at this tier.
- **MariaDB tuned in `my.cnf.d/cauldron.cnf`.** Stock defaults assume a dedicated database host;
  `performance_schema` alone costs ~80–100 MB.

> ⚠️ **`pm.max_children = 3` is bounded by argon2, not by throughput.** Banshee hashes with
> `PASSWORD_ARGON2I` (`banshee.php:16`) and PHP's argon2i defaults to `m=65536`, so **every**
> password hash or verify transiently allocates ~64 MB. The realistic worst case is a whole party
> hitting the login form at once when a session starts. Three children bounds that at ~192 MB.
> **Raise it only together with the memory tier — they are coupled.**

## Security notes

**Only `index.php` executes.** nginx uses `location = /index.php`, not a `\.php$` regex, and
explicitly denies `.php` under `/files` and `/resources`. Users upload map images and video into
those trees; an Apache + mod_php deployment would execute a `.php` dropped there. Do not add a
generic PHP handler.

**Realtime isolation is client-side only — this is inherent to upstream.** `cauldrond` has no
authentication. A client joins a group by sending a group key, and each frame goes to every other
client in the sender's group; `adventure.js` filters on arrival. The group key is an HMAC of the
adventure's title keyed by the site secret (`secret_website_code`), which the entrypoint sets on
first boot. Upstream's dump leaves it empty, and an empty secret makes every group key computable
from a title. Per-container hosting makes the broadcast domain exactly one user's install, which
resolves cross-tenant leakage. It does **not** fix visibility inside an adventure: a player with
devtools can see DM-private frames — hidden tokens, unrevealed fog, secret rolls, whispers — in
their own adventure's group.

This matches what a user gets self-hosting Cauldron, and it matches Cauldron's own positioning
("groups who trust each other"). **It differs from our Foundry offering and must be stated plainly
in the UI, not buried.**

`MAX_CLIENTS` is compiled at 32 (`ws.h`), i.e. 32 concurrent players per install — ample for one
group, and a recompile if that ever changes.

## Local development

```bash
docker build -t cfg-server-cauldronvtt:local .

mkdir -p /tmp/cauldron-data
docker run --rm -p 8090:80 --user "$(id -u):$(id -g)" \
  -v /tmp/cauldron-data:/data \
  -e CAULDRON_ADMIN_PASSWORD=changeme \
  cfg-server-cauldronvtt:local
```

`--user` makes the container run as you, so it can write the directory you just made. Without it
the container runs as uid 82, and on Linux the directory must then belong to 82
(`sudo chown 82:82 /tmp/cauldron-data`).

Then <http://localhost:8090> — sign in as `admin`.

Verify the realtime path separately, since a plain page load does not exercise it:

```bash
curl -i --max-time 4 --http1.1 \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  http://127.0.0.1:8090/websocket
# expect: HTTP/1.1 101 Switching Protocols
```

## Upgrading upstream

1. Bump `CAULDRON_COMMIT` (and `CAULDRON_VERSION`) in the Dockerfile to the new tag's commit.
2. Rebuild and boot against an **empty** `/data` — confirm the schema imports, the setup module
   is disabled, the log sets the resources key and the site secret, and a token uploaded in the
   Vault lands under `/data/resources/<key>/tokens/`. The entrypoint reads the resource
   directories from upstream's `USER_SUB_DIRECTORIES`, so a new type needs no change here.
3. Boot against an **existing** `/data` — confirm the seed guard logs `already provisioned` and no
   data is lost. Upstream ships no migration tooling, so a schema change between releases is
   something you must check for by hand. A file new to upstream's `public/files` is copied in at
   that boot; one upstream changed under the same name is not, since it may be the host's.
4. Re-run the websocket check above; `cauldrond` is versioned independently inside the tarball.
5. Confirm the sign-in still holds: Banshee's certificate login still reads `TLS_CERT_SERIAL` and
   `users.cert_serial` (`models/banshee/login.php`, `user::login_ssl_auth`), and the `users` and
   `user_role` columns `cfg-seats.php` writes are unchanged. The build's sign-in smoke test fails if
   either moved.
