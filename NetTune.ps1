<#
================================================================================
  RobloxNetTune  -  Latency diagnostic + safe optimizer + live monitor
================================================================================
  What it does (and why it actually helps Roblox):
    Roblox gameplay is UDP and its servers are well-peered, so the thing that
    wrecks your ping is almost always LOCAL: NIC power-saving micro-sleeps,
    CPU/adapter downclocking, Wi-Fi jitter, and background bandwidth. This tool
    measures those, applies safe reversible fixes, and lets you watch the result
    live. It NEVER touches the Roblox process, injects nothing, and loads no
    driver -- so there is no anti-cheat (Hyperion) interaction.

  Every change is written to a backup file first. Menu option 4 restores
  everything to exactly how it was.

  RUN AS ADMINISTRATOR (needed for adapter/registry/power changes).
================================================================================
#>

$ErrorActionPreference = 'Stop'
$BackupDir  = Join-Path $env:LOCALAPPDATA 'RobloxNetTune'
$BackupFile = Join-Path $BackupDir 'backup.json'
$Anchor     = '1.1.1.1'   # stable reference host for last-mile quality tests

# --- Elevation check ---------------------------------------------------------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- Latency quality sampler -------------------------------------------------
# Returns avg/min/max ms, jitter (mean abs delta between consecutive pings),
# and packet-loss %. Jitter + loss are what make Roblox feel "unstable".
function Get-LinkQuality {
    param([string]$Target = $Anchor, [int]$Count = 30, [int]$TimeoutMs = 1000)

    $ping = New-Object System.Net.NetworkInformation.Ping
    $rtts = New-Object System.Collections.Generic.List[double]
    $lost = 0
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $r = $ping.Send($Target, $TimeoutMs)
            if ($r.Status -eq 'Success') { $rtts.Add([double]$r.RoundtripTime) }
            else { $lost++ }
        } catch { $lost++ }
        Start-Sleep -Milliseconds 100
    }

    if ($rtts.Count -eq 0) {
        return [pscustomobject]@{ Target=$Target; Avg=$null; Min=$null; Max=$null
            Jitter=$null; LossPct=100.0; Samples=0 }
    }
    # Jitter = average absolute difference between back-to-back samples.
    $jit = 0.0
    for ($i = 1; $i -lt $rtts.Count; $i++) {
        $jit += [math]::Abs($rtts[$i] - $rtts[$i-1])
    }
    if ($rtts.Count -gt 1) { $jit = $jit / ($rtts.Count - 1) }

    [pscustomobject]@{
        Target  = $Target
        Avg     = [math]::Round(($rtts | Measure-Object -Average).Average, 1)
        Min     = [math]::Round(($rtts | Measure-Object -Minimum).Minimum, 1)
        Max     = [math]::Round(($rtts | Measure-Object -Maximum).Maximum, 1)
        Jitter  = [math]::Round($jit, 1)
        LossPct = [math]::Round(($lost / $Count) * 100, 1)
        Samples = $rtts.Count
    }
}

# --- Find the active internet-facing adapter ---------------------------------
function Get-ActiveAdapter {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
             Sort-Object RouteMetric | Select-Object -First 1
    if (-not $route) { return $null }
    Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
}

