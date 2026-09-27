<#
    Install-Projectivy.ps1  -  click-through wizard
    Replaces the Amazon Fire TV home screen with Projectivy Launcher on a Fire TV Stick (Fire OS 7/8),
    then optionally points the stick at a DNS profile so Amazon's automatic updates stop arriving.

    For anyone who does not want to touch a command line. Double-click Install-Projectivy.cmd instead
    of running this directly, so the execution policy is bypassed for this one script.

    Non-interactive equivalent with the same logic: setup-firestick.ps1
    Full write-up and the "why": README.md in this folder.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ErrorActionPreference = 'Stop'

$PROJ_PKG = 'com.spocky.projengmenu'
$PROJ_SVC = 'com.spocky.projengmenu/com.spocky.projengmenu.services.ProjectivyAccessibilityService'
$PROJ_URL = 'https://github.com/spocky/miproja1/releases/download/4.71/ProjectivyLauncher-4.71-c95-xda-release.apk'
$HOF_PKG  = 'io.github.toolicious.homeonfire'
$HOF_URL  = 'https://github.com/toolicious/home-on-fire/releases/latest/download/home-on-fire.apk'
$PT_URL   = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'

# AdGuard DNS: free, no account, blocks ads and trackers. It does NOT block Amazon's update servers,
# so it is offered as "ad blocking" only - NextDNS with a denylist is the one that stops updates.
$ADGUARD_DOT   = 'dns.adguard-dns.com'
$ADGUARD_PLAIN = '94.140.14.14,94.140.14.15'
# Cloudflare: no account, fast and private, but it blocks nothing - Amazon's updates still arrive.
$CLOUDFLARE_DOT = '1dot1dot1dot1.cloudflare-dns.com'

$OTA_HOSTS = @(
    'softwareupdates.amazon.com'
    'updates.amazon.com'
    'prod.ota-cloudfront.net'
    'd1s31zyz7dcc2d.cloudfront.net'
    'd1s31zyz7dcc2d.cloudfront.prod.ota-cloudfront.net'
    'amzdigital-a.akamaihd.net'
    'amzdigitaldownloads.edgesuite.net'
)

$script:Adb  = $null
$script:Ip   = ''
$script:Fail = ''
$script:DnsApplied = ''

# ---------------------------------------------------------------- logging
# A log file is always written next to the script: when something goes wrong on someone else's laptop,
# "send me the log" is the only practical support route. Nothing sensitive beyond the stick IP.
$script:LogFile = $null

function Start-Log {
    $dir = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'logs' } else { Join-Path $env:TEMP 'install-projectivy-logs' }
    try {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    } catch { $dir = $env:TEMP }
    $script:LogFile = Join-Path $dir ("install-projectivy-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    try {
        @(
            '=== Projectivy Launcher setup wizard log ==='
            "started : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "host    : $env:COMPUTERNAME   user: $env:USERNAME"
            "windows : $([System.Environment]::OSVersion.VersionString)"
            "powershell: $($PSVersionTable.PSVersion)"
            "payload : $PROJ_URL"
            '============================================'
        ) -join "`r`n" | Out-File -FilePath $script:LogFile -Encoding UTF8 -Append
    } catch { $script:LogFile = $null }
}

function Write-LogFile {
    param([string]$Text)
    if (-not $script:LogFile) { return }
    try { "$(Get-Date -Format 'HH:mm:ss') $Text" | Out-File -FilePath $script:LogFile -Encoding UTF8 -Append } catch { }
}

# ---------------------------------------------------------------- helpers
function Log {
    param([string]$Text, [string]$Colour = 'Black')
    $log.SelectionStart = $log.TextLength
    $log.SelectionLength = 0
    $log.SelectionColor = [System.Drawing.Color]::FromName($Colour)
    $log.AppendText("$Text`r`n")
    $log.SelectionStart = $log.TextLength
    $log.ScrollToCaret()
    $form.Refresh()
    Write-LogFile $Text
}

function Set-Text {
    param([string]$Title, [string]$Body)
    $lblTitle.Text = $Title
    $lblBody.Text  = $Body
    $form.Refresh()
}

function Invoke-Adb {
    param([string[]]$Arguments)
    $out = & $script:Adb @Arguments 2>&1
    $text = (($out | Out-String).Trim())
    Write-LogFile ("ADB {0}`r`n{1}" -f ($Arguments -join ' '), $text)
    return $text
}

