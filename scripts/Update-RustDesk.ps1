<#
    Update-RustDesk.ps1
    Downloads, verifies and silently installs the newest RustDesk for Windows x64.

    Usage:
      .\Update-RustDesk.ps1             # latest stable release (default)
      .\Update-RustDesk.ps1 -Nightly    # nightly build
      .\Update-RustDesk.ps1 -Force      # reinstall even if already up to date
      .\Update-RustDesk.ps1 -NoPause    # don't wait for a key at the end (for scheduled tasks)
      .\Update-RustDesk.ps1 -Yes        # don't ask for YES confirmation (for scheduled tasks)

    NOTE: Installing restarts the RustDesk service, which disconnects all active
          RustDesk sessions. You must type YES to agree before anything is installed.

    Every run is logged to C:\ProgramData\RustDesk-Update.log
#>
param(
    [switch]$Nightly,
    [switch]$Force,
    [switch]$NoPause,
    [switch]$Yes          # skip the YES confirmation (for scheduled / unattended runs)
)

# ---------------------------------------------------------------------------
# Relaunch elevated (UAC prompt) if not already running as Administrator
# ---------------------------------------------------------------------------
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

# Publisher name RustDesk's Windows installers are signed with
$ExpectedSigner = 'PURSLANE'
$ServiceName    = 'RustDesk'
$LogFile        = Join-Path $env:ProgramData 'RustDesk-Update.log'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-RustDeskInstall {
    # Returns @{ Version; Type = 'msi' | 'exe' } or $null if not installed.
    # The exe installer registers under ...\Uninstall\RustDesk, the MSI under a {GUID} key.
    $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    foreach ($r in $roots) {
        $e = Get-ItemProperty -Path $r -ErrorAction SilentlyContinue |
             Where-Object { $_.PSChildName -eq 'RustDesk' -or $_.DisplayName -like 'RustDesk*' } |
             Select-Object -First 1
        if ($e) {
            $ver  = if ($e.DisplayVersion) { $e.DisplayVersion } else { $e.Version }
            $type = if ($e.WindowsInstaller -eq 1 -or $e.UninstallString -match 'msiexec') { 'msi' } else { 'exe' }
            return @{ Version = $ver; Type = $type }
        }
    }
    $exe = Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe'
    if (Test-Path $exe) { return @{ Version = (Get-Item $exe).VersionInfo.ProductVersion; Type = 'exe' } }
    return $null
}

function ConvertTo-ShortVersion([string]$v) {
    # MSI reports e.g. 1.4.9.29722256 - compare only major.minor.patch (1.4.9)
    if (-not $v) { return $null }
    return (($v -replace '^v', '') -split '[.\-]' | Select-Object -First 3) -join '.'
}

function Invoke-AndWait([string]$file, [string]$arguments, [int]$timeoutSec) {
    # Waits for THIS process only. (Start-Process -Wait also waits for every child
    # process, and the RustDesk installer starts RustDesk itself, so it never returns.)
    $p = Start-Process -FilePath $file -ArgumentList $arguments -PassThru
    $null = $p.Handle                      # needed so ExitCode is available afterwards
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Write-Warning "$([IO.Path]::GetFileName($file)) still running after $timeoutSec s - continuing."
        return $null
    }
    return $p.ExitCode
}

