# Troubleshooting

Symptom first. Run `xf doctor` before anything else — it checks port exposure, every PHP extension XenForo 2.3 needs, the database, Elasticsearch health and document count, and HTTP reachability in one pass.

---

## Setup and startup

### `docker.exe not found` / `docker: command not found`

The runtime isn't installed, or you're in a shell that predates the install — PATH changes don't reach open terminals. Open a new one.

`xf.ps1` also probes the standard Docker Desktop and Rancher Desktop install paths before giving up, so if it still fails the runtime genuinely isn't there.

### `required variable MARIADB_PASSWORD is missing a value`

Working as intended. The compose file uses `${VAR:?message}` so the stack refuses to start rather than falling back to a default password. Run `xf setup`, which generates the secrets, or fill them in `stack/.env` yourself.

### `XF_SOURCE is not set`

You need to point the stack at your own licensed XenForo files — they are not distributed with this repo. Set `XF_SOURCE` in `stack/.env` to either an unpacked directory containing `src/` and `cmd.php`, or a XenForo release zip.

### MariaDB never becomes healthy

```bash
docker compose logs mariadb
```

Almost always the VM is short on memory. Raise it in the runtime's settings (4 GB minimum for this stack, since Elasticsearch reserves 2 GB of it).

If the logs mention corrupt tablespaces, the data volume is damaged — most commonly because someone bind-mounted the data directory onto a Windows or macOS path. Use the named volume as shipped; `docker compose down -v` and set up again.

### Elasticsearch exits immediately with `max virtual memory areas vm.max_map_count [65530] is too low`

