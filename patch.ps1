#Requires -Version 5.1
<#
.SYNOPSIS
    Adds RTL (right-to-left) text support to Claude Desktop on Windows.

.DESCRIPTION
    Patches app.asar directly inside the installed Claude MSIX package by
    prepending rtl-payload.js to the Electron renderer files. The normal
    Claude Desktop shortcut opens the patched version -- no separate launcher.

    A Windows scheduled task (registered at logon, elevated) automatically
    re-applies the patch whenever Claude auto-updates.

    Ported from the Mac version by @soguy:
      https://github.com/soguy/claude-desktop-rtl-mac
    RTL payload originally authored by @shraga100:
      https://github.com/shraga100/claude-desktop-rtl-patch

.PARAMETER Install
    Apply the patch. Auto-elevates to Administrator via UAC if needed.
.PARAMETER Uninstall
    Restore the original app.asar, re-enable the Electron fuse, and remove
    the scheduled task. Claude is left in its factory state.
.PARAMETER Status
    Show whether the current Claude version is patched and if the scheduled
    task is registered.
.PARAMETER Force
    Re-patch even if the installed Claude version is already up to date.
    Use this after editing rtl-payload.js.
.PARAMETER Diagnose
    Collect system info, Claude version, fuse state, and recent logs into a
    single report file on the Desktop. Attach this file when opening a GitHub
    issue.
.PARAMETER Help
    Show this help message.

.EXAMPLE
    .\patch.ps1 -Install
    .\patch.ps1 -Install -Force
    .\patch.ps1 -Status
    .\patch.ps1 -Diagnose
    .\patch.ps1 -Uninstall

.LINK
    https://github.com/Aviv943/claude-desktop-rtl-windows
#>
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$Diagnose,
    [switch]$Help,
    [switch]$Force
)

# ---------------------------------------------------------------------------
# Self-elevate to admin via UAC -- re-launches this script elevated if needed
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]'Administrator')

