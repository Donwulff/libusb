<#
.SYNOPSIS
    Deploy, monitor, or restore libusb-1.0.dll across Windows tool installations.

.DESCRIPTION
    Manages deployment of a custom libusb-1.0.dll build. Three modes of operation:

    REPLACE   Scan directories for installed copies of libusb-1.0.dll, back up
              originals (.bak), and replace with the specified build.  Only DLLs
              whose PE architecture matches the source are touched.

    WATCH     Launch a program and monitor the filesystem for any new copies of
              libusb-1.0.dll appearing in temp directories (self-extracting apps,
              PyInstaller, cx_Freeze, etc.).  Each copy is replaced as soon as
              it is written, before the application loads it.
              Without -App, runs as a background daemon until Ctrl+C.

    RESTORE   Restore all .bak files created by a previous -Replace run.

    LIST      Show all found DLLs with version, architecture, and backup status.

.PARAMETER SourceDll
    Path to the libusb-1.0.dll to deploy.  Required for -Replace and -Watch.
    If omitted, the script looks for a build relative to its own location.

.PARAMETER Replace
    Replace installed DLLs with backup (default mode if no switch given).

.PARAMETER Watch
    Monitor temp directories for self-extracting apps.  Patches any
    libusb-1.0.dll that appears.  Exits when -App process exits, or on Ctrl+C.

.PARAMETER App
    Path to an application to launch with -Watch.  The watcher runs until
    the application exits.  Without this, the watcher runs until Ctrl+C.

.PARAMETER AppArgs
    Arguments to pass to the application specified by -App.

.PARAMETER WatchPath
    Directory to monitor for self-extracted DLLs.  Default: $env:TEMP.

.PARAMETER Restore
    Restore original DLLs from .bak files.

.PARAMETER List
    List all found DLLs (read-only).

.PARAMETER SearchPaths
    Directories to scan for -Replace, -Restore, and -List.

.PARAMETER DryRun
    Preview changes without writing anything.

.EXAMPLE
    .\deploy_libusb.ps1 -List
    Show all installed libusb-1.0.dll with version and architecture.

.EXAMPLE
    .\deploy_libusb.ps1 -SourceDll .\libusb-1.0.dll -Replace -DryRun
    Preview which installed DLLs would be replaced.

.EXAMPLE
    .\deploy_libusb.ps1 -SourceDll .\libusb-1.0.dll -Replace
    Replace all architecture-matching DLLs. Originals backed up as .bak.

.EXAMPLE
    .\deploy_libusb.ps1 -SourceDll .\libusb-1.0.dll -Watch -App "C:\ti\toolbox.exe"
    Launch toolbox.exe and patch any libusb-1.0.dll it extracts to temp.

.EXAMPLE
    .\deploy_libusb.ps1 -SourceDll .\libusb-1.0.dll -Watch
    Run as a daemon, patching any libusb-1.0.dll extracted by any app.

.EXAMPLE
    .\deploy_libusb.ps1 -Restore
    Restore all originals from .bak backups.
#>

[CmdletBinding(DefaultParameterSetName = "Replace")]
param(
    # --- Source DLL (shared by Replace and Watch) ---
    [Parameter(ParameterSetName = "Replace",  Position = 0)]
    [Parameter(ParameterSetName = "Watch",    Position = 0)]
    [string]$SourceDll = "",

    # --- Mode switches ---
    [Parameter(ParameterSetName = "Replace")]
    [switch]$Replace,

    [Parameter(ParameterSetName = "Watch", Mandatory = $true)]
    [switch]$Watch,

    [Parameter(ParameterSetName = "Restore", Mandatory = $true)]
    [switch]$Restore,

    [Parameter(ParameterSetName = "List", Mandatory = $true)]
    [switch]$List,

    # --- Watch options ---
    [Parameter(ParameterSetName = "Watch")]
    [string]$App = "",

    [Parameter(ParameterSetName = "Watch")]
    [string]$AppArgs = "",

    [Parameter(ParameterSetName = "Watch")]
    [string]$WatchPath = $env:TEMP,

    # --- Replace/Restore options ---
    [Parameter(ParameterSetName = "Replace")]
    [Parameter(ParameterSetName = "Restore")]
    [Parameter(ParameterSetName = "List")]
    [string[]]$SearchPaths = @(
        "C:\ti",
        "C:\Program Files (x86)\Texas Instruments",
        "C:\Program Files\Texas Instruments"
    ),

    # --- Common ---
    [Parameter(ParameterSetName = "Replace")]
    [Parameter(ParameterSetName = "Restore")]
    [switch]$DryRun
)