function Start-RustDeskService {
    # Make sure the RustDesk service exists and is running. Returns $true on success.
    $exe = Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe'
    for ($try = 1; $try -le 3; $try++) {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if (-not $svc -and (Test-Path $exe)) {
            Write-Host "RustDesk service missing - registering it..."
            $null = Invoke-AndWait $exe '--install-service' 60
            Start-Sleep -Seconds 5
            $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        }
        if ($svc) {
            if ($svc.StartType -eq 'Disabled') { Set-Service -Name $ServiceName -StartupType Automatic }
            if ($svc.Status -ne 'Running') {
                try { Start-Service -Name $ServiceName -ErrorAction Stop } catch { }
            }
            Start-Sleep -Seconds 3
            if ((Get-Service -Name $ServiceName).Status -eq 'Running') { return $true }
        }
        Start-Sleep -Seconds 5
    }
    return $false
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$workDir        = $null
$serviceStopped = $false
$exitCode       = 0
try { Start-Transcript -Path $LogFile -Append | Out-Null } catch { }

try {
    # 1. Ask GitHub which release / file is current
    $api = if ($Nightly) { 'https://api.github.com/repos/rustdesk/rustdesk/releases/tags/nightly' }
           else          { 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest' }

    Write-Host "Checking GitHub for the $(if ($Nightly) {'nightly'} else {'latest stable'}) RustDesk build..."
    $release = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'RustDesk-Updater' }
    $latest  = $release.tag_name -replace '^v', ''

    $current = Get-RustDeskInstall
    Write-Host ("Installed: {0}   Available: {1}" -f
        $(if ($current) { "$($current.Version) ($($current.Type) install)" } else { 'not installed' }), $latest)

    # 1b. Compare versions and warn about cases this script should not handle blindly
    $curV = $null; $newV = $null
    if ($current) { try { $curV = [version](ConvertTo-ShortVersion $current.Version) } catch { } }
    try { $newV = [version](ConvertTo-ShortVersion $latest) } catch { }

    # WDKTestCert left in the Trusted Root store by RustDesk 1.2.3 (CVE-2024-25140) - an upgrade does NOT remove it
    $wdkCert = Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
               Where-Object { $_.Subject -like '*WDKTestCert*' }
    if ($wdkCert) {
        Write-Host ""
        Write-Host "SECURITY WARNING: an old RustDesk 'WDKTestCert' certificate is in Trusted Root (CVE-2024-25140)." -ForegroundColor Red
        Write-Host "  Upgrading does not remove it. Remove it manually (certlm.msc > Trusted Root Certification" -ForegroundColor Red
        Write-Host "  Authorities > Certificates > WDKTestCert) unless you rely on RustDesk's virtual display driver." -ForegroundColor Red
        Write-Host ""
    }

    if (-not $Nightly -and $curV -and $newV) {
        if ($curV -eq $newV -and -not $Force) {
            Write-Host ""
            Write-Host "RustDesk $($current.Version) is already installed - this is the latest version. Nothing to do." -ForegroundColor Green
            Write-Host "(Use -Force to reinstall anyway.)"
            $null = Start-RustDeskService
            return
        }
        if ($curV -gt $newV -and -not $Force) {
            Write-Host ""
            Write-Host "Installed RustDesk $($current.Version) is NEWER than the latest stable $latest" -ForegroundColor Yellow
            Write-Host "(probably a nightly/beta build). Not downgrading. Use -Force to install $latest anyway." -ForegroundColor Yellow
            return
        }
        if ($curV -lt [version]'1.2.0' -and -not $Force) {
            Write-Host ""
            Write-Host "Installed RustDesk $($current.Version) is a very old 1.1.x (Sciter) version." -ForegroundColor Yellow
            Write-Host "Upgrading it in place is NOT recommended. Instead:" -ForegroundColor Yellow
            Write-Host "  1. Write down this PC's RustDesk ID and server settings." -ForegroundColor Yellow
            Write-Host "  2. Uninstall RustDesk (Settings > Apps)." -ForegroundColor Yellow
            Write-Host "  3. Run this script again for a clean install of $latest." -ForegroundColor Yellow
            Write-Host "Use -Force to try the in-place upgrade anyway." -ForegroundColor Yellow
            return
        }
        if ($curV.Major -ne $newV.Major -or ($newV.Minor - $curV.Minor) -ge 2) {
            Write-Host "Note: big version jump ($($current.Version) -> $latest). Check settings after the upgrade." -ForegroundColor Yellow
        }
    }

    # 2. Pick the SAME installer type as the existing install.
    #    Mixing them (MSI over an exe install or vice versa) fails or leaves RustDesk broken.
    $wantType = if ($current) { $current.Type } else { 'msi' }
    $msiAsset = $release.assets | Where-Object { $_.name -like 'rustdesk-*-x86_64.msi' } | Select-Object -First 1
    $exeAsset = $release.assets | Where-Object { $_.name -like 'rustdesk-*-x86_64.exe' -and $_.name -notlike '*sciter*' } |
                Select-Object -First 1
    $asset = if ($wantType -eq 'msi' -and $msiAsset) { $msiAsset } elseif ($exeAsset) { $exeAsset } else { $msiAsset }
    if (-not $asset) { throw "No Windows x64 installer found in release '$($release.tag_name)'." }
    Write-Host "Using installer: $($asset.name)"

    # 3. Confirmation: the RustDesk service will be stopped and restarted
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

    # 4. Download into a fresh folder that only Administrators and SYSTEM can access
    $workDir = Join-Path $env:SystemRoot ("Temp\RustDeskUpdate-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $null = & icacls.exe $workDir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F'
    if ($LASTEXITCODE -ne 0) { throw "Could not lock down the download folder." }

    $installer = Join-Path $workDir $asset.name
    Write-Host "Downloading $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installer -UseBasicParsing
    if ((Get-Item $installer).Length -ne $asset.size) { throw "Downloaded file size doesn't match - download is incomplete." }

    # 5a. Verify SHA-256 against the hash GitHub publishes for the release file
    $hash = (Get-FileHash -Path $installer -Algorithm SHA256).Hash
    if ($asset.digest -and $asset.digest -like 'sha256:*') {
        $expected = $asset.digest.Substring(7)
        if ($hash -ne $expected) { throw "SHA-256 mismatch! Expected $expected, got $hash. Installer NOT run." }
        Write-Host "SHA-256 verified: $hash" -ForegroundColor Green
    } else {
        Write-Warning "GitHub did not publish a hash for this file - relying on the signature check only. SHA-256: $hash"
    }

    # 5b. Verify the Windows code signature and the publisher
    $sig = Get-AuthenticodeSignature -FilePath $installer
    if ($sig.Status -ne 'Valid') {
        throw "Digital signature is not valid ($($sig.Status): $($sig.StatusMessage)). Installer NOT run."
    }
    if ($sig.SignerCertificate.Subject -notmatch $ExpectedSigner) {
        throw "Unexpected publisher: $($sig.SignerCertificate.Subject). Installer NOT run."
    }
    Write-Host "Signature valid: $($sig.SignerCertificate.GetNameInfo('SimpleName', $false))" -ForegroundColor Green

    # 6. Stop RustDesk so its files can be replaced (ID and config are kept)
    Write-Host "Stopping RustDesk..."
    $serviceStopped = $true
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    Get-Process -Name 'rustdesk' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    # 7. Install silently
    Write-Host "Installing silently (this can take a minute)..."
    if ($installer -like '*.msi') {
        $msiLog = Join-Path $env:ProgramData 'RustDesk-Update-msi.log'
        $code = Invoke-AndWait 'msiexec.exe' "/i `"$installer`" /qn /norestart /l*v `"$msiLog`"" 600
        switch ($code) {
            0       { }
            $null   { Write-Warning "msiexec did not finish in 10 minutes - checking the result anyway." }
            3010    { Write-Warning "Installed - a reboot is required to finish." }
            1618    { throw "Another installation is in progress. Try again in a few minutes." }
            default { throw "msiexec failed with exit code $code. Details: $msiLog" }
        }
    }
    else {
        $null = Invoke-AndWait $installer '--silent-install' 180
    }

    # 8. Wait (up to 2 min) until Windows reports the NEW version
    $now = $null
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 2
        $now = Get-RustDeskInstall
        if ($now -and ($Nightly -or (ConvertTo-ShortVersion $now.Version) -eq (ConvertTo-ShortVersion $latest))) { break }
    }
    if (-not $now) { throw "Installer finished but RustDesk does not show up as installed." }
    if (-not $Nightly -and (ConvertTo-ShortVersion $now.Version) -ne (ConvertTo-ShortVersion $latest)) {
        throw "Install did not complete: version is still $($now.Version), expected $latest."
    }
    Write-Host "Installed version is now: $($now.Version)" -ForegroundColor Green
}
catch {
    Write-Host "Update failed: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}
finally {
    # Always bring the service back if we stopped it - even when the update failed
    if ($serviceStopped -or $exitCode -eq 0) {
        Write-Host "Starting RustDesk service..."
        if (Start-RustDeskService) {
            Write-Host "RustDesk service is running." -ForegroundColor Green
        } else {
            Write-Host "RustDesk service could NOT be started. Check 'services.msc' or reboot." -ForegroundColor Red
            $exitCode = 1
        }
    }

    # Clean up the download folder (retry while the installer is still locked)
    if ($workDir -and (Test-Path $workDir)) {
        for ($i = 0; $i -lt 10; $i++) {
            try { Remove-Item $workDir -Recurse -Force; Write-Host "Installer removed."; break }
            catch { Start-Sleep -Seconds 2 }
        }
    }

    Write-Host "Log: $LogFile"
    try { Stop-Transcript | Out-Null } catch { }

    if (-not $NoPause) {
        Write-Host "Press any key to exit..."
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
}
exit $exitCode
