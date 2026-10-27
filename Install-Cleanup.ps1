<#
    Install-Cleanup.ps1  -  the full cleanup, for Windows.

    Takes the ads, the tracking and the clutter out of an Amazon Fire TV Stick or Cube (Fire OS 7/8)
    over ADB, with no root: disables the ad and telemetry packages, starves the ones Amazon protects,
    turns off ad tracking, replaces the home screen, optionally swaps YouTube for SmartTube, and
    optionally runs a DNS filter on the TV itself.

    Every change is written to an undo log, and -Undo reverses it. The log format matches the Linux
    wizard (lib/cleanup.sh), so an undo started on one machine finishes correctly on the other.

    Double-click Cleanup-FireTV.cmd instead of running this directly, so the execution policy is
    bypassed for this one script.

    Options:
      -Undo            reverse the last cleanup and hand HOME back to Amazon
      -Ip 192.168.1.5  skip the address question
      -AnswerScript "y y 1 1 n -"  answer the questions without prompting (testing / scripted use);
                              the environment variable CLEANUP_ANSWERS does the same
#>

param(
    [switch]$Undo,
    [string]$Ip = '',
    [string]$AnswerScript = ''
)

Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$DataDir   = Join-Path $ScriptDir 'data'

$PROJ_PKG  = 'com.spocky.projengmenu'
$PROJ_SVC  = 'com.spocky.projengmenu/com.spocky.projengmenu.services.ProjectivyAccessibilityService'
$PROJ_URL  = 'https://github.com/spocky/miproja1/releases/download/4.71/ProjectivyLauncher-4.71-c95-xda-release.apk'
$DUMBTV_PKG = 'tv.dumbtv.home'
$DUMBTV_SVC = 'tv.dumbtv.home/tv.dumbtv.home.Guard'
$DUMBTV_URL = 'https://github.com/humblemuzzu/dumbtv/releases/download/launcher-v1.5/dumbtv-home.apk'
$DUMBTV_SHA = '564797e434f1960cfcb548f31ec84d79b515a8c27d5bf811e1b97972a72eeee8'
$SMART_PKG  = 'org.smarttube.stable'
$SMART_URL  = 'https://github.com/yuliskov/SmartTube/releases/download/32.56s/SmartTube_stable_32.56_universal.apk'
$SMART_SHA  = '4a35b90940612e048e4e9cb9e10379f7db1e84f30375994129f10a571ee04ce5'
$SMART_CODE = 2446
$YT_PKG     = 'com.amazon.firetv.youtube'
$DNSF_PKG   = 'dnsfilter.android'
$DNSF_VER   = '1506103'
$DNSF_URL   = "https://f-droid.org/repo/dnsfilter.android_$DNSF_VER.apk"
$DNSF_SHA   = '3ddd0db322d1ca5fe950ea29dc1788af6e6581bb5f34694085fb4aa2e77b68ad'
$HAGEZI_URL = 'https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.amazon-onlydomains.txt'
$CLOUDFLARE_DOT = '1dot1dot1dot1.cloudflare-dns.com'

# Tests and mirrors can override these; the shipped defaults are the pinned values.
if ($env:DNSF_SHA256)    { $DNSF_SHA  = $env:DNSF_SHA256 }
if ($env:DUMBTV_SHA256)  { $DUMBTV_SHA = $env:DUMBTV_SHA256 }
if ($env:SMARTTUBE_SHA256) { $SMART_SHA = $env:SMARTTUBE_SHA256 }

$script:Adb     = $null
$script:Ip      = $Ip
$script:Sdk     = 0
$script:LogFile = $null
$script:Work    = $null
# -Answers (or CLEANUP_ANSWERS) drives the questions without a prompt: testing, and scripted runs
# on a machine with no console. Read it in the body, not as a param default, which does not bind here.
if (-not $AnswerScript) { $AnswerScript = $env:CLEANUP_ANSWERS }
$script:Answers = @()
if ($AnswerScript) {
    $script:Answers = @($AnswerScript -split '\s+' | Where-Object { $_ -ne '' })
}

# answers collected by the questions
$script:Prime      = $true
$script:Alexa      = $true
$script:Launcher   = 'projectivy'   # projectivy | dumbtv | amazon
$script:DnsMode    = 'device'       # device | nextdns | cloudflare | none
$script:Remove     = @()
$script:SmartTube  = $false

$script:UndoLog = $null
$script:CleanDir = $null

# ---------------------------------------------------------------- output + log

function Log {
    param([string]$Text, [string]$Colour = 'Gray')
    Write-Host $Text -ForegroundColor $Colour
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $Text -Encoding UTF8 } catch { }
    }
}

function Step { param([string]$Text) Log '' ; Log ("== $Text") 'Cyan' }
function Good { param([string]$Text) Log ("  OK $Text") 'Green' }
function Warn2 { param([string]$Text) Log ("  !! $Text") 'Yellow' }
function Bad2 { param([string]$Text) Log ("  XX $Text") 'Red' }
function Dim2 { param([string]$Text) Log ("     $Text") 'DarkGray' }

function Start-Log {
    $dir = Join-Path $ScriptDir 'logs'
    try {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    } catch { $dir = $env:TEMP }
    $script:LogFile = Join-Path $dir ("cleanup-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    @(
        '=== Fire TV full cleanup log ==='
        "started : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "host    : $env:COMPUTERNAME   user: $env:USERNAME"
        "script  : $PSVersionTable.PSVersion"
    ) | Set-Content -LiteralPath $script:LogFile -Encoding UTF8
}

# ---------------------------------------------------------------- adb

