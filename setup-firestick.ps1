<#
.SYNOPSIS
    One-shot setup for Projectivy Launcher as the home screen on an Amazon Fire TV Stick (Fire OS 7/8),
    with optional DNS-level blocking of Amazon's update servers.

.DESCRIPTION
    Locates (or downloads) Android platform-tools, connects to the stick over ADB, confirms
    Projectivy is installed, applies the permission + accessibility hardwire that replaces Amazon's
    ad-filled home screen, and optionally points the stick at a DNS-over-TLS profile so Amazon's
    automatic updates cannot arrive and undo it. Verifies each step as it goes.

    Uses ONLY methods that still work after Amazon patched the system-user exploit in Oct 2025.
    It never tries to disable com.amazon.tv.launcher - that is a protected package and doing so
    removes access to Fire OS Settings.

    Interactive click-through version for non-technical users: Install-Projectivy.cmd / .ps1

.PARAMETER FireTvIp
    The stick's IP. Settings -> My Fire TV -> About -> Network. ADB debugging must be ON.

.PARAMETER InstallProjectivy
    Download and ADB-install Projectivy (v4.71) instead of expecting it to be there already.

.PARAMETER WithHomeOnFire
    Also install + configure Home on Fire, the accessibility redirector needed on newer Fire OS 8
    builds. Use this when Projectivy's own hook does not survive a cold boot.

.PARAMETER DnsDot
    DNS-over-TLS hostname to apply, e.g. abcd1234.dns.nextdns.io (NextDNS profile with the OTA domains
    on its denylist - this is the one that actually stops updates).

.PARAMETER DnsAdguard
    Apply AdGuard DNS instead. Blocks ads and trackers, needs no account, but does NOT block Amazon's
    update servers.

.PARAMETER DnsCloudflare
    Apply Cloudflare DNS. Fast and private, needs no account, but blocks nothing at all - updates still
    arrive. Useful only as a plain DNS change.

.PARAMETER DnsOff
    Remove any DNS setting this script (or a previous run) applied, back to the network default.

.PARAMETER WarmUp
    Send a wake key + Home key after setup so you can eyeball whether the launcher took over.

.PARAMETER Uninstall
    Revert everything: clear the accessibility hooks and the DNS settings, and return to Amazon's
    launcher. Nothing is deleted.

.PARAMETER Log
    Also write a transcript of the whole run to logs\setup-firestick-<timestamp>.log next to this script,
    including every adb command and its output.

.EXAMPLE
    .\setup-firestick.ps1 -FireTvIp 192.168.1.100

.EXAMPLE
    .\setup-firestick.ps1 -FireTvIp 192.168.1.100 -DnsDot abcd1234.dns.nextdns.io

.EXAMPLE
    .\setup-firestick.ps1 -FireTvIp 192.168.1.100 -Uninstall
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$FireTvIp,
    [switch]$InstallProjectivy,
    [switch]$WithHomeOnFire,
    [string]$DnsDot,
    [switch]$DnsAdguard,
    [switch]$DnsCloudflare,
    [switch]$DnsOff,
    [switch]$WarmUp,
    [switch]$Uninstall,
    [switch]$Log
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ProjectivyPkg  = 'com.spocky.projengmenu'
$ProjectivySvc  = 'com.spocky.projengmenu/com.spocky.projengmenu.services.ProjectivyAccessibilityService'
$ProjectivyApk  = 'https://github.com/spocky/miproja1/releases/download/4.71/ProjectivyLauncher-4.71-c95-xda-release.apk'
$HomeOnFirePkg  = 'io.github.toolicious.homeonfire'
$HomeOnFireApk  = 'https://github.com/toolicious/home-on-fire/releases/latest/download/home-on-fire.apk'
$PlatformTools  = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'
$AdguardDot     = 'dns.adguard-dns.com'
$CloudflareDot  = '1dot1dot1dot1.cloudflare-dns.com'

$OtaHosts = @(
    'softwareupdates.amazon.com'
    'updates.amazon.com'
    'prod.ota-cloudfront.net'
    'd1s31zyz7dcc2d.cloudfront.net'
    'd1s31zyz7dcc2d.cloudfront.prod.ota-cloudfront.net'
    'amzdigital-a.akamaihd.net'
    'amzdigitaldownloads.edgesuite.net'
)

