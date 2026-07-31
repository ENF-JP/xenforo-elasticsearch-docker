# Windows

Docker on Windows runs Linux containers inside a WSL2 virtual machine. Everything works, but two things differ from Linux in ways that cost real time: **filesystem performance across the Windows/Linux boundary**, and **PowerShell's handling of native command output**.

---

## 1. Install WSL2

In an **elevated** PowerShell:

```powershell
wsl --install --no-distribution
```

Reboot, then confirm:

```powershell
wsl --status          # should report WSL 2 as the default version
```

`--no-distribution` is deliberate — the container runtime supplies its own WSL image, so you don't need Ubuntu unless you want it for other reasons.

Requires virtualization enabled in firmware. If `wsl --status` complains, check that Intel VT-x / AMD-V is on in BIOS, and that Hyper-V or the Virtual Machine Platform feature isn't disabled by policy.

---

## 2. Choose a container runtime

### Docker Desktop

<https://www.docker.com/products/docker-desktop/>

Puts `docker` on `PATH` automatically, which is also what lets an AI agent drive the stack without extra configuration.

> **Licensing:** Docker Desktop requires a paid subscription for commercial use in organisations with **250+ employees or more than $10M annual revenue**. Below that it is free. Check this before installing at a business — it is a per-seat commercial licence, not a formality.

### Rancher Desktop

<https://rancherdesktop.io/> — free, no employee/revenue threshold.

During setup choose **dockerd (moby)** as the container engine, not containerd, so the `docker` CLI and Compose v2 work as documented here. `xf.ps1` already probes Rancher's install paths if `docker` isn't on `PATH`.

### Either way

Enable the **WSL2 backend**, and in Settings → Resources give the VM at least **4 GB RAM** (Elasticsearch alone reserves 2 GB) and 4 CPUs.

---

## 3. Verify in a *new* terminal

```powershell
docker version
docker compose version
```

PATH changes do not reach shells that were already open. "docker is not recognized" immediately after installing is almost always this, not a broken install — `xf.ps1` prints exactly that hint when it can't find `docker.exe`, and probes the standard install locations before giving up.

---

## 4. Bring it up

```powershell
git clone https://github.com/ENF-JP/xenforo-elasticsearch-docker
cd xenforo-elasticsearch-docker

Copy-Item stack\.env.example stack\.env
notepad stack\.env          # set XF_SOURCE to your licensed XenForo files

.\scripts\windows\xf.ps1 setup
```

`XF_SOURCE` accepts a Windows path to either an unpacked webroot or a release zip:

```ini
XF_SOURCE=G:\sources\xenforo_2.3.12\upload
XF_SOURCE=C:\Users\you\Downloads\xenforo_2.3.12.zip
```

Then:

```powershell
.\scripts\windows\xf.ps1 doctor
.\scripts\windows\xf.ps1 creds
```

### Execution policy

If PowerShell refuses to run the script:

