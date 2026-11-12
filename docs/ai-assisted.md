# Letting an AI agent drive the stack

This stack was built alongside AI-assisted development, and the helper scripts are shaped by it: they emit plain text, return meaningful exit codes, and expose a single `doctor` command that answers "is everything actually working?" in one call. That makes them equally pleasant for a human and for an agent like Claude Code, Cursor, Aider, or a CI job.

The interesting question isn't whether an agent *can* run these commands. It's which ones it should be allowed to run without asking.

---

## The split that matters

| Safe to allowlist — read-only or idempotent | Keep behind a prompt — destructive or outward-facing |
|---|---|
| `xf doctor`, `xf status`, `xf errors`, `xf log` | `xf reset` — destroys database, index and webroot |
| `xf es <path>` (GET queries) | `docker compose down -v` — the `-v` deletes volumes |
| `docker compose ps`, `docker compose logs` | `xf addon uninstall` — runs the add-on's uninstall steps |
| `docker compose exec xenforo php cmd.php xf:addon-list` | Anything writing to `.env` |
| `xf import`, `xf export`, `xf rebuild` | `git push`, `gh release create`, publishing anything |
| `xf addon install` / `upgrade` / `enable` / `disable` | `docker system prune` |
| `curl http://localhost/...` | Editing `docker-compose.yml` `ports:` entries |

The right test isn't "could this break something?" — `addon install` certainly can. It's **"if this goes wrong, is the damage bounded and recoverable in one command?"** A failed add-on install is diagnosed with `xf errors` and undone with `xf addon uninstall`. A `down -v` is not undoable at all.

---

## Claude Code

Add to `.claude/settings.json` in your workspace. Three lists, and the order they are checked in matters: **deny first, then ask, then allow** — an allow rule can never override a deny.

```json
{
  "permissions": {
    "allow": [
      "Bash(docker compose ps *)",
      "Bash(docker compose logs *)",
      "Bash(docker compose exec xenforo php cmd.php *)",
      "Bash(./scripts/linux/xf.sh doctor)",
      "Bash(./scripts/linux/xf.sh status)",
      "Bash(./scripts/linux/xf.sh errors *)",
      "Bash(./scripts/linux/xf.sh es *)",
      "Bash(./scripts/linux/xf.sh addon install *)",
      "Bash(./scripts/linux/xf.sh addon upgrade *)",
      "Bash(curl http://localhost*)"
    ],
    "ask": [
      "Bash(./scripts/linux/xf.sh addon uninstall *)"
    ],
    "deny": [
      "Bash(./scripts/linux/xf.sh reset*)",
      "Bash(./scripts/linux/xf.sh creds*)",
      "Bash(docker compose down -v*)",
      "Bash(docker system prune*)",
      "Read(./stack/.env)",
      "Edit(./stack/.env)"
    ]
  }
}
```

On Windows, Claude Code has a native PowerShell tool and its rules take the same shape: `PowerShell(.\scripts\windows\xf.ps1 doctor)`, `PowerShell(.\scripts\windows\xf.ps1 errors *)`, and so on. Mirror the deny list too — `PowerShell(.\scripts\windows\xf.ps1 reset*)` — because a `Bash(...)` deny does not cover a PowerShell call.

Notes on the rules:

- **Trailing `*` after a space** is the form Claude Code itself writes when you click "don't ask again". The older `Bash(cmd:*)` form still works, but only at the very end of a pattern; prefer the space form.
- **The deny list is the real control here, not the absence of an allow.** Without it, a rule you add later — or a "yes, don't ask again" clicked in a hurry — can re-admit `reset`. Deny rules from any settings file win over allow rules from any other.
- **`Read(./stack/.env)` and `Edit(./stack/.env)`** keep the generated secrets out of the agent's context and stop it rewriting them. `creds` is denied for the same reason: it prints the admin password into the transcript.
- **Deny rules are not a sandbox.** They match the commands Claude Code can recognise; they do not see inside `sh -c "..."` or a script that opens files itself. If the restriction must hold against a determined agent, turn on Claude Code's sandbox as well.

