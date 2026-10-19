<#
.SYNOPSIS
    Self-healer for the "BT audio receiver is connected but silent" state.

.DESCRIPTION
    What it fixes: the Windows A2DP Sink is a capture endpoint whose audio is played
    back by a system "listen" bridge owned by the Audio service. That bridge can die
    while the link and the endpoint stay up (endpoint = ACTIVE, zero samples). Then the
    phone streams into a sink nobody drains: total silence, and re-connecting the
    Bluetooth connection does NOT rebuild the bridge. What DOES rebuild it is making
    the audio service rebuild the render side, i.e. re-selecting the default output
    device - that is exactly what "switching the sound output" does by hand.

    So this watcher measures the A2DP SNK endpoint's peak; when the endpoint is ACTIVE
    but has produced no audio for N seconds, it rebuilds the bridge:
      1) re-apply the current default endpoint (invisible, no blip when it works)
      2) if still dead, briefly flip the default to another live endpoint and back
         (the same thing the user does by hand, ~0.4 s)

.PARAMETER Once
    Heal immediately and exit (for a desktop shortcut / hotkey).

.PARAMETER Auto
    Watch forever, heal only when audio was flowing recently (safe default).

.PARAMETER Aggressive
    Watch forever and heal even if no audio was seen recently (fires at most once
    per -BackoffSeconds while the sink stays silent).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\audio-heal.ps1 -Once
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\audio-heal.ps1 -Auto -Log V:\audiofix\heal.log
#>
param(
    [switch] $Once,
    [switch] $Auto,
    [switch] $Aggressive,
    [int] $SilenceSeconds = 8,
    [int] $IntervalMs = 500,
    [int] $RecentDataSeconds = 300,
    [int] $BackoffSeconds = 180,
    [string] $Log = ''
)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot

if (-not ('AudioProbe.Probe' -as [type])) {
    $m = [regex]::Match((Get-Content (Join-Path $here 'audio-probe.ps1') -Raw), "(?s)\`$source = @'\r?\n(.*?)\r?\n'@")
    if (-not $m.Success) { throw 'cannot load the probe C# block' }
    Add-Type -TypeDefinition $m.Groups[1].Value -Language CSharp
}
. (Join-Path $here 'audio-ctl.ps1') | Out-Null

function Write-Log([string]$msg) {
    $line = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $msg
    Write-Host $line
    if ($Log) { Add-Content -Path $Log -Value $line -Encoding UTF8 }
}

function Get-EpName([string]$endpointId) {
    if (-not $endpointId) { return '(unknown)' }
    $guid = $endpointId.Substring($endpointId.LastIndexOf('{'))
    foreach ($tree in 'Render', 'Capture') {
        $key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$tree\$($guid.ToUpper())"
        if (Test-Path $key) {
            $p = Get-ItemProperty "$key\Properties" -ErrorAction SilentlyContinue
            $dev = $p.'{a45c254e-df1c-4efd-8020-67d146a850e0},2'
            $nm = $p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
            if ($dev -and $nm) { return "$dev ($nm)" }
            if ($nm) { return $nm }
            return '(unknown)'
        }
    }
    return '(unknown)'
}

# --- every A2DP SNK capture endpoint (one per paired phone) -------------------
$snkIds = @()
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture' -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-ItemProperty ($_.PSPath + '\Properties') -ErrorAction SilentlyContinue
    if ($p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6' -match 'A2DP SNK') {
        $snkIds += ('{0.0.1.00000000}.' + $_.PSChildName.ToLower())
    }
}

function Get-SnkPeak {
    $best = 0.0
    $active = 0
    foreach ($id in $snkIds) {
        $e = [AudioProbe.Probe]::ById($id, $false)
        if ($e -and $e.State -eq 1) {
            $active++
            if ($e.Peak -gt $best) { $best = $e.Peak }
        }
    }
    [pscustomobject]@{ Peak = $best; Active = $active }
}

function Test-SnkLive {
    Start-Sleep -Milliseconds 700
    $s = Get-SnkPeak
    return ($s.Peak -gt 0.002)
}

