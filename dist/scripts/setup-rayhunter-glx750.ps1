#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads and installs Rayhunter onto a GL-X750 router's EP06 modem.

.DESCRIPTION
    This script runs on a Windows PC connected to the GL-X750 via LAN.
    It downloads all required files from GitHub and OpenWrt package repos,
    transfers them to the router via SCP, and runs the installation over SSH.

    The router does not need internet access.

.PARAMETER RouterIP
    IP address of the GL-X750 router. Default: 192.168.8.1

.PARAMETER User
    SSH user on the router. Default: root

.PARAMETER ReleaseTag
    GitHub release tag to download from. Default: ep06-v0.1.0

.PARAMETER OpenWrtVersion
    OpenWrt release version for package downloads. Default: 22.03.4

.PARAMETER Arch
    OpenWrt package architecture. Default: mips_24kc

.EXAMPLE
    .\setup-rayhunter-glx750.ps1
    .\setup-rayhunter-glx750.ps1 -RouterIP 192.168.1.1
    .\setup-rayhunter-glx750.ps1 -OpenWrtVersion 22.03.5
#>

param(
    [string]$RouterIP = "192.168.8.1",
    [string]$User = "root",
    [string]$ReleaseTag = "ep06-v0.8.0",
    [string]$OpenWrtVersion = "22.03.4",
    [string]$Arch = "mips_24kc"
)

$ErrorActionPreference = "Stop"

$GithubBaseURL = "https://github.com/chaugan/rayhunter/releases/download/$ReleaseTag"
$OpenWrtBaseURL = "https://downloads.openwrt.org/releases/$OpenWrtVersion"
$PackageRepos = @(
    "$OpenWrtBaseURL/packages/$Arch/packages",
    "$OpenWrtBaseURL/packages/$Arch/base",
    "$OpenWrtBaseURL/targets/ath79/nand/packages",
    "https://fw.gl-inet.com/releases/v${OpenWrtVersion}/kmod-4.3.2/x750",
    "https://fw.gl-inet.com/releases/v${OpenWrtVersion}/packages-4.2/ath79/packages",
    "https://fw.gl-inet.com/releases/v${OpenWrtVersion}/packages-4.2/ath79/glinet"
)

$RayhunterFiles = @("rayhunter-daemon", "install-from-openwrt.sh", "rayhunter-openwrt-boot", "rayhunter-notify.sh", "rayhunter-sync-sd.sh", "rayhunter-cmd.sh", "rayhunter-disk-monitor.sh", "rayhunter-ntfy-manager.sh", "rayhunter-signal.sh", "rayhunter-temperature.sh")
$RequiredPackages = @("adb", "openssl-util", "coreutils-stty")

$DownloadDir = Join-Path $PSScriptRoot "rayhunter-files"
$PkgDir = Join-Path $DownloadDir "packages"
$RemoteDest = "/tmp"
$RemotePkgDest = "/tmp/rayhunter-packages"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host ">>> $Message" -ForegroundColor Cyan
}

function Test-Command {
    param([string]$Command)
    $null = Get-Command $Command -ErrorAction SilentlyContinue
    return $?
}

# Parse an OpenWrt Packages manifest into a dictionary of package metadata.
# Each entry is keyed by package name and contains Depends and Filename.
function Parse-PackagesManifest {
    param([string]$Content)

    $packages = @{}
    $current = @{}
    $currentName = ""

    foreach ($line in $Content -split "`n") {
        $line = $line.TrimEnd("`r")
        if ($line -eq "") {
            if ($currentName -ne "") {
                $packages[$currentName] = $current
            }
            $current = @{}
            $currentName = ""
            continue
        }
        if ($line -match "^Package:\s*(.+)$") {
            $currentName = $Matches[1].Trim()
        }
        elseif ($line -match "^Depends:\s*(.+)$") {
            $current["Depends"] = $Matches[1].Trim()
        }
        elseif ($line -match "^Filename:\s*(.+)$") {
            $current["Filename"] = $Matches[1].Trim()
        }
    }
    # Capture last stanza
    if ($currentName -ne "") {
        $packages[$currentName] = $current
    }

    return $packages
}