function Get-Adb {
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
        (Join-Path $env:USERPROFILE 'Downloads\platform-tools\adb.exe'),
        (Join-Path $env:TEMP 'platform-tools\adb.exe'),
        (Join-Path $PSScriptRoot 'platform-tools\adb.exe'))) {
        if (Test-Path $p) { return $p }
    }
    Log 'Android platform-tools not found - downloading (~15 MB, one time)...' 'DarkOrange'
    $zip = Join-Path $env:TEMP 'platform-tools.zip'
    Invoke-WebRequest -Uri $PT_URL -OutFile $zip -UseBasicParsing
    $dest = Join-Path $env:TEMP 'platform-tools'
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $env:TEMP -Force
    $exe = Join-Path $dest 'adb.exe'
    if (-not (Test-Path $exe)) { throw 'platform-tools download did not produce adb.exe' }
    Log 'platform-tools installed.' 'Green'
    return $exe
}

function Get-LocalSubnet {
    try {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 |
               Where-Object { $_.IPAddress -notmatch '^(127|169\.254)\.' -and $_.PrefixOrigin -ne 'WellKnown' } |
               Select-Object -First 1).IPAddress
        if ($ip) { return ($ip -replace '\.\d+$', '.') }
    } catch { }
    return $null
}

function Find-FireTv {
    $base = Get-LocalSubnet
    if (-not $base) { return @() }
    Log "Scanning ${base}1-254 for a device listening on port 5555..." 'DarkOrange'
    $jobs = @()
    foreach ($n in 1..254) {
        $h = "$base$n"
        try {
            $c = New-Object System.Net.Sockets.TcpClient
            $t = $c.ConnectAsync($h, 5555)
            $jobs += [pscustomobject]@{ Ip = $h; Client = $c; Task = $t }
        } catch { }
    }
    Start-Sleep -Milliseconds 1500
    $found = @()
    foreach ($j in $jobs) {
        try { if ($j.Client.Connected) { $found += $j.Ip } } catch { }
        try { $j.Client.Close() } catch { }
    }
    return $found
}

# ---------------------------------------------------------------- stages
function Show-Stage {
    param([string]$Stage)

    $txtIp.Visible    = $false
    $txtDns.Visible   = $false
    $btnPrimary.Visible = $true
    $btnSecond.Visible  = $false
    $btnThird.Visible   = $false
    $btnFourth.Visible  = $false

    switch ($Stage) {

        'welcome' {
            Set-Text 'Projectivy Launcher - setup wizard' @"
This removes the ads from an Amazon Fire TV Stick by making Projectivy Launcher the home screen, and
optionally stops Amazon from pushing updates that would undo it.

It takes about 15 minutes and two trips to the TV. Nothing is deleted and there is an Undo button at
the end, so it is safe to try.

WHAT YOU NEED
  1. The Fire TV Stick plugged in and connected to the same wi-fi as this laptop.
  2. The remote, to press buttons on the TV when asked.
  3. Permission to unplug the stick's power for 30 seconds later on.
  4. Optional, for the update-blocking step: a free account at nextdns.io (2 minutes to set up).

Click Start, and follow the prompts on this screen and on the TV.
"@
            $btnPrimary.Text = 'Start'
            $btnPrimary.Tag = 'prepare'
            $btnSecond.Visible = $true
            $btnSecond.Text = 'Undo / restore Amazon home screen'
            $btnSecond.Tag = 'undo'
        }

        'prepare' {
            Set-Text 'Step 1 of 6 - get the stick ready' @"
On the TV, using the remote:

  1. Settings > My Fire TV > About > click the device name 7 times (says 'you are already a developer').
  2. Back > Developer Options > turn ON 'ADB debugging'.
  3. In Developer Options turn ON 'Apps from Unknown Sources'.
  4. From the Fire TV home screen search, install the app called 'Downloader' (by AFTVnews).

INSTALLING PROJECTIVY - either way works:

  a) LET THIS WIZARD DO IT. It offers to download and install Projectivy for you over the network - no
     typing on the TV at all. That is the easier option.

  b) IN DOWNLOADER on the TV: paste the long address into its address bar, or type one of these short
     codes (address bar, or tap the '#' key for a number pad):

         1198422   Projectivy Launcher APK (direct)
         250931    TROYPOINT Toolbox  - Projectivy plus other tools, one menu
         730116    FireStickHacks downloads page
         2571389   Simturax app centre

     Short codes get retired over time. The long address always works:

$PROJ_URL

Leave the TV switched on and on its home screen - you will need to approve a prompt on it shortly.
"@
            $btnPrimary.Text = 'Done - find my stick'
            $btnPrimary.Tag = 'find'
        }

        'connect' {
            Set-Text 'Step 2 of 6 - connect to the stick' @"
The stick's IP address is on the TV under Settings > My Fire TV > About > Network.

If you know it, type it below. If not, press 'Scan my network' and pick the address it finds.
"@
            $txtIp.Visible = $true
            $btnPrimary.Text = 'Connect'
            $btnPrimary.Tag = 'connect'
            $btnSecond.Visible = $true
            $btnSecond.Text = 'Scan my network'
            $btnSecond.Tag = 'scan'
        }

        'authorise' {
            Set-Text 'Step 3 of 6 - look at the TV now' @"
A message should appear on the TV asking whether to allow USB debugging.

Press 'Allow' (tick 'always allow' if it is offered).

If nothing appears, press the Home button on the remote once and wait - the prompt usually follows.
Then press Retry.
"@
            $btnPrimary.Text = 'Retry'
            $btnPrimary.Tag = 'connect'
            $btnSecond.Visible = $true
            $btnSecond.Text = 'Back to address'
            $btnSecond.Tag = 'connect'
            $btnThird.Visible = $true
            $btnThird.Text = 'Exit'
            $btnThird.Tag = 'exit'
        }

        'coldboot' {
            Set-Text 'Step 4 of 6 - the reboot test' @"
Everything is applied. Now the real test - the settings must survive a power cycle.

  1. Unplug the stick's power (or the TV's, if that is easier).
  2. Wait a full 30 seconds.
  3. Plug it back in and let it start up completely.
  4. When the home screen has finished loading, press Continue.