function Invoke-Heal {
    param([string]$Reason)

    Write-Log "HEAL start ($Reason)"
    $def = [AudioProbe.Probe]::DefaultIds($true)
    $cur = if ($def[0]) { $def[0] } else { $def[1] }
    if (-not $cur) { Write-Log 'HEAL abort: no default render endpoint'; return $false }
    $curName = Get-EpName $cur
    Write-Log "  current default: $curName"

    # step 1: re-apply the current default (no audible change when it works)
    Set-DefaultDevice -Id $cur | Out-Null
    if (Test-SnkLive) { Write-Log 'HEAL ok after re-applying the default (step 1)'; return $true }

    # step 2: flip to another live endpoint and back
    $render = @([AudioProbe.Probe]::Active($true))
    $alt = $render | Where-Object { $_.Id -ne $cur -and $_.State -eq 1 } |
           Sort-Object -Property @{ Expression = { if ($_.Peak -gt 0.002) { 1 } else { 0 } } } |
           Select-Object -First 1
    if (-not $alt) { Write-Log 'HEAL abort: no alternate endpoint to flip to'; return $false }
    $altName = Get-EpName $alt.Id
    Write-Log "  step 2: flip $curName -> $altName -> back"

    Set-DefaultDevice -Id $alt.Id | Out-Null
    Start-Sleep -Milliseconds 400
    Set-DefaultDevice -Id $cur | Out-Null
    if (Test-SnkLive) { Write-Log 'HEAL ok after the default-endpoint flip (step 2)'; return $true }

    Write-Log 'HEAL failed: sink still silent (the phone may not be streaming at all)'
    return $false
}

# ---------------------------------------------------------------------------
if ($Once) {
    $ok = Invoke-Heal 'manual'
    if ($ok) { exit 0 } else { exit 1 }
}

if (-not ($Auto -or $Aggressive)) {
    Write-Host 'Nothing to do: pass -Once, -Auto or -Aggressive.'
    exit 2
}

Write-Log ("watching {0} A2DP SNK endpoint(s){1}" -f $snkIds.Count, $(if ($Aggressive) { ' [aggressive]' } else { ' [auto]' }))
$lastData = $null
$silentSince = $null
$lastHeal = Get-Date '2000-01-01'
$lastStateKey = ''

while ($true) {
    $s = Get-SnkPeak
    $now = Get-Date

    if ($s.Active -eq 0) {
        if ($lastStateKey -ne 'no-endpoint') { Write-Log 'sink not active (phone not connected / stream closed)'; $lastStateKey = 'no-endpoint' }
        $silentSince = $null
        Start-Sleep -Milliseconds $IntervalMs
        continue
    }

    if ($s.Peak -gt 0.002) {
        if ($lastStateKey -ne 'flowing') { Write-Log ('audio flowing (peak {0:N5})' -f $s.Peak); $lastStateKey = 'flowing' }
        $lastData = $now
        $silentSince = $null
        Start-Sleep -Milliseconds $IntervalMs
        continue
    }

    if (-not $silentSince) { $silentSince = $now }
    $silentFor = ($now - $silentSince).TotalSeconds
    if ($lastStateKey -ne 'silent') {
        Write-Log ('sink ACTIVE but no audio for {0:N0}s' -f $silentFor)
        $lastStateKey = 'silent'
    }

    if ($silentFor -lt $SilenceSeconds) { Start-Sleep -Milliseconds $IntervalMs; continue }

    $recentData = $lastData -and (($now - $lastData).TotalSeconds -le $RecentDataSeconds)
    $backedOff = (($now - $lastHeal).TotalSeconds -ge $BackoffSeconds)

    if (($Aggressive -and $backedOff) -or ($Auto -and $recentData)) {
        $reason = if ($Aggressive -and -not $recentData) { 'aggressive, no recent audio' } else { 'audio stopped while streaming' }
        $null = Invoke-Heal $reason
        $lastHeal = Get-Date
        $silentSince = $null
        # give the phone a moment to resume, then re-measure
        Start-Sleep -Seconds 1
        $lastStateKey = ''
    }

    Start-Sleep -Milliseconds $IntervalMs
}