# Recursively resolve all dependencies for a package.
function Resolve-Dependencies {
    param(
        [string]$PackageName,
        [hashtable]$AllPackages,
        [System.Collections.Generic.HashSet[string]]$Resolved
    )

    if ($Resolved.Contains($PackageName)) { return }
    $null = $Resolved.Add($PackageName)

    if (-not $AllPackages.ContainsKey($PackageName)) {
        # Package not found in manifests - likely a kernel module or already installed base package
        return
    }

    $pkg = $AllPackages[$PackageName]
    if ($pkg.ContainsKey("Depends") -and $pkg["Depends"]) {
        $deps = $pkg["Depends"] -split ",\s*"
        foreach ($dep in $deps) {
            # Strip version constraints like "libc (>=2.0)"
            $depName = ($dep -replace "\s*\(.*\)\s*", "").Trim()
            if ($depName -ne "" -and $depName -notmatch "^kernel\b") {
                Resolve-Dependencies -PackageName $depName -AllPackages $AllPackages -Resolved $Resolved
            }
        }
    }
}

# --- Main script ---

Write-Host "============================================"
Write-Host "  Rayhunter Setup for GL-X750 (EP06)"
Write-Host "============================================"
Write-Host ""

if (-not (Test-Command "ssh")) {
    Write-Host "ERROR: ssh not found. Install OpenSSH (included in Windows 10+)." -ForegroundColor Red
    exit 1
}
if (-not (Test-Command "scp")) {
    Write-Host "ERROR: scp not found. Install OpenSSH (included in Windows 10+)." -ForegroundColor Red
    exit 1
}

# --- Create download directories ---

if (-not (Test-Path $DownloadDir)) { New-Item -ItemType Directory -Path $DownloadDir | Out-Null }
if (-not (Test-Path $PkgDir)) { New-Item -ItemType Directory -Path $PkgDir | Out-Null }

# --- Step 1: Download Rayhunter files from GitHub ---

Write-Step "Downloading Rayhunter files from GitHub release ($ReleaseTag)..."

foreach ($File in $RayhunterFiles) {
    $URL = "$GithubBaseURL/$File"
    $Dest = Join-Path $DownloadDir $File

    if (Test-Path $Dest) {
        Write-Host "  $File already exists, skipping."
        continue
    }

    Write-Host "  Downloading $File..."
    try {
        Invoke-WebRequest -Uri $URL -OutFile $Dest -UseBasicParsing
    }
    catch {
        Write-Host "ERROR: Failed to download $URL" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 1
    }
}

foreach ($File in $RayhunterFiles) {
    $Path = Join-Path $DownloadDir $File
    $Size = (Get-Item $Path).Length
    if ($Size -eq 0) {
        Write-Host "ERROR: $File is empty. Download may have failed." -ForegroundColor Red
        exit 1
    }
    Write-Host "  $File - $([math]::Round($Size / 1KB)) KB"
}

# --- Step 2: Download OpenWrt packages ---

Write-Step "Downloading OpenWrt package manifests for $Arch ($OpenWrtVersion)..."

$allPackages = @{}