Do not skip this. Amazon re-checks the home screen on boot, and this is where a setup that looks fine
usually breaks.
"@
            $btnPrimary.Text = 'Continue - check the result'
            $btnPrimary.Tag = 'verify'
        }

        'fallback' {
            Set-Text 'Step 5 of 6 - needs the fallback' @"
The check did not pass: the stick came back to Amazon's home screen instead of Projectivy.

That happens on newer Fire OS builds. There is a second, newer tool for exactly this - 'Home on Fire' -
which redirects the Home button instead of overriding the launcher. Click below and it will set it up
and open the app on the TV, then follow the three instructions that appear in the log.
"@
            $btnPrimary.Text = 'Install Home on Fire'
            $btnPrimary.Tag = 'hof'
            $btnSecond.Visible = $true
            $btnSecond.Text = 'Retry the check'
            $btnSecond.Tag = 'verify'
        }

        'hofdone' {
            Set-Text 'Home on Fire - finish on the TV' @"
In the app now open on the TV:

  1. Turn the 'Accessibility service' switch ON.
  2. Choose target app > Projectivy Launcher.
  3. Turn on 'Launch on boot' / 'launch when device wakes up'.

Then in Projectivy: Settings > General > 'Override current launcher' = OFF.
Only one of the two should be active - they fight each other if both are on.

When that is done, press the button to run the check again.
"@
            $btnPrimary.Text = 'Check again'
            $btnPrimary.Tag = 'verify'
        }

        'dns' {
            Set-Text 'Step 6 of 6 - optional: stop Amazon pushing updates over it' @"
Amazon can reset all of this with an automatic update. Blocking it means pointing the stick at a DNS
profile - optional, and worth it.

FIRST, THE WARNING: if any streaming app (Netflix, Plex, iPlayer) misbehaves after this step, undo the
DNS setting before anything else - it is the most likely cause and one click to reverse.

  1. NextDNS (RECOMMENDED, free account) - blocks Amazon's update addresses:
       - my.nextdns.io > create a profile > Denylist tab > add these:

$($OTA_HOSTS | ForEach-Object { "         $_" } | Out-String)
       - Setup tab > copy the DNS-over-TLS address (like abcd1234.dns.nextdns.io) > paste below > Apply

  2. Cloudflare - fast and private, NO account, but blocks nothing. Updates still arrive.
  3. AdGuard - blocks ads and trackers, no account. Does not block Amazon's updates.

Whichever you choose: if the stick ever returns to Amazon's home screen, re-run this wizard. Amazon's
updates can clear the launcher settings, and re-running fixes it - nothing needs reinstalling.
"@
            $txtDns.Visible = $true
            $btnPrimary.Text = 'Apply NextDNS profile'
            $btnPrimary.Tag = 'dnsdot'
            $btnSecond.Visible = $true
            $btnSecond.Text = 'Cloudflare'
            $btnSecond.Tag = 'dnscloudflare'
            $btnThird.Visible = $true
            $btnThird.Text = 'AdGuard'
            $btnThird.Tag = 'dnsadguard'
            $btnFourth.Visible = $true
            $btnFourth.Text = 'Skip'
            $btnFourth.Tag = 'done'
        }

        'dnsdone' {
            if ($script:DnsApplied -eq 'cloudflare' -or $script:DnsApplied -eq 'adguard-plain') {
                $extra = "`r`n`r`nNOTE: this profile does not block Amazon's update addresses, so updates will still arrive.`r`n"
            } elseif ($script:DnsApplied -eq 'adguard') {
                $extra = "`r`n`r`nNOTE: AdGuard blocks ads and trackers but not Amazon's update addresses, so updates will still arrive.`r`n"
            } else {
                $extra = ''
            }
            Set-Text 'DNS is set' @"
Names now resolve through the profile you chose, and this is what would stop the update downloads.

To check it on the TV: Settings > My Fire TV > check for updates. It should fail with a connection error
- that is the desired result. (If it does not fail, the denylist in NextDNS is missing entries.)

IF A STREAMING APP MISBEHAVES from here on: click 'Remove the DNS setting' below first, and see whether
that fixes it, before anything else.
$extra
One more thing: if the stick ever comes back to Amazon's home screen, re-run this wizard. An update
that gets through can clear the launcher settings - nothing needs reinstalling, the apps stay put.
"@
            $btnPrimary.Text = 'Finish'
            $btnPrimary.Tag = 'done'
            $btnSecond.Visible = $true
            $btnSecond.Text = 'Remove the DNS setting'
            $btnSecond.Tag = 'dnsoff'
        }

        'done' {
            Set-Text 'Finished' @"
Verified: the stick boots to Projectivy and the Home button returns to it.

To go back to Amazon's home screen at any time, press the Undo button below (or hold the Home button on
the remote on a Home on Fire setup). Undo also removes any DNS setting this wizard made.

