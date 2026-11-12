# Linux

The best-performing option of the three. Docker runs natively — no VM, no filesystem translation layer — so the 13,000-file XenForo webroot behaves the way it does on a real server.

---

## 1. Install Docker Engine

Use Docker's own repository, not your distribution's `docker.io` package, which is usually well behind and sometimes ships without the Compose plugin.

**Debian / Ubuntu**

```bash
curl -fsSL https://get.docker.com | sh
```

For a non-scripted install, follow <https://docs.docker.com/engine/install/>.

**Fedora / RHEL**

```bash
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
```

**Arch**

```bash
sudo pacman -S docker docker-compose
sudo systemctl enable --now docker
```

Verify — Compose **v2 or later** is required (`docker compose`, not the old `docker-compose`; current releases are v5), and the engine must be **28.3.3 or later**:

```bash
docker version --format '{{.Server.Version}}'   # 28.3.3 or later
docker compose version
```

The engine version matters for security, not features. Before 28.0, another machine on your network could reach a port published on `127.0.0.1`; 28.2.0–28.3.2 reopened that after a firewalld reload (CVE-2025-54388). Fedora and RHEL use firewalld by default. See [SECURITY.md](SECURITY.md), Rule 1.

---

## 2. Decide how you'll run it: `docker` group vs rootless

### The `docker` group is root

```bash
sudo usermod -aG docker "$USER"    # convenient, and a full privilege grant
```

Anyone in the `docker` group can run:

```bash
docker run -v /:/host -it alpine chroot /host sh
```

That is unrestricted root on the host. This is not a flaw being reported — it is documented, intended behaviour of the Docker daemon socket. On a personal workstation it's a reasonable trade. On a shared or sensitive machine, it is not.

### Rootless mode

```bash
dockerd-rootless-setuptool.sh install
export DOCKER_HOST=unix:///run/user/$UID/docker.sock
```

Everything in this repo works rootless with two caveats:

- **Ports below 1024 cannot be bound.** Set `HTTP_PORT=8080` in `.env` and use <http://localhost:8080>. Also set the board URL in the XenForo ACP to match, or generated links will point at port 80.
- **`mem_limit` needs cgroup v2 delegation.** Most current distributions have this; if Elasticsearch ignores its limit, check `systemd-cgls` and the delegation docs.

Rootless is the better default if the host holds anything you care about.

---

## 3. The bind-mount ownership problem — and how this stack solves it

This is the single most common Linux-specific frustration with containerised PHP, and it does not exist on Docker Desktop for Mac or Windows.

A bind mount passes through the **host's** numeric ownership. Apache in the container runs as `www-data`, uid **33**. Your host user is probably uid **1000**. So:

- The container can't write `data/` or `internal_data/` → XenForo throws permission errors on install.
- `chown -R 33:33 webroot` on the host fixes the container and locks *you* out of your own files.

The usual advice — `chmod -R 777` — is bad advice. It makes every file world-writable, including PHP the web server executes.

**What this stack does instead:** the Dockerfile takes `PUID`/`PGID` build args and remaps `www-data` inside the image to match your host user. `xf.sh setup` fills them in automatically:

```bash
env_set PUID "$(id -u)"
env_set PGID "$(id -g)"
```

So `www-data` inside the container *is* uid 1000, the files stay owned by you on the host, and both sides can write. The remap also relocates any pre-existing account holding that uid, so it works on distributions where uid 1000 is already taken inside the base image.

If you change users or move the checkout, rebuild so the ids are re-baked:

```bash
./xf.sh build && ./xf.sh restart
```

To confirm it took:

```bash
docker compose exec xenforo id www-data
# uid=1000(www-data) gid=1000(www-data)
```

---

## 4. SELinux (Fedora, RHEL, CentOS, Rocky)

With SELinux enforcing, a bind mount is unreadable by the container until it is labelled. The symptom is a blank page plus `Permission denied` in the Apache log, even though the file permissions look correct.

