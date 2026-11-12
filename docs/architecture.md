# Architecture and design decisions

Every choice here has a trade-off. This document records what was chosen, what was rejected, and why — so you can disagree deliberately rather than by accident.

---

## Service layout

```
        host (loopback only)
              │
              │  127.0.0.1:80
              ▼
      ┌───────────────┐
      │   xenforo     │  Apache + PHP 8.4
      │  (webroot)    │
      └───┬───────┬───┘
          │       │        compose network — no host ports
          ▼       ▼
   ┌──────────┐  ┌───────────────┐
   │ mariadb  │  │ elasticsearch │
   │ 11.4     │  │ 8.19          │
   └──────────┘  └───────────────┘
```

Only the web container publishes a port. The other two are reachable by service name (`mariadb`, `elasticsearch`) from inside the network and are unreachable from the host — deliberately. See [SECURITY.md](SECURITY.md).

---

## Apache in the PHP image, not nginx + php-fpm

**Chosen because:** it is one service instead of two, and XenForo ships `.htaccess` rules that Apache honours directly. With nginx you must translate those rules into a server block by hand, and re-translate them whenever XenForo changes them — a recurring source of "friendly URLs 404 after upgrade".

**Cost:** Apache with mod_php uses more memory per connection than nginx + php-fpm, and scales worse. For a development box serving one developer, this is irrelevant.

**If you want nginx anyway:** split into `nginx` and `php-fpm` services sharing the webroot volume, and port XenForo's `.htaccess` into a `location` block. Do it if your production environment is nginx and you're chasing an environment-specific bug — otherwise the simpler stack is worth more than the fidelity.

---

## PHP 8.4 by default

XenForo 2.3's installer accepts **PHP 7.2 and up**. The official `php` images only carry maintained PHP branches, so this stack can build **8.2, 8.3, 8.4 or 8.5**. 8.4 is the default: it is in active support (8.3 receives security fixes only), and every extension the image installs supports it. 8.5 is the newest release and the one to test deprecations against.

```bash
docker compose build --build-arg PHP_VERSION=8.5
```
or set `PHP_VERSION` in `.env`. The image tag includes the version, so switching back and forth doesn't force a rebuild each time.

Two details in the Dockerfile follow from supporting 8.5:

- **OPcache is part of PHP itself from 8.5.** `docker-php-ext-install opcache` fails there, so the Dockerfile only builds it as a separate extension on 8.4 and older. `php -m` lists `Zend OPcache` on every version either way.
- **Xdebug is pinned to the 3.5 line**, the first with PHP 8.5 support. APCu and Xdebug versions are `ARG`s at the top of the Dockerfile.

The base image is pinned to Debian 13 with the `-trixie` tag suffix, so the OS under the image changes only when you change it.

**A linter is not a substitute for this.** Code that passes `php -l` on 8.3 can still use syntax unavailable on 8.2 — and if your add-on advertises 8.2 support, only running it on 8.2 proves anything.

---

## The webroot is a *copy*, not your XenForo download

`xf setup` copies `XF_SOURCE` into `stack/webroot/` once and never touches the source again.

**Why:** your reference download stays pristine, so you can diff against it, re-copy from it, and be certain a broken experiment didn't corrupt the only clean copy you have. The webroot is disposable by design — `xf reset` deletes it without ceremony.

**Consequence:** upgrading XenForo means pointing `XF_SOURCE` at the new version and re-running setup, not upgrading in place. For add-on development that is the honest workflow anyway: you want to know your add-on installs cleanly on a fresh board of the target version.

---

## Add-ons are bind-mounted individually

```yaml
- ../MyAddon/upload/src/addons/Vendor/AddonId:/var/www/html/src/addons/Vendor/AddonId
```

**Mount at add-on level, never vendor level.** Mounting `../MyAddon/upload/src/addons/Vendor` onto `/var/www/html/src/addons/Vendor` replaces the *entire vendor directory* in the webroot — every other add-on from that vendor disappears from the board. The symptom is bizarre ("my other add-ons uninstalled themselves") and the cause is invisible unless you know to look.

Your add-on source stays in its own repository, edited with your own tools, with its own git history. The container just sees it.

---

## MariaDB data is a named volume, never a bind mount

Bind-mounting a MySQL/MariaDB data directory onto a Windows or macOS filesystem corrupts InnoDB. The file-locking and `fsync` semantics the storage engine relies on are not faithfully reproduced across the VM boundary. The failure is not immediate — it shows up later as corrupt tables, which is worse than failing fast.

The named volume lives inside the VM's own filesystem where those semantics hold, and it's faster besides.

Same reasoning for `es-data`.

**Consequence:** `docker compose down -v` destroys the database. That's the intended behaviour for a disposable dev environment, but it's why `xf reset` requires typing `RESET`.

---

## Opcache: enabled, with timestamp validation

```ini
opcache.enable = 1
opcache.revalidate_freq = 0
opcache.validate_timestamps = 1
```

