# Security: do's and don'ts for XenForo Docker stacks

This document is not theoretical. Every rule in it is here because something went wrong, or because a review found something that was one small change away from going wrong.

**The short version:** a development stack on a laptop is reachable from the internet more often than people believe, contains credentials that are frequently reused elsewhere, and runs with debug settings that would be a serious disclosure on a public host. Treat it as a real system with real consequences, because attackers do.

---

## The incident this repo is built around

An earlier version of this environment published MariaDB with:

```yaml
ports:
  - "3306:3306"        # and "80:80"
```

and credentials `root`/`root`, `xenforo`/`password`.

**Roughly 76 minutes later** an automated scanner had found it, dropped the `xenforo` database, and created a `RECOVER_YOUR_DATA` table demanding payment.

Three things made it possible, and all three are common:

1. **A bare `host:container` mapping means `0.0.0.0`** — every interface, including the one facing the internet. Not localhost. Docker's own words for this default are easy to miss.
2. **Docker installs its own NAT/iptables rules**, which on Linux bypass most `ufw`/`firewalld` configurations, and on Windows do not necessarily hit a Windows Firewall prompt. "My firewall blocks 3306" was believed, and was false.
3. **Default credentials** turned discovery into compromise instantly. Scanning for open 3306 and trying `root/root` is a fully automated, continuous, internet-wide activity.

Nothing of value was lost — the database was a blank install minutes old, and the webroot and add-on source were verified byte-identical afterwards. That was luck, not resilience.

> **"It's only a dev box" is not a mitigation.** It was compromised in under two hours.

---

## Rule 1 — Every published port is explicitly loopback-bound

```yaml
ports:
  - "3306:3306"             # ✘ WRONG — all interfaces, internet-reachable
  - "0.0.0.0:3306:3306"     # ✘ WRONG — same thing, said out loud
  - "127.0.0.1:3306:3306"   # ✓ correct — loopback only
```

**Do:**
- Write the `127.0.0.1:` prefix on every single `ports:` entry, without exception.
- Re-check after any edit. `docker compose config` shows the resolved `host_ip` for each mapping:
  ```bash
  docker compose config | grep -A1 host_ip
  ```
- Keep the automated check. Both helper scripts run `Assert-NoPublicBind` / `assert_no_public_bind` on `up` and `doctor`, which scans `docker ps` for `0.0.0.0:` and `[::]:` and warns in red.

**Don't:**
- Don't assume a host firewall protects you. On Linux, Docker's `DOCKER` iptables chain is consulted before the `INPUT` chain where `ufw` rules live — a published port is reachable even with `ufw` set to deny.
- Don't publish a port "temporarily to test something" and plan to remove it. That is precisely the 76-minute window.
- Don't rely on binding to a LAN address as a safety measure on a laptop that later joins a café or hotel network.

---

## Rule 2 — Don't publish the database at all

The web container reaches MariaDB over the compose network as hostname `mariadb`. The host does not need a port for the stack to work.

**Do:**
- Leave the `ports:` block for `mariadb` commented out, as shipped.
- Use `xf db` / `.\xf.ps1 db` for a SQL prompt — it runs the client *inside* the network.
- If a GUI client genuinely needs access, prefer an SSH tunnel or `docker compose exec`. If you must publish, use `127.0.0.1:3306:3306` and remove it when you're done.

**Don't:**
- Don't publish a database port so that a teammate can reach it. That is a VPN or a bastion's job.

---

## Rule 3 — Elasticsearch here is unauthenticated. Never publish it.

This stack runs Elasticsearch with `xpack.security.enabled=false`, which is reasonable for a single-node dev backend and is what keeps XFES configuration simple. The consequence is absolute:

**Anyone who can reach port 9200 has full administrative control of the cluster, with no credentials.** They can read every indexed post, and they can delete every index.

This is *strictly worse* than the exposed MariaDB above, because there is not even a password to guess. Ransomed open Elasticsearch clusters are a well-documented, ongoing, industry-wide phenomenon.

**Do:**
- Keep the `elasticsearch` service with **no `ports:` entry whatsoever** — as shipped.
- Query it through the web container:
  ```bash
  ./xf.sh es                    # _cat/indices?v
  ./xf.sh es "xf/_count"        # any path
  docker compose exec xenforo curl -s elasticsearch:9200/_cluster/health
  ```
