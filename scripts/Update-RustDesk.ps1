<#
    Update-RustDesk.ps1
    Downloads and silently installs the newest RustDesk for Windows x64.

    Usage:
      .\Update-RustDesk.ps1             # latest stable release (default)
      .\Update-RustDesk.ps1 -Nightly    # nightly build
      .\Update-RustDesk.ps1 -Force      # reinstall even if already up to date
      .\Update-RustDesk.ps1 -NoPause    # don't wait for a key at the end (for scheduled tasks)
      .\Update-RustDesk.ps1 -Yes        # don't ask for YES confirmation (for scheduled tasks)

    NOTE: Installing restarts the RustDesk service, which disconnects all active
          RustDesk sessions. You must type YES to agree before anything is installed.
#>
param(
    [switch]$Nightly,
    [switch]$Force,
    [switch]$NoPause,
    [switch]$Yes          # skip the YES confirmation (for scheduled / unattended runs)
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
    if ($Yes)     { $argList += '-Yes' }
    try   { Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs }
    catch { Write-Host "Administrator rights were declined - cannot update RustDesk." -ForegroundColor Red; exit 1 }
    exit 0
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # makes Invoke-WebRequest much faster in Windows PowerShell 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-InstalledRustDeskVersion {
    # Look in every uninstall location (exe installer and MSI register differently)
    $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    foreach ($r in $roots) {
        $e = Get-ItemProperty -Path $r -ErrorAction SilentlyContinue |
             Where-Object { $_.PSChildName -eq 'RustDesk' -or $_.DisplayName -like 'RustDesk*' } |
             Select-Object -First 1
        if ($e) {
            if ($e.DisplayVersion) { return $e.DisplayVersion }
            if ($e.Version)        { return $e.Version }
        }
    }
    # Fallback: version of the installed program file
    $exe = Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe'
    if (Test-Path $exe) { return (Get-Item $exe).VersionInfo.ProductVersion }
    return $null
}

# Publisher name RustDesk's Windows installers are signed with
$ExpectedSigner = 'PURSLANE'