if (-not $isAdmin) {
    $flags = @()
    if ($Install)   { $flags += '-Install' }
    if ($Uninstall) { $flags += '-Uninstall' }
    if ($Status)    { $flags += '-Status' }
    if ($Diagnose)  { $flags += '-Diagnose' }
    if ($Force)     { $flags += '-Force' }
    if ($Help)      { $flags += '-Help' }
    $argStr = "-ExecutionPolicy Bypass -File `"$PSCommandPath`" $($flags -join ' ')"
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argStr -Wait
    exit
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$SCRIPT_DIR    = $PSScriptRoot
$PAYLOAD_FILE  = "$SCRIPT_DIR\rtl-payload.js"
$CONFIG_DIR    = "$env:APPDATA\Claude-RTL"
$BACKUP_DIR    = "$CONFIG_DIR\backups"
$VERSION_FILE  = "$CONFIG_DIR\patched-version.txt"
$LOG_FILE      = "$CONFIG_DIR\patch.log"
$TASK_NAME     = "Claude RTL Auto-Patch"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param($m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "    [!!] $m" -ForegroundColor Yellow }
function Write-Fail { param($m) Write-Host "`n    [ERR] $m`n" -ForegroundColor Red; throw $m }

function Write-Log {
    param($m, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    New-Item -ItemType Directory -Path $CONFIG_DIR -Force | Out-Null
    Add-Content -Path $LOG_FILE -Value "[$ts] [$Level] $m" -Encoding UTF8
}
function Write-LogStep  { param($m) Write-Log $m 'STEP' }
function Write-LogOK    { param($m) Write-Log $m 'OK' }
function Write-LogWarn  { param($m) Write-Log $m 'WARN' }
function Write-LogError { param($m) Write-Log $m 'ERROR' }

function Get-ClaudePackage {
    $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue
    if (-not $pkg) { Write-Fail 'Claude Desktop (MSIX) not found. Install it from https://claude.ai/download' }
    return $pkg
}

function Get-AsarPath {
    param($pkg)
    return "$($pkg.InstallLocation)\app\resources\app.asar"
}

function Get-ExePath {
    param($pkg)
    return "$($pkg.InstallLocation)\app\claude.exe"
}

function Invoke-Native {
    # Runs a native command (scriptblock) and throws if it exits non-zero.
    # Native tools often write progress/warnings to stderr; under
    # $ErrorActionPreference='Stop' Windows PowerShell 5.1 turns any native
    # stderr into a fatal NativeCommandError (even with 2>&1). Relax it for the
    # call and rely on the exit code instead.
    param([string]$Desc, [scriptblock]$Cmd)
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try     { $output = & $Cmd 2>&1 }
    finally { $ErrorActionPreference = $eap }
    if ($LASTEXITCODE -ne 0) {
        $output | ForEach-Object { Write-Host "    $_" }
        Write-Fail "$Desc failed (exit $LASTEXITCODE)"
    }
    return $output
}

function Grant-WriteAccess {
    param([string]$Path)
    $null = (takeown /f $Path /a) 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Fail "takeown failed: $Path" }
    $null = (icacls $Path /grant 'Administrators:F') 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Fail "icacls grant failed: $Path" }
}

function Restore-Permissions {
    param([string]$Path)
    # Resets ACL to inherited -- removes the explicit Administrators:F entry we added
    $null = (icacls $Path /reset) 2>&1
}

function Stop-ClaudeProcesses {
    # Stops any Claude Desktop processes running from the WindowsApps package directory.
    # Returns $true if any were stopped.
    $procs = Get-Process -Name claude -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like '*WindowsApps*Claude*' }
    if (-not $procs) { return $false }
    Write-Warn "Stopping $($procs.Count) Claude Desktop process(es) for patching..."
    $procs | ForEach-Object { $_.CloseMainWindow() | Out-Null }
    Start-Sleep -Seconds 2
    # Force-kill any that didn't respond to close
    $procs | ForEach-Object {
        if (-not $_.HasExited) { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Seconds 1
    return $true
}

function Start-ClaudeDeElevated {
    # Launches Claude at NORMAL (medium) integrity even though this script runs
    # elevated. A process started directly from this elevated script would inherit
    # High integrity, and a High-integrity Claude window blocks the global
    # low-level keyboard hooks (WH_KEYBOARD_LL) of OTHER non-elevated apps --
    # dictation / hotkey tools such as AutoHotkey -- whenever Claude is the
    # foreground window (Windows UIPI). Handing the launch to the medium-integrity
    # shell (explorer.exe) makes Claude run as a normal user app so those global
    # hotkeys keep working over the Claude window.
    param($Package, [string]$ExePath)
    $env:NODE_NO_WARNINGS = '1'
    try {
        $appId = 'Claude'
        try { $appId = @((Get-AppxPackageManifest $Package).Package.Applications.Application.Id)[0] } catch {}
        $aumid = "$($Package.PackageFamilyName)!$appId"
        Start-Process 'explorer.exe' "shell:AppsFolder\$aumid"
    } catch {
        Write-Warn "Normal-integrity launch failed ($_); falling back to direct launch."
        Start-Process $ExePath
    }
    $env:NODE_NO_WARNINGS = $null
}

function Test-FuseDisabled {
    # Returns $true if the ASAR integrity validation fuse reads back as Disabled.
    param([string]$ExePath)
    $env:NODE_NO_WARNINGS = '1'
    try {
        $out = (cmd.exe /c "npx --yes @electron/fuses read --app `"$ExePath`" 2>&1") | Out-String
    } finally { $env:NODE_NO_WARNINGS = $null }
    return ($out -match 'EnableEmbeddedAsarIntegrityValidation[^\r\n]*Disabled')
}