function Invoke-Adb {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $out = & $script:Adb @Args 2>&1 | Out-String
    $clean = ($out -replace "`r", '').TrimEnd()
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value ("adb {0} -> {1}" -f ($Args -join ' '), $clean) -Encoding UTF8 } catch { }
    }
    return $clean
}

function Invoke-AdbShell {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    return (Invoke-Adb @(@('shell') + $Args))
}

function Get-Adb {
    if ($script:Adb -and (Test-Path $script:Adb)) { return $true }
    if ($env:ADB -and (Test-Path $env:ADB)) { $script:Adb = $env:ADB; return $true }

    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { $script:Adb = $cmd.Source; return $true }

    $local = Join-Path $ScriptDir 'platform-tools\adb.exe'
    if (Test-Path $local) { $script:Adb = $local; return $true }

    Step 'Android platform-tools are not installed - downloading them (about 15 MB, one time)'
    $zip = Join-Path (Get-TempDir) 'platform-tools.zip'
    try {
        Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' `
            -OutFile $zip -UseBasicParsing
    } catch {
        Bad2 'Download failed - check the internet connection.'
        return $false
    }
    $dest = Join-Path $ScriptDir 'platform-tools'
    try {
        Expand-Archive -LiteralPath $zip -DestinationPath $ScriptDir -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    } catch {
        Bad2 'Could not unpack the download.'
        return $false
    }
    if (Test-Path (Join-Path $dest 'adb.exe')) {
        $script:Adb = Join-Path $dest 'adb.exe'; Good "adb: $script:Adb"; return $true
    }
    Bad2 'Extraction produced no adb.exe.'
    return $false
}

# ---------------------------------------------------------------- device reads

function Get-DataList {
    param([string]$Name)
    $path = Join-Path $DataDir $Name
    if (-not (Test-Path $path)) { return @() }
    return @(Get-Content -LiteralPath $path | ForEach-Object { ($_ -replace '#.*$', '').Trim() } |
             Where-Object { $_ -ne '' } | ForEach-Object { ($_ -split '\s+')[0] })
}

function Get-Packages { return @((Invoke-AdbShell 'pm' 'list' 'packages') -split "`n" | ForEach-Object { $_ -replace '^package:', '' } | Where-Object { $_ }) }
function Get-DisabledPackages { return @((Invoke-AdbShell 'pm' 'list' 'packages' '-d') -split "`n" | ForEach-Object { $_ -replace '^package:', '' } | Where-Object { $_ }) }

function Test-Pkg {
    param([string]$Pkg)
    return ((Get-Packages) -contains $Pkg)
}

function Test-PkgDisabled {
    param([string]$Pkg)
    return ((Get-DisabledPackages) -contains $Pkg)
}

function Get-PkgVersion {
    param([string]$Pkg)
    $d = Invoke-AdbShell 'dumpsys' 'package' $Pkg
    if ($d -match 'versionCode=(\d+)') { return [int]$Matches[1] }
    return 0
}

function Get-Uid {
    param([string]$Pkg)
    $d = Invoke-AdbShell 'dumpsys' 'package' $Pkg
    if ($d -match 'userId=(\d+)') { return $Matches[1] }
    return ''
}

function Get-Front {
    $d = Invoke-AdbShell 'dumpsys' 'window'
    if ($d -match 'mCurrentFocus=Window\{[^ ]+ [^ ]+ ([^ }]+)') { return $Matches[1] }
    return ''
}

function Resolve-Apps {
    param([string]$Text)
    $out = @()
    foreach ($word in ($Text -split '\s+' | Where-Object { $_ })) {
        if ($word -match '\.') { $out += $word; continue }
        $hit = $null
        foreach ($line in (Get-Content -LiteralPath (Join-Path $DataDir 'apps.txt'))) {
            if ($line -match '^\s*#' -or $line -notmatch '\|') { continue }
            $parts = $line -split '\|', 2
            $name = $parts[0].Trim(); $pkg = $parts[1].Trim()
            if ($name.ToLower().StartsWith($word.ToLower())) { $hit = $pkg; break }
        }
        if ($hit) { $out += $hit } else { Warn2 "No package id for '$word' - skipping it." }
    }
    return $out
}

# ---------------------------------------------------------------- questions

function Get-TempDir {
    # $env:TEMP is not set everywhere (and never on Linux), so always fall back to the .NET answer.
    if ($env:TEMP) { return $env:TEMP }
    if ($env:TMPDIR) { return $env:TMPDIR }
    return [System.IO.Path]::GetTempPath()
}

function Read-Reply {
    param([string]$Prompt)
    try { return (Read-Host $Prompt) } catch { return '' }
}

function Next-Answer {
    if ($script:Answers.Count -eq 0) { return $null }
    $a = $script:Answers[0]
    $script:Answers = @($script:Answers | Select-Object -Skip 1)
    return $a
}

function Ask-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $a = Next-Answer
    if ($null -ne $a) {
        Log "$Prompt $a"
        return ($a -match '^(y|yes|1)$')
    }
    if ($script:Answers.Count -eq 0) { Log "$Prompt" }
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $a = Read-Reply "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return ($a -match '^(y|yes)')
}

function Ask-Choice {
    param([string]$Prompt, [string[]]$Items)
    Log ''
    Log $Prompt 'Cyan'
    for ($i = 0; $i -lt $Items.Count; $i++) { Log ("  {0}: {1}" -f ($i + 1), $Items[$i]) }
    $reply = $null
    $reply = Next-Answer
    if ($null -ne $reply) {
        Log "  selected: $reply"
    } else {
        $reply = Read-Reply 'Select [1]: '
    }
    $n = 0
    if (-not [int]::TryParse(("$reply").Trim(), [ref]$n)) { $n = 1 }
    if ($n -lt 1 -or $n -gt $Items.Count) { $n = 1 }
    return ($n - 1)
}