$installer = $null
$workDir   = $null
$exitCode  = 0
try {
    # 1. Ask GitHub which release / file is current (no hard-coded version)
    $api = if ($Nightly) { 'https://api.github.com/repos/rustdesk/rustdesk/releases/tags/nightly' }
           else          { 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest' }

    Write-Host "Checking GitHub for the $(if ($Nightly) {'nightly'} else {'latest stable'}) RustDesk build..."
    $release = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'RustDesk-Updater' }

    # Prefer the MSI (reliable silent install, exit codes, log file); fall back to the exe
    $asset = $release.assets | Where-Object { $_.name -like 'rustdesk-*-x86_64.msi' } | Select-Object -First 1
    if (-not $asset) {
        $asset = $release.assets |
                 Where-Object { $_.name -like 'rustdesk-*-x86_64.exe' -and $_.name -notlike '*sciter*' } |
                 Select-Object -First 1
    }
    if (-not $asset) { throw "No Windows x64 installer found in release '$($release.tag_name)'." }

    $latest    = $release.tag_name -replace '^v', ''
    $installed = Get-InstalledRustDeskVersion
    Write-Host "Installed: $(if ($installed) {$installed} else {'not installed'})   Available: $latest ($($asset.name))"

    # 2. Skip if already current (version check only makes sense for stable tags)
    if (-not $Nightly -and -not $Force -and $installed -and ($installed -eq $latest)) {
        Write-Host "RustDesk is already up to date. Nothing to do." -ForegroundColor Green
        return
    }

    # Confirmation: the RustDesk service will be stopped and restarted
    if (-not $Yes) {
        Write-Host ""
        Write-Host "NOTE: To install the update, the RustDesk service will be STOPPED and RESTARTED." -ForegroundColor Yellow
        Write-Host "      All active RustDesk connections to this computer will be disconnected" -ForegroundColor Yellow
        Write-Host "      (including the one you may be using right now)." -ForegroundColor Yellow
        Write-Host ""
        $answer = Read-Host "Type YES to agree and install RustDesk $latest"
        if ($answer -cne 'YES') {
            Write-Host "Cancelled - nothing was changed." -ForegroundColor Cyan
            return
        }
    }

    # 3. Download into a fresh folder that only Administrators and SYSTEM can access
    #    (user TEMP is writable by any non-admin process, which could swap the file)
    $workDir = Join-Path $env:SystemRoot ("Temp\RustDeskUpdate-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $null = & icacls.exe $workDir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F'
    if ($LASTEXITCODE -ne 0) { throw "Could not lock down the download folder." }

    $installer = Join-Path $workDir $asset.name
    Write-Host "Downloading $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installer -UseBasicParsing

    if ((Get-Item $installer).Length -ne $asset.size) { throw "Downloaded file size doesn't match - download is incomplete." }

    # 4a. Verify SHA-256 against the hash GitHub publishes for the release file
    $hash = (Get-FileHash -Path $installer -Algorithm SHA256).Hash
    if ($asset.digest -and $asset.digest -like 'sha256:*') {
        $expected = $asset.digest.Substring(7)
        if ($hash -ne $expected) { throw "SHA-256 mismatch! Expected $expected, got $hash. Installer NOT run." }
        Write-Host "SHA-256 verified: $hash" -ForegroundColor Green
    } else {
        Write-Warning "GitHub did not publish a hash for this file - relying on the signature check only. SHA-256: $hash"
    }

    # 4b. Verify the Windows code signature and the publisher
    $sig = Get-AuthenticodeSignature -FilePath $installer
    if ($sig.Status -ne 'Valid') {
        throw "Digital signature is not valid ($($sig.Status): $($sig.StatusMessage)). Installer NOT run."
    }
    if ($sig.SignerCertificate.Subject -notmatch $ExpectedSigner) {
        throw "Unexpected publisher: $($sig.SignerCertificate.Subject). Installer NOT run."
    }
    Write-Host "Signature valid: $($sig.SignerCertificate.GetNameInfo('SimpleName', $false))" -ForegroundColor Green

    # 4. Stop running RustDesk so its files can be replaced (ID and config are kept)
    Write-Host "Stopping RustDesk if it is running..."
    Stop-Service -Name 'RustDesk' -Force -ErrorAction SilentlyContinue
    Get-Process -Name 'rustdesk' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    # 5. Install silently
    Write-Host "Installing silently (this can take a minute)..."
    if ($installer -like '*.msi') {
        $log  = Join-Path $workDir 'rustdesk-install.log'
        $p    = Start-Process -FilePath 'msiexec.exe' -Wait -PassThru `
                  -ArgumentList "/i `"$installer`" /qn /norestart /l*v `"$log`""
        switch ($p.ExitCode) {
            0       { }
            3010    { Write-Warning "Installed - a reboot is required to finish." }
            1618    { throw "Another installation is in progress. Try again in a few minutes." }
            default {
                $keptLog = Join-Path $env:ProgramData 'rustdesk-install-failed.log'
                Copy-Item $log $keptLog -Force -ErrorAction SilentlyContinue
                throw "msiexec failed with exit code $($p.ExitCode). See log: $keptLog"
            }
        }
    }
    else {
        $p = Start-Process -FilePath $installer -ArgumentList '--silent-install' -PassThru
        $null = $p.WaitForExit(180000)
    }

    # 6. Wait (up to 90 s) until Windows reports RustDesk as installed
    $now = $null
    for ($i = 0; $i -lt 45 -and -not $now; $i++) { Start-Sleep -Seconds 2; $now = Get-InstalledRustDeskVersion }
    if (-not $now) { throw "Installer finished but RustDesk does not show up as installed." }

    $svc = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') { Start-Service -Name 'RustDesk' -ErrorAction SilentlyContinue }

    Write-Host "Done. Installed version is now: $now" -ForegroundColor Green
}
catch {
    Write-Host "Update failed: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}
finally {
    # Clean up the download folder (retry while the installer is still locked)
    if ($workDir -and (Test-Path $workDir)) {
        for ($i = 0; $i -lt 10; $i++) {
            try { Remove-Item $workDir -Recurse -Force; Write-Host "Installer removed."; break }
            catch { Start-Sleep -Seconds 2 }
        }
    }
    if (-not $NoPause) {
        Write-Host "Press any key to exit..."
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
}
exit $exitCode
