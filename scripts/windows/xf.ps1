<#
    XenForo + Elasticsearch dev stack - Windows helper.

    Wraps docker compose so day-to-day commands are short, and resolves
    docker.exe explicitly so it still works in a shell that was open before
    Docker was installed (a very common first-run failure).

    Usage:  .\xf.ps1 <command> [args]
            .\xf.ps1 help

    Tested on Windows PowerShell 5.1 and PowerShell 7. Several constructs here
    look roundabout; each one works around a real PowerShell 5.1 behaviour that
    is documented inline. Please read the comment before "simplifying" one.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Command = 'help',

    # Not named $Args: that collides with PowerShell's automatic variable.
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]] $Rest
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$StackDir  = (Resolve-Path (Join-Path $ScriptDir '..\..\stack')).Path
$EnvFile   = Join-Path $StackDir '.env'

# ---- locate docker ---------------------------------------------------------
function Get-DockerExe {
    # -CommandType Application matters: without it this resolves to any alias or
    # function named "docker" - including one defined in this script - and a
    # FunctionInfo has an empty .Source, which yields "" and breaks the & call.
    $cmd = Get-Command docker -CommandType Application -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        "$env:ProgramFiles\Docker\Docker\resources\bin\docker.exe",
        "${env:ProgramFiles(x86)}\Docker\Docker\resources\bin\docker.exe",
        "$env:LOCALAPPDATA\Programs\Docker\Docker\resources\bin\docker.exe",
        "$env:ProgramFiles\RancherDesktop\resources\resources\win32\bin\docker.exe",
        "$env:LOCALAPPDATA\Programs\Rancher Desktop\resources\resources\win32\bin\docker.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }

    throw "docker.exe not found. Install Docker Desktop or Rancher Desktop, start it, open a NEW terminal, then retry. See docs/platform-windows.md."
}

# Resolved lazily so `help` works before Docker is installed.
# NOT named "Docker": a function by that name shadows the docker command itself.
$script:DockerExe = $null
function Resolve-DockerBin {
    if (-not $script:DockerExe) { $script:DockerExe = Get-DockerExe }
    return $script:DockerExe
}

# ---- native-command invocation ---------------------------------------------
# Docker writes progress and much of its normal output to STDERR. Under
# PowerShell 5.1, if that stderr is redirected anywhere (a caller's 2>&1, a CI
# log, an agent capturing output) each line is wrapped in an ErrorRecord; with
# $ErrorActionPreference = 'Stop' the first such line aborts the script even
# though docker exited 0. Every native call below therefore relaxes the
# preference and reports success from $LASTEXITCODE alone.

function Invoke-Docker {
    <#
      Streams docker's output to the console and returns ONLY the exit code.

      Out-Host is essential: without it docker's stdout joins this function's
      output stream, so the caller receives @(<output lines>, <exit code>).
      Comparing that array to 0 yields a non-empty array, which is truthy - so
      a perfectly successful build reports failure.
    #>
    param([Parameter(Mandatory)][string[]] $Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & (Resolve-DockerBin) $Arguments | Out-Host
        return $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prev }
}

function Invoke-DockerInteractive {
    <# For TTY sessions: no Out-Host and no capture, so the terminal passes through. #>
    param([Parameter(Mandatory)][string[]] $Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & (Resolve-DockerBin) $Arguments }
    finally { $ErrorActionPreference = $prev }
}

function Get-DockerOutput {
    <# Captures stdout as lines, discarding stderr so no ErrorRecords form. #>
    param([Parameter(Mandatory)][string[]] $Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& (Resolve-DockerBin) $Arguments 2>$null) }
    finally { $ErrorActionPreference = $prev }
}

function Invoke-Compose {
    param([string[]] $ComposeArgs)
    Push-Location $StackDir
    # Parentheses matter: without them PowerShell passes "+" as an argument.
    try { return (Invoke-Docker (@('compose') + $ComposeArgs)) }
    finally { Pop-Location }
}

function Get-ComposeOutput {
    param([string[]] $ComposeArgs)
    Push-Location $StackDir
    try { return (Get-DockerOutput (@('compose') + $ComposeArgs)) }
    finally { Pop-Location }
}

function Invoke-InContainer {
    <# Runs a command in the web container as www-data unless -AsRoot. #>
    param([string[]] $Cmd, [switch] $AsRoot)
    $pre = @('exec', '-T')
    if (-not $AsRoot) { $pre += @('-u', 'www-data') }
    $pre += 'xenforo'
    return (Invoke-Compose ($pre + $Cmd))
}

function Get-FromContainer {
    param([string[]] $Cmd)
    return (Get-ComposeOutput (@('exec', '-T', 'xenforo') + $Cmd))
}