# ============================================================================
# Helpers
# ============================================================================

function Get-PEMachine([string]$path) {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $peOffset = [BitConverter]::ToInt32($bytes, 60)
        return [BitConverter]::ToUInt16($bytes, $peOffset + 4)
    } catch { return $null }
}

function Get-ArchName([nullable[uint16]]$machine) {
    if ($null -eq $machine) { return "?" }
    switch ($machine) {
        0x8664 { return "x64"   }
        0x14c  { return "x86"   }
        0x1c0  { return "ARM"   }
        0xAA64 { return "ARM64" }
        default { return "0x{0:X4}" -f $machine }
    }
}

function Get-DllVersion([string]$path) {
    try {
        $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($path)
        if ($vi.FileVersion) { return $vi.FileVersion }
        return "?"
    } catch { return "?" }
}

function Get-AllLibusbDlls([string[]]$paths) {
    $results = @()
    foreach ($p in $paths) {
        if (Test-Path $p) {
            $results += Get-ChildItem -Path $p -Recurse -Filter "libusb-1.0.dll" `
                            -ErrorAction SilentlyContinue
        }
    }
    return $results
}

function Resolve-SourceDll([string]$given) {
    if ($given -and (Test-Path $given)) {
        return (Resolve-Path $given).Path
    }
    # Auto-discover relative to script location
    $scriptDir = Split-Path -Parent $MyInvocation.ScriptName
    $candidates = @(
        (Join-Path $scriptDir "..\..\build\v145\x64\Release\dll\libusb-1.0.dll"),
        (Join-Path $scriptDir "..\..\build\v145\x64\Debug\dll\libusb-1.0.dll"),
        (Join-Path $scriptDir "libusb-1.0.dll")
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return (Resolve-Path $c).Path }
    }
    return $null
}

function Show-SourceInfo([string]$path) {
    $machine = Get-PEMachine $path
    $arch    = Get-ArchName $machine
    $ver     = Get-DllVersion $path
    $size    = (Get-Item $path).Length
    Write-Host "Source DLL : $path" -ForegroundColor Cyan
    Write-Host ("            {0}, version {1}, {2:N0} bytes" -f $arch, $ver, $size)
    return $machine
}

# ============================================================================
# LIST
# ============================================================================

if ($List) {
    Write-Host "Searching for libusb-1.0.dll ..." -ForegroundColor Cyan
    Write-Host ""
    $dlls = Get-AllLibusbDlls $SearchPaths
    if ($dlls.Count -eq 0) {
        Write-Host "None found in: $($SearchPaths -join ', ')"
        exit 0
    }
    foreach ($dll in $dlls) {
        $machine = Get-PEMachine $dll.FullName
        $arch    = Get-ArchName $machine
        $ver     = Get-DllVersion $dll.FullName
        $hasBak  = Test-Path ($dll.FullName + ".bak")
        $bakNote = if ($hasBak) { " [backup]" } else { "" }
        Write-Host ("[{0,-5}] v{1,-18} {2}{3}" -f $arch, $ver, $dll.FullName, $bakNote)
    }
    exit 0
}

# ============================================================================
# RESTORE
# ============================================================================

if ($Restore) {
    $label = if ($DryRun) { "Restore (dry run)" } else { "Restore" }
    Write-Host "$label - scanning for .bak files ..." -ForegroundColor Cyan
    $baks = @()
    foreach ($p in $SearchPaths) {
        if (Test-Path $p) {
            $baks += Get-ChildItem -Path $p -Recurse -Filter "libusb-1.0.dll.bak" `
                         -ErrorAction SilentlyContinue
        }
    }
    if ($baks.Count -eq 0) {
        Write-Host "No .bak files found. Nothing to restore."
        exit 0
    }

    $ok = 0; $fail = 0
    foreach ($bak in $baks) {
        $target = $bak.FullName -replace '\.bak$', ''
        $bakVer = Get-DllVersion $bak.FullName
        $curVer = if (Test-Path $target) { Get-DllVersion $target } else { "(missing)" }
        if ($DryRun) {
            Write-Host ("WOULD RESTORE  v{0,-18} <- v{1,-18} {2}" -f $bakVer, $curVer, $target) -ForegroundColor Cyan
            $ok++
        } else {
            try {
                Copy-Item $bak.FullName $target -Force
                Remove-Item $bak.FullName -Force
                Write-Host ("RESTORED       v{0,-18} {1}" -f $bakVer, $target) -ForegroundColor Green
                $ok++
            } catch {
                Write-Host ("ERROR          {0}: {1}" -f $target, $_) -ForegroundColor Red
                $fail++
            }
        }
    }
    Write-Host "`nRestored: $ok, errors: $fail"
    exit $(if ($fail -gt 0) { 1 } else { 0 })
}

