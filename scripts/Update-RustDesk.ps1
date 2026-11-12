<#
    Update-RustDesk.ps1
    Downloads and silently installs the newest RustDesk for Windows x64.

    Usage:
      .\Update-RustDesk.ps1             # latest stable release (default)
      .\Update-RustDesk.ps1 -Nightly    # nightly build
      .\Update-RustDesk.ps1 -Force      # reinstall even if already up to date
      .\Update-RustDesk.ps1 -NoPause    # don't wait for a key at the end (for scheduled tasks)
#>
param(
    [switch]$Nightly,
    [switch]$Force,
    [switch]$NoPause
)

# Relaunch elevated (UAC prompt) if not already running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Requesting administrator rights..."
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Nightly) { $argList += '-Nightly' }
    if ($Force)   { $argList += '-Force' }
    if ($NoPause) { $argList += '-NoPause' }
    try   { Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs }
    catch { Write-Host "Administrator rights were declined - cannot update RustDesk." -ForegroundColor Red; exit 1 }
    exit 0
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # makes Invoke-WebRequest much faster in Windows PowerShell 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-InstalledRustDeskVersion {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk'
    foreach ($k in $keys) {
        $v = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).Version
        if ($v) { return $v }
    }
    return $null
}

$installer = $null
$exitCode  = 0
try {
    # 1. Ask GitHub which release / file is current (no hard-coded version)
    $api = if ($Nightly) { 'https://api.github.com/repos/rustdesk/rustdesk/releases/tags/nightly' }
           else          { 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest' }

    Write-Host "Checking GitHub for the $(if ($Nightly) {'nightly'} else {'latest stable'}) RustDesk build..."
    $release = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'RustDesk-Updater' }

    $asset = $release.assets |
             Where-Object { $_.name -like 'rustdesk-*-x86_64.exe' -and $_.name -notlike '*sciter*' } |
             Select-Object -First 1
    if (-not $asset) { throw "No Windows x64 .exe found in release '$($release.tag_name)'." }

    $latest    = $release.tag_name -replace '^v', ''
    $installed = Get-InstalledRustDeskVersion
    Write-Host "Installed: $(if ($installed) {$installed} else {'not installed'})   Available: $latest ($($asset.name))"

    # 2. Skip if already current (version check only makes sense for stable tags)
    if (-not $Nightly -and -not $Force -and $installed -and ($installed -eq $latest)) {
        Write-Host "RustDesk is already up to date. Nothing to do." -ForegroundColor Green
        return
    }

    # 3. Download to TEMP
    $installer = Join-Path $env:TEMP $asset.name
    Write-Host "Downloading $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installer -UseBasicParsing

    if ((Get-Item $installer).Length -ne $asset.size) { throw "Downloaded file size doesn't match - download is incomplete." }

    # 4. Install silently (keeps existing ID, config and service)
    Write-Host "Installing silently..."
    $p = Start-Process -FilePath $installer -ArgumentList '--silent-install' -PassThru
    if (-not $p.WaitForExit(180000)) { Write-Warning "Installer still running after 3 minutes - continuing anyway." }

    # Give the service a moment to restart, then report the result
    Start-Sleep -Seconds 10
    $svc = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') { Start-Service -Name 'RustDesk' -ErrorAction SilentlyContinue }

    Write-Host "Done. Installed version is now: $(Get-InstalledRustDeskVersion)" -ForegroundColor Green
}
catch {
    Write-Host "Update failed: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}
finally {
    # 5. Clean up the installer (retry while it's still locked)
    if ($installer -and (Test-Path $installer)) {
        for ($i = 0; $i -lt 10; $i++) {
            try { Remove-Item $installer -Force; Write-Host "Installer removed."; break }
            catch { Start-Sleep -Seconds 2 }
        }
    }
    if (-not $NoPause) {
        Write-Host "Press any key to exit..."
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
}
exit $exitCode