function Set-AsarFuseDisabled {
    # Turns the ASAR integrity fuse OFF and VERIFIES it by reading it back.
    # The fuse write fails if claude.exe is still running/locked, so we fully
    # stop Claude and retry. Hard-fails if it can't be confirmed disabled --
    # callers rely on that to abort before modifying app.asar.
    param([string]$ExePath)

    if (Test-FuseDisabled $ExePath) {
        Write-OK 'Fuse already disabled -- skipping write'
        return
    }

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        Stop-ClaudeProcesses | Out-Null
        Start-Sleep -Seconds 3
        $env:NODE_NO_WARNINGS = '1'
        $out  = cmd.exe /c "npx --yes @electron/fuses write --app `"$ExePath`" EnableEmbeddedAsarIntegrityValidation=off 2>&1"
        $code = $LASTEXITCODE
        $env:NODE_NO_WARNINGS = $null

        if ($code -eq 0 -and (Test-FuseDisabled $ExePath)) { return }

        Write-Warn "Fuse write attempt $attempt/5 failed (exit $code; claude.exe may be busy) -- retrying..."
        $out | ForEach-Object { Write-Host "    $_" }
    }

    Write-Fail @'
Could not disable the ASAR integrity fuse after 5 attempts.
app.asar was NOT modified, so Claude Desktop still works normally.
Fully quit Claude Desktop (check the system tray) and re-run with -Install.
'@
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
function Install-RTLPatch {

    # --- Locate Claude + version check FIRST ---
    # The auto-patch task fires on every MSIX register (event 613), most of which
    # are other apps (OneDrive, Edge, ...). Doing the cheap version check before
    # the slower Node/npx dependency probes lets those spurious runs exit in ~1s.
    Write-Step 'Locating Claude Desktop installation'
    $pkg  = Get-ClaudePackage
    $ver  = $pkg.Version.ToString()
    $ASAR = Get-AsarPath $pkg
    $EXE  = Get-ExePath  $pkg
    Write-OK "Claude $ver"
    Write-OK "Location: $($pkg.InstallLocation)"

    # --- Version check ---
    if (-not $Force -and (Test-Path $VERSION_FILE)) {
        $cached = (Get-Content $VERSION_FILE -Raw).Trim()
        if ($cached -eq $ver) {
            Write-Host "`n    Claude RTL is already patched (v$ver). Use -Force to reinstall." -ForegroundColor Green
            return
        }
        Write-Warn "Claude was updated: $cached -> $ver. Reapplying patch..."
    }

    Write-Step 'Checking dependencies'

    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        Write-Fail 'Node.js not found. Install from https://nodejs.org then rerun.'
    }
    Write-OK "Node.js $(node --version)"

    # Probe via cmd.exe so npx's stderr (download notices, etc.) can't trip
    # Windows PowerShell 5.1's NativeCommandError under -ErrorActionPreference Stop.
    # --version prints to stdout and exits 0, so it's a clean availability check.
    $asarVer = (cmd.exe /c "npx --yes @electron/asar --version 2>&1") | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0) { Write-Fail '@electron/asar not available via npx' }
    Write-OK "@electron/asar $asarVer"

    if (-not (Test-Path $PAYLOAD_FILE)) {
        Write-Fail "rtl-payload.js not found at: $PAYLOAD_FILE"
    }
    Write-OK 'RTL payload found'

    # --- Backup original asar (once per version) ---
    Write-Step 'Backing up original app.asar'
    $backupFile = "$BACKUP_DIR\$ver\app.asar.original"
    if (-not (Test-Path $backupFile)) {
        New-Item -ItemType Directory -Path "$BACKUP_DIR\$ver" -Force | Out-Null
        Copy-Item $ASAR $backupFile -Force
        Write-OK "Saved to: $backupFile"
    } else {
        Write-OK "Backup already exists for v$ver -- skipped"
    }

    # --- Extract app.asar (the LIVE file -- it sits beside its app.asar.unpacked
    #     sidecar of native modules, which a standalone backup copy lacks, so the
    #     backup can't be extracted directly). Any previously-injected payload is
    #     stripped during injection below, so re-patching never stacks copies. ---
    Write-Step 'Extracting app.asar'
    $extractDir = "$env:TEMP\claude-rtl-extract-$(Get-Random)"
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    $null = cmd.exe /c "npx --yes @electron/asar extract `"$ASAR`" `"$extractDir`" 2>&1"
    if ($LASTEXITCODE -ne 0) { Write-Fail "asar extract failed (exit $LASTEXITCODE)" }
    Write-OK 'Extracted'

    # --- Inject RTL payload into renderer files ---
    Write-Step 'Injecting RTL payload into renderer files'
    $payload = [System.IO.File]::ReadAllText($PAYLOAD_FILE, [System.Text.Encoding]::UTF8)

    $renderers = Get-ChildItem -Path $extractDir -Recurse -Filter '*.js' | Where-Object {
        $_.FullName -match ([regex]::Escape('.vite') + '[/\\]build[/\\]') -and
        $_.Extension -eq '.js'
    }

    if ($renderers.Count -eq 0) {
        Remove-Item $extractDir -Recurse -Force
        Write-Fail 'No .vite/build/*.js files found in app.asar. App structure may have changed.'
    }

    foreach ($f in $renderers) {
        $original = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
        # Strip any previously-injected payload block(s) so re-patching an
        # already-patched renderer never stacks a second copy.
        $clean = [regex]::Replace($original, '(?s)// --- CLAUDE RTL PATCH START ---.*?// --- CLAUDE RTL PATCH END ---\r?\n?', '')
        [System.IO.File]::WriteAllText($f.FullName, $payload + "`n" + $clean, [System.Text.Encoding]::UTF8)
        Write-OK "Patched $($f.Name)"
    }

    # --- Pack to a temp file first, then atomically replace ---
    # Native binaries MUST stay outside the archive in app.asar.unpacked -- the
    # OS loads them via dlopen/LoadLibrary/CreateProcess, which cannot read from
    # a virtual asar path. Without this --unpack rule they get packed INTO the
    # asar and Claude crashes on launch.
    #
    # The factory build unpacks EXACTLY the .node / .dll / .exe files (the
    # claude-native + node-pty + office365-mcp binaries) and nothing else -- the
    # large .mjs files in those same folders stay packed. So we match by
    # extension only: unpacking whole directories would also externalize those
    # .mjs files, and since we keep the existing on-disk app.asar.unpacked
    # sidecar (which never contained them), they'd go missing and break the
    # office365-mcp / pdf features.
    Write-Step 'Repacking app.asar'
    $asarNew = "$env:TEMP\app.asar.rtl-$(Get-Random)"
    $unpack  = '*.{node,dll,exe}'
    $null = cmd.exe /c "npx --yes @electron/asar pack `"$extractDir`" `"$asarNew`" --unpack `"$unpack`" 2>&1"
    if ($LASTEXITCODE -ne 0) { Write-Fail "asar pack failed (exit $LASTEXITCODE)" }
    Remove-Item $extractDir -Recurse -Force

    # Guard: confirm the repack actually externalized the native modules. If the
    # .unpacked sidecar is missing/empty the glob didn't match -- abort rather
    # than install an asar that swallows the native modules.
    $asarNewUnpacked = "$asarNew.unpacked"
    $unpackedNodes = @(Get-ChildItem $asarNewUnpacked -Recurse -Filter '*.node' -ErrorAction SilentlyContinue)
    if ($unpackedNodes.Count -lt 1) {
        Remove-Item $asarNew -Force -ErrorAction SilentlyContinue
        Remove-Item $asarNewUnpacked -Recurse -Force -ErrorAction SilentlyContinue
        Write-Fail 'Repack did not unpack any native (.node) modules -- aborting to avoid a broken launch. The asar --unpack glob may need updating.'
    }
    Write-OK "Packed ($($unpackedNodes.Count) native modules kept unpacked)"

    # --- Stop Claude so we can replace claude.exe + app.asar ---
    $hadClaude = Stop-ClaudeProcesses
    if ($hadClaude) { Write-OK 'Claude Desktop stopped' }

    # --- Grant write access to the WindowsApps files ---
    Write-Step 'Granting write access to WindowsApps files'
    Grant-WriteAccess $ASAR
    Write-OK 'app.asar -- write granted'
    Grant-WriteAccess $EXE
    Write-OK 'claude.exe -- write granted'

    # --- Disable the ASAR integrity fuse BEFORE swapping the asar ---
    # With the fuse on, an integrity-validated Electron rejects the modified
    # asar and refuses to launch. Disabling (and verifying) it first means a
    # failure here aborts while the ORIGINAL, working asar is still in place --
    # never leaving a modified-asar + enabled-fuse combination that won't start.
    Write-Step 'Disabling ASAR integrity fuse on claude.exe'
    Set-AsarFuseDisabled $EXE
    Write-OK 'ASAR integrity fuse is Disabled (verified)'

    # --- Overwrite app.asar in-place ---
    # We only have file-level write access (not parent-dir write), so renaming or
    # moving inside WindowsApps is denied.  [IO.File]::Copy with overwrite=true
    # works with just file-level write permission. The native modules stay in the
    # existing resources\app.asar.unpacked sidecar (untouched), which the freshly
    # repacked header references.
    Write-Step 'Installing patched app.asar'
    [System.IO.File]::Copy($asarNew, $ASAR, $true)
    Remove-Item $asarNew -Force -ErrorAction SilentlyContinue
    Remove-Item $asarNewUnpacked -Recurse -Force -ErrorAction SilentlyContinue
    Write-OK 'app.asar replaced'

    # --- Restore original (restrictive) permissions ---
    Write-Step 'Restoring file permissions'
    Restore-Permissions $ASAR
    Restore-Permissions $EXE
    Write-OK 'Permissions restored'

    # --- Save patched version ---
    New-Item -ItemType Directory -Path $CONFIG_DIR -Force | Out-Null
    $ver | Set-Content $VERSION_FILE -Encoding UTF8
    Write-LogOK "Patched Claude $ver successfully"
    Write-LogStep "Renderers patched: $($renderers.Count) files"

    # --- Register scheduled task (logon, admin, 30-second startup delay) ---
    Write-Step 'Registering auto-patch scheduled task'
    Register-AutoPatchTask
    Write-OK "Task '$TASK_NAME' registered -- fires at logon and on Claude auto-update"

    # --- Remove old Claude-RTL copy (from prior approach) if present ---
    $oldDir = "$env:LOCALAPPDATA\Claude-RTL"
    if (Test-Path $oldDir) {
        Write-Step 'Cleaning up old Claude-RTL copy'
        Remove-Item $oldDir -Recurse -Force
        $desktopDir  = [Environment]::GetFolderPath('Desktop')
        $programsDir = [Environment]::GetFolderPath('Programs')
        foreach ($lnk in @(
            "$desktopDir\Claude RTL.lnk",
            "$programsDir\Claude RTL.lnk",
            "$env:USERPROFILE\Desktop\Claude RTL.lnk"
        )) {
            if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-OK "Removed: $lnk" }
        }
        Write-OK 'Old copy removed'
    }

    Write-Host ''
    Write-Host '=====================================================' -ForegroundColor Green
    Write-Host ' Claude RTL patch applied!' -ForegroundColor Green
    Write-Host ' Open Claude Desktop normally -- RTL is active.' -ForegroundColor Green
    Write-Host ' After future Claude updates, the patch reapplies automatically' -ForegroundColor Green
    Write-Host ' within seconds (or at next logon as a fallback).' -ForegroundColor Green
    Write-Host '=====================================================' -ForegroundColor Green

    # Always restart Claude after patching so the new asar is loaded.
    # Kill any lingering process first, then start fresh.
    $lingering = Get-Process -Name claude -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like '*WindowsApps*Claude*' }
    $lingering | ForEach-Object {
        $_.CloseMainWindow() | Out-Null
        Start-Sleep -Seconds 1
        if (-not $_.HasExited) { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "`n    Reopening Claude Desktop (at normal integrity)..." -ForegroundColor Cyan
    Start-ClaudeDeElevated $pkg $EXE
}

# ---------------------------------------------------------------------------
# Scheduled task registration
# ---------------------------------------------------------------------------
function Register-AutoPatchTask {
    $action = New-ScheduledTaskAction `
        -Execute   'powershell.exe' `
        -Argument  "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Install"

    # --- Trigger 1: at logon (30s delay) ---
    # Catches updates that were applied while signed out / before this session.
    $logon = New-ScheduledTaskTrigger -AtLogOn
    $logon.Delay = 'PT30S'

    # --- Trigger 2: the instant Claude finishes (re)registering after an update ---
    # An MSIX update raises AppxDeploymentServer event 613 ("Deployment Register
    # operation") for the new package version. This fires the re-patch within
    # seconds of an in-session auto-update, instead of waiting for the next logon.
    # The Windows event-query engine has no string functions, so we can't filter
    # by package name -- we match ANY 613 and let the version check above no-op
    # for non-Claude packages. The 15s delay lets the new files settle first.
    $subscription = @'
<QueryList><Query Id="0" Path="Microsoft-Windows-AppxDeploymentServer/Operational"><Select Path="Microsoft-Windows-AppxDeploymentServer/Operational">*[System[Provider[@Name='Microsoft-Windows-AppXDeployment-Server'] and (EventID=613)]]</Select></Query></QueryList>
'@
    $evtClass = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskEventTrigger'
    $onUpdate = New-CimInstance -CimClass $evtClass -ClientOnly
    $onUpdate.Enabled      = $true
    $onUpdate.Subscription = $subscription
    $onUpdate.Delay        = 'PT15S'

    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit    (New-TimeSpan -Minutes 10) `
        -StartWhenAvailable `
        -DontStopIfGoingOnBatteries `
        -MultipleInstances     IgnoreNew

    # RunLevel Highest = runs elevated without a UAC prompt at logon
    $principal = New-ScheduledTaskPrincipal `
        -UserId    ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive `
        -RunLevel  Highest

    Register-ScheduledTask `
        -TaskName   $TASK_NAME `
        -Action     $action `
        -Trigger    @($logon, $onUpdate) `
        -Settings   $settings `
        -Principal  $principal `
        -Description 'Re-applies Claude RTL patch at logon and the moment Claude auto-updates (AppX deployment event 613). Registered by patch.ps1.' `
        -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
function Uninstall-RTLPatch {
    Write-Step 'Removing Claude RTL patch'

    $pkg = Get-ClaudePackage
    $ver  = $pkg.Version.ToString()
    $ASAR = Get-AsarPath $pkg
    $EXE  = Get-ExePath  $pkg
    $backupFile = "$BACKUP_DIR\$ver\app.asar.original"

    if (Test-Path $backupFile) {
        $hadClaude = Stop-ClaudeProcesses
        if ($hadClaude) { Write-OK 'Claude Desktop stopped' }

        Grant-WriteAccess $ASAR
        Grant-WriteAccess $EXE

        # Restore original asar from backup
        Copy-Item $backupFile $ASAR -Force
        Write-OK 'Original app.asar restored'

        # Re-enable the ASAR integrity fuse
        $env:NODE_NO_WARNINGS = '1'
        $fuseOut = Invoke-Native '@electron/fuses write' {
            npx --yes '@electron/fuses' write --app "$EXE" EnableEmbeddedAsarIntegrityValidation=on
        }
        $env:NODE_NO_WARNINGS = $null
        $fuseOut | ForEach-Object { Write-Host "    $_" }
        Write-OK 'ASAR integrity fuse re-enabled'

        Restore-Permissions $ASAR
        Restore-Permissions $EXE

        if ($hadClaude) {
            Start-ClaudeDeElevated $pkg $EXE
        }
    } else {
        Write-Warn "No backup found for Claude v$ver."
        Write-Host "    Claude will be fully restored on its next auto-update." -ForegroundColor Yellow
        Write-Host "    Or reinstall Claude from https://claude.ai/download" -ForegroundColor Yellow
    }

    # Remove scheduled task
    Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false -ErrorAction SilentlyContinue
    Write-OK "Scheduled task '$TASK_NAME' removed"

    # Remove config directory
    if (Test-Path $CONFIG_DIR) {
        Remove-Item $CONFIG_DIR -Recurse -Force
        Write-OK 'Config/backups removed'
    }

    Write-Host "`nClaude RTL uninstalled. Claude Desktop is restored." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
function Show-Status {
    Write-Host "`n=== Claude RTL Status ===" -ForegroundColor Cyan

    $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue
    if ($pkg) {
        Write-Host "  Installed Claude  : $($pkg.Version)"
    } else {
        Write-Host "  Installed Claude  : NOT FOUND" -ForegroundColor Red
    }

    if (Test-Path $VERSION_FILE) {
        $pv    = (Get-Content $VERSION_FILE -Raw).Trim()
        $match = $pkg -and ($pv -eq $pkg.Version.ToString())
        $color = if ($match) { 'Green' } else { 'Yellow' }
        $tag   = if ($match) { '(up to date)' } else { '(OUTDATED -- run -Install)' }
        Write-Host "  Patched version   : $pv $tag" -ForegroundColor $color
    } else {
        Write-Host "  RTL Patch         : NOT INSTALLED" -ForegroundColor Red
    }

    $task = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    Write-Host "  Auto-patch task   : $(if ($task) { 'Registered' } else { 'Not registered' })"
    Write-Host "  Log file          : $LOG_FILE"
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Diagnose
# ---------------------------------------------------------------------------
function Show-Diagnose {
    $lines = [System.Collections.Generic.List[string]]::new()
    $add   = { param($s) $lines.Add($s) }

    & $add '=== Claude Desktop RTL Windows — Diagnostic Report ==='
    & $add "Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    & $add "Script    : $PSCommandPath"
    & $add ''

    # --- OS ---
    & $add '--- System ---'
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        & $add "OS        : $($os.Caption) (Build $($os.BuildNumber))"
        & $add "Version   : $($os.Version)"
    } catch {
        & $add "OS        : (could not read - $_)"
    }
    & $add "Arch      : $($env:PROCESSOR_ARCHITECTURE)"
    & $add "PowerShell: $($PSVersionTable.PSVersion)"
    & $add ''

    # --- Node.js ---
    & $add '--- Node.js ---'
    $nodeVer = (node --version 2>&1)
    if ($LASTEXITCODE -eq 0) { & $add "Version : $nodeVer" }
    else                     { & $add 'Version : NOT FOUND — install from https://nodejs.org' }
    & $add ''

    # --- Claude Desktop ---
    & $add '--- Claude Desktop ---'
    $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue
    if ($pkg) {
        $ver  = $pkg.Version.ToString()
        $ASAR = Get-AsarPath $pkg
        $EXE  = Get-ExePath  $pkg
        & $add "Version  : $ver"
        & $add "Location : $($pkg.InstallLocation)"
        & $add "app.asar : $(if (Test-Path $ASAR) { 'found' } else { 'MISSING' })"

        # Check if our payload is present in the asar (fast: read first 512 KB)
        if (Test-Path $ASAR) {
            try {
                $fs     = [System.IO.File]::OpenRead($ASAR)
                $buf    = New-Object byte[] 524288
                $read   = $fs.Read($buf, 0, $buf.Length)
                $fs.Close()
                $sample = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
                if ($sample -match 'CLAUDE RTL PATCH') { & $add 'Payload  : FOUND (asar is patched)' }
                else                                   { & $add 'Payload  : NOT FOUND (asar is unpatched)' }
            } catch { & $add "Payload  : could not read asar - $_" }
        }

        # Fuse state (read-only, no write, no UAC risk)
        $env:NODE_NO_WARNINGS = '1'
        $fuseOut = (cmd.exe /c "npx --yes @electron/fuses read --app `"$EXE`" 2>&1") | Out-String
        $env:NODE_NO_WARNINGS = $null
        if      ($fuseOut -match 'EnableEmbeddedAsarIntegrityValidation[^\n]*Disabled') { & $add 'Fuse     : Disabled (correct)' }
        elseif  ($fuseOut -match 'EnableEmbeddedAsarIntegrityValidation[^\n]*Enabled')  { & $add 'Fuse     : Enabled  (patch will not load)' }
        else                                                                              { & $add 'Fuse     : unknown — fuse tool output below'; & $add $fuseOut }
    } else {
        & $add 'Claude Desktop : NOT INSTALLED'
    }
    & $add ''

    # --- Patch state ---
    & $add '--- Patch State ---'
    if (Test-Path $VERSION_FILE) {
        $pv    = (Get-Content $VERSION_FILE -Raw).Trim()
        $match = $pkg -and ($pv -eq $pkg.Version.ToString())
        & $add "Patched version : $pv"
        & $add "Status          : $(if ($match) { 'UP TO DATE' } else { 'OUTDATED — run -Install' })"
    } else {
        & $add 'Status : NOT PATCHED'
    }
    & $add ''

    # --- Scheduled task ---
    & $add '--- Scheduled Task ---'
    $task = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    if ($task) {
        $tri  = ($task.Triggers | ForEach-Object { $_.GetType().Name }) -join ', '
        & $add "Task   : Registered"
        & $add "State  : $($task.State)"
        & $add "Trigger: $tri"
    } else {
        & $add 'Task : NOT REGISTERED'
    }
    & $add ''

    # --- Recent log ---
    & $add '--- Recent Log (last 30 lines) ---'
    if (Test-Path $LOG_FILE) {
        Get-Content $LOG_FILE -Tail 30 | ForEach-Object { & $add $_ }
    } else {
        & $add '(no log file — patcher has not run yet)'
    }
    & $add ''
    & $add '=== End of report ==='

    # Write to Desktop
    $dest = [Environment]::GetFolderPath('Desktop') + '\claude-rtl-diagnose.txt'
    $lines | Set-Content $dest -Encoding UTF8

    Write-Host ''
    Write-Host "  Diagnostic report saved to:" -ForegroundColor Cyan
    Write-Host "  $dest" -ForegroundColor White
    Write-Host ''
    Write-Host '  Attach this file when opening a GitHub issue:' -ForegroundColor Yellow
    Write-Host '  https://github.com/Aviv943/claude-desktop-rtl-windows/issues' -ForegroundColor Yellow
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
function Show-Help {
    Write-Host @'

Claude Desktop RTL Patcher for Windows
Ported from: https://github.com/soguy/claude-desktop-rtl-mac

USAGE
  .\patch.ps1 [-Install] [-Uninstall] [-Status] [-Force] [-Help]

OPTIONS
  -Install    Patch Claude in-place. Auto-elevates via UAC if needed.
  -Uninstall  Restore original Claude and remove auto-patch task.
  -Status     Show patch status.
  -Force      Re-patch even if already up to date.
  -Help       Show this help.

HOW IT WORKS
  1. Backs up the original app.asar (per version, in AppData).
  2. Extracts app.asar, prepends RTL detection JS to renderer files, repacks.
  3. Disables Electron ASAR integrity fuse on claude.exe.
  4. Registers a logon scheduled task that auto-repatches after Claude updates.
  No separate shortcut needed -- the normal Claude Desktop has RTL support.

'@
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if ($Help)      { Show-Help;          exit 0 }
if ($Uninstall) { Uninstall-RTLPatch; exit 0 }
if ($Status)    { Show-Status;        exit 0 }
if ($Diagnose)  { Show-Diagnose;      exit 0 }
if ($Install)   { Install-RTLPatch;   exit 0 }

# Interactive menu when no flags given
Write-Host ''
Write-Host '=== Claude Desktop RTL Patcher for Windows ===' -ForegroundColor Cyan
Write-Host '  Based on: https://github.com/soguy/claude-desktop-rtl-mac'
Write-Host ''
Write-Host '  1) Install / Update RTL patch'
Write-Host '  2) Uninstall'
Write-Host '  3) Status'
Write-Host '  4) Generate diagnostic report'
Write-Host '  5) Exit'
Write-Host ''
$choice = Read-Host 'Select option'
switch ($choice) {
    '1' { Install-RTLPatch }
    '2' { Uninstall-RTLPatch }
    '3' { Show-Status }
    '4' { Show-Diagnose }
    '5' { exit 0 }
    default { Write-Host 'Invalid option.' -ForegroundColor Red }
}