KEEP THIS IN MIND: Amazon's updates can sometimes clear the launcher settings, and the stick will go back
to its ad-filled home screen. If that happens, just run this wizard again - the apps are still installed,
so it is a 30-second job, not a reinstall.
"@
            $btnPrimary.Text = 'Close'
            $btnPrimary.Tag = 'exit'
            $btnSecond.Visible = $true
            $btnSecond.Text = 'Undo / restore Amazon home screen'
            $btnSecond.Tag = 'undo'
        }
    }
    $form.Refresh()
}

# ---------------------------------------------------------------- actions
function Do-Connect {
    $target = $txtIp.Text.Trim()
    if ($target -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        [System.Windows.Forms.MessageBox]::Show("Enter the stick IP address like 192.168.1.100`r`n`r`nIt is on the TV under Settings > My Fire TV > About > Network.",'That is not a valid address') | Out-Null
        return $false
    }
    $script:Ip = $target

    try { $script:Adb = Get-Adb } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not find or download adb: $($_.Exception.Message)",'adb problem') | Out-Null
        return $false
    }

    # Say what is happening BEFORE the wait - this is the step where people think it has frozen.
    Set-Text "Step 3 of 6 - connecting to $target" @"
LOOK AT THE TV NOW.

A message will appear on it asking whether to allow USB debugging. Press 'Allow' on the remote (tick
'always allow' if it is offered).

Nothing appearing? Press the Home button on the remote once and wait a few seconds - the prompt usually
follows.

This window will keep trying and the log below shows progress. It is not frozen.
"@

    Log "Connecting to ${target}:5555 ..."
    $c = Invoke-Adb @('connect', "${target}:5555")
    Log $c 'Gray'

    $unauthed = $false
    for ($i = 1; $i -le 30; $i++) {
        $list = Invoke-Adb @('devices')
        if ($list -match [regex]::Escape("${target}:5555") + '\s+device') {
            Log "Connected to $target." 'Green'
            return $true
        }
        if ($list -match [regex]::Escape("${target}:5555") + '\s+unauthorized') { $unauthed = $true }
        Log "  waiting for the TV to allow the connection ... ($i/30)" 'DarkOrange'
        Start-Sleep -Seconds 1
        $form.Refresh()
    }

    if ($unauthed) { Log 'The TV has not been allowed yet - press Allow on the remote, then Retry.' 'DarkOrange' }
    else { Log "No answer from ${target}:5555. Check ADB debugging is ON and that this laptop is on the same wi-fi." 'Firebrick' }
    return $false
}