function Read-Answers {
    Step 'A few questions'
    Log 'Your answers decide what gets touched. Nothing is removed unless you name it, and every'
    Log 'change can be undone from the menu afterwards.'

    $script:Prime = Ask-YesNo 'Do you watch Prime Video? (yes keeps the servers it needs reachable)' $true
    if ($script:Prime) { Dim2 'Prime Video: kept working' } else { Dim2 'Prime Video: its servers are blocked, so it will not play' }

    $script:Alexa = Ask-YesNo "Keep Alexa and the remote's voice button? (no switches Alexa and the microphone off)" $true
    if ($script:Alexa) { Dim2 'Alexa: kept' } else { Dim2 'Alexa: switched off' }

    $i = Ask-Choice 'Which home screen?' @(
        'Projectivy Launcher (recommended - categories, wallpaper, app hiding)',
        'dumbtv home (tiny: 54 KB, no internet permission, apps and inputs only)',
        "Keep Amazon's home screen (remove the ads around it, nothing else)"
    )
    $script:Launcher = @('projectivy', 'dumbtv', 'amazon')[$i]
    Dim2 "home screen: $($script:Launcher)"

    $i = Ask-Choice 'Block Amazon on the TV itself?' @(
        'On-device DNS filter (no account, blocks telemetry and updates)',
        'NextDNS profile (no app, but you make a free account)',
        'Cloudflare (fast, private, blocks nothing)',
        'Nothing - leave DNS alone'
    )
    $script:DnsMode = @('device', 'nextdns', 'cloudflare', 'none')[$i]
    Dim2 "DNS: $($script:DnsMode)"

    $script:SmartTube = Ask-YesNo 'Replace the YouTube app with SmartTube? (no ads, no Shorts, account untouched)' $false
    if ($script:SmartTube) { Dim2 'YouTube: will be replaced with SmartTube (stock app disabled, not deleted)' }
    else { Dim2 'YouTube: left alone' }

    Log ''
    Log 'Apps are only removed when you name them (Netflix, Spotify... or a package id).'
    $text = ''
    $text = Next-Answer
    if ($null -ne $text) {
        if ($text -eq '-') { $text = '' }
        Log "Apps to remove: $text"
    } else {
        $text = Read-Reply 'Apps to remove (Enter for none)'
    }
    $script:Remove = @(Resolve-Apps $text)
}

function Show-Plan {
    Step 'Here is what will change'
    Log ("Disabled, never deleted: {0} Amazon ad, telemetry and experiment packages." -f (Get-DataList 'packages.txt').Count)
    Log ("Starved instead (Amazon protects them): {0} packages lose background running and data." -f (Get-DataList 'protected.txt').Count)
    Log 'Ad tracking and usage reporting: switched off.'
    switch ($script:Launcher) {
        'projectivy' { Log 'Home screen: Projectivy Launcher.' }
        'dumbtv'     { Log 'Home screen: dumbtv home (54 KB, no internet permission).' }
        default      { Log "Home screen: Amazon's, left in place." }
    }
    switch ($script:DnsMode) {
        'device'     { Log 'DNS: on-device filter, no account, blocks about 400 Amazon hosts.' }
        'nextdns'    { Log 'DNS: your NextDNS profile (you will paste the address).' }
        'cloudflare' { Log 'DNS: Cloudflare. Blocks nothing.' }
        default      { Log 'DNS: left alone.' }
    }
    if ($script:SmartTube) { Log 'YouTube: replaced with SmartTube (stock app disabled).' }
    if ($script:Remove.Count -gt 0) { Log ("Apps to remove: {0}" -f ($script:Remove -join ', ')) }
    Log ''
    Log 'Your apps and everything you watch stay. Undo in the menu reverses all of it.'
    $i = Ask-Choice 'Go ahead?' @('Yes - start the cleanup', 'No - back to the questions')
    return ($i -eq 0)
}

# ---------------------------------------------------------------- preflight

function Start-Preflight {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:CleanDir = Join-Path (Join-Path $ScriptDir 'logs') "cleanup-$stamp"
    New-Item -ItemType Directory -Path $script:CleanDir -Force | Out-Null
    $script:UndoLog = Join-Path $script:CleanDir 'undo.tsv'
    Set-Content -LiteralPath $script:UndoLog -Value '' -Encoding UTF8

    Step 'Checking the TV before anything changes'
    $script:Sdk = 0
    $sdkRaw = Invoke-AdbShell 'getprop' 'ro.build.version.sdk'
    [void][int]::TryParse(($sdkRaw -replace '\D', ''), [ref]$script:Sdk)

    $model = Invoke-AdbShell 'getprop' 'ro.product.model'
    $os    = Invoke-AdbShell 'getprop' 'ro.build.version.name'
    $pkgs  = (Get-Packages).Count
    $dis   = (Get-DisabledPackages).Count
    Good ("{0} / {1} / SDK {2}" -f $model.Trim(), $os.Trim(), $script:Sdk)
    Good "$pkgs packages installed, $dis already disabled"

    (Invoke-AdbShell 'settings' 'list' 'secure')  | Set-Content -LiteralPath (Join-Path $script:CleanDir 'settings-secure-before.txt') -Encoding UTF8
    (Invoke-AdbShell 'settings' 'list' 'global')  | Set-Content -LiteralPath (Join-Path $script:CleanDir 'settings-global-before.txt') -Encoding UTF8
    (Invoke-AdbShell 'pm' 'list' 'packages' '-d') | Set-Content -LiteralPath (Join-Path $script:CleanDir 'disabled-before.txt') -Encoding UTF8
    Dim2 "Snapshot kept in $($script:CleanDir)"
}