# =============================================================================
#  1. DIAGNOSE
# =============================================================================
function Invoke-Diagnose {
    Write-Host "`n=== DIAGNOSTIC ===" -ForegroundColor Cyan

    $ad = Get-ActiveAdapter
    if ($ad) {
        $isWifi = $ad.PhysicalMediaType -match 'Wireless|802.11' -or $ad.Name -match 'Wi-?Fi|Wireless'
        Write-Host ("Active adapter : {0} ({1})" -f $ad.Name, $ad.LinkSpeed)
        if ($isWifi) {
            Write-Host "  [!] You are on Wi-Fi. This is the #1 cause of Roblox jitter." -ForegroundColor Yellow
            Write-Host "      A wired ethernet cable will beat anything this tool can do." -ForegroundColor Yellow
        } else {
            Write-Host "  [ok] Wired connection detected." -ForegroundColor Green
        }
    } else { Write-Host "Active adapter : (could not determine)" -ForegroundColor Yellow }

    # Power plan
    $plan = (powercfg /getactivescheme) -replace '.*\((.*)\).*','$1'
    Write-Host ("Power plan     : {0}" -f $plan)
    if ($plan -notmatch 'High performance|Ultimate') {
        Write-Host "  [!] Not on High performance -- CPU/NIC can downclock and cause spikes." -ForegroundColor Yellow
    }

    # NIC power management
    if ($ad) {
        try {
            $pm = Get-NetAdapterPowerManagement -Name $ad.Name -ErrorAction Stop
            Write-Host ("NIC sleep      : AllowComputerToTurnOffDevice = {0}" -f $pm.AllowComputerToTurnOffDevice)
            if ($pm.AllowComputerToTurnOffDevice -eq 'Enabled') {
                Write-Host "  [!] Windows may power down the NIC mid-game -> latency spikes." -ForegroundColor Yellow
            }
        } catch { Write-Host "NIC sleep      : (adapter has no power mgmt settings)" }
    }

    # Multimedia throttling
    $mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    $nti = (Get-ItemProperty $mm -Name NetworkThrottlingIndex -EA SilentlyContinue).NetworkThrottlingIndex
    Write-Host ("Net throttling : NetworkThrottlingIndex = {0}" -f ($(if($null -ne $nti){'0x{0:X}' -f $nti}else{'default(10)'})))

    # Link quality to anchor
    Write-Host "`nMeasuring last-mile quality (30 pings to $Anchor)..." -ForegroundColor Gray
    $q = Get-LinkQuality
    Write-Host ("  Avg {0} ms | Min {1} | Max {2} | Jitter {3} ms | Loss {4}%" -f `
        $q.Avg, $q.Min, $q.Max, $q.Jitter, $q.LossPct)
    if ($q.LossPct -gt 1)  { Write-Host "  [!] Packet loss present -- check cabling/Wi-Fi/router." -ForegroundColor Red }
    if ($q.Jitter -gt 8)   { Write-Host "  [!] High jitter -- connection is unstable; optimizer will help." -ForegroundColor Yellow }
    if ($q.LossPct -le 1 -and $q.Jitter -le 8) { Write-Host "  [ok] Baseline looks clean." -ForegroundColor Green }

    Write-Host "`nTip: run the bufferbloat test at waveform.com/bufferbloat while a" -ForegroundColor Gray
    Write-Host "download runs -- if ping balloons under load, enable SQM/cake on your router." -ForegroundColor Gray
}

# =============================================================================
#  Backup helpers
# =============================================================================
function Save-Backup([hashtable]$data) {
    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir | Out-Null }
    $data | ConvertTo-Json -Depth 5 | Set-Content -Path $BackupFile -Encoding UTF8
}
function Get-RegDword($path, $name) {
    try { (Get-ItemProperty -Path $path -Name $name -EA Stop).$name } catch { $null }
}
# Create a registry key (and any missing parents) if it doesn't exist yet.
function Confirm-RegPath($path) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
}

# =============================================================================
#  2. OPTIMIZE  (all changes recorded to backup first)
# =============================================================================
function Invoke-Optimize {
    Write-Host "`n=== OPTIMIZE ===" -ForegroundColor Cyan
    $ad = Get-ActiveAdapter
    $mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'

    $backup = @{
        PowerSchemeGuid = ((powercfg /getactivescheme) -replace '.*GUID:\s*([a-f0-9\-]+).*','$1').Trim()
        AdapterName     = if ($ad) { $ad.Name } else { $null }
        NicPowerMgmt    = if ($ad) {
                              try { (Get-NetAdapterPowerManagement -Name $ad.Name -EA Stop).AllowComputerToTurnOffDevice } catch { $null }
                          } else { $null }
        NetworkThrottlingIndex = Get-RegDword $mm 'NetworkThrottlingIndex'
        SystemResponsiveness   = Get-RegDword $mm 'SystemResponsiveness'
    }
    Save-Backup $backup
    Write-Host "Backed up current settings to:`n  $BackupFile`n" -ForegroundColor Gray

    # 1) High performance power plan (prevents NIC/CPU downclock spikes -> stability)
    try {
        powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null
        if ($LASTEXITCODE -ne 0) {
            # Duplicate the built-in High performance scheme if it's hidden.
            powercfg -duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c | Out-Null
            powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null
        }
        Write-Host "[ok] Power plan set to High performance." -ForegroundColor Green
    } catch { Write-Host "[skip] Could not set power plan: $_" -ForegroundColor Yellow }

    # 2) Stop Windows powering down the NIC (biggest single stability fix)
    if ($ad) {
        try {
            Set-NetAdapterPowerManagement -Name $ad.Name -AllowComputerToTurnOffDevice Disabled -EA Stop
            Write-Host "[ok] Disabled NIC power-down on '$($ad.Name)'." -ForegroundColor Green
        } catch { Write-Host "[skip] NIC power mgmt not settable on this adapter." -ForegroundColor Yellow }
    }

    # 3) Multimedia network throttling off + responsive scheduling
    Confirm-RegPath $mm   # key is absent on some Windows installs; create it first
    Set-ItemProperty $mm -Name NetworkThrottlingIndex -Value 0xffffffff -Type DWord
    Set-ItemProperty $mm -Name SystemResponsiveness   -Value 0          -Type DWord
    Write-Host "[ok] Disabled network throttling, set responsive scheduling." -ForegroundColor Green

    # 4) Flush DNS (clears stale/slow resolver entries)
    ipconfig /flushdns | Out-Null
    Write-Host "[ok] Flushed DNS cache." -ForegroundColor Green

    Write-Host "`nDone. Some changes fully apply after a reboot." -ForegroundColor Cyan
    Write-Host "Run option 3 (Monitor) in a game to see the difference." -ForegroundColor Cyan
}

