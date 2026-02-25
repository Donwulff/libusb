# replace_libusb_rds.ps1
#
# Replaces libusb-1.0.dll in TI tool installations with a custom build
# that supports Windows RDS/Terminal Services USB pass-through.
#
# Only replaces DLLs whose PE architecture matches the source DLL.
# Skips unrelated directories (Cygwin, NCS toolchains, FreeCAD, etc.)
#
# Usage:
#   .\replace_libusb_rds.ps1 [-SourceDll <path>] [-SearchPaths <paths>] [-DryRun]
#
# Examples:
#   # Dry run to see what would be replaced:
#   .\replace_libusb_rds.ps1 -DryRun
#
#   # Replace with explicit source DLL:
#   .\replace_libusb_rds.ps1 -SourceDll "C:\path\to\libusb-1.0.dll"
#
#   # Also patch a running PyInstaller app's temp directory:
#   .\replace_libusb_rds.ps1 -IncludeTemp

param(
    [string]$SourceDll = "",
    [string[]]$SearchPaths = @(
        "C:\ti",
        "C:\Program Files (x86)\Texas Instruments"
    ),
    [switch]$IncludeTemp,
    [switch]$DryRun
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-PEMachine([string]$path) {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $peOffset = [BitConverter]::ToInt32($bytes, 60)
        $machine  = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
        return $machine
    } catch {
        return $null
    }
}

function Get-ArchName([uint16]$machine) {
    switch ($machine) {
        0x8664 { return "x64" }
        0x14c  { return "x86" }
        0x1c0  { return "ARM" }
        0xAA64 { return "ARM64" }
        default { return "unknown(0x{0:X4})" -f $machine }
    }
}

# ---------------------------------------------------------------------------
# Locate source DLL
# ---------------------------------------------------------------------------

if (-not $SourceDll) {
    # Default: look relative to this script (repo build output)
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $candidates = @(
        (Join-Path $scriptDir "..\..\build\v145\x64\Release\dll\libusb-1.0.dll"),
        (Join-Path $scriptDir "..\..\build\v145\x64\Debug\dll\libusb-1.0.dll")
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $SourceDll = (Resolve-Path $c).Path; break }
    }
}

if (-not $SourceDll -or -not (Test-Path $SourceDll)) {
    Write-Error "Source DLL not found. Specify -SourceDll <path>."
    exit 1
}

$srcMachine = Get-PEMachine $SourceDll
$srcArch    = Get-ArchName $srcMachine
$srcSize    = (Get-Item $SourceDll).Length
Write-Host "Source DLL : $SourceDll" -ForegroundColor Cyan
Write-Host "Source arch: $srcArch ($("0x{0:X4}" -f $srcMachine)), size: $srcSize bytes"
if ($DryRun) { Write-Host "(DRY RUN - no files will be changed)" -ForegroundColor Yellow }
Write-Host ""

# ---------------------------------------------------------------------------
# Optionally include PyInstaller temp directories
# ---------------------------------------------------------------------------

if ($IncludeTemp) {
    $tempMei = Get-ChildItem "$env:TEMP\_MEI*" -Directory -ErrorAction SilentlyContinue
    if ($tempMei) {
        $SearchPaths += $tempMei.FullName
        Write-Host "Including PyInstaller temp dirs:" -ForegroundColor Cyan
        $tempMei | ForEach-Object { Write-Host "  $($_.FullName)" }
        Write-Host ""
    } else {
        Write-Host "No _MEI* temp dirs found (PyInstaller app not running?)" -ForegroundColor Yellow
        Write-Host ""
    }
}

# ---------------------------------------------------------------------------
# Find and replace
# ---------------------------------------------------------------------------

$replaced = 0
$skipped  = 0
$errors   = 0

foreach ($searchPath in $SearchPaths) {
    if (-not (Test-Path $searchPath)) { continue }

    $dlls = Get-ChildItem -Path $searchPath -Recurse -Filter "libusb-1.0.dll" -ErrorAction SilentlyContinue

    foreach ($dll in $dlls) {
        $path = $dll.FullName

        # Skip if this IS the source DLL
        if ($path -eq $SourceDll) { continue }

        $machine = Get-PEMachine $path
        $arch    = Get-ArchName $machine

        if ($machine -ne $srcMachine) {
            Write-Host "SKIP ($arch): $path" -ForegroundColor DarkGray
            $skipped++
            continue
        }

        if ($dll.Length -eq $srcSize) {
            # Quick same-size check; for a proper check compare hashes
            $srcHash = (Get-FileHash $SourceDll -Algorithm SHA256).Hash
            $dstHash = (Get-FileHash $path -Algorithm SHA256).Hash
            if ($srcHash -eq $dstHash) {
                Write-Host "SAME: $path" -ForegroundColor Green
                $skipped++
                continue
            }
        }

        if ($DryRun) {
            Write-Host "WOULD REPLACE ($arch, $($dll.Length) -> $srcSize bytes): $path" -ForegroundColor Cyan
            $replaced++
        } else {
            try {
                Copy-Item $SourceDll $path -Force
                Write-Host "REPLACED: $path" -ForegroundColor Green
                $replaced++
            } catch {
                Write-Host "ERROR replacing $path`: $_" -ForegroundColor Red
                $errors++
            }
        }
    }
}

Write-Host ""
if ($DryRun) {
    Write-Host "Dry run complete. Would replace: $replaced, skip: $skipped" -ForegroundColor Yellow
} else {
    Write-Host "Done. Replaced: $replaced, skipped: $skipped, errors: $errors"
}
