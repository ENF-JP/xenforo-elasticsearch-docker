# macOS

Like Windows, macOS runs Linux containers inside a VM, so the same filesystem-boundary cost applies. Unlike Windows, you have several mature runtime choices and the shell is already POSIX — `scripts/linux/xf.sh` is the helper on macOS too.

---

## 1. Choose a runtime

| Runtime | Cost | Notes |
|---|---|---|
| **OrbStack** | Free personal / paid commercial | Fastest filesystem of the four by a wide margin, lowest idle battery use. The pragmatic default for XenForo's 13,000-file webroot. |
| **Docker Desktop** | Free under the 250-employee / $10M threshold; paid above | The reference implementation. Enable VirtioFS. |
| **Colima** | Free (MIT) | `brew install colima docker docker-compose`. Lima-based, CLI-only, no licence question at any company size. |
| **Podman Desktop** | Free | Works, but `docker compose` compatibility needs `podman-compose` or the Docker-compatible socket; the healthcheck-gated `depends_on` in this stack is the part most likely to need attention. |

**OrbStack**

```bash
brew install orbstack
```

**Colima** — allocate resources explicitly, since the defaults are too small for Elasticsearch:

```bash
brew install colima docker docker-compose
colima start --cpu 4 --memory 8 --disk 60 --vm-type=vz --mount-type=virtiofs
```

`--vm-type=vz` uses Apple's Virtualization.framework and `--mount-type=virtiofs` is substantially faster than the sshfs default. Both need macOS 13+.

**Docker Desktop** — Settings → Resources: at least **4 GB RAM** (Elasticsearch reserves 2 GB) and 4 CPUs. Settings → General: enable **VirtioFS**.

Verify:

```bash
docker version
docker compose version
```

---

## 2. Apple Silicon

The images this stack uses all publish `linux/arm64` variants — `php:8.3-apache`, `mariadb:11.4`, and Elasticsearch since 7.17. Everything runs natively on M-series hardware; there is no Rosetta emulation involved and no `platform:` override needed.

Two things to know:

- **If you add a service that is amd64-only**, pin it explicitly rather than letting Docker guess:
  ```yaml
  some-legacy-service:
    image: vendor/thing:1.2
    platform: linux/amd64      # runs under emulation - slow, but works
  ```
- **`pecl install` compiles from source** in the Dockerfile (apcu, xdebug). That works fine on arm64 but makes the first build a couple of minutes slower than on x86. Subsequent builds are cached.

---

## 3. Bring it up

```bash
git clone https://github.com/ENF-JP/xenforo-elasticsearch-docker
cd xenforo-elasticsearch-docker
chmod +x scripts/linux/xf.sh

cp stack/.env.example stack/.env
$EDITOR stack/.env          # set XF_SOURCE to your licensed XenForo files

./scripts/linux/xf.sh setup
```

### bash version

macOS ships **bash 3.2** (2007) because of GPLv3 licensing. `xf.sh` uses arrays and `[[ ]]` in ways bash 3.2 handles, but it is developed against bash 4+ and not regression-tested on 3.2. If you hit a syntax error:

```bash
brew install bash
/opt/homebrew/bin/bash ./scripts/linux/xf.sh setup
```

The `#!/usr/bin/env bash` shebang picks up the Homebrew build automatically once it precedes `/bin/bash` on your `PATH`.

`zsh` is macOS's default *interactive* shell, which is irrelevant here — the script declares its own interpreter.

---

## 4. Filesystem performance

Same trade-off as Windows: bind mounts cross a VM boundary. In rough order, fastest first: OrbStack, Colima with virtiofs, Docker Desktop with VirtioFS, anything with the legacy osxfs/gRPC-FUSE.

`xf-dev:rebuild-caches` is the operation that feels it most. Everyday browsing is fine thanks to opcache.

If you want native-speed I/O, keep the webroot inside the VM rather than on your Mac's filesystem — change the webroot bind mount in `stack/docker-compose.yml` to a named volume:

```yaml
volumes:
  - xf-webroot:/var/www/html      # instead of ${XF_WEBROOT}:/var/www/html
```

You lose direct Finder/editor access to the webroot, which is a real loss for reading `internal_data/error_log.php` — use `./xf.sh errors` instead. Add-on bind mounts still work normally, so your actual source stays on the Mac where your editor and git are.

---

## 5. Ports

macOS reserves few low ports, but AirPlay Receiver historically listened on 5000 and some setups have services on 80. If port 80 is taken:

```bash
lsof -nP -iTCP:80 -sTCP:LISTEN
```

Set `HTTP_PORT=8080` in `.env`, use <http://localhost:8080>, and update the board URL in the XenForo ACP. **Do not remove the `127.0.0.1:` prefix** in `docker-compose.yml` — see [SECURITY.md](SECURITY.md).

macOS's application firewall does not filter Docker's published ports any more reliably than `ufw` does on Linux. Loopback binding is the control that actually works.

---

## 6. File ownership

Docker Desktop, OrbStack and Colima all translate ownership across the VM boundary, so the `PUID`/`PGID` remapping that Linux needs is unnecessary here — the defaults (33) are correct and `xf.sh setup` writing your real uid does no harm.

If you see permission errors on `data/` or `internal_data/` anyway, the direct fix works because the translation layer maps it back sensibly:

```bash
docker compose exec -u root xenforo chown -R www-data:www-data /var/www/html/data /var/www/html/internal_data
```

---

## 7. Xdebug

```bash
./scripts/linux/xf.sh xdebug on
```

Connects to `host.docker.internal:9003`. PhpStorm: Preferences → PHP → Debug, set the Xdebug port to 9003, and map `/var/www/html` to `stack/webroot`. VS Code uses the same `launch.json` shown in [platform-windows.md](platform-windows.md) with the path adjusted.

Turn it off when finished — it roughly halves throughput.

---

## 8. Battery and idle cost

Elasticsearch is a JVM that stays resident and does periodic background work. On a laptop this is noticeable.

```bash
./scripts/linux/xf.sh down          # stop everything when you're not developing
```

If you're working on an add-on that has nothing to do with search, you can run without it — comment out the `elasticsearch` service *and* the `depends_on` entry that references it in `stack/docker-compose.yml`. XenForo falls back to MySQL search automatically when XFES can't reach a cluster, so the board still works.
