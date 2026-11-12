# XenForo + Elasticsearch Docker Stack

A reproducible local development environment for [XenForo](https://xenforo.com/) 2.3 add-on work: Apache + PHP, MariaDB, and Elasticsearch for [XenForo Enhanced Search](https://xenforo.com/purchase/) (XFES) — brought up with one command on **Linux, macOS or Windows**.

```bash
git clone https://github.com/ENF-JP/xenforo-elasticsearch-docker
cd xenforo-elasticsearch-docker

# point it at your own licensed XenForo files, then:
./scripts/linux/xf.sh setup          # Linux / macOS
.\scripts\windows\xf.ps1 setup       # Windows
```

---

## ⚠️ Read this before you change a `ports:` line

**The whole reason we have decided to build this repo is related to a test environment that was purposely exposed to the open internet. The test environment this repo is derived from was compromised in roughly 76 minutes. Vigilance in security is a must, no longer is ever just a consideration.**

An early version published MariaDB as `"3306:3306"` with weak credentials. Docker reads a bare `host:container` mapping as `0.0.0.0` — every interface — and installs its own NAT rules, so the host firewall did not block it. An automated scanner found it, dropped the database, and left a `RECOVER_YOUR_DATA` ransom table.

Nothing of value was lost: the database was a blank install minutes old. It would have been trivially worse with real data.

Everything in **[docs/SECURITY.md](docs/SECURITY.md)** is written from that incident and the review that followed. If you read one file in this repo, read that one.

---

## What you need to supply

**XenForo source is not distributed here, and never will be.** XenForo is commercial, licensed software. This repo contains only the build scripts, container definitions and documentation — all of it original work.

You supply your own licensed copy by setting `XF_SOURCE` in `stack/.env`:

```ini
# an unpacked directory containing src/ and cmd.php ...
XF_SOURCE=/home/you/xenforo_2.3.x/upload
# ... or a XenForo release zip
XF_SOURCE=/home/you/Downloads/xenforo_2.3.x.zip
```

The setup script copies it into a disposable working copy, so your reference download stays untouched.

The same applies to XenForo Enhanced Search: the Elasticsearch service here is the *backend* XFES talks to. XFES itself is a separately licensed XenForo add-on that you install into the board yourself.

---

## What you get

| Service | Image | Published? |
|---|---|---|
| `xenforo` | Apache + PHP 8.4 (built here; 8.2–8.5 selectable) | `127.0.0.1:80` only |
| `mariadb` | `mariadb:11.4` (LTS; 11.8 / 12.3 selectable) | **no** — reachable only inside the compose network |
| `elasticsearch` | `elasticsearch:8.19.25` | **no** — and it must never be; see below |
| `mailpit` *(optional)* | `axllent/mailpit:v1.33.1` | `127.0.0.1:8025`, only with `--profile mail` |

Every image is pinned to an explicit version in `stack/.env`. What changed between releases, and what to do on an existing stack, is in [CHANGELOG.md](CHANGELOG.md) and [docs/upgrading.md](docs/upgrading.md).

Plus a helper script — `xf.sh` on Linux/macOS, `xf.ps1` on Windows — with identical commands on both:

```
setup      Generate secrets, build, start, install XenForo
doctor     Check engine version, ports, PHP extensions, DB, Elasticsearch, HTTP
addon      install | upgrade | rebuild | enable | disable | uninstall Vendor/AddonId
import     _output dev files -> database
export     database -> _data XML
rebuild    Rebuild caches               reindex  Full Elasticsearch reindex
errors     Last n XenForo errors        log      Tail the Apache log
shell      Bash in the container        db       MariaDB client
es         Query Elasticsearch safely   xdebug   on | off
creds      Show the generated admin login
reset      Destroy everything and start over
```

`doctor` is the one to run first whenever something looks wrong. It checks the Docker Engine is new enough to keep loopback-bound ports private, verifies every PHP extension XenForo 2.3 needs, confirms the database has tables, checks Elasticsearch cluster health and the document count of the `xf` index, hits the board over HTTP, and warns loudly if any container port has escaped to `0.0.0.0`.

---

## Documentation

| Document | What's in it |
|---|---|
| **[docs/SECURITY.md](docs/SECURITY.md)** | **Do's and don'ts.** Port binding, secrets, the unauthenticated-Elasticsearch problem, why dev settings must never reach a public host, incident response. |
| [docs/platform-linux.md](docs/platform-linux.md) | Native Docker Engine, rootless mode, the bind-mount UID problem and how this stack solves it, SELinux, systemd |
| [docs/platform-windows.md](docs/platform-windows.md) | WSL2, Docker Desktop vs Rancher Desktop and the licence threshold, PowerShell 5.1 traps, filesystem performance |
| [docs/platform-macos.md](docs/platform-macos.md) | Docker Desktop / OrbStack / Colima, VirtioFS, Apple Silicon and the `elasticsearch` image architecture question |
| [docs/architecture.md](docs/architecture.md) | Every design decision and its trade-off: Apache vs nginx, named volumes vs bind mounts, opcache settings, why the webroot is a copy |
| [docs/elasticsearch-xfes.md](docs/elasticsearch-xfes.md) | Wiring XFES to this stack, single-node "yellow" health, reindexing, and a measured explanation of why old content stops appearing in search |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptom-first index of everything that has actually gone wrong |
| [docs/ai-assisted.md](docs/ai-assisted.md) | Letting an AI coding agent drive the stack safely — allowlists, what it can verify unattended, what it must never be allowed to run |
| [docs/upgrading.md](docs/upgrading.md) | Moving an existing stack to a new release: version changes, behaviour changes, and which ones are one-way |
| [CHANGELOG.md](CHANGELOG.md) | Every change, per release |
| [ROADMAP.md](ROADMAP.md) | Suggested additions, ranked, with the reasoning for each |

---

## Repository layout

```
stack/                     the environment itself
  docker-compose.yml       services, networks, volumes
  Dockerfile               Apache + PHP image
  .env.example             every tunable, documented (copy to .env)
  config.php.template      XenForo dev config; reads credentials from getenv()
scripts/
  linux/xf.sh              helper for Linux and macOS
  windows/xf.ps1           helper for Windows (PowerShell 5.1 and 7)
docs/                      see the table above
```

`stack/.env` and `stack/webroot/` are git-ignored. The webroot is 13,000+ disposable files and contains licensed XenForo source; `.env` holds generated secrets. Neither belongs in a repository.

---

## Requirements

- A container runtime with Compose v2 or later (current releases are v5): Docker Engine, Docker Desktop, Rancher Desktop, OrbStack or Colima
- **Docker Engine 28.3.3 or later.** Older engines can let other machines on your network reach ports bound to `127.0.0.1` — see [docs/SECURITY.md](docs/SECURITY.md), Rule 1. `doctor` warns if yours is older.
- ~4 GB RAM free for the VM (Elasticsearch alone takes 2 GB), ~6 GB disk
- Your own licensed XenForo 2.3 files (XenForo 2.3 itself accepts PHP 7.2+; the images here cover PHP 8.2–8.5)

Per-platform install steps are in the platform documents above.

---

## Licence

[MIT](LICENSE) — for the scripts, container definitions and documentation in this repository, all of which are original work.

This licence covers **this repository's contents only**. It grants you nothing with respect to XenForo, XenForo Enhanced Search, or any third-party add-on; those remain subject to their own licences, and none of them are contained or distributed here. Elasticsearch, MariaDB, PHP and the other images are licensed by their respective projects and pulled from their own registries at build time. See [NOTICE](NOTICE) for the full breakdown.

Not affiliated with or endorsed by XenForo Ltd.