`validate_timestamps=1` with `revalidate_freq=0` means PHP stats each file on every request and recompiles if it changed — your edits take effect immediately, while cached bytecode still saves the parse cost. This is the correct development setting.

Production would use `validate_timestamps=0` (never stat, never notice changes until a restart). Don't copy that here or you'll spend an hour wondering why your edits do nothing.

---

## Xdebug: installed but disabled

Xdebug roughly halves request throughput even when not actively debugging. It's baked into the image so it's there when needed, but the config file ships as `zz-xdebug.ini.disabled` and the helper scripts rename it into place:

```bash
xf xdebug on    # copies the file, restarts PHP
xf xdebug off   # removes it
```

Port **9003** (the Xdebug 3 default). It connects *out* to `host.docker.internal`, which `extra_hosts: host-gateway` provides on Linux and Docker Desktop provides natively.

---

## Healthcheck-gated startup

```yaml
depends_on:
  mariadb:
    condition: service_healthy
  elasticsearch:
    condition: service_healthy
```

Plain `depends_on` waits for the container to *start*, not to be *ready* — so PHP would come up while MariaDB was still initialising and XenForo would fail to connect. The `condition: service_healthy` form waits for the healthcheck to pass.

Elasticsearch's healthcheck accepts **green or yellow**:

```bash
curl -fsS http://localhost:9200/_cluster/health | grep -qE '"status":"(green|yellow)"'
```

A single-node cluster can never allocate replica shards, so yellow is its permanent steady state — not a fault. Only red is a failure. Treating yellow as unhealthy would mean the stack never starts.

---

## Elasticsearch memory: `ES_HEAP` and `ES_MEM_LIMIT` are a pair

```yaml
ES_JAVA_OPTS=-Xms${ES_HEAP:-1g} -Xmx${ES_HEAP:-1g}
mem_limit: ${ES_MEM_LIMIT:-2g}
```

Elastic's guidance is a heap of at most half the container's memory — the JVM needs the rest for off-heap structures, and Lucene wants page cache. Raising `ES_HEAP` without raising `ES_MEM_LIMIT` gets the JVM OOM-killed under load, which presents as Elasticsearch restarting mid-reindex for no visible reason.

`-Xms` equals `-Xmx` deliberately: a fixed heap avoids GC pauses from resizing.

Also set: `cluster.routing.allocation.disk.threshold_enabled=false`, because a dev laptop is often near its disk limit, and Elasticsearch's 95% flood stage flips indices to **read-only** — after which every index request fails with an error that doesn't mention disk space.

---

## Credentials come from the environment, never a file

`config.php.template` reads `getenv()`:

```php
$config['db']['password'] = getenv('XF_DB_PASSWORD') ?: '';
```

Compose populates that from `.env`. So the file that lands in the webroot contains no secret and could be committed harmlessly, while the actual secret lives in one git-ignored place.

The `:?` guard in the compose file means a missing secret stops the stack with a clear message rather than silently falling back to a default:

```yaml
MARIADB_PASSWORD: ${MARIADB_PASSWORD:?set it in .env}
```

That is not a stylistic choice. A default password is how the environment this repo derives from was compromised.

---

## Container naming is prefixed and configurable

```yaml
container_name: ${COMPOSE_PREFIX:-xf}-mariadb
```

Fixed container names make `docker exec` commands memorable, but they collide if you run two stacks. To run a second stack — a 2.2 board beside a 2.3 board, say — give it its own checkout and set **three** variables in its `.env`: `COMPOSE_PREFIX` (container names), `COMPOSE_PROJECT_NAME` (the Compose project, and so the volume names) and `HTTP_PORT`.

`COMPOSE_PREFIX` alone is not enough. Both stacks would still be the same Compose project, sharing one database volume and one search index, and bringing one up would recreate the other's containers. `COMPOSE_PROJECT_NAME` overrides the `name:` line in the compose file. Never change it on a stack that already holds data: the old volumes stay on disk under the old name and the stack starts empty.

The helper scripts use `docker compose exec <service>` rather than `docker exec <container>` throughout, so they keep working whatever the prefix is.

---

## What is deliberately *not* here

| Not included | Why |
|---|---|
| XenForo source | Commercial software. You supply your own licensed copy. |
| A `latest` tag anywhere | Reproducibility. Pinned versions, refreshed deliberately. |
| Redis / Valkey | XenForo works fine without a cache backend at dev scale; adding one hides cache-invalidation bugs that would bite in production. See [ROADMAP.md](../ROADMAP.md). |
| TLS / HTTPS | Loopback HTTP is appropriate for local development, and a self-signed cert adds friction to every tool. If you need to test HTTPS-only behaviour, put a reverse proxy in front. |
| A production-shaped image | Different requirements, opposite settings. Mixing the two produces an image that is bad at both. |
| Automatic XenForo upgrades | Upgrading in place hides whether your add-on installs cleanly on a fresh board — which is the thing you actually need to know. |