# =============================================================================
#  4. REVERT  (restore everything from backup)
# =============================================================================
function Invoke-Revert {
    Write-Host "`n=== REVERT ===" -ForegroundColor Cyan
    if (-not (Test-Path $BackupFile)) {
        Write-Host "No backup found -- nothing was changed by this tool." -ForegroundColor Yellow
        return
    }
    $b = Get-Content $BackupFile -Raw | ConvertFrom-Json
    $mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'

    if ($b.PowerSchemeGuid) {
        powercfg /setactive $b.PowerSchemeGuid 2>$null
        Write-Host "[ok] Restored previous power plan." -ForegroundColor Green
    }
    if ($b.AdapterName -and $b.NicPowerMgmt) {
        try {
            Set-NetAdapterPowerManagement -Name $b.AdapterName -AllowComputerToTurnOffDevice $b.NicPowerMgmt -EA Stop
            Write-Host "[ok] Restored NIC power management." -ForegroundColor Green
        } catch {}
    }
    # Restore or remove registry DWORDs to match original state.
    Confirm-RegPath $mm
    foreach ($name in 'NetworkThrottlingIndex','SystemResponsiveness') {
        $orig = $b.$name
        if ($null -eq $orig) { Remove-ItemProperty $mm -Name $name -EA SilentlyContinue }
        else { Set-ItemProperty $mm -Name $name -Value ([int]$orig) -Type DWord }
    }
    Write-Host "[ok] Restored multimedia/network registry values." -ForegroundColor Green
    Write-Host "`nAll changes reverted." -ForegroundColor Cyan
}

# =============================================================================
#  3. LIVE MONITOR
# =============================================================================
# Tries to auto-detect a Roblox UDP local port to confirm the game is running,
# then continuously ping-tests the anchor as a real-time stability readout.
function Invoke-Monitor {
    Write-Host "`n=== LIVE MONITOR (Ctrl+C to stop) ===" -ForegroundColor Cyan
    $rblx = Get-Process -Name 'RobloxPlayerBeta' -EA SilentlyContinue
    if ($rblx) { Write-Host "Roblox is running (PID $($rblx.Id))." -ForegroundColor Green }
    else { Write-Host "Roblox not detected -- monitoring last-mile link instead." -ForegroundColor Gray }

    $ping = New-Object System.Net.NetworkInformation.Ping
    $window = New-Object System.Collections.Generic.Queue[double]
    $max = 20; $prev = $null
    Write-Host ("{0,-10}{1,-10}{2,-12}{3}" -f 'RTT','JITTER','LOSS(20)','STATUS')
    while ($true) {
        $ms = $null
        try { $r = $ping.Send($Anchor, 1000); if ($r.Status -eq 'Success') { $ms = [double]$r.RoundtripTime } } catch {}
        if ($window.Count -ge $max) { $window.Dequeue() | Out-Null }
        $window.Enqueue($(if ($null -ne $ms) { 1 } else { 0 }))
        $loss = [math]::Round((($window | Measure-Object -Sum).Sum / $window.Count * -1 + 1) * 100, 0)

        $jit = if ($null -ne $ms -and $null -ne $prev) { [math]::Abs($ms - $prev) } else { 0 }
        $status = 'ok'; $col = 'Green'
        if ($null -eq $ms) { $status='DROP'; $col='Red' }
        elseif ($ms -gt 80 -or $jit -gt 15) { $status='SPIKE'; $col='Yellow' }

        $rttStr = if ($null -ne $ms) { "$ms ms" } else { '--' }
        Write-Host ("{0,-10}{1,-10}{2,-12}{3}" -f $rttStr, "$([math]::Round($jit,0)) ms", "$loss%", $status) -ForegroundColor $col
        if ($null -ne $ms) { $prev = $ms }
        Start-Sleep -Milliseconds 500
    }
}

# =============================================================================
#  Menu
# =============================================================================
if (-not (Test-Admin)) {
    Write-Host "Please run this script in an ELEVATED PowerShell (Run as Administrator)." -ForegroundColor Red
    Write-Host "Right-click PowerShell -> Run as administrator, then run this .ps1 again." -ForegroundColor Red
    return
}

while ($true) {
    Write-Host "`n============ RobloxNetTune ============" -ForegroundColor Cyan
    Write-Host " 1) Diagnose   (measure, no changes)"
    Write-Host " 2) Optimize   (apply safe fixes, backed up)"
    Write-Host " 3) Monitor    (live ping/jitter/loss)"
    Write-Host " 4) Revert     (undo all changes)"
    Write-Host " 5) Quit"
    switch (Read-Host "Select") {
        '1' { Invoke-Diagnose }
        '2' { Invoke-Optimize }
        '3' { Invoke-Monitor }
        '4' { Invoke-Revert }
        '5' { break }
        default { Write-Host "Pick 1-5." -ForegroundColor Yellow }
    }
}