# ============================================================================
# Require SourceDll for Replace and Watch
# ============================================================================

$SourceDll = Resolve-SourceDll $SourceDll
if (-not $SourceDll) {
    Write-Error ("Source DLL not found. Specify -SourceDll <path>.`n" +
                 "Use -List to see currently installed copies.")
    exit 1
}
$srcMachine = Show-SourceInfo $SourceDll
$srcHash    = (Get-FileHash $SourceDll -Algorithm SHA256).Hash
$srcVer     = Get-DllVersion $SourceDll
if ($DryRun) { Write-Host "(DRY RUN)" -ForegroundColor Yellow }
Write-Host ""

# ============================================================================
# WATCH
# ============================================================================

if ($Watch) {
    $process = $null

    if ($App) {
        if (-not (Test-Path $App)) {
            Write-Error "Application not found: $App"
            exit 1
        }
        Write-Host "Launching: $App $AppArgs" -ForegroundColor Cyan

        # Also try placing DLL next to the exe (helps for non-self-extracting apps)
        $appDir = Split-Path -Parent (Resolve-Path $App).Path
        $sideLoad = Join-Path $appDir "libusb-1.0.dll"
        if (-not (Test-Path $sideLoad)) {
            try {
                Copy-Item $SourceDll $sideLoad
                Write-Host "Placed DLL next to application: $sideLoad"
            } catch {
                # Permission denied or read-only - not critical
            }
        }

        if ($AppArgs) {
            $process = Start-Process -FilePath $App -ArgumentList $AppArgs -PassThru
        } else {
            $process = Start-Process -FilePath $App -PassThru
        }
        Write-Host "PID: $($process.Id)"
    }

    Write-Host "Watching $WatchPath for libusb-1.0.dll ..." -ForegroundColor Cyan
    Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray
    Write-Host ""

    $patchCount = 0

    # FileSystemWatcher monitors recursively for any new libusb-1.0.dll
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $WatchPath
    $watcher.Filter = "libusb-1.0.dll"
    $watcher.IncludeSubdirectories = $true
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor `
                            [System.IO.NotifyFilters]::LastWrite

    $action = {
        $changedPath = $Event.SourceEventArgs.FullPath
        # Small delay - let the extractor finish writing
        Start-Sleep -Milliseconds 200
        try {
            # Check arch compatibility
            $targetMachine = $null
            try {
                $bytes = [System.IO.File]::ReadAllBytes($changedPath)
                $peOff = [BitConverter]::ToInt32($bytes, 60)
                $targetMachine = [BitConverter]::ToUInt16($bytes, $peOff + 4)
            } catch {}

            if ($null -ne $targetMachine -and $targetMachine -ne $Event.MessageData.SrcMachine) {
                return  # Architecture mismatch, skip
            }

            $hash = (Get-FileHash $changedPath -Algorithm SHA256).Hash
            if ($hash -eq $Event.MessageData.SrcHash) {
                return  # Already our DLL
            }

            Copy-Item $Event.MessageData.SrcDll $changedPath -Force
            $Event.MessageData.Count++
            $ts = Get-Date -Format "HH:mm:ss"
            Write-Host "[$ts] Patched: $changedPath" -ForegroundColor Green
        } catch {
            $ts = Get-Date -Format "HH:mm:ss"
            Write-Host "[$ts] Failed:  $changedPath - $_" -ForegroundColor Red
        }
    }

    $msgData = [PSCustomObject]@{
        SrcDll     = $SourceDll
        SrcMachine = $srcMachine
        SrcHash    = $srcHash
        Count      = 0
    }

    $created = Register-ObjectEvent $watcher "Created"  -Action $action -MessageData $msgData
    $changed = Register-ObjectEvent $watcher "Changed"  -Action $action -MessageData $msgData
    $watcher.EnableRaisingEvents = $true

    # Also do an immediate scan for any existing extractions
    $existing = Get-ChildItem -Path $WatchPath -Recurse -Filter "libusb-1.0.dll" `
                    -ErrorAction SilentlyContinue
    foreach ($f in $existing) {
        $hash = (Get-FileHash $f.FullName -Algorithm SHA256).Hash
        if ($hash -ne $srcHash) {
            $m = Get-PEMachine $f.FullName
            if ($null -eq $m -or $m -eq $srcMachine) {
                try {
                    Copy-Item $SourceDll $f.FullName -Force
                    Write-Host "Patched (existing): $($f.FullName)" -ForegroundColor Green
                    $patchCount++
                } catch {
                    Write-Host "Failed (existing):  $($f.FullName) - $_" -ForegroundColor Red
                }
            }
        }
    }

    try {
        if ($process) {
            # Wait for app to exit
            $process.WaitForExit()
            Write-Host "`nApplication exited (code $($process.ExitCode))."
        } else {
            # Daemon mode - wait forever (Ctrl+C to stop)
            while ($true) { Start-Sleep -Seconds 1 }
        }
    } finally {
        $watcher.EnableRaisingEvents = $false
        Unregister-Event $created.Name -ErrorAction SilentlyContinue
        Unregister-Event $changed.Name -ErrorAction SilentlyContinue
        $watcher.Dispose()
        $totalPatched = $patchCount + $msgData.Count
        Write-Host "Watcher stopped. Patched $totalPatched file(s) total."
    }
    exit 0
}