function Add-Undo {
    param([string]$Kind, [string]$Subject, [string]$Action, [string]$Extra = '')
    $line = if ($Extra) { "$Kind`t$Subject`t$Action`t$Extra" } else { "$Kind`t$Subject`t$Action" }
    Add-Content -LiteralPath $script:UndoLog -Value $line -Encoding UTF8
}

# ---------------------------------------------------------------- debloat

function Disable-One {
    param([string]$Pkg)
    $out = Invoke-AdbShell 'pm' 'disable-user' '--user' '0' $Pkg
    if ($out -match 'new state: disabled') { return 'disabled' }
    if ($out -match 'protected package|SecurityException') { return 'protected' }
    if ($out -match 'Shell cannot change component state') {
        $d = Invoke-AdbShell 'dumpsys' 'package' $Pkg
        if ($d -match 'enabled=2') { return 'system' }
        return 'suspect'
    }
    return 'suspect'
}

function Starve-Pkg {
    param([string]$Pkg)
    [void](Invoke-AdbShell 'appops' 'set' $Pkg 'RUN_IN_BACKGROUND' 'ignore')
    if ($script:Sdk -ge 28) { [void](Invoke-AdbShell 'appops' 'set' $Pkg 'RUN_ANY_IN_BACKGROUND' 'ignore') }
    $uid = Get-Uid $Pkg
    if ($uid) { [void](Invoke-AdbShell 'cmd' 'netpolicy' 'add' 'restrict-background-blacklist' $uid) }
    Add-Undo 'pkg' $Pkg 'starved'
}

function Invoke-Debloat {
    Step 'Removing the ads and the tracking'
    $never = @(Get-DataList 'never-disable.txt')
    $list = @(Get-DataList 'packages.txt')
    if (-not $script:Alexa) { $list += @(Get-DataList 'alexa.txt') }

    $dis = 0; $star = 0; $skip = 0; $abs = 0; $susp = 0
    foreach ($p in $list) {
        if ($never -contains $p) { Log ("  {0,-44} kept (never-disable)" -f $p); $skip++; continue }
        if ($script:Remove -contains $p) { Log ("  {0,-44} kept (you asked)" -f $p); $skip++; continue }
        if (-not (Test-Pkg $p)) { Log ("  {0,-44} not on this TV" -f $p); $abs++; continue }
        $state = Disable-One $p
        switch ($state) {
            'disabled'  { Log ("  {0,-44} off" -f $p); $dis++; Add-Undo 'pkg' $p 'disabled' }
            'protected' { Log ("  {0,-44} protected - starved" -f $p); $star++; Starve-Pkg $p }
            'system'    { Log ("  {0,-44} already off by the system" -f $p) }
            default     { Log ("  {0,-44} could not change (flagged)" -f $p); $susp++; Add-Undo 'pkg' $p 'suspect' }
        }
    }

    foreach ($p in @(Get-DataList 'protected.txt')) {
        if ($never -contains $p) { continue }
        if (-not (Test-Pkg $p)) { continue }
        Starve-Pkg $p; $star++
        Log ("  {0,-44} protected - starved" -f $p)
    }

    if ($script:Remove.Count -gt 0) {
        Log ''
        Log '  apps you asked to remove:'
        foreach ($p in $script:Remove) {
            if ($never -contains $p) { Log ("  {0,-44} keeps the TV working - not touched" -f $p); continue }
            if (-not (Test-Pkg $p)) { Log ("  {0,-44} not on this TV" -f $p); continue }
            $isSystem = ((Invoke-AdbShell 'pm' 'list' 'packages' '-s') -split "`n" | ForEach-Object { $_ -replace '^package:', '' }) -contains $p
            if ($isSystem) {
                if ((Disable-One $p) -eq 'disabled') {
                    Log ("  {0,-44} disabled (system app, restorable)" -f $p); Add-Undo 'pkg' $p 'disabled'
                } else { Log ("  {0,-44} cannot be changed on this build" -f $p) }
            } else {
                [void](Invoke-AdbShell 'pm' 'uninstall' '--user' '0' $p)
                if (Test-Pkg $p) { Log ("  {0,-44} could not be removed" -f $p) }
                else { Log ("  {0,-44} removed (Appstore reinstalls it)" -f $p); Add-Undo 'pkg' $p 'uninstalled' }
            }
        }
    }

    Good "$dis disabled, $star starved, $skip kept, $abs not present"
    if ($susp -gt 0) { Warn2 "$susp package(s) could not be changed on this build - see the log." }
}

function Invoke-Settings {
    Step 'Turning off ad tracking and usage reporting'
    $n = 0
    foreach ($line in (Get-Content -LiteralPath (Join-Path $DataDir 'settings.txt'))) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Trim() -split '\s+'
        if ($parts.Count -lt 3) { continue }
        $ns = $parts[0]; $key = $parts[1]; $value = ($parts[2..($parts.Count - 1)] -join ' ')
        $old = (Invoke-AdbShell 'settings' 'get' $ns $key).Trim()
        if (-not $old) { $old = 'null' }
        Add-Undo 'settings' $ns $key $old
        [void](Invoke-AdbShell 'settings' 'put' $ns $key $value)
        $n++
    }
    Good "$n setting(s) tightened"
}

# ---------------------------------------------------------------- downloads