- Keep `action.destructive_requires_name=true` (set in `docker-compose.yml`). It refuses `DELETE /_all` and `DELETE /*`, which turns one class of catastrophic mistake — and one class of drive-by attack — into an error message.

**Don't:**
- Don't add `ports: - "9200:9200"` to use Kibana, Cerebro, Dejavu or any browser tool. Attach that tool to the compose network as another service instead:
  ```yaml
  kibana:
    image: docker.elastic.co/kibana/kibana:8.15.0
    environment: [ELASTICSEARCH_HOSTS=http://elasticsearch:9200]
    ports: ["127.0.0.1:5601:5601"]     # the UI may be published; ES still must not be
  ```
- Don't enable `xpack.security` halfway. Either leave it off and unpublished, or turn it on properly with real credentials and TLS — a cluster with security enabled but a default/blank password is worse than one that is simply unreachable.

---

## Rule 4 — No default credentials, ever

Not `root/root`. Not `admin/admin`. Not `xenforo/password`. Not "just for now".

**Do:**
- Generate long random secrets. Both setup scripts do this automatically on first run:
  ```bash
  # Linux/macOS
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
  ```
  ```powershell
  # Windows — RandomNumberGenerator, not Get-Random, which is not cryptographic
  $chars = (48..57)+(65..90)+(97..122)
  $b = New-Object byte[] 32
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  -join ($b | % { [char]$chars[$_ % $chars.Count] })
  ```
- Keep secrets in `.env`, and keep `.env` git-ignored. It already is.
- Read them into config through the environment — `config.php.template` uses `getenv()`, so no password is ever written into a file that might be committed.
- Use the `:?` guard in compose so the stack *refuses to start* rather than falling back to a default:
  ```yaml
  MARIADB_PASSWORD: ${MARIADB_PASSWORD:?set it in .env}
  ```
- On Linux/macOS, `chmod 600 .env`.

**Don't:**
- Don't commit `.env`. If you already have: rotate every secret in it, then purge the file from history (`git filter-repo`) — deleting it in a new commit leaves it fully readable in the old one.
- Don't paste real secrets into issues, screenshots, or a chat with an AI assistant.
- Don't reuse a password you use anywhere else, on the assumption the box is disposable.
- Don't use `Get-Random` on Windows to generate secrets. It is a deterministic PRNG, not a CSPRNG.

---

## Rule 5 — Development settings must never reach a public host

The image and config here deliberately enable things that are dangerous in production:

| Setting | Where | Why it's dangerous publicly |
|---|---|---|
| `display_errors = On`, `error_reporting = E_ALL` | `Dockerfile` | Leaks absolute paths, SQL fragments and stack traces to any visitor |
| `$config['debug'] = true` | `config.php.template` | Exposes query counts, timings and template debug output |
| `$config['development']['enabled'] = true` | `config.php.template` | Enables ACP development tools that can write files |
| Xdebug (when toggled on) | `Dockerfile` | A remote debugging channel; historically exploited for RCE when exposed |
| `xpack.security.enabled=false` | `docker-compose.yml` | Unauthenticated cluster admin |

**Do:**
- Treat this stack as local-only, by design and forever.
- If you want a production-shaped image, build a separate one: `display_errors=Off`, `opcache.validate_timestamps=0`, no Xdebug, no dev config, security enabled on Elasticsearch, TLS terminated in front.

**Don't:**
- Don't "just deploy the dev compose file to a VPS to show a client". Use a staging host built for it, or a tunnel (`cloudflared`, `ngrok`, `tailscale`) that exposes only HTTP, keeping debug output off while it is reachable.
- Don't leave Xdebug enabled. Beyond the security surface it roughly halves throughput — `xf xdebug off`.

---

## Rule 6 — Understand what a bind mount gives the container

`./webroot:/var/www/html` means the container has read/write access to that host directory. A compromised or malicious dependency inside the container can modify anything under it.

**Do:**
- Mount only what the container needs: the webroot, and each add-on you are actively developing.
- Mount add-ons at **add-on level** (`.../addons/Vendor/AddonId`), not vendor level — mounting `.../addons/Vendor` shadows every other add-on from that vendor in the webroot, which produces baffling "my add-on vanished" symptoms.
- Consider `:ro` for anything the container should not write.

**Don't:**
- Don't bind-mount your whole home directory, source tree root, or `/` into the container "for convenience".
- Don't bind-mount a MariaDB data directory onto a Windows or macOS filesystem. File-locking differences corrupt InnoDB. Use the named volume, as shipped.
- Don't mount your SSH keys, cloud credentials, or `.git` config into a web container.

