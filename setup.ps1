<#
.SYNOPSIS
    Sets up spotify-qt with a local librespot playback device on Windows x64.

.DESCRIPTION
    Installs the prebuilt spotify-qt release (no Qt or Visual Studio needed),
    builds librespot from crates.io, and wires the two together so librespot
    starts and stops with the app and appears as a local Spotify Connect device.

    Idempotent. Safe to re-run: it skips work that is already done and always
    backs up the spotify-qt config before touching it.

.PARAMETER InstallDir
    Where to unpack spotify-qt. Defaults to %LOCALAPPDATA%\Programs\spotify-qt.

.PARAMETER SkipLibrespot
    Only install the spotify-qt app, do not build or wire librespot.

.PARAMETER Force
    Re-download and re-extract spotify-qt even if it is already installed.

.EXAMPLE
    .\setup.ps1
.EXAMPLE
    .\setup.ps1 -SkipLibrespot
#>
[CmdletBinding()]
param(
    [string] $InstallDir = "$env:LOCALAPPDATA\Programs\spotify-qt",
    [switch] $SkipLibrespot,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# WinLibs is chosen deliberately over the UCRT variants: Rust's
# x86_64-pc-windows-gnu target links against msvcrt, so the MSVCRT build stays
# consistent with the rust-mingw libs rustup installs.
$MingwPackageId = 'BrechtSanders.WinLibs.POSIX.MSVCRT'
$RustToolchain  = 'stable-x86_64-pc-windows-gnu'
$ConfigPath     = "$env:LOCALAPPDATA\kraxarn\spotify-qt.json"

function Write-Step  { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "    OK: $m"   -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "    !!  $m"   -ForegroundColor Yellow }

function Test-Exe { param($Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# The MinGW bin directory, wherever winget dropped it. Returns $null if absent.
function Get-MingwBin {
    $p = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Directory `
            -Filter "$MingwPackageId*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { return $null }
    $bin = Join-Path $p.FullName 'mingw64\bin'
    if (Test-Path (Join-Path $bin 'dlltool.exe')) { return $bin }
    return $null
}

# ---------------------------------------------------------------------------
# 0. Preflight
# ---------------------------------------------------------------------------
Write-Step 'Preflight'

if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw "This script targets x64. Detected '$env:PROCESSOR_ARCHITECTURE'. " +
          "For ARM64 use the -woa64 release asset and an ARM64 Rust toolchain."
}
Write-Ok "architecture $env:PROCESSOR_ARCHITECTURE"

# spotify-qt rewrites its config on exit, so editing it underneath a live
# process silently loses whatever we write here.
if (Get-Process spotify-qt -ErrorAction SilentlyContinue) {
    throw 'spotify-qt is running. Close it first, otherwise it overwrites the config on exit.'
}
Write-Ok 'spotify-qt is not running'

# ---------------------------------------------------------------------------
# 1. spotify-qt (prebuilt, no toolchain required)
# ---------------------------------------------------------------------------
Write-Step 'spotify-qt'

$exePath = Join-Path $InstallDir 'spotify-qt.exe'

if ((Test-Path $exePath) -and -not $Force) {
    Write-Ok "already installed at $exePath (use -Force to reinstall)"
}
else {
    $rel = Invoke-RestMethod 'https://api.github.com/repos/kraxarn/spotify-qt/releases/latest' `
             -Headers @{ 'User-Agent' = 'spotify-qt-windows-setup' }

    $asset = $rel.assets | Where-Object { $_.name -like '*win64.zip' } | Select-Object -First 1
    if (-not $asset) { throw "No win64.zip asset in release $($rel.tag_name)." }

    Write-Host "    downloading $($asset.name) ($([math]::Round($asset.size/1MB,1)) MB)"
    $tmp = Join-Path $env:TEMP $asset.name
    Invoke-WebRequest $asset.browser_download_url -OutFile $tmp

    if ((Get-Item $tmp).Length -ne $asset.size) {
        throw "Download size mismatch: expected $($asset.size), got $((Get-Item $tmp).Length)."
    }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($tmp, $InstallDir, $true)
    Remove-Item $tmp -Force

    Write-Ok "$($rel.tag_name) extracted to $InstallDir"
}

# Start Menu shortcut. Makes it searchable; the taskbar pin cannot be scripted
# (see README) and stays a manual right-click.
$lnk = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\spotify-qt.lnk"
$ws  = New-Object -ComObject WScript.Shell
$sc  = $ws.CreateShortcut($lnk)
$sc.TargetPath       = $exePath
$sc.WorkingDirectory = $InstallDir
$sc.IconLocation     = "$exePath,0"
$sc.Description      = 'spotify-qt - lightweight Spotify client'
$sc.Save()
Write-Ok 'Start Menu shortcut created'

if ($SkipLibrespot) {
    Write-Host "`nDone (librespot skipped)." -ForegroundColor Green
    return
}

# ---------------------------------------------------------------------------
# 2. Rust toolchain
# ---------------------------------------------------------------------------
Write-Step 'Rust toolchain'

if (-not (Test-Exe 'rustup')) {
    throw 'rustup not found. Install Rust from https://rustup.rs and re-run.'
}

if ((rustup toolchain list) -match [regex]::Escape($RustToolchain)) {
    Write-Ok "$RustToolchain already installed"
} else {
    Write-Host "    installing $RustToolchain ..."
    rustup toolchain install $RustToolchain | Out-Null
    Write-Ok "$RustToolchain installed"
}

# ---------------------------------------------------------------------------
# 3. dlltool (the step that trips people up)
# ---------------------------------------------------------------------------
# rustup's rust-mingw component ships a linker but NOT dlltool.exe. The
# windows-sys crates use raw-dylib on the gnu target and need dlltool to
# generate import libraries, so without it the build dies with:
#   error: error calling dlltool 'dlltool.exe': program not found
Write-Step 'dlltool (MinGW binutils)'

$mingwBin = Get-MingwBin
if ($mingwBin) {
    Write-Ok "dlltool present: $mingwBin"
}
else {
    if (-not (Test-Exe 'winget')) {
        throw "dlltool.exe missing and winget unavailable. Install MinGW-w64 manually and re-run."
    }
    Write-Host "    installing $MingwPackageId via winget ..."
    winget install --id $MingwPackageId --accept-package-agreements `
                   --accept-source-agreements --disable-interactivity | Out-Null

    $mingwBin = Get-MingwBin
    if (-not $mingwBin) { throw 'MinGW installed but dlltool.exe still not found.' }
    Write-Ok "dlltool installed: $mingwBin"
}

# ---------------------------------------------------------------------------
# 4. librespot
# ---------------------------------------------------------------------------
Write-Step 'librespot'

$librespot = "$env:USERPROFILE\.cargo\bin\librespot.exe"

if ((Test-Path $librespot) -and -not $Force) {
    Write-Ok "already built: $librespot"
}
else {
    Write-Host '    building from crates.io, expect several minutes ...'
    $saved = $env:PATH
    try {
        $env:PATH = "$mingwBin;$env:PATH"
        # Default features on Windows are native-tls (SChannel) + rodio (WASAPI)
        # + libmdns, all pure Rust. No OpenSSL, no C compiler needed.
        cargo "+$RustToolchain" install librespot --locked
        if ($LASTEXITCODE -ne 0) { throw "cargo install failed with exit code $LASTEXITCODE." }
    }
    finally { $env:PATH = $saved }

    if (-not (Test-Path $librespot)) { throw 'Build reported success but librespot.exe is missing.' }
    Write-Ok "built: $librespot"
}

# spotify-qt refuses clients without OAuth support, so verify before wiring.
if (-not ((& $librespot --help 2>&1 | Out-String) -match '--enable-oauth')) {
    throw 'This librespot lacks --enable-oauth; spotify-qt will reject it. Update librespot.'
}
Write-Ok '--enable-oauth supported'

# ---------------------------------------------------------------------------
# 5. Wire librespot into the spotify-qt config
# ---------------------------------------------------------------------------
Write-Step 'spotify-qt config'

if (-not (Test-Path $ConfigPath)) {
    Write-Warn2 "no config at $ConfigPath yet."
    Write-Warn2 'Launch spotify-qt once, complete the Spotify setup dialog, close it, then re-run.'
    return
}

# The config holds access and refresh tokens. Always keep a copy.
$backup = "$ConfigPath.bak"
Copy-Item $ConfigPath $backup -Force
Write-Ok "backed up to $backup"

$cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$cfg.Spotify.path         = $librespot
$cfg.Spotify.start_client = $true   # start and stop librespot with the app
$cfg.Spotify.always_start = $true   # start it even if other devices exist
$cfg.Spotify.backend      = ''      # empty = librespot default = rodio (WASAPI)

$cfg | ConvertTo-Json -Depth 20 | Set-Content $ConfigPath -Encoding UTF8

# Prove the write did not corrupt the credentials.
$check = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $check.Account.refresh_token) {
    Copy-Item $backup $ConfigPath -Force
    throw 'Config write lost the refresh token. Restored from backup, nothing changed.'
}
Write-Ok 'librespot wired in, credentials intact'

# ---------------------------------------------------------------------------
# Next steps
# ---------------------------------------------------------------------------
$hostName = [System.Net.Dns]::GetHostName()

Write-Host @"

Done.

Remaining manual steps:
  1. Start spotify-qt. It launches librespot and opens a browser tab to
     authorize it. Approve there. This happens once.
  2. Pick the device: hamburger menu -> Device -> spotify-qt@$hostName
  3. Pin to taskbar: right-click the running icon -> pin. Windows exposes no
     scriptable verb for this.

Notes:
  - Playback requires Spotify Premium.
  - Window not resizable? Settings -> Interface -> untick "Application title
    bar", then restart. That switches to the native Windows frame.
"@ -ForegroundColor Green