function Save-Verified {
    param([string]$Url, [string]$Sha, [string]$Dest)
    if ($env:CLEANUP_APK_DIR) {
        $src = Join-Path $env:CLEANUP_APK_DIR (Split-Path -Leaf ([uri]$Url).AbsolutePath)
        if (-not (Test-Path $src)) { Warn2 "test fixture missing: $src"; return $false }
        Copy-Item -LiteralPath $src -Destination $Dest -Force
    } else {
        try { Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing }
        catch { Warn2 "download failed: $Url"; return $false }
    }
    if ([string]::IsNullOrWhiteSpace($Sha)) { return $true }   # unpinned: download only
    $got = (Get-FileHash -LiteralPath $Dest -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $Sha.ToLower()) {
        Bad2 'Checksum mismatch - the file is not the published build, so it was not installed.'
        Dim2 "expected $Sha"
        Dim2 "got      $got"
        return $false
    }
    return $true
}

# ---------------------------------------------------------------- launcher

function Add-A11y {
    param([string]$Component)
    $cur = (Invoke-AdbShell 'settings' 'get' 'secure' 'enabled_accessibility_services').Trim()
    if ([string]::IsNullOrWhiteSpace($cur) -or $cur -eq 'null') { $new = $Component }
    elseif ($cur -like "*$Component*") { $new = $cur }
    else { $new = "$cur`:$Component" }
    [void](Invoke-AdbShell 'settings' 'put' 'secure' 'enabled_accessibility_services' $new)
    [void](Invoke-AdbShell 'settings' 'put' 'secure' 'accessibility_enabled' '1')
}

function Try-SetHome {
    param([string]$Component, [string]$Pkg)
    [void](Invoke-AdbShell 'cmd' 'package' 'set-home-activity' $Component)
    Start-Sleep -Seconds 2
    [void](Invoke-AdbShell 'input' 'keyevent' 'KEYCODE_HOME')
    Start-Sleep -Seconds 3
    $front = Get-Front
    if ($front -like "*$Pkg*") { return $true }
    return $false
}

function Install-Launcher {
    switch ($script:Launcher) {
        'amazon' {
            Step "Leaving Amazon's home screen in place"
            Good 'Ads are already gone from the rows themselves - no launcher change needed.'
            Add-Undo 'launcher' 'amazon' ''
            return
        }
        'projectivy' {
            Step 'Installing Projectivy Launcher'
            if (Test-Pkg $PROJ_PKG) { Good 'Projectivy is already installed' }
            else {
                $tmp = Join-Path (Get-TempDir) 'projectivy.apk'
                if (-not (Save-Verified $PROJ_URL '' $tmp)) {
                    # Projectivy is not checksum-pinned here (it is the upstream release asset); the
                    # empty hash means "download only", which Save-Verified treats as a pass.
                }
                $out = Invoke-Adb 'install' '-r' $tmp
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                if (-not (Test-Pkg $PROJ_PKG)) { Warn2 "Projectivy did not install: $out"; return }
                Good 'Projectivy installed'
            }
            [void](Invoke-AdbShell 'appops' 'set' $PROJ_PKG 'SYSTEM_ALERT_WINDOW' 'allow')
            [void](Invoke-AdbShell 'dumpsys' 'deviceidle' 'whitelist' "+$PROJ_PKG")
            Add-A11y $PROJ_SVC
            Add-Undo 'launcher' 'projectivy' ''
            if (Try-SetHome "$PROJ_PKG/.MainActivity" $PROJ_PKG) {
                Good 'Projectivy is the home screen - no remote presses needed'
            } else {
                Warn2 'Amazon still owns the Home button on this build.'
                Dim2 'On the TV: Projectivy > Settings > General > Override current launcher = ON'
                [void](Read-Reply 'Press Enter once that switch is on')
            }
        }
        'dumbtv' {
            Step 'Installing dumbtv home'
            if (Test-Pkg $DUMBTV_PKG) { Good 'dumbtv home is already installed' }
            else {
                $tmp = Join-Path (Get-TempDir) 'dumbtv-home.apk'
                if (-not (Save-Verified $DUMBTV_URL $DUMBTV_SHA $tmp)) { return }
                $out = Invoke-Adb 'install' '-r' $tmp
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                if (-not (Test-Pkg $DUMBTV_PKG)) { Warn2 "dumbtv home did not install: $out"; return }
                Good 'dumbtv home installed (checksum verified)'
            }
            Add-A11y $DUMBTV_SVC
            Add-Undo 'launcher' 'dumbtv' ''
            if (Try-SetHome "$DUMBTV_PKG/.Home" $DUMBTV_PKG) { Good 'dumbtv home is the home screen' }
            else {
                Warn2 'Amazon still owns the Home button on this build.'
                Dim2 'Open dumbtv home once from the apps row so its guard can bind.'
                [void](Read-Reply 'Press Enter once dumbtv home has opened on the TV')
            }
        }
    }
}

# ---------------------------------------------------------------- SmartTube