$repoIndex = 0
foreach ($repo in $PackageRepos) {
    $repoIndex++
    $repoName = ($repo -split "/")[-1]
    $manifestURL = "$repo/Packages.gz"
    $manifestGz = Join-Path $PkgDir "Packages_${repoIndex}_${repoName}.gz"
    $manifestTxt = Join-Path $PkgDir "Packages_${repoIndex}_${repoName}.txt"

    Write-Host "  Fetching manifest from $repoName..."
    try {
        Invoke-WebRequest -Uri $manifestURL -OutFile $manifestGz -UseBasicParsing

        # Decompress .gz
        $input_stream = [System.IO.File]::OpenRead($manifestGz)
        $output_stream = [System.IO.File]::Create($manifestTxt)
        $gz = New-Object System.IO.Compression.GZipStream($input_stream, [System.IO.Compression.CompressionMode]::Decompress)
        $gz.CopyTo($output_stream)
        $gz.Close()
        $output_stream.Close()
        $input_stream.Close()

        $content = Get-Content $manifestTxt -Raw
        $repoPkgs = Parse-PackagesManifest -Content $content

        # Store with repo URL so we can download later
        foreach ($key in $repoPkgs.Keys) {
            if (-not $allPackages.ContainsKey($key)) {
                $entry = $repoPkgs[$key]
                $entry["RepoURL"] = $repo
                $allPackages[$key] = $entry
            }
        }
        Write-Host "    Found $($repoPkgs.Count) packages."
    }
    catch {
        Write-Host "  WARNING: Could not fetch manifest from $repoName - $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Step "Resolving dependencies for: $($RequiredPackages -join ', ')..."

$resolved = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($pkg in $RequiredPackages) {
    Resolve-Dependencies -PackageName $pkg -AllPackages $allPackages -Resolved $resolved
}

# Filter to packages we actually found in the manifests
$toDownload = @()
foreach ($pkgName in $resolved) {
    if ($allPackages.ContainsKey($pkgName) -and $allPackages[$pkgName].ContainsKey("Filename")) {
        $toDownload += $pkgName
    }
}

Write-Host "  Resolved $($toDownload.Count) packages to download:"
foreach ($pkgName in $toDownload) {
    Write-Host "    - $pkgName"
}

Write-Step "Downloading .ipk packages..."

foreach ($pkgName in $toDownload) {
    $pkg = $allPackages[$pkgName]
    $filename = $pkg["Filename"]
    $repoURL = $pkg["RepoURL"]
    $ipkURL = "$repoURL/$filename"
    $ipkDest = Join-Path $PkgDir (Split-Path $filename -Leaf)

    if (Test-Path $ipkDest) {
        Write-Host "  $pkgName already downloaded, skipping."
        continue
    }

    Write-Host "  Downloading $pkgName..."
    try {
        Invoke-WebRequest -Uri $ipkURL -OutFile $ipkDest -UseBasicParsing
    }
    catch {
        Write-Host "  WARNING: Failed to download $pkgName from $ipkURL" -ForegroundColor Yellow
        Write-Host "    $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# --- Step 3: SCP everything to router ---

Write-Step "Copying Rayhunter files to router ($User@${RouterIP}:${RemoteDest})..."

foreach ($File in $RayhunterFiles) {
    $LocalPath = Join-Path $DownloadDir $File
    $RemotePath = "${User}@${RouterIP}:${RemoteDest}/${File}"

    Write-Host "  Sending $File..."
    & scp -O $LocalPath $RemotePath
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: scp failed for $File" -ForegroundColor Red
        Write-Host "Make sure you can SSH to the router: ssh ${User}@${RouterIP}" -ForegroundColor Yellow
        exit 1
    }
}

Write-Step "Creating package directory on router and copying .ipk files..."

& ssh "${User}@${RouterIP}" "mkdir -p ${RemotePkgDest}"
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to create $RemotePkgDest on router" -ForegroundColor Red
    exit 1
}

$ipkFiles = Get-ChildItem -Path $PkgDir -Filter "*.ipk" -ErrorAction SilentlyContinue
if ($ipkFiles.Count -gt 0) {
    foreach ($ipk in $ipkFiles) {
        Write-Host "  Sending $($ipk.Name)..."
        & scp -O $ipk.FullName "${User}@${RouterIP}:${RemotePkgDest}/$($ipk.Name)"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "WARNING: Failed to SCP $($ipk.Name)" -ForegroundColor Yellow
        }
    }
    Write-Host "  Transferred $($ipkFiles.Count) packages."
}
else {
    Write-Host "  No .ipk files to transfer." -ForegroundColor Yellow
}

# --- Step 4: SSH in and run installer ---

Write-Step "Running installer on router..."

& ssh "${User}@${RouterIP}" "chmod +x ${RemoteDest}/install-from-openwrt.sh && sh ${RemoteDest}/install-from-openwrt.sh ${RemoteDest}/rayhunter-daemon"
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "WARNING: Installer exited with code $LASTEXITCODE" -ForegroundColor Yellow
    Write-Host "SSH into the router to check: ssh ${User}@${RouterIP}" -ForegroundColor Yellow
}
else {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  Installation complete!" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Access the Rayhunter web UI at: http://${RouterIP}:8080"
    Write-Host ""
    Write-Host "To view modem logs, SSH into the router and run:"
    Write-Host "  adb shell cat /data/rayhunter/rayhunter.log"
}