function Info { param($m) Write-Host "  $m" }
function Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Good { param($m) Write-Host "  OK  $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "  !   $m" -ForegroundColor Yellow }
function Fail { param($m) Write-Host "  X   $m" -ForegroundColor Red; exit 1 }

function Resolve-Adb {
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
        (Join-Path $env:USERPROFILE 'Downloads\platform-tools\adb.exe'),
        (Join-Path $env:TEMP 'platform-tools\adb.exe'))) {
        if (Test-Path $p) { return $p }
    }
    Step 'Android platform-tools not found - downloading (~15 MB)'
    $zip = Join-Path $env:TEMP 'platform-tools.zip'
    Invoke-WebRequest -Uri $PlatformTools -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $env:TEMP -Force
    $exe = Join-Path $env:TEMP 'platform-tools\adb.exe'
    if (-not (Test-Path $exe)) { Fail 'platform-tools download did not produce adb.exe' }
    Good "installed to $env:TEMP\platform-tools"
    return $exe
}

$Adb = Resolve-Adb
Good "adb: $Adb"

if ($Log) {
    $logDir = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'logs' } else { Join-Path $env:TEMP 'logs' }
    try {
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $logPath = Join-Path $logDir ("setup-firestick-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Start-Transcript -Path $logPath -Force | Out-Null
        Write-Host "  Transcript: $logPath" -ForegroundColor Cyan
    } catch { Warn "Could not start the transcript: $($_.Exception.Message)" }
}

function Invoke-Adb {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $out = & $Adb @Args 2>&1
    return @{ Output = ($out -join "`n"); Ok = ($LASTEXITCODE -eq 0) }
}

function Set-DnsDot {
    param([string]$DotHost)
    Step "Pointing the stick at DNS-over-TLS host $DotHost"
    (Invoke-Adb shell settings put global private_dns_mode hostname).Output   | Out-Null
    (Invoke-Adb shell settings put global private_dns_specifier $DotHost).Output | Out-Null
    $mode = (Invoke-Adb shell settings get global private_dns_mode).Output
    $spec = (Invoke-Adb shell settings get global private_dns_specifier).Output
    Info "private_dns_mode      : $mode"
    Info "private_dns_specifier : $spec"
    if ($mode -match 'hostname' -and $spec -match [regex]::Escape($DotHost)) { Good 'DNS profile applied' }
    else { Warn 'The stick did not accept the DNS setting.' }

    Step 'Checking whether the update address still resolves (advisory)'
    $ping = (Invoke-Adb shell ping -c 1 -w 3 softwareupdates.amazon.com).Output
    if ($ping -match 'unknown host|bad address|Name or service|No address associated|0\.0\.0\.0') {
        Good 'softwareupdates.amazon.com does not resolve - updates are blocked'
    } elseif ($ping -match 'bytes from') {
        Warn 'softwareupdates.amazon.com STILL resolves - this profile does not block it. Check the denylist.'
    } else { Warn "Could not test automatically. Output: $ping" }
}

function Clear-Dns {
    Step 'Removing the DNS settings'
    (Invoke-Adb shell settings put global private_dns_mode off).Output              | Out-Null
    (Invoke-Adb shell settings delete global private_dns_specifier).Output          | Out-Null
    (Invoke-Adb shell settings delete global dns_servers).Output                    | Out-Null
    $mode = (Invoke-Adb shell settings get global private_dns_mode).Output
    Info "private_dns_mode : $mode"
    Good 'DNS back to the network default'
}