function Invoke-InContainerWithInput {
    <#
      Runs a command in the web container as www-data, feeding InputLines to
      its stdin, and returns only the exit code.

      Used to hand a secret to a command that would otherwise need it as an
      argument. Command-line arguments are visible to every local user
      (`ps` on Linux and macOS, process listings on Windows) - including the
      arguments of processes inside a container. Stdin is not.
    #>
    param([Parameter(Mandatory)][string[]] $InputLines, [Parameter(Mandatory)][string[]] $Cmd)
    Push-Location $StackDir
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # The text must reach the container without a byte-order mark, or the
    # first line arrives as EF BB BF + password and never matches the
    # confirmation line. Which setting decides the bytes differs by version:
    #   - Windows PowerShell 5.1 encodes a native command's stdin with
    #     [Console]::InputEncoding, which is UTF-8 WITH a BOM when Windows'
    #     "Use Unicode UTF-8 for worldwide language support" option is on.
    #     It ignores $OutputEncoding here (verified on 5.1.26100).
    #   - PowerShell 7 uses $OutputEncoding.
    # Both are set BOM-free for this call. $OutputEncoding is a local
    # assignment; the console encoding is process-wide, so it is restored.
    # Setting it throws when no console is attached - then it is left alone.
    $noBom = New-Object System.Text.UTF8Encoding($false)
    $OutputEncoding = $noBom
    $prevIn = $null
    try { $prevIn = [Console]::InputEncoding; [Console]::InputEncoding = $noBom } catch { $prevIn = $null }
    try {
        $InputLines | & (Resolve-DockerBin) (@('compose', 'exec', '-T', '-u', 'www-data', 'xenforo') + $Cmd) | Out-Host
        return $LASTEXITCODE
    }
    finally {
        if ($null -ne $prevIn) {
            try { [Console]::InputEncoding = $prevIn }
            catch { Write-Verbose "Could not restore the console input encoding: $($_.Exception.Message)" }
        }
        $ErrorActionPreference = $prev
        Pop-Location
    }
}

function Get-DbClientCommand {
    <#
      Returns the `compose exec` arguments that start the MariaDB client in
      the mariadb container. The password is not among them: the callers put
      it in the MYSQL_PWD environment variable of this process for the length
      of the call, and `-e MYSQL_PWD` (a name, no value) copies it into the
      container. Environment variables are readable only by the process owner
      and administrators; command-line arguments are readable by every user.
    #>
    param([switch] $Interactive)
    $u = Get-EnvValue 'MARIADB_USER'; if (-not $u) { $u = 'xenforo' }
    $n = Get-EnvValue 'MARIADB_DATABASE'; if (-not $n) { $n = 'xenforo' }
    $a = @('exec')
    if (-not $Interactive) { $a += '-T' }
    return ($a + @('-e', 'MYSQL_PWD', 'mariadb', 'mariadb', "-u$u", $n))
}

function Get-DbOutput {
    <# Runs one MariaDB client call (e.g. -e 'SHOW TABLES') and returns its output lines. #>
    param([Parameter(Mandatory)][string[]] $SqlArgs)
    $had = Test-Path Env:MYSQL_PWD; $old = $env:MYSQL_PWD
    $env:MYSQL_PWD = Get-EnvValue 'MARIADB_PASSWORD'
    try { return (Get-ComposeOutput ((Get-DbClientCommand) + $SqlArgs)) }
    finally { if ($had) { $env:MYSQL_PWD = $old } else { Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue } }
}