Add `:z` (shared) or `:Z` (private) to the mount in `stack/docker-compose.yml`:

```yaml
volumes:
  - ${XF_WEBROOT:-./webroot}:/var/www/html:z
```

`:z` relabels for sharing between containers; `:Z` labels exclusively for one container. Prefer `:z` here since add-on mounts may overlap.

Do not disable SELinux to fix this. Check what is being denied instead:

```bash
sudo ausearch -m avc -ts recent
```

---

## 5. Elasticsearch needs a kernel setting

Elasticsearch requires `vm.max_map_count` of at least 262144. Most desktop distributions default lower, and the container will exit at startup with `max virtual memory areas vm.max_map_count [65530] is too low`.

```bash
sudo sysctl -w vm.max_map_count=262144                        # now
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-elasticsearch.conf   # persistent
```

This is a host-level setting; the container cannot set it for you. (Docker Desktop on Windows and macOS sets it inside its own VM, which is why the problem is Linux-specific.)

---

## 6. Bring it up

```bash
git clone https://github.com/ENF-JP/xenforo-elasticsearch-docker
cd xenforo-elasticsearch-docker
chmod +x scripts/linux/xf.sh

cp stack/.env.example stack/.env
$EDITOR stack/.env          # set XF_SOURCE to your licensed XenForo files

./scripts/linux/xf.sh setup
```

`setup` generates the secrets, aligns PUID/PGID, copies the webroot, builds the image, starts the three services, waits for MariaDB and Elasticsearch to report healthy, and runs `xf:install`.

Then:

```bash
./scripts/linux/xf.sh doctor
./scripts/linux/xf.sh creds
```

Put it on your PATH if you use it often:

```bash
ln -s "$PWD/scripts/linux/xf.sh" ~/.local/bin/xf
xf doctor
```

---

## 7. Running it at boot

Compose's `restart: unless-stopped` handles this once the Docker daemon starts at boot (`systemctl enable docker`). For rootless, enable lingering so your user's daemon starts without a login:

```bash
sudo loginctl enable-linger "$USER"
systemctl --user enable docker
```

A dev stack starting automatically is a mild security consideration: it will be running when you join an untrusted network. Everything is loopback-bound, but see [SECURITY.md](SECURITY.md).

---

## 8. Firewall — read this even though it sounds boring

**`ufw` does not filter published Docker ports.** Docker inserts rules into the `DOCKER` iptables chain, consulted in `PREROUTING`/`FORWARD` before the `INPUT` chain where `ufw`'s rules live. So:

```bash
sudo ufw default deny incoming     # feels safe
```

...does **not** stop a container published on `0.0.0.0` from being reachable. This is the mechanism that made the 76-minute compromise possible.

The reliable fix is the one this repo already applies: **bind to `127.0.0.1` in the compose file**, so nothing is published to a routable interface in the first place. Verify:

```bash
sudo ss -tlnp | grep -E 'docker|:80|:3306|:9200'
# every line should show 127.0.0.1:<port>, never 0.0.0.0:<port>
```

If you need Docker to respect `ufw`, `ufw-docker` exists — but binding to loopback is simpler and needs no maintenance.

---

## 9. Performance notes

Native Linux needs no filesystem tuning. Two things still help:

- **Opcache** is configured with `validate_timestamps=1`, `revalidate_freq=0` — your edits are picked up immediately while cached bytecode still saves the parse. Leave it.
- **Elasticsearch heap**: `ES_HEAP` must stay at or below half of `ES_MEM_LIMIT`. Raising the heap without raising the limit gets the JVM OOM-killed under load, which presents as Elasticsearch mysteriously restarting mid-reindex.

If the machine has plenty of RAM:

```ini
ES_HEAP=2g
ES_MEM_LIMIT=4g
MARIADB_BUFFER_POOL=1G
```