---

## Rule 7 — Keep images current, and pin them deliberately

**Do:**
- Pin image versions (`mariadb:11.4`, `elasticsearch:8.15.0`) so builds are reproducible and an upstream change cannot silently alter the stack.
- Refresh those pins on a schedule and rebuild: `docker compose pull && docker compose build --pull`.
- Scan occasionally: `docker scout cves xenforo-dev-php:8.3`, or `trivy image <image>`.

**Don't:**
- Don't use `:latest` for infrastructure images. "It worked yesterday" stops being debuggable.
- Don't run months-old images because the stack still starts. The PHP and Elasticsearch images accumulate real CVEs.

---

## Rule 8 — Containers are not a security boundary you should lean on

**Do:**
- Prefer rootless Docker or Podman on Linux if the host matters. See [platform-linux.md](platform-linux.md).
- Keep `no-new-privileges` in mind for services that don't need to escalate:
  ```yaml
  security_opt: ["no-new-privileges:true"]
  ```
- Remember that anyone in the `docker` group on Linux effectively has root on the host — `docker run -v /:/host` is trivially a full takeover. Adding a user to `docker` is granting root.

**Don't:**
- Don't run containers with `--privileged`, `--net=host`, or `--pid=host` for a web stack. Nothing here needs any of them.
- Don't assume a container escape is exotic. Treat the container as roughly as trusted as the host.

---

## Rule 9 — Destructive commands stay manual

`docker compose down -v` destroys the database and the search index. `xf reset` destroys those *and* the webroot.

**Do:**
- Keep the confirmation prompt in `reset` (it requires typing `RESET`).
- Keep destructive commands off any AI agent's permission allowlist — see [ai-assisted.md](ai-assisted.md).
- Take a dump before anything irreversible:
  ```bash
  docker compose exec -T mariadb mariadb-dump -uxenforo -p"$PASS" xenforo > backup.sql
  ```

**Don't:**
- Don't wire `down -v` into a "restart" alias or a watch script. The `-v` is the whole difference between stopping and deleting.

---

## Rule 10 — If it *was* exposed, assume compromise

Discovery of an open port by automated scanners is measured in minutes, not days.

**Do, in order:**
1. **Disconnect it** — `docker compose down`, or pull the network.
2. **Rotate every credential in `.env`**, and anywhere you reused those values. Assume they were read.
3. **Rebuild from scratch** rather than cleaning up: `docker compose down -v`, delete the webroot, `xf setup`. Volumes and file mounts can carry persistence.
4. **Verify your source tree** against a known-good copy — `git status`, `git diff`, and for XenForo add-ons, the hash manifest:
   ```bash
   sha256sum -c hashes.txt        # or XenForo's own file health check in the ACP
   ```
5. **Check what else that machine could reach.** A dev laptop usually holds SSH keys, cloud tokens and VPN access. The database was rarely the real target.
6. **Look for persistence**: unexpected cron entries, new containers/images, modified `.bashrc`/PowerShell profile, unknown SSH `authorized_keys`.

**Don't:**
- Don't just drop the ransom table and carry on. That addresses the symptom that the attacker *chose* to show you.
- Don't restore a backup taken after the exposure window began without verifying it.

---

## Quick audit

Run this before you leave a stack running unattended:

```bash
# 1. Nothing bound to all interfaces
docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E '0\.0\.0\.0|\[::\]' && echo "^^ FIX THIS"

# 2. Elasticsearch is not reachable from the host
curl -s --max-time 3 http://localhost:9200 && echo "^^ ES IS EXPOSED - remove its ports entry"

# 3. No secrets staged for commit
git status --porcelain | grep -E '\.env$' && echo "^^ do not commit .env"

# 4. .env is not world-readable (Linux/macOS)
stat -c '%a %n' stack/.env 2>/dev/null

# 5. Images are current
docker compose pull --dry-run 2>/dev/null || docker compose pull
```

The helper scripts fold checks 1 and 2 into `xf doctor`.

---

## Reporting a problem with this repository

If you find a security defect in these scripts or compose definitions, please open an issue — or, if you consider it sensitive, use GitHub's private vulnerability reporting on the repository.

This repository contains no XenForo source and no credentials. If you believe you have found either committed here, please report it immediately; it would be a mistake, and it will be purged from history rather than merely deleted.
