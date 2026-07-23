# Contributing to cfg-server-cauldronvtt

This repo is a container around [Cauldron VTT](https://gitlab.com/hsleisink/cauldron) —
a `Dockerfile`, an `entrypoint.sh`, and the `rootfs/` config tree. Upstream is
fetched at build time (never vendored), and there is no Node toolchain and no
test suite; **Docker is the only prerequisite**.

## Build & run locally

See the README's "Local development" section:

```bash
docker build -t cfg-server-cauldronvtt:local .
docker run --rm -p 8090:80 -v /tmp/cauldron-data:/data \
  -e CAULDRON_ADMIN_PASSWORD=changeme cfg-server-cauldronvtt:local
```

When changing the Dockerfile, `entrypoint.sh`, or anything under `rootfs/`,
verify by hand:

- fresh boot against an **empty** `/data` seeds the schema and admin account;
- reboot against an **existing** `/data` logs `already provisioned` and loses
  nothing;
- the websocket upgrade check in the README returns `101 Switching Protocols`
  (a plain page load does not exercise `cauldrond`);
- memory stays inside the `nano` tier — the README's Sizing section explains
  why `pm.max_children` and the MariaDB tuning are load-bearing.

## Ground rules

- **Pin upstream by commit SHA**, never by tag or archive checksum (tags are
  mutable; GitLab archive tarballs are not byte-stable). Upgrades follow the
  README's "Upgrading upstream" checklist.
- **Don't widen PHP execution.** `location = /index.php` only — users upload
  into `/files` and `/resources`, so a generic `\.php$` handler is an RCE.
- **Keep MariaDB socket-only** (`skip-networking`) and the DB password
  in-container.
- The realtime tier's client-side-only isolation is an upstream property we
  ship knowingly (see the README's Security notes) — don't try to patch it
  in this repo.

## Commit messages & PRs

Use [Conventional Commits](https://www.conventionalcommits.org/)
(`feat`, `fix`, `chore`, `docs`, `ci`, `build`). Fork, branch from `main`,
describe how you tested the container, and explain the *why* in the PR
description.

## License

Contributions to this repo are accepted under [AGPL-3.0-only](LICENSE). The
built image also contains Cauldron VTT (GPL-2.0-or-later) and cauldrond/wsServer
(GPL-3.0) — keep their licence files and headers intact.