Deliberately absent from `allow`: any bare `xf.sh *` wildcard. A wildcard over the whole script re-admits every destructive subcommand.

---

## What an agent can verify unattended

This is the payoff, and it's specific. With the allowlist above, an agent can answer — without a human watching — questions that only a real install can answer:

- **Does the add-on install cleanly from scratch?** `xf addon uninstall` then `xf addon install`, then `xf errors` must be empty.
- **Does it survive an upgrade?** Bump the version, `xf addon upgrade`, check for errors.
- **Do the ACP screens actually render?** `curl` an authenticated session against the options page and grep for the controls that should be there. A malformed `options.xml` produces a debug error on that page and nothing else — no exception, no log entry.
- **Does the board still serve HTTP 200** after the change?
- **Is search behaving?** `xf doctor` reports the index document count; `xf es` runs arbitrary read queries.

That is precisely the class of failure that static analysis misses: an add-on that lints clean, parses clean, and cannot install.

---

## Rules for the agent, not just the allowlist

**Never let an agent generate or edit secrets.** `.env` is generated once by the setup script using a CSPRNG. An agent asked to "put a password in .env" will produce something plausible and weak, and it may echo it into a transcript that gets shared. Keep `.env` off the editable list entirely.

**Never let an agent add a `ports:` entry.** This is the single highest-consequence edit in the repo, and it looks innocuous — "expose 3306 so I can check the database" is a reasonable-sounding step that ends in the 76-minute scenario from [SECURITY.md](SECURITY.md). Agents should query through `xf db` and `xf es`, which need no published port. If you let an agent edit `docker-compose.yml` at all, have it run `xf doctor` afterwards — `Assert-NoPublicBind` catches the mistake.

**Don't paste real credentials into a prompt.** `xf creds` prints the generated admin password to the terminal. If an agent is capturing terminal output, that password is now in a transcript. It's a disposable local account, but treat the habit as the thing you're training.

**Expect stderr weirdness on Windows.** Docker writes progress to stderr; when an agent captures output under PowerShell 5.1, each line becomes an ErrorRecord and a successful command can look like a failure. `xf.ps1` already works around this internally (see [platform-windows.md](platform-windows.md#6-powershell-traps-this-script-works-around)) — but if you have an agent call `docker` directly, it will hit this and may "fix" a build that was never broken.

---

## Making the stack legible to an agent

A few properties here are deliberate, and worth preserving if you adapt the scripts:

- **`doctor` is one command that checks everything** and prints a flat, greppable report. An agent that can run one command to get full system state doesn't guess.
- **Exit codes are meaningful.** Both scripts return non-zero on failure rather than printing an error and exiting 0.
- **Output is plain text, not decorated tables.** Colour is used only for warnings.
- **Errors say what to do next** — `"The web container is not running. Start it with: ./xf.sh up"` rather than a stack trace. An agent will follow that instruction correctly; it will hallucinate a fix from a stack trace.
- **Destructive commands prompt interactively.** `xf reset` requires typing `RESET`, which an agent in a non-interactive shell cannot satisfy. That's a backstop, not the primary control — the allowlist is.

---

## A worked loop

The workflow this stack was built for, run end to end:

```bash
# 1. static checks first - cheap, catch the obvious
php -l upload/src/addons/Vendor/AddonId/Setup.php

# 2. clean-slate install
./xf.sh addon uninstall Vendor/AddonId
./xf.sh addon install   Vendor/AddonId

# 3. did anything error?
./xf.sh errors          # must be empty

# 4. does the board still work?
curl -s -o /dev/null -w '%{http_code}\n' http://localhost/

# 5. did the ACP options page render, or is it showing a debug error?
#    (with an authenticated session cookie)
curl -s -b cookies.txt 'http://localhost/admin.php?options/groups/myGroup/' | grep -q 'expected-control'
```

Steps 2–5 are the ones no linter can do, and all four are allowlist-safe.