Linux hosts only. See [platform-linux.md](platform-linux.md#5-elasticsearch-needs-a-kernel-setting):

```bash
sudo sysctl -w vm.max_map_count=262144
```

### Elasticsearch restarts partway through a reindex

The JVM is being OOM-killed. `ES_HEAP` must be at or below half of `ES_MEM_LIMIT`. Raising the heap without raising the limit causes exactly this.

```bash
docker inspect xf-elasticsearch --format '{{.State.OOMKilled}}'
```

### Port 80 already in use

```bash
# Linux/macOS
lsof -nP -iTCP:80 -sTCP:LISTEN
```
```powershell
# Windows
Get-NetTCPConnection -LocalPort 80 -State Listen | Select-Object OwningProcess
```

Set `HTTP_PORT=8080` in `.env` and use <http://localhost:8080>. Update the board URL in the XenForo ACP so generated links match. **Keep the `127.0.0.1:` prefix** in the compose file — change the port, never the binding.

### `setup` stopped at "Board URL" / "Primary board email", or aborted with `Aborted.`

Versions before v1.1.0 did not pass `--email`, `--title`, `--url` or `--skip-statistics` to `xf:install`, so the installer stopped to ask. With no keyboard attached (CI, an AI agent, a pipe) it aborted. Update the checkout. The values now come from `XF_ADMIN_EMAIL`, `XF_BOARD_TITLE` and `HTTP_PORT` in `.env`, and usage statistics are never switched on.

### `doctor` warns that the Docker Engine is older than 28.3.3

Upgrade the engine (or Docker Desktop). This is a security warning, not a compatibility one: older engines can let other machines on your network reach ports bound to `127.0.0.1`. See [SECURITY.md](SECURITY.md), Rule 1. Podman numbers its versions differently; there the warning means "check", not "broken".

### Image build fails with `cp: cannot stat 'modules/*'` on PHP 8.5

The Dockerfile from before v1.1.0 tried to build OPcache as a separate extension, which PHP 8.5 no longer allows because OPcache is compiled in. Update the checkout.

### `xf setup` says XenForo is already installed, but the board is empty

The database lives in a Docker volume while `internal_data/` lives on the host, so destroying the volume leaves `install-lock.php` behind. `setup` decides from the *database* (table count), not the lock file, and clears a stale lock automatically. If you genuinely want to start over: `xf reset`.

---

## Permissions

### `Permission denied` writing `data/` or `internal_data/`

**Linux:** the container's `www-data` (uid 33) doesn't match your host user. This stack remaps `www-data` to your uid via the `PUID`/`PGID` build args; `xf.sh setup` sets them from `id -u`/`id -g`. If you changed users or moved the checkout, rebuild:

```bash
./xf.sh build && ./xf.sh restart
docker compose exec xenforo id www-data     # should show your uid
```

**Any platform**, as a direct fix:

```bash
docker compose exec -u root xenforo chown -R www-data:www-data \
    /var/www/html/data /var/www/html/internal_data
```

Do **not** `chmod -R 777`. That makes PHP files world-writable in a directory the web server executes from.

**Fedora/RHEL:** if permissions look right but access is still denied, it's SELinux. Add `:z` to the bind mount — see [platform-linux.md](platform-linux.md#4-selinux-fedora-rhel-centos-rocky).

---

## Add-on development

### My other add-ons disappeared from the board

You mounted at **vendor** level instead of add-on level:

```yaml
- ../MyAddon/upload/src/addons/Vendor:/var/www/html/src/addons/Vendor    # ✘ shadows the whole vendor dir
- ../MyAddon/upload/src/addons/Vendor/AddonId:/var/www/html/src/addons/Vendor/AddonId   # ✓
```

The mount replaces the entire directory, so every other add-on from that vendor vanishes from the webroot.

### Changes to my add-on aren't showing

Depends what changed:

| Changed | Needed |
|---|---|
| PHP class | Nothing — development mode picks it up immediately |
| `_output/` dev files | `xf import Vendor/AddonId` (`xf-dev:import`) |
| `_data/*.xml`, edited by hand | `xf addon rebuild Vendor/AddonId` (`xf:addon-rebuild`) |
| Templates or phrases | `xf rebuild` |
| `addon.json` version | `xf addon upgrade Vendor/AddonId` |
| Anything, and still nothing | Check the mount is actually in place: `docker compose exec xenforo ls -la src/addons/Vendor/AddonId` |

### Add-on install fails with no useful message

```bash
xf errors 10            # last 10 XenForo errors
xf log                  # Apache error log
```

If the failure is in `_data` import, the cause is very often a schema mistake that no static check catches:

- an attribute XenForo actually reads as a **child element** (`default_value`, `edit_format_params`, `sub_options`, `relation` in `options.xml`)
- a `data_type="array"` option with no `<sub_options>` — this aborts the whole add-on data import, so install and upgrade both fail outright

Both are invisible to XML well-formedness checks and to `php -l`. This class of defect is the reason this stack exists.

### `xf-rebuild:search` — command not found

The command is `xf-rebuild:search`, not `xf:rebuild-search`. XenForo builds every rebuild command as `xf-rebuild:<name>`. `xf reindex` wraps it.

---

## Search

### Searching returns nothing at all

Check in this order — the reasoning and the measurements behind it are in [elasticsearch-xfes.md](elasticsearch-xfes.md#old-content-doesnt-come-back-in-search):

1. **Is XFES enabled and pointed at `elasticsearch:9200`?** Not `localhost` — inside the container that's the container itself.
2. **Is the index populated?** `xf doctor` reports the `xf` document count. If it's 0, run `xf reindex`.
3. **Is it the analyzer?** XFES ships with stemming off, so `flangebolts` will not match content containing `flangebolt`. Enable stemming, then reindex — changing an analyzer *deletes and recreates the index*, so the reindex is mandatory or the board searches an empty index.

### Old content is missing, recent content is fine

Not an indexing problem. Two separate mechanisms:

- The **result cap** (`maximumSearchResults`, default 200) genuinely excludes old results — it's applied before permission filtering. Raise it toward 625; above that the ×4/×4 scaling hits Elasticsearch's 10000 clamp silently.
- The **recency half-life** doesn't exclude anything, but at the default 365 days a 2019 document scores 0.8% of an identical 2026 one, so it sorts to the bottom.

### Cluster status is `yellow`

Correct and expected. A single node cannot allocate replica shards. Only **red** is a problem.

---

## Performance

### Everything is slow on Windows or macOS

The webroot bind mount crosses a VM boundary; XenForo is ~13,000 files. `xf-dev:rebuild-caches` feels it most.

- Windows: move the webroot into the WSL2 filesystem, or run the CLI work from inside WSL.
- macOS: enable VirtioFS, or consider OrbStack/Colima with `--mount-type=virtiofs`. Alternatively make the webroot a named volume and keep only your add-on source bind-mounted.
- Both: make sure **Xdebug is off** (`xf xdebug off`). It roughly halves throughput.

### Requests are slow even on Linux

Check Xdebug is off, then confirm opcache is enabled:

```bash
docker compose exec xenforo php -i | grep -E 'opcache.enable|validate_timestamps'
```

---

## Security-adjacent

### `xf doctor` warns that ports are published on all interfaces

Stop and fix it before doing anything else. Something in `docker-compose.yml` lost its `127.0.0.1:` prefix. The environment this repo derives from was compromised in ~76 minutes through exactly that. See [SECURITY.md](SECURITY.md).

```bash
docker compose config | grep -A1 host_ip     # every mapping must show 127.0.0.1
```

### I committed `.env`

Rotate every secret in it first — assume they're public. Then purge it from history with `git filter-repo` (or BFG); deleting it in a new commit leaves it fully readable in the old one.

---

## Starting over

```bash
xf reset          # containers + volumes + webroot, asks for confirmation
```

Or by hand:

```bash
docker compose down -v
rm -rf stack/webroot
xf setup
```

Take a database dump first if there's anything in it you want:

```bash
# from stack/; variables expand inside the container, password via MYSQL_PWD
docker compose exec -T mariadb sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" mariadb-dump -u"$MARIADB_USER" "$MARIADB_DATABASE"' > backup.sql
```