# ============================================================================
# REPLACE (default)
# ============================================================================

$replaced = 0; $skipped = 0; $errors = 0

$dlls = Get-AllLibusbDlls $SearchPaths
foreach ($dll in $dlls) {
    $path = $dll.FullName

    # Never replace the source itself
    try {
        if ((Resolve-Path $path).Path -eq $SourceDll) { continue }
    } catch {}

    $machine = Get-PEMachine $path
    $arch    = Get-ArchName $machine
    $ver     = Get-DllVersion $path

    if ($machine -ne $srcMachine) {
        Write-Host ("SKIP  ({0,-5}) v{1,-18} {2}" -f $arch, $ver, $path) -ForegroundColor DarkGray
        $skipped++
        continue
    }

    $dstHash = (Get-FileHash $path -Algorithm SHA256).Hash
    if ($dstHash -eq $srcHash) {
        Write-Host ("SAME  ({0,-5}) v{1,-18} {2}" -f $arch, $ver, $path) -ForegroundColor Green
        $skipped++
        continue
    }

    $bakPath = $path + ".bak"
    $hasBak  = Test-Path $bakPath

    if ($DryRun) {
        $note = if ($hasBak) { " [.bak exists]" } else { "" }
        Write-Host ("WOULD ({0,-5}) v{1,-18} -> v{2,-10} {3}{4}" -f `
            $arch, $ver, $srcVer, $path, $note) -ForegroundColor Cyan
        $replaced++
    } else {
        try {
            if (-not $hasBak) {
                Copy-Item $path $bakPath -Force
            }
            Copy-Item $SourceDll $path -Force
            Write-Host ("OK    ({0,-5}) v{1,-18} -> v{2,-10} {3}" -f `
                $arch, $ver, $srcVer, $path) -ForegroundColor Green
            $replaced++
        } catch {
            Write-Host ("ERROR {0}: {1}" -f $path, $_) -ForegroundColor Red
            $errors++
        }
    }
}

Write-Host ""
if ($DryRun) {
    Write-Host "Dry run: would replace $replaced, skip $skipped."
} else {
    Write-Host "Replaced: $replaced, skipped: $skipped, errors: $errors"
    if ($replaced -gt 0) {
        Write-Host "Originals backed up as .bak. To undo:  .\deploy_libusb.ps1 -Restore"
    }
}
exit $(if ($errors -gt 0) { 1 } else { 0 })