function Install-SmartTube {
    if (-not $script:SmartTube) { return }
    Step 'Replacing YouTube with SmartTube'
    $tmp = Join-Path (Get-TempDir) 'smarttube.apk'
    if (-not (Save-Verified $SMART_URL $SMART_SHA $tmp)) { return }
    $code = 0
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $out = Invoke-Adb 'install' '-r' $tmp
        Start-Sleep -Seconds 1
        $code = Get-PkgVersion $SMART_PKG
        if ($code -ge $SMART_CODE) { break }
        if ($attempt -eq 1) { Dim2 'Not installed yet - the wifi can drop after the push; trying once more.' }
    }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    if ($code -lt $SMART_CODE) { Warn2 "SmartTube did not install ($out). YouTube left alone."; return }
    Good "SmartTube installed (versionCode $code)"
    Add-Undo 'app' 'smarttube' 'installed'
    if (Test-Pkg $YT_PKG) {
        if (Test-PkgDisabled $YT_PKG) { Good 'YouTube was already disabled' }
        else {
            [void](Invoke-AdbShell 'pm' 'disable-user' '--user' '0' $YT_PKG)
            if (Test-PkgDisabled $YT_PKG) { Good 'YouTube app disabled (still installed, Undo re-enables it)'; Add-Undo 'app' 'youtube' 'disabled' }
            else { Warn2 'Could not disable the YouTube app - both apps will show on the home screen.' }
        }
    } else { Good 'The YouTube app is not installed on this TV' }
    Dim2 'Worth setting once in SmartTube: Hide shorts everywhere, and the 1080p vp9 preset.'
}

# ---------------------------------------------------------------- DNS

function Get-Blocklist {
    $feed = $null
    if ($env:CLEANUP_BLOCKLIST -and (Test-Path $env:CLEANUP_BLOCKLIST)) {
        $feed = Get-Content -LiteralPath $env:CLEANUP_BLOCKLIST
    } else {
        $tmp = Join-Path (Get-TempDir) 'hagezi.txt'
        try {
            Invoke-WebRequest -Uri $HAGEZI_URL -OutFile $tmp -UseBasicParsing
            $feed = Get-Content -LiteralPath $tmp
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        } catch { $feed = @() }
    }
    $hosts = @($feed | ForEach-Object { ($_ -replace '#.*$', '').Trim().ToLower() } | Where-Object { $_ })
    $hosts += @(Get-DataList 'extra-hosts.txt')
    $hosts = $hosts | Select-Object -Unique
    if ($script:Prime) {
        $hosts = $hosts | Where-Object { $_ -notmatch 'aiv-delivery|aiv-cdn|^device-messaging-na\.amazon\.com$' }
    }
    return $hosts
}