function Do-Find {
    try { $script:Adb = Get-Adb } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not find or download adb: $($_.Exception.Message)",'adb problem') | Out-Null
        return 'connect'
    }
    $found = @(Find-FireTv)
    if ($found.Count -eq 0) {
        Log 'No Fire TV found on this network. Type the address in by hand.' 'Firebrick'
        return 'connect'
    }
    if ($found.Count -eq 1) {
        $txtIp.Text = $found[0]
        Log "Found $($found[0])." 'Green'
        return 'connect'
    }
    $pick = [System.Windows.Forms.MessageBox]::Show("Found more than one device: $($found -join ', ').`r`n`r`nUse the first one?",'Several devices','YesNo')
    $txtIp.Text = $found[0]
    if ($pick -eq 'No') { Log "Found: $($found -join ', ')" 'DarkOrange' }
    return 'connect'
}

function Do-Apply {
    # guard: refuse Vega OS outright
    $name = Invoke-Adb @('shell','getprop','ro.build.version.name')
    $os   = Invoke-Adb @('shell','getprop','ro.build.version.fireos')
    Log "Fire OS $os ($name)"
    if ("$name $os" -match 'Vega') {
        [System.Windows.Forms.MessageBox]::Show('This device runs Vega OS, which cannot sideload apps or use a custom launcher. Nothing can be changed here.','Vega OS - not supported') | Out-Null
        return 'exit'
    }
    if ($os -and $os -notmatch '^(7|8)') { Log "Note: Fire OS $os is untested; the hooks may not take." 'DarkOrange' }

    $pkgs = Invoke-Adb @('shell','pm','list','packages')
    if ($pkgs -notmatch [regex]::Escape($PROJ_PKG)) {
        Log 'Projectivy Launcher is not installed on the stick yet.' 'DarkOrange'
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "Projectivy is not on the TV yet.`r`n`r`nInstall it now, over the network, from this laptop? (recommended - nothing to type on the TV)`r`n`r`nChoose No to install it on the TV with Downloader instead.",
            'Install Projectivy now?', 'YesNo', 'Question')
        if ($choice -eq 'Yes') {
            try {
                Log 'Downloading Projectivy 4.71 (~11 MB)...'
                $apk = Join-Path $env:TEMP 'projectivy.apk'
                Invoke-WebRequest -Uri $PROJ_URL -OutFile $apk -UseBasicParsing
                Log 'Installing on the stick...'
                Log (Invoke-Adb @('install','-r',$apk)) 'Gray'
                $pkgs = Invoke-Adb @('shell','pm','list','packages')
                if ($pkgs -match [regex]::Escape($PROJ_PKG)) { Log 'Projectivy installed.' 'Green' }
                else {
                    Log 'It did not install - the TV may be showing a blocked-install prompt.' 'Firebrick'
                    [System.Windows.Forms.MessageBox]::Show("Projectivy did not install. Check the TV screen for a prompt, then press Retry on the previous screen.",'Install failed') | Out-Null
                    return 'prepare'
                }
            } catch {
                Log "Download/install failed: $($_.Exception.Message)" 'Firebrick'
                [System.Windows.Forms.MessageBox]::Show("Could not install it automatically: $($_.Exception.Message)`r`n`r`nInstall it on the TV with Downloader instead - code 1198422, or the long address in the previous step.",'Install failed') | Out-Null
                return 'prepare'
            }
        } else {
            [System.Windows.Forms.MessageBox]::Show("On the TV, open Downloader and enter this code:`r`n`r`n    1198422`r`n`r`nOther working codes: 250931 (TROYPOINT Toolbox), 730116 (FireStickHacks), 2571389 (Simturax).`r`n`r`nOr paste the long address from the previous screen. Install it, then continue here.",'Install Projectivy on the TV with Downloader') | Out-Null
            $pkgs = Invoke-Adb @('shell','pm','list','packages')
            if ($pkgs -notmatch [regex]::Escape($PROJ_PKG)) {
                Log 'Still not seeing Projectivy on the stick.' 'Firebrick'
                return 'prepare'
            }
            Log 'Projectivy found on the stick.' 'Green'
        }
    }
    else { Log 'Projectivy found on the stick.' 'Green' }

    Log 'Applying permissions...'
    Invoke-Adb @('shell','appops','set',$PROJ_PKG,'SYSTEM_ALERT_WINDOW','allow')          | Out-Null
    Invoke-Adb @('shell','dumpsys','deviceidle','whitelist',"+$PROJ_PKG")                | Out-Null
    Invoke-Adb @('shell','settings','put','secure','enabled_accessibility_services',$PROJ_SVC) | Out-Null

    $on = Invoke-Adb @('shell','settings','get','secure','enabled_accessibility_services')
    if ($on -match 'ProjectivyAccessibilityService') { Log 'Accessibility service registered.' 'Green' }
    else { Log "Could not register the accessibility service (got: $on)" 'Firebrick' }

    [System.Windows.Forms.MessageBox]::Show("On the TV now:`r`n`r`n1. Open Projectivy Launcher (or hold the select/OK button on the remote for a moment to open its settings directly).`r`n2. Settings > General.`r`n3. Turn ON 'Override current launcher'.`r`n`r`nThat switch lives inside Projectivy's own settings, so it cannot be set from here - it is the one step that needs the remote, and it takes about 20 seconds.`r`n`r`nThen press OK here.",'Two taps on the TV - cannot be automated') | Out-Null
    return 'coldboot'
}