```powershell
Get-ExecutionPolicy -List
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

`RemoteSigned` allows local scripts while still blocking unsigned downloaded ones. You may also need to unblock the file after cloning through a browser:

```powershell
Unblock-File .\scripts\windows\xf.ps1
```

---

## 5. Filesystem performance — the one real trade-off

A bind mount from `C:\` or `G:\` into a Linux container crosses the 9p/virtiofs boundary. XenForo is ~13,000 files, and operations that stat all of them — `xf-dev:rebuild-caches` most of all — are noticeably slower than on native Linux.

Steady-state browsing is fine, because opcache (`validate_timestamps=1`, `revalidate_freq=0`) keeps the parse cost down while still picking up edits immediately.

If rebuilds become annoying, move the webroot **inside** the WSL2 filesystem, where I/O is native:

```powershell
# In .env — a WSL path, reachable from Windows as \\wsl$\...
XF_WEBROOT=\\wsl$\docker-desktop-data\xf-webroot
```

You trade direct Windows access to the files (Explorer, your editor's file watcher) for a large speed-up. A middle path many prefer: keep the webroot on Windows, but do the heavy CLI work from inside WSL using `scripts/linux/xf.sh` against the same Docker daemon.

---

## 6. PowerShell traps this script works around

These are not stylistic quirks. Each one produced a real, confusing failure, and the workaround is commented in `xf.ps1`. If you adapt the script, keep them.

### `Get-Command docker` can return more than one match

```powershell
$d = (Get-Command docker).Source          # may concatenate several paths
$d = (Get-Command docker -CommandType Application | Select-Object -First 1).Source   # correct
```

Without `-CommandType Application`, it also matches aliases and functions named `docker` — including one defined in the same script — and a `FunctionInfo` has an empty `.Source`, producing an empty string that breaks the call operator.

### Docker writes normal output to stderr

Under PowerShell 5.1, if that stderr is redirected anywhere — a caller's `2>&1`, a CI log, an AI agent capturing output — **each line is wrapped in an ErrorRecord**. With `$ErrorActionPreference = 'Stop'`, the first such line aborts the script even though `docker` exited 0.

`xf.ps1` relaxes the preference around every native call and reports success from `$LASTEXITCODE` alone.

### A function's output stream swallows exit codes

```powershell
function Invoke-Docker {
    & docker $Arguments              # stdout joins the function's output...
    return $LASTEXITCODE             # ...so the caller gets @(lines..., 0)
}
if ((Invoke-Docker @('build')) -ne 0) { throw }   # array is truthy -> false failure
```

The fix is `| Out-Host`, so docker's output goes to the console and only the exit code is returned.

### Double quotes don't survive into native commands

PowerShell 5.1 mangles double quotes embedded in a native command's arguments:

```powershell
docker exec xenforo php -r 'echo implode(",", get_loaded_extensions());'
# reaches PHP as implode(, , ...) -> reports every extension missing
```

`doctor` uses `php -m` instead, which needs no quoting. The same applies to SQL: it runs `SHOW TABLES` rather than a `SELECT` with a quoted `table_schema`.

### Non-ASCII characters in a BOM-less `.ps1`

PowerShell 5.1 reads a `.ps1` without a byte-order mark as **Windows-1252**, not UTF-8. An em dash (`—`, UTF-8 `E2 80 94`) decodes to three CP1252 characters, the last of which is `"` (U+201D) — and PowerShell's tokenizer **treats smart quotes as string delimiters**. The result is a string that terminates early and a cascade of parse errors far from the real cause.

`xf.ps1` is deliberately pure ASCII. If you add non-ASCII text, save the file as UTF-8 **with BOM**. To check:

```powershell
$t = [System.IO.File]::ReadAllText('.\scripts\windows\xf.ps1', [System.Text.UTF8Encoding]::new($false))
[regex]::Matches($t, '[^\x00-\x7F]') | Group-Object Value | Select-Object Count, Name
```

### No `&&`, no ternary, no `??` in PowerShell 5.1

Those are PowerShell 7 features. `xf.ps1` targets 5.1 so it runs on a stock Windows install with nothing extra. Use `;` with `if ($?)`, and explicit `if`/`else`.

---

## 7. Ports

Port 80 is often taken on Windows — IIS, or the `http.sys` reservation used by various services.

```powershell
Get-NetTCPConnection -LocalPort 80 -State Listen | Select-Object OwningProcess
Get-Process -Id <pid>
```

Change the host port in `.env` rather than fighting it:

```ini
HTTP_PORT=8080
```

Then use <http://localhost:8080>, and update the board URL in the XenForo ACP so generated links match. **Keep the `127.0.0.1:` prefix in `docker-compose.yml`** — changing the port is fine, dropping the loopback binding is not. See [SECURITY.md](SECURITY.md).

---

## 8. Line endings

If you edit these scripts inside a Git repo on Windows, Git's system-level `core.autocrlf=true` will check them out as CRLF. `xf.sh` with CRLF line endings fails inside a container with `bad interpreter: /usr/bin/env bash^M` — a genuinely baffling error the first time.

This repo ships a `.gitattributes` that pins `*.sh`, `Dockerfile`, `*.yml` and `*.php` to LF. Verify:

```powershell
git ls-files --eol | Select-String 'w/crlf|w/mixed'    # should return nothing for those types
```

A local `git config` setting is not a substitute — it doesn't travel to CI or to another clone. The `.gitattributes` file must be committed.

---

## 9. Xdebug from VS Code or PhpStorm

Xdebug is installed but disabled (it roughly halves throughput):

```powershell
.\scripts\windows\xf.ps1 xdebug on
```

It connects out to `host.docker.internal` on port **9003** (the Xdebug 3 default). VS Code `launch.json`:

```json
{
    "name": "Listen for Xdebug",
    "type": "php",
    "request": "launch",
    "port": 9003,
    "pathMappings": { "/var/www/html": "${workspaceFolder}/stack/webroot" }
}
```

`pathMappings` must point at the webroot the container actually serves — if you moved it into WSL, map to that path instead. Turn Xdebug off when you're done.