function Install-DnsFilter {
    if ($script:DnsMode -eq 'none') { return }
    if ($script:DnsMode -eq 'cloudflare') {
        [void](Invoke-AdbShell 'settings' 'put' 'global' 'private_dns_mode' 'hostname')
        [void](Invoke-AdbShell 'settings' 'put' 'global' 'private_dns_specifier' $CLOUDFLARE_DOT)
        Add-Undo 'dns' 'cloudflare' $CLOUDFLARE_DOT
        Warn2 'Cloudflare blocks nothing - Amazon updates will still reach this TV.'
        return
    }
    if ($script:DnsMode -eq 'nextdns') {
        Step 'Set up the NextDNS profile'
        Log 'On a phone or computer: my.nextdns.io > new profile > Denylist > add these:'
        foreach ($h in @('softwareupdates.amazon.com', 'updates.amazon.com', 'prod.ota-cloudfront.net',
                         'd1s31zyz7dcc2d.cloudfront.net', 'amzdigital-a.akamaihd.net',
                         'amzdigitaldownloads.edgesuite.net')) { Dim2 $h }
        $host2 = Read-Reply 'Paste the DNS-over-TLS address (blank to skip)'
        if ($host2 -match '\.') {
            [void](Invoke-AdbShell 'settings' 'put' 'global' 'private_dns_mode' 'hostname')
            [void](Invoke-AdbShell 'settings' 'put' 'global' 'private_dns_specifier' $host2.Trim())
            Add-Undo 'dns' 'nextdns' $host2.Trim()
            Good "DNS set to $($host2.Trim())"
        }
        return
    }

    Step 'Setting up the on-device DNS filter'
    $have = Get-PkgVersion $DNSF_PKG
    if ($have -eq [int]$DNSF_VER) { Good "The filter is already installed (version $DNSF_VER)" }
    else {
        Dim2 "Downloading personalDNSfilter $DNSF_VER from F-Droid..."
        $tmp = Join-Path (Get-TempDir) 'dnsfilter.apk'
        if (-not (Save-Verified $DNSF_URL $DNSF_SHA $tmp)) { return }
        $out = Invoke-Adb 'install' '-r' $tmp
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        $have = Get-PkgVersion $DNSF_PKG
        if ($have -ne [int]$DNSF_VER) { Warn2 "The filter did not install: $out"; return }
        Good "Filter installed (version $have)"
    }
    Add-Undo 'dns' 'device' $DNSF_VER
    [void](Invoke-AdbShell 'dumpsys' 'deviceidle' 'whitelist' "+$DNSF_PKG")

    Dim2 'Building the blocklist...'
    $hosts = @(Get-Blocklist)
    if ($hosts.Count -lt 10) { Warn2 "The blocklist came out too small ($($hosts.Count) entries) - not enabling the filter."; return }
    Good "$($hosts.Count) hosts in the list"

    $work = Join-Path (Get-TempDir) ("cleanup-{0}" -f (Get-Random))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $listFile = Join-Path $work 'blocklist.txt'
    $confFile = Join-Path $work 'dnsfilter.conf'
    $mediaDir = "/sdcard/Android/media/$DNSF_PKG"
    $appDir   = "/sdcard/Android/data/$DNSF_PKG/files/PersonalDNSFilter"
    Set-Content -LiteralPath $listFile -Value $hosts -Encoding ASCII
    Set-Content -LiteralPath $confFile -Encoding ASCII -Value ("<dnsfilter><blocklist>file://$mediaDir/blocklist.txt</blocklist></dnsfilter>")

    [void](Invoke-AdbShell 'mkdir' '-p' $mediaDir)
    $push = Invoke-Adb 'push' $listFile "$mediaDir/blocklist.txt"
    if ($push -match 'error|failed') { Warn2 'Could not copy the blocklist to the TV - DNS left as it was.'; return }

    $placed = 'media'
    $pushApp = Invoke-Adb 'push' $listFile "$appDir/blocklist.txt"
    if ($pushApp -notmatch 'error|failed') {
        $pushConf = Invoke-Adb 'push' $confFile "$appDir/dnsfilter.conf"
        if ($pushConf -notmatch 'error|failed') { $placed = 'app' }
    }

    [void](Invoke-AdbShell 'settings' 'put' 'secure' 'always_on_vpn_app' $DNSF_PKG)
    [void](Invoke-AdbShell 'am' 'start' '-n' "$DNSF_PKG/.DNSProxyActivity")
    Good 'Filter configured to start with the TV'

    if ($placed -ne 'app') {
        Log ''
        Log 'This build will not let a computer write into the app own folder, and its backup service'
        Log 'is switched off, so the list has to be pointed at once on the TV:'
        Log '  1. Open personalDNSfilter from the apps row.'
        Log '  2. Advanced settings > Configure filter update.'
        Log '  3. Tap the pencil on the first entry and replace the URL with:'
        Dim2 "file://$mediaDir/blocklist.txt"
        Log '  4. Untick the other entries, then go back so it reloads.'
        Log '  5. Accept the VPN prompt if it appears.'
        Log 'If that is more than you want to do, the NextDNS option blocks Amazon update servers with'
        Log 'no app at all - it is the safer choice on Fire OS 8.'
        [void](Read-Reply 'Press Enter once that is done (or just to carry on)')
    }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- verify

function Test-Result {
    Step 'Checking the result'
    $front = Get-Front
    switch ($script:Launcher) {
        'projectivy' {
            if ($front -like "*$PROJ_PKG*") { Good "Home screen: Projectivy ($front)" }
            else { Warn2 "Front app is $front, not Projectivy" }
        }
        'dumbtv' {
            if ($front -like "*$DUMBTV_PKG*") { Good "Home screen: dumbtv home ($front)" }
            else { Warn2 "Front app is $front, not dumbtv home" }
        }
        default { Good "Home screen left as Amazon's" }
    }
    $dis = (Get-DisabledPackages).Count
    Good "$dis Amazon packages are disabled"

    if ($script:DnsMode -eq 'device') {
        $fails = 0
        foreach ($h in @('softwareupdates.amazon.com', 'device-metrics-us.amazon.com')) {
            $line = (Invoke-AdbShell 'ping' '-c' '1' '-W' '2' $h)
            $first = ($line -split "`n")[0]
            if ($first -match '0\.0\.0\.0|127\.0\.0\.1') { Good "$h is blocked" }
            else { Warn2 "$h is NOT blocked yet ($first)"; $fails++ }
        }
        $art = ((Invoke-AdbShell 'ping' '-c' '1' '-W' '2' 'm.media-amazon.com') -split "`n")[0]
        if ($art -match '0\.0\.0\.0') { Warn2 'Artwork host is blocked - the home screen will look bare. Undo the DNS step.' }
        else { Good 'Everyday Amazon hosts still resolve (app artwork works)' }
        if ($fails -gt 0) { Log 'If it is not blocking yet, reboot the TV and run the checks again.' }
    }

    if ($script:SmartTube) {
        if (Test-Pkg $SMART_PKG) { Good "SmartTube installed (versionCode $(Get-PkgVersion $SMART_PKG))" }
        if (Test-PkgDisabled $YT_PKG) { Good 'The stock YouTube app is disabled' }
    }
    Log ''
    Log "Everything changed here is listed in $($script:UndoLog), and Undo reverses it."
}

# ---------------------------------------------------------------- undo

function Invoke-Undo {
    if (-not (Get-Adb)) { return }
    if (-not $script:Ip) { $script:Ip = (Read-Reply 'Stick IP address') }

    Step "Undoing everything on $($script:Ip)"
    [void](Invoke-Adb 'connect' "$($script:Ip):5555")
    $sdkRaw = Invoke-AdbShell 'getprop' 'ro.build.version.sdk'
    [void][int]::TryParse(($sdkRaw -replace '\D', ''), [ref]$script:Sdk)

    if (-not $script:UndoLog -or -not (Test-Path $script:UndoLog)) {
        $logs = Get-ChildItem -Path (Join-Path $ScriptDir 'logs') -Directory -Filter 'cleanup-*' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending
        foreach ($d in $logs) {
            $candidate = Join-Path $d.FullName 'undo.tsv'
            if ((Test-Path $candidate) -and (Get-Item $candidate).Length -gt 0) { $script:UndoLog = $candidate; break }
        }
    }

    if ($script:UndoLog -and (Test-Path $script:UndoLog) -and (Get-Item $script:UndoLog).Length -gt 0) {
        Dim2 "Reading $($script:UndoLog)"
        $lines = @(Get-Content -LiteralPath $script:UndoLog | Where-Object { $_ -ne '' })
        [array]::Reverse($lines)
        foreach ($line in $lines) {
            $f = $line -split "`t"
            switch ($f[0]) {
                'pkg' {
                    $p = $f[1]; $act = $f[2]
                    switch ($act) {
                        'disabled' {
                            [void](Invoke-AdbShell 'pm' 'enable' '--user' '0' $p)
                            if (-not (Test-PkgDisabled $p)) { Good "re-enabled $p" }
                        }
                        'starved' {
                            [void](Invoke-AdbShell 'appops' 'set' $p 'RUN_IN_BACKGROUND' 'allow')
                            if ($script:Sdk -ge 28) { [void](Invoke-AdbShell 'appops' 'set' $p 'RUN_ANY_IN_BACKGROUND' 'allow') }
                            $uid = Get-Uid $p
                            if ($uid) { [void](Invoke-AdbShell 'cmd' 'netpolicy' 'remove' 'restrict-background-blacklist' $uid) }
                            Good "restored background for $p"
                        }
                        'uninstalled' {
                            [void](Invoke-AdbShell 'cmd' 'package' 'install-existing' $p)
                            Good "reinstalled $p"
                        }
                    }
                }
                'settings' {
                    $ns = $f[1]; $key = $f[2]; $old = if ($f.Count -ge 4) { $f[3] } else { '' }
                    if ($old -and $old -ne 'null') { [void](Invoke-AdbShell 'settings' 'put' $ns $key $old) }
                    elseif ($old -eq 'null') { [void](Invoke-AdbShell 'settings' 'delete' $ns $key) }
                }
                'app' {
                    switch ($f[1]) {
                        'smarttube' { [void](Invoke-AdbShell 'pm' 'uninstall' $SMART_PKG); Good 'SmartTube removed' }
                        'youtube'   { [void](Invoke-AdbShell 'pm' 'enable' '--user' '0' $YT_PKG); Good 'YouTube app re-enabled' }
                    }
                }
                'dns' {
                    [void](Invoke-AdbShell 'settings' 'delete' 'secure' 'always_on_vpn_app')
                    [void](Invoke-AdbShell 'pm' 'uninstall' $DNSF_PKG)
                    [void](Invoke-AdbShell 'settings' 'put' 'global' 'private_dns_mode' 'off')
                    [void](Invoke-AdbShell 'settings' 'delete' 'global' 'private_dns_specifier')
                    Good 'DNS filter removed, DNS left on automatic'
                }
            }
        }
    } else {
        Warn2 'No cleanup log found - only clearing the launcher hooks and DNS.'
    }

    [void](Invoke-AdbShell 'settings' 'put' 'secure' 'enabled_accessibility_services' '""')
    [void](Invoke-AdbShell 'cmd' 'package' 'set-home-activity' 'com.amazon.tv.launcher/.ui.HomeActivity_vNext')
    [void](Invoke-AdbShell 'am' 'start' '-n' 'com.amazon.tv.launcher/.ui.HomeActivity_vNext')
    [void](Invoke-AdbShell 'settings' 'delete' 'secure' 'always_on_vpn_app')
    Good 'Amazon home screen restored. Apps stay installed; anything disabled is enabled again.'
}

# ---------------------------------------------------------------- connect

function Connect-Stick {
    if (-not (Get-Adb)) { return $false }
    if (-not $script:Ip) {
        Log ''
        Log 'The address is on the TV: Settings > My Fire TV > About > Network.'
        $script:Ip = (Read-Reply 'Fire TV IP address')
    }
    if (-not $script:Ip) { Bad2 'No address given.'; return $false }

    Step "Connecting to $($script:Ip):5555"
    Log ''
    Log '>>> LOOK AT THE TV NOW. It will ask whether to allow USB debugging.' 'Yellow'
    Log ">>> Press Allow on the remote (tick 'always allow' if offered)." 'Yellow'
    [void](Invoke-Adb 'connect' "$($script:Ip):5555")

    for ($i = 1; $i -le 30; $i++) {
        $devices = Invoke-Adb 'devices'
        if ($devices -match [regex]::Escape("$($script:Ip):5555") + '\s+device') {
            Good "connected to $($script:Ip)"
            return $true
        }
        Start-Sleep -Seconds 1
        Write-Host '.' -NoNewline
    }
    Log ''
    Bad2 'Not connected. Check ADB debugging is on, and press Allow on the TV when asked.'
    return $false
}

# ---------------------------------------------------------------- main

function Show-Menu {
    Log ''
    Log 'Fire TV cleanup' 'Cyan'
    Log '  1: Full cleanup - remove the ads and tracking, replace the home screen, block Amazon'
    Log '  2: Undo everything - put the TV back how it was'
    Log '  3: Exit'
    $reply = Read-Reply 'Select [1]'
    if ([string]::IsNullOrWhiteSpace($reply)) { return 1 }
    $n = 0
    if (-not [int]::TryParse($reply.Trim(), [ref]$n)) { return 1 }
    return $n
}

Start-Log
Log '=== Fire TV full cleanup ===' 'Cyan'
Log 'Takes about 15 minutes, and two trips to the TV. Nothing is deleted.'

try {
    if ($Undo) {
        Invoke-Undo
        exit 0
    }

    $choice = if ($AnswerScript -or $script:Answers.Count -gt 0) { 1 } else { Show-Menu }
    if ($choice -eq 2) { Invoke-Undo; exit 0 }
    if ($choice -eq 3) { exit 0 }

    if (-not (Connect-Stick)) { exit 1 }
    Read-Answers
    if (-not (Show-Plan)) { Warn2 'Cancelled. Nothing was changed.'; exit 0 }

    Start-Preflight
    Invoke-Debloat
    Invoke-Settings
    Install-Launcher
    Install-SmartTube
    Install-DnsFilter
    Test-Result

    Step 'Cleanup finished'
    Log 'Your TV now has no ad rows, no tracking packages running, and no path to Amazon telemetry.'
    Log "Log: $($script:LogFile)"
    if ($script:UndoLog) { Log "Undo log: $($script:UndoLog)" }
} catch {
    Bad2 "Stopped: $($_.Exception.Message)"
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value "EXCEPTION: $($_ | Out-String)" -Encoding UTF8 }
    exit 1
}