function Do-Verify {
    Log 'Checking the result...'
    $on    = Invoke-Adb @('shell','settings','get','secure','enabled_accessibility_services')
    $focus = Invoke-Adb @('shell','dumpsys','window') | Select-String 'mCurrentFocus'
    $focus = if ($focus) { $focus.ToString().Trim() } else { '' }
    Log "accessibility : $on"
    Log "on screen     : $focus"

    $script:Fail = ''
    if ($on -notmatch 'ProjectivyAccessibilityService') { $script:Fail = 'the accessibility hook was reset on boot' }
    elseif ($focus -notmatch 'com.spocky.projengmenu')   { $script:Fail = 'the stick is showing Amazon home instead of Projectivy' }

    if (-not $script:Fail) {
        Log 'PASS - the stick boots to Projectivy.' 'Green'
        return 'dns'
    }
    Log "FAIL - $($script:Fail)." 'Firebrick'
    return 'fallback'
}

function Do-Hof {
    try {
        Log 'Downloading Home on Fire...'
        $apk = Join-Path $env:TEMP 'home-on-fire.apk'
        Invoke-WebRequest -Uri $HOF_URL -OutFile $apk -UseBasicParsing
        $install = Invoke-Adb @('install','-r',$apk)
        Log $install 'Gray'
        Invoke-Adb @('shell','pm','grant',$HOF_PKG,'android.permission.WRITE_SECURE_SETTINGS') | Out-Null
        $dump = Invoke-Adb @('shell','dumpsys','package',$HOF_PKG)
        if ($dump -match 'WRITE_SECURE_SETTINGS: granted=true') { Log 'Permission granted.' 'Green' }
        else { Log 'Permission grant not confirmed - the accessibility switch in the app may refuse.' 'DarkOrange' }
        Invoke-Adb @('shell','am','start','-n',"$HOF_PKG/.MainActivity") | Out-Null
        Log 'Home on Fire installed and opened on the TV.' 'Green'
    } catch {
        Log "Install failed: $($_.Exception.Message)" 'Firebrick'
        [System.Windows.Forms.MessageBox]::Show("Home on Fire could not be installed:`r`n$($_.Exception.Message)",'Install failed') | Out-Null
        return 'fallback'
    }
    return 'hofdone'
}

function Set-DnsDot {
    param([string]$Host_, [switch]$NoBlockWarning)
    Invoke-Adb @('shell','settings','put','global','private_dns_mode','hostname')   | Out-Null
    Invoke-Adb @('shell','settings','put','global','private_dns_specifier',$Host_) | Out-Null
    $mode = Invoke-Adb @('shell','settings','get','global','private_dns_mode')
    $spec = Invoke-Adb @('shell','settings','get','global','private_dns_specifier')
    Log "private_dns_mode      : $mode"
    Log "private_dns_specifier : $spec"
    if ($mode -match 'hostname' -and $spec -match [regex]::Escape($Host_)) {
        Log "DNS set to $Host_ ." 'Green'
        $script:DnsApplied = $Host_
    } else {
        Log 'The stick did not accept the DNS setting.' 'Firebrick'
        return $false
    }

    # advisory only - empty output means it is resolving, an unknown-host error means it is blocked
    Log 'Testing whether the update address still resolves (advisory)...'
    $ping = Invoke-Adb @('shell','ping','-c','1','-w','3','softwareupdates.amazon.com')
    if ($ping -match 'unknown host|bad address|Name or service|No address associated|0\.0\.0\.0') {
        Log 'softwareupdates.amazon.com does not resolve - updates are blocked.' 'Green'
    } elseif ($ping -match 'bytes from') {
        if ($NoBlockWarning) {
            Log 'Amazon update addresses still resolve - expected for this option, it blocks nothing.' 'DarkOrange'
        } else {
            Log 'softwareupdates.amazon.com STILL resolves - this profile does not block it. Check the denylist in NextDNS.' 'Firebrick'
        }
    } else {
        Log "Could not test it automatically. Output was: $ping" 'DarkOrange'
    }
    return $true
}

