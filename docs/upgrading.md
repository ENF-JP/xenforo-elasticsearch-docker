# Upgrading an existing stack

What to do when you pull a new release onto a stack that already has a database and a search index. The full list of changes is in [CHANGELOG.md](../CHANGELOG.md); this page covers only what needs a decision or an action.

**The rule that matters most:** a database or search index that a *newer* version has opened cannot be opened by the older version again. Take a dump before changing `MARIADB_VERSION` or `ES_VERSION` on a stack you care about.

Commands below use `xf` for the helper — `./scripts/linux/xf.sh` on Linux/macOS, `.\scripts\windows\xf.ps1` on Windows.

---

## 1.0 → 1.1

### Step 0 — If you use the Claude Code allowlist from 1.0, replace it first

The 1.0 version of [ai-assisted.md](ai-assisted.md) suggested `Bash(curl http://localhost:*)` and `Bash(docker compose exec xenforo php cmd.php:*)` as allow rules. Both are wider than they look: the first lets an agent send `stack/.env` or any other readable file to another host without asking, and the second admits `xf-dev:export` and `xf:addon-uninstall`. Delete both from your `.claude/settings.json` and use the 1.1 version of the block, which asks before every `curl` and denies the destructive commands.

### Step 1 — Pull, then look at your `.env`

```bash
git pull
```

Your `stack/.env` is not touched by a pull, so **your stack keeps the versions it had** until you change them. Compare it with `stack/.env.example`:

| Key | What to do |
|---|---|
| `PHP_VERSION=8.3` | Optional: change to `8.4` (new default) or `8.5`. Safe both ways — PHP holds no data. |
| `ES_VERSION=8.15.0` | Recommended: change to `8.19.25`. **One-way** — see step 3. |
| `MARIADB_VERSION` | New and optional. Absent means `11.4`, as before. See step 4 before changing it. |
| `MAILPIT_VERSION` | New and optional. Absent means `v1.33.1`. |
| `PHP_TIMEZONE` | New and optional. Absent means `UTC`, as before. |
| `XF_ADMIN_EMAIL`, `XF_BOARD_TITLE` | New. Used only by a fresh install; absent means `admin@example.com` / `XenForo Dev`. |
| `COMPOSE_PROJECT_NAME` | **Do not add it to an existing stack.** It renames the volumes, and the stack would start empty (the old data stays on disk under the old name). It is only for a *second* stack. |

### Step 2 — Check the Docker Engine version

```bash
docker version --format '{{.Server.Version}}'
```

**28.3.3 or later** is now required. Older engines can let other machines on your network reach ports bound to `127.0.0.1` — see [SECURITY.md](SECURITY.md), Rule 1. Update Docker Engine or Docker Desktop first if you are below it. `xf doctor` now reports this too.

### Step 3 — Elasticsearch 8.15.0 → 8.19.25 (recommended, one-way)

A minor-version upgrade within 8.x: Elasticsearch upgrades the index in place on first start. You cannot go back to 8.15 on the same volume afterwards.

```bash
# set ES_VERSION=8.19.25 in stack/.env, then:
docker compose -f stack/docker-compose.yml pull elasticsearch
xf down && xf up
xf doctor          # cluster yellow or green, 'xf' index document count unchanged
```

If the document count dropped, or you would rather start clean: `xf reindex`.

Not ready to commit? Leave `ES_VERSION=8.15.0` — it still works, it just no longer receives fixes.

**Elasticsearch 9.x** is not covered by this upgrade and is untested with XFES. See [elasticsearch-xfes.md](elasticsearch-xfes.md#elasticsearch-9x).

### Step 4 — MariaDB (optional; only if you want a newer LTS)

The default stays **11.4**, an LTS supported until 2029, so there is nothing to do. If your production host runs **11.8** or **12.3** and you want the dev stack to match it:

```bash
# 1. dump first - this is the only way back
docker compose -f stack/docker-compose.yml exec -T mariadb \
  sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb-dump -uroot --all-databases' > backup.sql
# (password via MYSQL_PWD inside the container, never on a command line)

# 2. set MARIADB_VERSION=11.8 (or 12.3) in stack/.env, then:
xf down && xf up
```

On first start the official image sees the data directory was written by an older version and runs `mariadb-upgrade` on it, because the compose file sets `MARIADB_AUTO_UPGRADE=1` (added in 1.1). It backs up the system tables first, and does nothing when the version has not changed. Going back down means a fresh volume and restoring `backup.sql`. If your board is disposable, the simpler route is `xf reset` with the new version set.

### Step 5 — Rebuild the PHP image

Needed even if you keep `PHP_VERSION=8.3`: the Dockerfile changed (pinned Debian base, pinned extensions, the PHP 8.5 fix).

```bash
xf build && xf restart
xf doctor
```

Expect the first build to take a few minutes. Your webroot, database and index are not affected.

### Step 6 — Nothing to do for these

- **`no-new-privileges`** and `MARIADB_AUTO_UPGRADE` are set by the compose file. The first `xf up` after the pull **recreates all three containers** to apply them — expect "Recreate" lines. Your database, index and webroot are untouched (tested: 224 tables and a test search document survived it).
- **`setup` changes** (unattended install, board URL with port, no usage statistics) apply only to a fresh install. An existing board keeps its settings. To stop an existing board sending usage statistics, untick **Send anonymous usage statistics** under Admin CP → Setup → Options → Statistics and metrics.
- **`xf addon rebuild`** is a new command; nothing to configure.

### Rolling back to 1.0

```bash
git checkout 7476fe3     # the 1.0 state
xf build && xf restart
```

This works as long as you did **not** do step 3 or step 4. If you did, also restore the old `ES_VERSION` / `MARIADB_VERSION` and start those services on fresh volumes: `xf reindex` for search, `backup.sql` for the database.
