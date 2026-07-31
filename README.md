# XenForo + Elasticsearch Docker Stack

A reproducible local development environment for [XenForo](https://xenforo.com/) 2.3 add-on work: Apache + PHP, MariaDB, and Elasticsearch for [XenForo Enhanced Search](https://xenforo.com/purchase/) (XFES) — brought up with one command on **Linux, macOS or Windows**.

It exists because static checks are not enough. An add-on can pass `php -l`, pass XML well-formedness, pass every unit test, and still fail to install on a real board — because `options.xml` used an attribute where XenForo reads a child element, or declared an array option without `sub_options`. Neither is catchable without a real install. This stack makes "install it on a clean board and click through the ACP" a 30-second step instead of an afternoon.

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
XF_SOURCE=/home/you/xenforo_2.3.12/upload
# ... or a XenForo release zip
XF_SOURCE=/home/you/Downloads/xenforo_2.3.12.zip
```

The setup script copies it into a disposable working copy, so your reference download stays untouched.

The same applies to XenForo Enhanced Search: the Elasticsearch service here is the *backend* XFES talks to. XFES itself is a separately licensed XenForo add-on that you install into the board yourself.

---

## What you get

| Service | Image | Published? |
|---|---|---|
| `xenforo` | Apache + PHP 8.3 (built here) | `127.0.0.1:80` only |
| `mariadb` | `mariadb:11.4` | **no** — reachable only inside the compose network |
| `elasticsearch` | `elasticsearch:8.15.0` | **no** — and it must never be; see below |
| `mailpit` *(optional)* | `axllent/mailpit` | `127.0.0.1:8025`, only with `--profile mail` |

Plus a helper script — `xf.sh` on Linux/macOS, `xf.ps1` on Windows — with identical commands on both:

```
setup      Generate secrets, build, start, install XenForo
doctor     Check ports, PHP extensions, DB, Elasticsearch, HTTP
addon      install | upgrade | enable | disable | uninstall Vendor/AddonId
import     _data XML -> database        export   database -> _output
rebuild    Rebuild caches               reindex  Full Elasticsearch reindex
errors     Last n XenForo errors        log      Tail the Apache log
shell      Bash in the container        db       MariaDB client
es         Query Elasticsearch safely   xdebug   on | off
creds      Show the generated admin login
reset      Destroy everything and start over
```

`doctor` is the one to run first whenever something looks wrong. It verifies every PHP extension XenForo 2.3 needs, confirms the database has tables, checks Elasticsearch cluster health and the document count of the `xf` index, hits the board over HTTP, and warns loudly if any container port has escaped to `0.0.0.0`.

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

- A container runtime with Compose v2: Docker Engine, Docker Desktop, Rancher Desktop, OrbStack or Colima
- ~4 GB RAM free for the VM (Elasticsearch alone takes 2 GB), ~6 GB disk
- Your own licensed XenForo 2.3 files

Per-platform install steps are in the platform documents above.

---

## Licence

[MIT](LICENSE) — for the scripts, container definitions and documentation in this repository, all of which are original work.

This licence covers **this repository's contents only**. It grants you nothing with respect to XenForo, XenForo Enhanced Search, or any third-party add-on; those remain subject to their own licences, and none of them are contained or distributed here. Elasticsearch, MariaDB, PHP and the other images are licensed by their respective projects and pulled from their own registries at build time. See [NOTICE](NOTICE) for the full breakdown.

Not affiliated with or endorsed by XenForo Ltd.