function Do-DnsDot {
    $h = $txtDns.Text.Trim()
    if ($h -notmatch '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') {
        [System.Windows.Forms.MessageBox]::Show("Paste the DNS-over-TLS address exactly as NextDNS shows it, for example:`r`n`r`nabcd1234.dns.nextdns.io",'That does not look like a DNS address') | Out-Null
        return 'dns'
    }
    if (Set-DnsDot $h) { return 'dnsdone' }
    return 'dns'
}

function Do-DnsAdguard {
    Log 'Setting AdGuard DNS (ad and tracker blocking - does not stop Amazon updates).'
    if (Set-DnsDot $ADGUARD_DOT -NoBlockWarning) { return 'dnsdone' }
    Log 'Trying plain AdGuard DNS addresses instead...' 'DarkOrange'
    Invoke-Adb @('shell','settings','put','global','dns_servers',$ADGUARD_PLAIN) | Out-Null
    $s = Invoke-Adb @('shell','settings','get','global','dns_servers')
    Log "dns_servers : $s"
    $script:DnsApplied = 'adguard-plain'
    return 'dnsdone'
}

function Do-DnsCloudflare {
    Log 'Setting Cloudflare DNS (fast and private, no account, blocks nothing).'
    if (Set-DnsDot $CLOUDFLARE_DOT -NoBlockWarning) {
        $script:DnsApplied = 'cloudflare'
        return 'dnsdone'
    }
    Log 'Trying plain Cloudflare addresses instead...' 'DarkOrange'
    Invoke-Adb @('shell','settings','put','global','dns_servers','1.1.1.1,1.0.0.1') | Out-Null
    Log "dns_servers : $(Invoke-Adb @('shell','settings','get','global','dns_servers'))"
    $script:DnsApplied = 'cloudflare'
    return 'dnsdone'
}

function Do-DnsOff {
    Log 'Removing the DNS settings...'
    Invoke-Adb @('shell','settings','put','global','private_dns_mode','off')                | Out-Null
    Invoke-Adb @('shell','settings','delete','global','private_dns_specifier')             | Out-Null
    Invoke-Adb @('shell','settings','delete','global','dns_servers')                       | Out-Null
    $mode = Invoke-Adb @('shell','settings','get','global','private_dns_mode')
    Log "private_dns_mode : $mode"
    Log 'DNS back to the network default - updates will reach the stick again.' 'Green'
    $script:DnsApplied = ''
    return 'done'
}

function Do-Undo {
    if (-not $script:Adb) { $script:Adb = Get-Adb }
    if (-not $script:Ip) {
        $txtIp.Visible = $true
        [System.Windows.Forms.MessageBox]::Show('Enter the stick IP address first, then press Undo again.','Need the address') | Out-Null
        return $false
    }
    Invoke-Adb @('connect', "$($script:Ip):5555") | Out-Null
    Log 'Restoring the Amazon home screen...'
    Invoke-Adb @('shell','settings','put','secure','enabled_accessibility_services','""') | Out-Null
    Invoke-Adb @('shell','appops','set',$PROJ_PKG,'SYSTEM_ALERT_WINDOW','default')      | Out-Null
    Invoke-Adb @('shell','dumpsys','deviceidle','whitelist',"-$PROJ_PKG")               | Out-Null
    Invoke-Adb @('shell','am','start','-n','com.amazon.tv.launcher/.ui.HomeActivity_vNext') | Out-Null
    Do-DnsOff | Out-Null
    Log 'Done - the stick is back on Amazon home. Apps are still installed.' 'Green'
    [System.Windows.Forms.MessageBox]::Show('Amazon home screen restored and DNS cleared. Projectivy is still installed; you can start the wizard again any time.','Undone') | Out-Null
    return $false
}

# ---------------------------------------------------------------- window
$form = New-Object System.Windows.Forms.Form
$form.Text          = 'Projectivy Launcher setup'
$form.Size          = New-Object System.Drawing.Size(780, 660)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize   = New-Object System.Drawing.Size(720, 600)
$form.TopMost       = $true

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Location = New-Object System.Drawing.Point(14, 12)
$lblTitle.Size     = New-Object System.Drawing.Size(736, 28)
$lblTitle.Font     = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblTitle)