function Assert-SafeWebroot {
    <#
      Throws unless the path is a disposable XenForo webroot that `reset` may
      delete. XF_WEBROOT can be any path, and `reset` removes it recursively,
      so a mistaken value (the pristine XF_SOURCE copy, a profile folder, a
      drive root) would otherwise be deleted without further question.
    #>
    param([Parameter(Mandatory)][string] $Path)
    # -LiteralPath and plain string comparisons throughout: [ ] ? * are legal
    # in Windows folder names, and the wildcard-aware forms would treat them
    # as patterns - making a comparison miss, or matching sibling folders.
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd('\')
    $forbidden = @([System.IO.Path]::GetPathRoot($full).TrimEnd('\'), $env:USERPROFILE.TrimEnd('\'), $StackDir.TrimEnd('\'))
    foreach ($f in $forbidden) {
        if ([string]::Equals($full, $f, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to delete ${full}: XF_WEBROOT points at a directory that is not a webroot."
        }
    }
    if (-not (Test-Path -LiteralPath ([System.IO.Path]::Combine($full, 'src', 'XF.php')))) {
        throw "Refusing to delete ${full}: it does not contain src\XF.php, so it does not look like a XenForo webroot. Check XF_WEBROOT in stack\.env."
    }
    # A junction or symlink is refused outright. Resolve-Path does not follow
    # links, so a link to XF_SOURCE would pass the comparison below. (Links
    # INSIDE the webroot are handled by Remove-DirectoryTree.)
    # Every ANCESTOR is checked too: Resolve-Path does not resolve links in
    # parent folders, so D:\j\upload with D:\j a junction to E:\src would
    # compare as unrelated to XF_SOURCE=E:\src\upload while being the same
    # directory.
    $probe = $full
    while ($probe -and $probe.Length -gt [System.IO.Path]::GetPathRoot($full).Length) {
        if ((Get-Item -LiteralPath $probe -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to delete ${full}: $probe is a junction or symbolic link. Point XF_WEBROOT at a path made of real directories."
        }
        $probe = [System.IO.Path]::GetDirectoryName($probe)
    }
    $src = Get-EnvValue 'XF_SOURCE'
    if ($src -and (Test-Path -LiteralPath $src -PathType Container)) {
        $srcFull = (Resolve-Path -LiteralPath $src).ProviderPath.TrimEnd('\')
        # Equal, or one inside the other: deleting the webroot would take
        # XF_SOURCE with it (or the webroot IS part of XF_SOURCE). Ordinal,
        # case-insensitive prefix tests with a trailing separator, so
        # D:\xf is not mistaken for a parent of D:\xf2.
        $ic = [System.StringComparison]::OrdinalIgnoreCase
        if ("$srcFull\".StartsWith("$full\", $ic)) { throw "Refusing to delete ${full}: XF_SOURCE ($src) is inside it." }
        if ("$full\".StartsWith("$srcFull\", $ic)) { throw "Refusing to delete ${full}: it is inside XF_SOURCE ($src), your reference copy of XenForo." }
    }
}

function Remove-DirectoryTree {
    <#
      Deletes a directory tree WITHOUT following junctions or symbolic links
      inside it. A link is removed as a link; whatever it points to is left
      alone.

      Why not Remove-Item -Recurse: on some Windows PowerShell 5.1 builds it
      follows a directory junction and deletes the target's contents
      (PowerShell issue #621). A webroot can legitimately contain one - an
      add-on folder linked in from the developer's working repository - and
      `reset` must not empty that repository. [IO.Directory]::Delete with
      recursion refuses ("access denied") on a junction instead.
    #>
    param([Parameter(Mandatory)][string] $Path)
    $attrs = [System.IO.File]::GetAttributes($Path)
    if ($attrs -band [System.IO.FileAttributes]::ReparsePoint) {
        # Non-recursive delete of a link removes the link only.
        [System.IO.Directory]::Delete($Path)
        return
    }
    foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($Path)) {
        $a = [System.IO.File]::GetAttributes($entry)
        if ($a -band [System.IO.FileAttributes]::Directory) {
            Remove-DirectoryTree -Path $entry
        }
        else {
            # Clear only the read-only flag, and only on a real file, so the
            # delete is not refused. Never on a file symlink (attributes could
            # land on its target outside the webroot); on a hard link the flag
            # is shared with the file's other names, so nothing else is touched.
            if (($a -band [System.IO.FileAttributes]::ReadOnly) -and -not ($a -band [System.IO.FileAttributes]::ReparsePoint)) {
                [System.IO.File]::SetAttributes($entry, ($a -band (-bnot [System.IO.FileAttributes]::ReadOnly)))
            }
            [System.IO.File]::Delete($entry)
        }
    }
    # A read-only directory refuses deletion; clear the flag on the directory
    # itself (a real directory here - links returned above).
    $d = [System.IO.File]::GetAttributes($Path)
    if ($d -band [System.IO.FileAttributes]::ReadOnly) {
        [System.IO.File]::SetAttributes($Path, ($d -band (-bnot [System.IO.FileAttributes]::ReadOnly)))
    }
    [System.IO.Directory]::Delete($Path)
}

function Assert-Running {
    <#
      Throws unless the xenforo service is running.

      The match is an exact per-line comparison. `$out -notmatch 'xenforo'`
      looks equivalent but is not: on an array, -notmatch returns the
      elements that do NOT match ('elasticsearch', 'mariadb'), which is a
      non-empty, truthy array whenever the other services are up - so it
      threw "not running" on a perfectly healthy stack.
    #>
    $out = @(Get-ComposeOutput @('ps', '--services', '--filter', 'status=running'))
    if (-not ($out | Where-Object { "$_".Trim() -eq 'xenforo' })) {
        throw "The web container is not running. Start it with: .\xf.ps1 up"
    }
}

# ---- .env handling ---------------------------------------------------------
function Get-EnvValue {
    param([Parameter(Mandatory)][string] $Key)
    if (-not (Test-Path $EnvFile)) { throw ".env not found at $EnvFile - run: .\xf.ps1 setup" }
    foreach ($line in Get-Content $EnvFile) {
        if ($line -match "^\s*$([regex]::Escape($Key))\s*=\s*(.*)$") { return $Matches[1].Trim() }
    }
    return $null
}

function Set-EnvValue {
    param([Parameter(Mandatory)][string] $Key, [Parameter(Mandatory)][string] $Value)
    $lines = @(Get-Content $EnvFile)
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*$([regex]::Escape($Key))\s*=") {
            $lines[$i] = "$Key=$Value"; $found = $true; break
        }
    }
    if (-not $found) { $lines += "$Key=$Value" }
    # .NET writer with explicit LF: Out-File would emit CRLF, and docker compose
    # tolerates it but shell-based tooling reading the same file does not.
    [System.IO.File]::WriteAllText($EnvFile, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-WebrootPath {
    <#
      Returns the full path of the webroot the container serves.

      XF_WEBROOT may be relative (resolved from stack\, the default
      ./webroot) or absolute. Join-Path alone would glue an absolute path
      onto stack\ and produce a path that does not exist, so rooted paths
      are returned as they are.
    #>
    $rel = Get-EnvValue 'XF_WEBROOT'
    if (-not $rel) { $rel = './webroot' }
    if ([System.IO.Path]::IsPathRooted($rel)) { return $rel }
    return (Join-Path $StackDir ($rel -replace '^\./', ''))
}

function New-Secret {
    param([int] $Length = 32)
    # Alphanumeric only: '/', '+' and '=' from base64 need escaping in .env,
    # in connection strings and in shell arguments. Not worth the trouble.
    $chars = (48..57) + (65..90) + (97..122)
    $rng   = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] $Length
    $rng.GetBytes($bytes)
    -join ($bytes | ForEach-Object { [char]$chars[$_ % $chars.Count] })
}

# Minimum Docker Engine that keeps loopback-bound ports private. Engine 28.0
# stopped other hosts on the same network from reaching ports published on
# 127.0.0.1; 28.2.0-28.3.2 then reopened them after a firewalld reload
# (CVE-2025-54388), fixed in 28.3.3. Rule 1 in docs/SECURITY.md depends on it.
$script:MinEngine = [version]'28.3.3'

function Test-EngineVersion {
    <#
      Prints whether the Docker Engine is new enough to keep 127.0.0.1-bound
      ports private. Warns, never throws: Podman and other engines report
      their own version numbering, so a warning there is a prompt to check.
    #>
    $raw = (Get-DockerOutput @('version', '--format', '{{.Server.Version}}')) -join ''
    # Strip suffixes such as "-rd" or "+dfsg1" before parsing.
    $clean = ($raw -split '[-+]')[0].Trim()
    $v = $null
    if (-not [version]::TryParse($clean, [ref] $v)) {
        Write-Host "  could not read the Docker Engine version ($raw)" -ForegroundColor Yellow
    }
    elseif ($v -ge $script:MinEngine) {
        Write-Host "  ok      Docker Engine $clean"
    }
    else {
        Write-Host "  Docker Engine $clean is older than $($script:MinEngine). Older engines can expose ports bound to 127.0.0.1 to the local network. Upgrade - see docs/SECURITY.md (Rule 1)." -ForegroundColor Red
    }
}

function Assert-NoPublicBind {
    <#
      Refuses to stay quiet if a container port is published beyond loopback.
      The stack this is derived from was compromised in ~76 minutes because of
      a bare "3306:3306". See docs/SECURITY.md.

      Docker lists ports as "127.0.0.1:80->80/tcp, 9200/tcp": entries with
      "->" are published, the rest are only exposed inside the network. For
      each published entry the address before ":<port>->" must be 127.0.0.1
      or [::1]. That catches 0.0.0.0 and [::] (all interfaces) and also a
      specific LAN address, which is just as reachable from the network.
    #>
    $rows = Get-DockerOutput @('ps', '--format', '{{.Names}}|{{.Ports}}')
    $bad = @()
    foreach ($r in $rows) {
        if (-not $r) { continue }
        $name, $ports = $r -split '\|', 2
        foreach ($entry in ($ports -split ',\s*')) {
            if ($entry -match '^(.+?):\d+(-\d+)?->' -and $Matches[1] -ne '127.0.0.1' -and $Matches[1] -ne '[::1]') {
                $bad += "$name -> $ports"; break
            }
        }
    }
    if ($bad.Count) {
        Write-Host "WARNING: container ports are published beyond loopback:" -ForegroundColor Red
        $bad | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        Write-Host "  Bind them to 127.0.0.1 in docker-compose.yml, then: .\xf.ps1 down; .\xf.ps1 up" -ForegroundColor Red
        Write-Host "  Read docs/SECURITY.md before continuing." -ForegroundColor Red
    }
}

# ---- commands --------------------------------------------------------------
switch ($Command.ToLower()) {

    'help' {
@"
XenForo + Elasticsearch dev stack (Windows)

  First run
    setup                 Generate .env, build the image, start, install XenForo
    reset                 Destroy containers, volumes and webroot, then set up again

  Lifecycle
    up | down | restart   Start / stop / restart
    status                Container and health status
    build                 Rebuild the PHP image (after editing Dockerfile)

  XenForo
    cli <args...>         php cmd.php <args>   e.g.  cli xf:addon-list
    addon install|upgrade|rebuild|enable|disable|uninstall <Vendor/Id>
                          (rebuild = re-import the add-on's _data/ XML)
    import <Vendor/Id>    _output/ dev files -> database   (xf-dev:import)
    export <Vendor/Id>    database -> _data/ XML           (xf-addon:export)
    rebuild               xf-dev:rebuild-caches
    reindex               xf-rebuild:search  (full Elasticsearch reindex)
    defaultaddon <V/Id>   Set development.defaultAddOn in config.php

  Diagnostics
    doctor                Check engine, ports, PHP extensions, DB, Elasticsearch, HTTP
    errors [n]            Show the last n XenForo errors (default 5)
    log                   Tail the Apache error log
    shell                 Bash shell in the web container
    db ['SQL']            MariaDB client, or run one query
    es [path]             Query Elasticsearch  (default: _cat/indices?v)
    xdebug on|off         Toggle Xdebug (off is roughly twice as fast)
    creds                 Show the ACP URL and admin credentials

  Every published port binds to 127.0.0.1 only. See docs/SECURITY.md.
"@ | Write-Host
    }

    'setup' {
        # ---- .env -------------------------------------------------------
        if (-not (Test-Path $EnvFile)) {
            Copy-Item (Join-Path $StackDir '.env.example') $EnvFile
            Write-Host "Created stack\.env from .env.example"
        }

        foreach ($k in 'MARIADB_ROOT_PASSWORD', 'MARIADB_PASSWORD', 'XF_ADMIN_PASSWORD') {
            if (-not (Get-EnvValue $k)) {
                $len = 32; if ($k -eq 'XF_ADMIN_PASSWORD') { $len = 24 }
                Set-EnvValue $k (New-Secret -Length $len)
                Write-Host "Generated $k"
            }
        }
        if (-not (Get-EnvValue 'XF_ADMIN_USER')) { Set-EnvValue 'XF_ADMIN_USER' 'admin' }

        # ---- webroot ----------------------------------------------------
        $Webroot = Get-WebrootPath

        if (-not (Test-Path $Webroot)) {
            $source = Get-EnvValue 'XF_SOURCE'
            if (-not $source) {
                throw @"
XF_SOURCE is not set in stack\.env.

XenForo is commercial software and is not distributed with this repo. Point
XF_SOURCE at your own licensed copy - either an unpacked directory containing
src\ and cmd.php, or the upload\ directory from a XenForo release zip:

    XF_SOURCE=G:\sources\xenforo_2.3.x\upload
"@
            }
            if (-not (Test-Path $source)) { throw "XF_SOURCE path does not exist: $source" }

            if ((Get-Item $source).PSIsContainer) {
                if (-not (Test-Path (Join-Path $source 'cmd.php'))) {
                    throw "XF_SOURCE does not look like a XenForo webroot (no cmd.php): $source"
                }
                Write-Host "Copying XenForo source -> $Webroot (one-time, ~65 MB, takes a minute)..."
                Copy-Item $source $Webroot -Recurse -Force
            }
            elseif ($source -like '*.zip') {
                Write-Host "Extracting $source -> $Webroot ..."
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $tmp = Join-Path $env:TEMP ("xfsrc-" + [guid]::NewGuid().ToString('N'))
                [System.IO.Compression.ZipFile]::ExtractToDirectory($source, $tmp)
                # A XenForo release zip wraps everything in upload/.
                $inner = Join-Path $tmp 'upload'
                if (Test-Path $inner) { Copy-Item $inner $Webroot -Recurse -Force }
                else { Copy-Item $tmp $Webroot -Recurse -Force }
                Remove-Item $tmp -Recurse -Force
            }
            else { throw "XF_SOURCE must be a directory or a .zip file: $source" }
        }
        else {
            Write-Host "Webroot already exists; leaving it alone."
        }

        $cfg = Join-Path $Webroot 'src\config.php'
        if (-not (Test-Path $cfg)) {
            Copy-Item (Join-Path $StackDir 'config.php.template') $cfg -Force
            Write-Host "Installed development config.php"
        }
        foreach ($d in 'data', 'internal_data') {
            $p = Join-Path $Webroot $d
            if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force $p | Out-Null }
        }

        # ---- build and start --------------------------------------------
        # Before anything is published: an engine below the minimum can expose
        # the 127.0.0.1 ports to the local network.
        Write-Host ""
        Test-EngineVersion

        Write-Host "`nBuilding image (first build takes a few minutes)..."
        if ((Invoke-Compose @('build')) -ne 0) { throw "Image build failed." }

        Write-Host "`nStarting containers..."
        if ((Invoke-Compose @('up', '-d')) -ne 0) { throw "Failed to start containers." }

        Write-Host "`nWaiting for MariaDB and Elasticsearch to report healthy..."
        $prefix = Get-EnvValue 'COMPOSE_PREFIX'; if (-not $prefix) { $prefix = 'xf' }
        foreach ($svc in "$prefix-mariadb", "$prefix-elasticsearch") {
            $ok = $false
            foreach ($i in 1..90) {
                $h = Get-DockerOutput @('inspect', '-f', '{{.State.Health.Status}}', $svc)
                if ($h -eq 'healthy') { $ok = $true; break }
                Start-Sleep -Seconds 2
            }
            if (-not $ok) { throw "$svc did not become healthy. Check: .\xf.ps1 status" }
            Write-Host "  $svc healthy"
        }

        # Bind-mounted Windows files can land with awkward ownership.
        Invoke-InContainer -AsRoot @('chown', '-R', 'www-data:www-data', '/var/www/html/data', '/var/www/html/internal_data') | Out-Null

        # The database lives in a Docker volume but internal_data/ lives on the
        # host, so destroying the volume leaves install-lock.php behind and
        # XenForo then refuses to install. Decide from the DATABASE whether this
        # is a fresh install - never from the lock file alone, or re-running
        # setup could wipe a working install.
        $tables = Get-DbOutput @('-e', 'SHOW TABLES')
        $tableCount = @($tables | Where-Object { $_ -and $_ -notmatch '^Tables_in_' }).Count

        if ($tableCount -gt 0) {
            Write-Host "`nXenForo is already installed ($tableCount tables) - skipping install."
            Write-Host "To start over: .\xf.ps1 reset"
        }
        else {
            $lock = Join-Path $Webroot 'internal_data\install-lock.php'
            if (Test-Path $lock) {
                Write-Host "`nDatabase is empty but install-lock.php exists (left by a previous"
                Write-Host "install whose volume was destroyed). Clearing stale install state..."
                Remove-Item $lock -Force
                foreach ($stale in 'internal_data\code_cache', 'internal_data\temp') {
                    $sp = Join-Path $Webroot $stale
                    if (Test-Path $sp) { Remove-Item $sp -Recurse -Force -ErrorAction SilentlyContinue }
                }
            }

            Write-Host "`nInstalling XenForo..."
            $adminUser = Get-EnvValue 'XF_ADMIN_USER'
            $adminPass = Get-EnvValue 'XF_ADMIN_PASSWORD'
            if (-not $adminPass) { throw "XF_ADMIN_PASSWORD is not set in .env" }
            $email = Get-EnvValue 'XF_ADMIN_EMAIL'; if (-not $email) { $email = 'admin@example.com' }
            $title = Get-EnvValue 'XF_BOARD_TITLE'; if (-not $title) { $title = 'XenForo Dev' }
            $iport = Get-EnvValue 'HTTP_PORT'; if (-not $iport) { $iport = '80' }
            $iurl  = "http://localhost"; if ($iport -ne '80') { $iurl = "http://localhost:$iport" }
            # Every value xf:install would otherwise ask for is passed
            # explicitly, so setup runs unattended (CI, an AI agent, a script).
            # Without them the installer stops to prompt, and with no input it
            # aborts.
            # --skip-statistics: never opt a dev board into sending usage
            # statistics to XenForo. That prompt defaults to "yes", so
            # accepting defaults non-interactively would have switched it on.
            # --url: must include HTTP_PORT, or generated links point at port 80.
            # The password is NOT passed as --password: command-line arguments
            # are visible to every local user, inside the container too. With
            # no --password, xf:install reads it from stdin twice (entry and
            # confirmation); with no terminal attached it reads plain lines.
            #
            # Windows PowerShell 5.1 does not escape a double quote inside a
            # native command's argument, so a " in the title or email would
            # split it into extra xf:install arguments. A trailing backslash
            # does the same to an argument containing spaces: it turns the
            # closing quote into \" and swallows the next argument. Refuse both.
            foreach ($pair in @(@('XF_BOARD_TITLE', $title), @('XF_ADMIN_EMAIL', $email), @('XF_ADMIN_USER', $adminUser))) {
                if ($pair[1] -match '"' -or $pair[1] -match '\\$') {
                    throw "$($pair[0]) in stack\.env must not contain a double quote or end with a backslash."
                }
            }
            $installArgs = @('php', 'cmd.php', 'xf:install',
                "--user=$adminUser",
                "--email=$email", "--title=$title", "--url=$iurl",
                '--skip-statistics', '--clear')
            if ((Invoke-InContainerWithInput -InputLines @($adminPass, $adminPass) -Cmd $installArgs) -ne 0) {
                throw "xf:install failed. Inspect with: .\xf.ps1 log"
            }
            $adminPass = $null
        }

        Assert-NoPublicBind

        $port = Get-EnvValue 'HTTP_PORT'; if (-not $port) { $port = '80' }
        $url  = "http://localhost"; if ($port -ne '80') { $url = "http://localhost:$port" }
        Write-Host "`nDone. $url/admin.php"
        Write-Host "Credentials: .\xf.ps1 creds"
        Write-Host "Next: mount an add-on in stack\docker-compose.yml, then .\xf.ps1 addon install Vendor/AddonId"
    }

    'reset' {
        $Webroot = Get-WebrootPath
        Assert-SafeWebroot $Webroot
        Write-Host "This destroys the containers, all volumes (database AND search index), and the webroot:" -ForegroundColor Yellow
        Write-Host "    $Webroot" -ForegroundColor Yellow
        $c = Read-Host "Type RESET to confirm"
        if ($c -ne 'RESET') { Write-Host "Aborted."; break }
        Invoke-Compose @('down', '-v') | Out-Null
        if (Test-Path -LiteralPath $Webroot) {
            # If the delete stops part-way (a locked file, an over-long path),
            # nothing outside the webroot has been touched; say how to finish.
            try { Remove-DirectoryTree -Path ((Resolve-Path -LiteralPath $Webroot).ProviderPath) }
            catch { throw "The webroot was only partly deleted ($($_.Exception.Message)). Close anything using files in $Webroot, then run .\xf.ps1 reset again." }
        }
        & $PSCommandPath 'setup'
    }

    # The engine check runs before `up -d`, so the warning comes before any
    # port is published.
    'up'      { Test-EngineVersion; Invoke-Compose @('up', '-d') | Out-Null; Invoke-Compose @('ps') | Out-Null; Assert-NoPublicBind }
    'down'    { Invoke-Compose @('down') | Out-Null }
    'restart' { Invoke-Compose @('restart') | Out-Null }
    'build'   { Invoke-Compose @('build') | Out-Null }
    'status'  { Invoke-Compose @('ps') | Out-Null }

    'cli' {
        Assert-Running
        Invoke-InContainer (@('php', 'cmd.php') + $Rest) | Out-Null
    }

    'addon' {
        Assert-Running
        if ($Rest.Count -lt 2) { throw "Usage: .\xf.ps1 addon install|upgrade|rebuild|enable|disable|uninstall <Vendor/Id>" }
        $action = $Rest[0]; $id = $Rest[1]
        # rebuild re-imports the add-on's _data/ XML into the database without
        # a version bump - what you need after editing _data/ by hand.
        $map = @{
            'install'   = 'xf:addon-install';   'upgrade' = 'xf:addon-upgrade'
            'rebuild'   = 'xf:addon-rebuild'
            'enable'    = 'xf:addon-enable';    'disable' = 'xf:addon-disable'
            'uninstall' = 'xf:addon-uninstall'
        }
        if (-not $map.ContainsKey($action)) { throw "Unknown action '$action'." }
        Invoke-InContainer @('php', 'cmd.php', $map[$action], $id) | Out-Null
    }

    'import' {
        Assert-Running
        if (-not $Rest) { throw "Usage: .\xf.ps1 import <Vendor/Id>" }
        Invoke-InContainer @('php', 'cmd.php', 'xf-dev:import', "--addon=$($Rest[0])") | Out-Null
    }

    'export' {
        Assert-Running
        if (-not $Rest) { throw "Usage: .\xf.ps1 export <Vendor/Id>" }
        Invoke-InContainer @('php', 'cmd.php', 'xf-addon:export', $Rest[0]) | Out-Null
    }

    'rebuild' { Assert-Running; Invoke-InContainer @('php', 'cmd.php', 'xf-dev:rebuild-caches') | Out-Null }

    'reindex' {
        # The command is xf-rebuild:search. AbstractRebuildCommand builds every
        # rebuild command as xf-rebuild:<name>; there is no xf:rebuild-search.
        Assert-Running
        Invoke-InContainer (@('php', 'cmd.php', 'xf-rebuild:search') + $Rest) | Out-Null
    }

    'defaultaddon' {
        if (-not $Rest) { throw "Usage: .\xf.ps1 defaultaddon <Vendor/Id>" }
        # The id is written into a PHP string in config.php, through a regex
        # replacement. An id shape keeps a quote from ending the PHP string and
        # keeps $ (special in the replacement) out of it.
        if ($Rest[0] -notmatch '^[A-Za-z][A-Za-z0-9_]*(/[A-Za-z][A-Za-z0-9_]*)?$') {
            throw "Not an add-on id: '$($Rest[0])'. Expected Vendor/AddonId (letters, digits, underscore)."
        }
        $cfg = Join-Path (Get-WebrootPath) 'src\config.php'
        $txt = Get-Content $cfg -Raw
        $new = [regex]::Replace($txt, "(\`$config\['development'\]\['defaultAddOn'\]\s*=\s*')[^']*(')", "`${1}$($Rest[0])`${2}")
        [System.IO.File]::WriteAllText($cfg, $new)
        Write-Host "development.defaultAddOn = $($Rest[0])"
    }

    'creds' {
        $port = Get-EnvValue 'HTTP_PORT'; if (-not $port) { $port = '80' }
        $url  = "http://localhost"; if ($port -ne '80') { $url = "http://localhost:$port" }
        Write-Host "URL      : $url/admin.php"
        Write-Host "Username : $(Get-EnvValue 'XF_ADMIN_USER')"
        Write-Host "Password : $(Get-EnvValue 'XF_ADMIN_PASSWORD')"
    }

    'doctor' {
        Write-Host "=== Docker Engine ==="
        Test-EngineVersion

        Write-Host "`n=== containers ==="
        Invoke-Compose @('ps') | Out-Null

        Write-Host "`n=== port exposure ==="
        Assert-NoPublicBind
        Write-Host "  (no warning above = every published port is loopback-only)"

        Write-Host "`n=== PHP extensions XenForo 2.3 needs ==="
        # `php -m` deliberately, not `php -r 'implode(...)'`: PowerShell 5.1
        # mangles double quotes inside a native command's arguments, so the -r
        # variant reaches PHP malformed and reports every extension missing.
        # -m needs no quoting at all.
        # XenForo's installer requires mysqli, gd, iconv, ctype, pcre, json,
        # curl, mbstring, dom and SimpleXML. The rest are ones this image adds
        # because add-ons and XenForo features commonly use them.
        $required = 'mysqli','gd','json','pcre','ctype','iconv','mbstring','openssl','SimpleXML','dom','filter','hash','session','zip','intl','curl','zlib'
        $have = Get-FromContainer @('php', '-m')
        $missing = 0
        foreach ($e in $required) {
            if ($have | Where-Object { $_.Trim() -ieq $e }) { Write-Host ("  ok      {0}" -f $e) }
            else { Write-Host ("  MISSING {0}" -f $e) -ForegroundColor Red; $missing++ }
        }
        if ($missing) { Write-Host "  -> $missing missing; add to the Dockerfile and run: .\xf.ps1 build" -ForegroundColor Red }

        Write-Host "`n=== PHP version ==="
        Get-FromContainer @('php', '-v') | Select-Object -First 1

        Write-Host "`n=== database ==="
        # SHOW TABLES, not a SELECT with a quoted table_schema - same PowerShell
        # 5.1 quoting problem as above.
        $dbName = Get-EnvValue 'MARIADB_DATABASE'; if (-not $dbName) { $dbName = 'xenforo' }
        $tbl = Get-DbOutput @('-e', 'SHOW TABLES')
        $count = @($tbl | Where-Object { $_ -and $_ -notmatch '^Tables_in_' }).Count
        if ($count -gt 0) { Write-Host "  ok      $count tables in '$dbName'" }
        else { Write-Host "  no tables found - has XenForo been installed?" -ForegroundColor Red }

        Write-Host "`n=== Elasticsearch ==="
        # Queried from inside the web container on purpose: Elasticsearch is not
        # published to the host and must never be.
        $esHealth = Get-FromContainer @('curl', '-fsS', 'http://elasticsearch:9200/_cluster/health')
        if ($esHealth) {
            $esJoined = ($esHealth -join '')
            if ($esJoined -match '"status"\s*:\s*"(green|yellow)"') {
                # yellow is normal for a single node: replica shards stay unassigned.
                Write-Host "  ok      cluster status $($Matches[1])"
                $esCount = (Get-FromContainer @('curl', '-fsS', 'http://elasticsearch:9200/xf/_count')) -join ''
                if ($esCount -match '"count"\s*:\s*(\d+)') { Write-Host "  ok      index 'xf' holds $($Matches[1]) document(s)" }
                else { Write-Host "  index 'xf' not found - run the XFES setup wizard in the ACP" -ForegroundColor Yellow }
            }
            else { Write-Host "  cluster unhealthy: $esJoined" -ForegroundColor Red }
        }
        else { Write-Host "  not reachable - XFES will fall back to MySQL search" -ForegroundColor Yellow }

        Write-Host "`n=== HTTP ==="
        $port = Get-EnvValue 'HTTP_PORT'; if (-not $port) { $port = '80' }
        $url  = "http://localhost"; if ($port -ne '80') { $url = "http://localhost:$port" }
        try {
            $r = Invoke-WebRequest -Uri "$url/" -UseBasicParsing -TimeoutSec 15
            Write-Host "  $url -> $($r.StatusCode)"
        } catch { Write-Host "  $url FAILED: $($_.Exception.Message)" -ForegroundColor Red }

        Write-Host "`n=== installed add-ons ==="
        Invoke-InContainer @('php', 'cmd.php', 'xf:addon-list') | Out-Null
    }

    'errors' {
        $n = 5
        if ($Rest -and $Rest[0] -match '^\d+$') { $n = [int]$Rest[0] }
        $logPath = Join-Path (Get-WebrootPath) 'internal_data\error_log.php'
        if (-not (Test-Path $logPath)) { Write-Host "No error_log.php yet - nothing has errored."; break }
        # XenForo writes each entry as a PHP block; show the tail of the raw file.
        Get-Content $logPath -Tail ($n * 12)
    }

    'log'   { Invoke-DockerInteractive @('compose', '--project-directory', $StackDir, 'logs', '--tail', '80', '-f', 'xenforo') }
    'shell' { Assert-Running; Invoke-DockerInteractive @('compose', '--project-directory', $StackDir, 'exec', '-u', 'www-data', 'xenforo', 'bash') }

    'db' {
        # Password via MYSQL_PWD for the length of the session; see Get-DbClientCommand.
        $had = Test-Path Env:MYSQL_PWD; $old = $env:MYSQL_PWD
        $env:MYSQL_PWD = Get-EnvValue 'MARIADB_PASSWORD'
        # .\xf.ps1 db 'SELECT ...' runs one query. A bare -e cannot be used
        # here: this script takes PowerShell's common parameters, and -e is
        # read as an ambiguous abbreviation of -ErrorAction / -ErrorVariable.
        # So a first argument that is not an option is treated as the query.
        $extra = @($Rest | Where-Object { $_ })
        if ($extra.Count -and -not $extra[0].StartsWith('-')) { $extra = @('-e', ($extra -join ' ')) }
        try { Invoke-DockerInteractive (@('compose', '--project-directory', $StackDir) + (Get-DbClientCommand -Interactive) + $extra) }
        finally { if ($had) { $env:MYSQL_PWD = $old } else { Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue } }
    }

    'es' {
        # Queried through the web container because Elasticsearch has no
        # published port and must not get one - it is unauthenticated.
        Assert-Running
        $path = '_cat/indices?v'
        if ($Rest -and $Rest[0]) { $path = $Rest[0] }
        $path = $path.TrimStart('/')
        Invoke-InContainer @('curl', '-fsS', "http://elasticsearch:9200/$path") | Out-Null
        Write-Host ""
    }

    'xdebug' {
        if (-not $Rest) { throw "Usage: .\xf.ps1 xdebug on|off" }
        $dir = '/usr/local/etc/php/conf.d'
        if ($Rest[0] -ieq 'on') {
            Invoke-InContainer -AsRoot @('sh', '-c', "cp $dir/zz-xdebug.ini.disabled $dir/zz-xdebug.ini") | Out-Null
            Write-Host "Xdebug ON (client port 9003)"
        } else {
            Invoke-InContainer -AsRoot @('sh', '-c', "rm -f $dir/zz-xdebug.ini") | Out-Null
            Write-Host "Xdebug OFF"
        }
        Invoke-Compose @('restart', 'xenforo') | Out-Null
    }

    default { throw "Unknown command '$Command'. Run: .\xf.ps1 help" }
}
