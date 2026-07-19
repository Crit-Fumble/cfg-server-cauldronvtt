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

They share one container because `KindAdapter.provision()` returns a single `ServerHandle`. A
per-install database sidecar is precisely the pattern the Spacebar pivot discarded — see
`docs/agent/spacebar-shared-platform.md` in the dev-tools repo.

**One exposed port (80).** nginx proxies the websocket internally, so the platform's TLS terminator
needs exactly one upstream.

## Upstream is fetched, not vendored

The Dockerfile clones upstream at build time pinned to a **commit SHA**, matching how
`cfg-server-terraria` fetches the official server zip.

Pinned to `c5606f1c451349e11db0a7004567f0076078286d` (tag `v4.0`, 2025-10-15).

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

The database password is **generated in-container** on first boot and persisted to `/data/.dbpass`.
It is deliberately not an env var: nothing outside the container can reach MariaDB (it listens on a
unix socket only, `skip-networking`), so an env var would only leak it into `docker inspect`.

Upstream seeds the admin account with the literal string `none` as its password — not a valid hash,
so the account cannot be logged into until `CAULDRON_ADMIN_PASSWORD` is applied. That is a safe
default and the entrypoint preserves it.

### Volume

`/data` is the per-installation mount:

```
/data/mysql/       MariaDB datadir
/data/files/       user uploads      → symlinked to public/files
/data/resources/   user resources    → symlinked to public/resources
/data/.dbpass      generated DB password (0600)
```

## Sizing

Fits the **`nano`** tier (0.25 thread / 512 MB). Measured idle on 2026-07-19: **80 MiB**.

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
authentication and no rooms: `ws_sendframe()` fans every frame to every client on the port, and
`adventure.js` filters on arrival. Per-container hosting makes the broadcast domain exactly one
user's group, which resolves cross-tenant leakage. It does **not** fix intra-install visibility:
a player with devtools can see DM-private frames — hidden tokens, unrevealed fog, secret rolls,
whispers — inside their own install.

This matches what a user gets self-hosting Cauldron, and it matches Cauldron's own positioning
("groups who trust each other"). **It differs from our Foundry offering and must be stated plainly
in the UI, not buried.**

`MAX_CLIENTS` is compiled at 32 (`ws.h`), i.e. 32 concurrent players per install — ample for one
group, and a recompile if that ever changes.

## Local development

```bash
docker build -t cfg-server-cauldronvtt:local .

docker run --rm -p 8090:80 \
  -v /tmp/cauldron-data:/data \
  -e CAULDRON_ADMIN_PASSWORD=changeme \
  cfg-server-cauldronvtt:local
```

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
2. Rebuild and boot against an **empty** `/data` — confirm the schema imports and the setup module
   is disabled.
3. Boot against an **existing** `/data` — confirm the seed guard logs `already provisioned` and no
   data is lost. Upstream ships no migration tooling, so a schema change between releases is
   something you must check for by hand.
4. Re-run the websocket check above; `cauldrond` is versioned independently inside the tarball.