# --- connect ------------------------------------------------------------
Step "Connecting to $FireTvIp`:5555"
if (-not (Test-NetConnection -ComputerName $FireTvIp -Port 5555 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    Warn "Port 5555 is not answering on $FireTvIp."
    Warn 'On the stick: Settings -> My Fire TV -> Developer Options -> ADB debugging = ON, and re-check the IP under About -> Network.'
}

(Invoke-Adb connect "$FireTvIp`:5555").Output | Out-Null

Step 'Waiting for authorisation (accept the prompt on the TV if one appears)'
$device = $null
for ($i = 1; $i -le 30; $i++) {
    $list = (Invoke-Adb devices).Output
    if ($list -match "$([regex]::Escape($FireTvIp)):5555\s+device") { $device = 'device'; break }
    if ($list -match "$([regex]::Escape($FireTvIp)):5555\s+unauthorized") { $device = 'unauthorized' }
    Start-Sleep -Seconds 2
}
if ($device -ne 'device') {
    Fail "Could not get an authorised ADB session (last state: $device). 'failed to authenticate' on the first connect is normal - it races the on-screen prompt; re-run this script."
}
Good "connected: $FireTvIp`:5555"

# --- environment guard --------------------------------------------------
Step 'Checking Fire OS version'
$osName = (Invoke-Adb shell getprop ro.build.version.name).Output
$fireos = (Invoke-Adb shell getprop ro.build.version.fireos).Output
Info "Fire OS $fireos ($osName)"
if ($osName -match 'Vega' -or $fireos -match 'Vega') {
    Fail 'Vega OS device - sideloading and custom launchers are not possible. Nothing to do here.'
}
if ($fireos -and $fireos -notmatch '^(7|8)') {
    Warn "Fire OS $fireos is outside the tested range (7.x / 8.x). Continuing, but the hooks may not take."
}

# --- DNS only / revert --------------------------------------------------
if ($DnsOff) {
    Clear-Dns
    exit 0
}

if ($DnsDot -or $DnsAdguard -or $DnsCloudflare) {
    if ($DnsDot)             { Set-DnsDot $DnsDot }
    elseif ($DnsCloudflare)  {
        Set-DnsDot $CloudflareDot
        Write-Host ''
        Warn 'Cloudflare is applied, but it blocks NOTHING - Amazon updates will still reach this stick.'
        Warn 'Use -DnsDot <profile>.dns.nextdns.io if the goal is to stop updates.'
    }
    else                     { Set-DnsDot $AdguardDot }
    if (-not $Uninstall) {
        Step 'Domains to put on your resolver denylist'
        $OtaHosts | ForEach-Object { Info $_ }
    }
    exit 0
}

# --- uninstall / revert -------------------------------------------------
if ($Uninstall) {
    Step 'Reverting to the Amazon launcher'
    (Invoke-Adb shell settings put secure enabled_accessibility_services '""').Output | Out-Null
    (Invoke-Adb shell appops set $ProjectivyPkg SYSTEM_ALERT_WINDOW default).Output   | Out-Null
    (Invoke-Adb shell dumpsys deviceidle whitelist "-$ProjectivyPkg").Output         | Out-Null
    (Invoke-Adb shell am start -n 'com.amazon.tv.launcher/.ui.HomeActivity_vNext').Output | Out-Null
    Clear-Dns
    Good 'Hooks cleared and Amazon launcher started. Apps left installed.'
    exit 0
}

# --- Projectivy present? ------------------------------------------------
Step 'Checking for Projectivy Launcher'
$packages = (Invoke-Adb shell pm list packages).Output
if ($packages -notmatch [regex]::Escape($ProjectivyPkg)) {
    if ($InstallProjectivy) {
        Step 'Downloading Projectivy 4.71'
        $apk = Join-Path $env:TEMP 'projectivy.apk'
        Invoke-WebRequest -Uri $ProjectivyApk -OutFile $apk -UseBasicParsing
        Info (Invoke-Adb install -r $apk).Output
        Good 'Projectivy installed'
    }
    else {
        Warn 'Projectivy is not installed. Install it on the stick via the Downloader app:'
        Info $ProjectivyApk
        Info 'Short codes for Downloader: 1198422 (Projectivy APK), 250931 (TROYPOINT Toolbox), 730116 (FireStickHacks)'
        Info 'Or re-run this script with -InstallProjectivy and it will download + install it over ADB.'
        exit 1
    }
}
else { Good "found $ProjectivyPkg" }

# --- block 1: Projectivy's own hook ------------------------------------
Step 'Applying Projectivy permissions + accessibility service'
(Invoke-Adb shell appops set $ProjectivyPkg SYSTEM_ALERT_WINDOW allow).Output           | Out-Null
(Invoke-Adb shell dumpsys deviceidle whitelist "+$ProjectivyPkg").Output               | Out-Null
(Invoke-Adb shell settings put secure enabled_accessibility_services $ProjectivySvc).Output | Out-Null

$enabled = (Invoke-Adb shell settings get secure enabled_accessibility_services).Output
if ($enabled -match [regex]::Escape($ProjectivySvc)) { Good 'accessibility service registered' }
else { Warn "accessibility service did not register (settings returned: $enabled)" }

Write-Host ''
Info 'On the TV: Projectivy -> Settings -> General -> Override current launcher = ON'

# --- block 2: Home on Fire ---------------------------------------------
if ($WithHomeOnFire) {
    Step 'Installing Home on Fire (Home-button redirector for newer Fire OS 8 builds)'
    $apk = Join-Path $env:TEMP 'home-on-fire.apk'
    Invoke-WebRequest -Uri $HomeOnFireApk -OutFile $apk -UseBasicParsing
    Info (Invoke-Adb install -r $apk).Output
    (Invoke-Adb shell pm grant $HomeOnFirePkg android.permission.WRITE_SECURE_SETTINGS).Output | Out-Null
    $granted = (Invoke-Adb shell dumpsys package $HomeOnFirePkg).Output
    if ($granted -match 'WRITE_SECURE_SETTINGS: granted=true') { Good 'WRITE_SECURE_SETTINGS granted' }
    else { Warn 'WRITE_SECURE_SETTINGS grant not confirmed - the in-app accessibility toggle may fail.' }
    (Invoke-Adb shell am start -n "$HomeOnFirePkg/.MainActivity").Output | Out-Null
    Write-Host ''
    Info 'On the TV, in Home on Fire:'
    Info '  1. Accessibility service   = ON'
    Info '  2. Choose target app...    = Projectivy Launcher'
    Info '  3. Launch on boot / on wake = ON'
    Info '  4. Then set Projectivy -> Settings -> General -> Override current launcher = OFF'
}

if ($WarmUp) {
    Step 'Waking the device and pressing Home'
    (Invoke-Adb shell input keyevent KEYCODE_WAKEUP).Output | Out-Null
    Start-Sleep -Seconds 2
    (Invoke-Adb shell input keyevent KEYCODE_HOME).Output | Out-Null
    Start-Sleep -Seconds 3
    $focus = (Invoke-Adb shell dumpsys window).Output | Select-String 'mCurrentFocus'
    if ($focus) { Info "focus: $($focus.ToString().Trim())" }
    Warn 'com.spocky.projengmenu = win. com.amazon.tv.launcher = the hook did not take (-WithHomeOnFire).'
}

# --- verify -------------------------------------------------------------
Step 'Verification'
$enabled = (Invoke-Adb shell settings get secure enabled_accessibility_services).Output
Info "enabled_accessibility_services : $enabled"
Info 'Now unplug the stick for 30 seconds and power back up - the cold-boot path is the real test.'
Info 'After it boots:'
Info "  & '$Adb' shell settings get secure enabled_accessibility_services"
Info "  & '$Adb' shell dumpsys window | Select-String mCurrentFocus"
Info ''
Info 'Recovery if it goes wrong:'
Info "  & '$Adb' shell settings put secure enabled_accessibility_services `"`""
Info "  & '$Adb' shell am start -n com.amazon.tv.launcher/.ui.HomeActivity_vNext"
Info ''
Info 'To stop Amazon pushing an update that reverts this, either:'
Info '  .\setup-firestick.ps1 -FireTvIp <ip> -DnsDot <profile>.dns.nextdns.io   (NextDNS - blocks updates)'
Info '  .\setup-firestick.ps1 -FireTvIp <ip> -DnsCloudflare                      (fast/private, blocks nothing)'
Info '  .\setup-firestick.ps1 -FireTvIp <ip> -DnsAdguard                         (ads only, no update blocking)'
Info 'Domains for the denylist:'
$OtaHosts | ForEach-Object { Info "  $_" }
Write-Host ''
Info 'IF A STREAMING APP MISBEHAVES after this: remove the DNS setting first, before blaming anything else:'
Info "  & '$Adb' shell settings put global private_dns_mode off"
Info "  & '$Adb' shell settings delete global private_dns_specifier"
Write-Host ''
info "IF THE STICK EVER RETURNS TO AMAZON'S HOME SCREEN: just re-run this script. An update that got"
info 'through can clear the launcher settings - the apps are still installed, so it is a 30-second job.'

if ($Log) { try { Stop-Transcript | Out-Null } catch { } }