$lblBody = New-Object System.Windows.Forms.Label
$lblBody.Location = New-Object System.Drawing.Point(14, 44)
$lblBody.Size     = New-Object System.Drawing.Size(736, 250)
$lblBody.Font     = New-Object System.Drawing.Font('Segoe UI', 9.5)
$form.Controls.Add($lblBody)

$txtIp = New-Object System.Windows.Forms.TextBox
$txtIp.Location = New-Object System.Drawing.Point(14, 300)
$txtIp.Size     = New-Object System.Drawing.Size(240, 26)
$txtIp.Font     = New-Object System.Drawing.Font('Consolas', 11)
$txtIp.Visible  = $false
$form.Controls.Add($txtIp)

$txtDns = New-Object System.Windows.Forms.TextBox
$txtDns.Location = New-Object System.Drawing.Point(14, 300)
$txtDns.Size     = New-Object System.Drawing.Size(360, 26)
$txtDns.Font     = New-Object System.Drawing.Font('Consolas', 11)
$txtDns.Visible  = $false
$form.Controls.Add($txtDns)

$log = New-Object System.Windows.Forms.TextBox
$log.Location   = New-Object System.Drawing.Point(14, 336)
$log.Size       = New-Object System.Drawing.Size(736, 250)
$log.Multiline  = $true
$log.ReadOnly   = $true
$log.ScrollBars = 'Vertical'
$log.BackColor  = [System.Drawing.Color]::White
$log.Font       = New-Object System.Drawing.Font('Consolas', 9)
$log.Anchor     = 'Top,Left,Right,Bottom'
$form.Controls.Add($log)

$btnPrimary = New-Object System.Windows.Forms.Button
$btnPrimary.Location = New-Object System.Drawing.Point(14, 598)
$btnPrimary.Size     = New-Object System.Drawing.Size(200, 34)
$btnPrimary.Anchor   = 'Bottom,Left'
$form.Controls.Add($btnPrimary)

$btnSecond = New-Object System.Windows.Forms.Button
$btnSecond.Location = New-Object System.Drawing.Point(224, 598)
$btnSecond.Size     = New-Object System.Drawing.Size(220, 34)
$btnSecond.Anchor   = 'Bottom,Left'
$form.Controls.Add($btnSecond)

$btnThird = New-Object System.Windows.Forms.Button
$btnThird.Location = New-Object System.Drawing.Point(454, 598)
$btnThird.Size     = New-Object System.Drawing.Size(150, 34)
$btnThird.Anchor   = 'Bottom,Left'
$form.Controls.Add($btnThird)

$btnFourth = New-Object System.Windows.Forms.Button
$btnFourth.Location = New-Object System.Drawing.Point(614, 598)
$btnFourth.Size     = New-Object System.Drawing.Size(136, 34)
$btnFourth.Anchor   = 'Bottom,Right'
$form.Controls.Add($btnFourth)

function Invoke-Action {
    param($Which)
    switch ($Which) {
        'prepare' { Show-Stage 'prepare' }
        'find'    { $next = Do-Find;    Show-Stage $next }
        'connect' {
            if (Do-Connect) {
                $next = Do-Apply
                Show-Stage $next
            } else {
                Show-Stage 'authorise'
            }
        }
        'verify'    { Show-Stage (Do-Verify) }
        'hof'       { Show-Stage (Do-Hof) }
        'dnsdot'    { Show-Stage (Do-DnsDot) }
        'dnscloudflare' { Show-Stage (Do-DnsCloudflare) }
        'dnsadguard'{ Show-Stage (Do-DnsAdguard) }
        'dnsoff'    { Show-Stage (Do-DnsOff) }
        'undo'      { Do-Undo | Out-Null }
        'exit'      { $form.Close() }
    }
}

$btnPrimary.Add_Click({ Invoke-Action $btnPrimary.Tag })
$btnSecond.Add_Click({  Invoke-Action $btnSecond.Tag })
$btnThird.Add_Click({   Invoke-Action $btnThird.Tag })
$btnFourth.Add_Click({  Invoke-Action $btnFourth.Tag })

Start-Log
Log "Projectivy setup wizard - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
if ($script:LogFile) { Log "Log file: $script:LogFile" }
Show-Stage 'welcome'

[void]$form.ShowDialog()
$form.Dispose()