<#
.SYNOPSIS
    One-shot heal ladder: tries the candidate repairs for the "connected but silent"
    A2DP receiver state and reports which one (if any) actually restores audio.

.DESCRIPTION
    Run this while the phone is playing music and the PC is silent. Each step is
    applied, then the A2DP SNK capture peak is sampled again:

      step 1  re-apply the current default render endpoint (silent)
      step 2  flip the default endpoint to another render device and back
      step 3  restart AudioPlaybackConnector (closes and reopens the A2DP connection)

    The numbers tell us which repair order the patched build should use.

.EXAMPLE
    .\tools\heal-ladder.ps1
#>

param(
    [int]$WaitMs = 2500,
    [string]$Log = 'V:\audiofix\heal-ladder.log'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'audio-ctl.ps1')

# peak / state / default queries come from the probe's C# block, reused verbatim
if (-not ('AudioProbe.Probe' -as [type])) {
    $match = [regex]::Match((Get-Content (Join-Path $PSScriptRoot 'audio-probe.ps1') -Raw), "(?s)\`$source = @'\r?\n(.*?)\r?\n'@")
    if (-not $match.Success) { throw 'cannot extract the C# block from audio-probe.ps1' }
    Add-Type -TypeDefinition $match.Groups[1].Value -Language CSharp
}

function Write-Log {
    param([string]$Text)
    $line = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $Text
    Write-Host $line
    Add-Content -Path $Log -Value $line -Encoding UTF8
}

function Get-EpName {
    param([string]$Guid, [string]$Flow = 'Render')
    $key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$Flow\$Guid\Properties"
    $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    if (-not $props) { return $Guid }
    foreach ($name in @('{b3f8fa53-0004-438e-9003-51a46e139bfc},6', '{a45c254e-df1c-4efd-8020-67d146a850e0},2')) {
        $v = $props.PSObject.Properties[$name]
        if ($v -and $v.Value) { return [string]$v.Value }
    }
    return $Guid
}

function Get-Snk {
    # the A2DP SNK capture endpoints are not enumerable on Win11, so find them by
    # the registry name and read them through IMMDeviceEnumerator::GetDevice
    $base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture'
    $found = @()
    foreach ($k in Get-ChildItem $base) {
        $props = Get-ItemProperty -Path (Join-Path $k.PSPath 'Properties') -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        $name = [string]$props.PSObject.Properties['{b3f8fa53-0004-438e-9003-51a46e139bfc},6'].Value
        if ($name -match 'A2DP SNK') {
            $found += [pscustomobject]@{ Guid = $k.PSChildName; Name = $name; Id = '{0.0.1.00000000}.' + $k.PSChildName.ToLower() }
        }
    }
    $best = $null
    foreach ($e in $found) {
        $info = [AudioProbe.Probe]::ById($e.Id, $false)
        if ($info) {
            $e | Add-Member -NotePropertyName State -NotePropertyValue $info.State -Force
            $e | Add-Member -NotePropertyName Peak -NotePropertyValue $info.Peak -Force
            if (-not $best -or $info.Peak -gt $best.Peak) { $best = $e }
        }
    }
    return $best
}

function Measure-State {
    $snk = Get-Snk
    $defs = [AudioProbe.Probe]::DefaultIds($true)
    [pscustomobject]@{
        SnkName  = if ($snk) { $snk.Name } else { '(none)' }
        SnkState = if ($snk) { $snk.State } else { -1 }
        SnkPeak  = if ($snk) { [math]::Round($snk.Peak, 5) } else { -1 }
        Default  = Get-EpName ($defs[0] -replace '^\{0\.0\.0\.00000000\}\.', '')
        DefId    = $defs[0]
    }
}

function Show-State {
    param([string]$Label)
    $s = Measure-State
    Write-Log ('{0}: snk={1}[state={2}] peak={3} | default={4}' -f $Label, $s.SnkName, $s.SnkState, $s.SnkPeak, $s.Default)
    return $s
}

function Get-Alternate {
    param([string]$CurrentId)
    $renders = [AudioProbe.Probe]::Active($true) | Where-Object { $_.State -eq 1 -and $_.Id -ne $CurrentId }
    # prefer a real device over virtual ones; Realtek speakers are always present here
    $real = $renders | Where-Object { (Get-EpName ($_.Id -replace '^\{0\.0\.0\.00000000\}\.', '')) -match 'Realtek' } | Select-Object -First 1
    if ($real) { return $real }
    return ($renders | Select-Object -First 1)
}

Write-Log '==== heal ladder start ===='
$app = Get-Process -Name 'AudioPlaybackConnector*' -ErrorAction SilentlyContinue
Write-Log ('app: ' + $(if ($app) { "$($app.ProcessName) pid=$($app.Id) path=$($app.Path)" } else { 'not running' }))

$baseline = Show-State 'baseline'
if ($baseline.SnkPeak -le 0.001) {
    Write-Log 'note: no phone audio is arriving right now - start playback, then re-run for a valid trial'
}

$result = 'inconclusive'

# ---- step 1: re-apply the current default endpoint
Write-Log '-- step 1: re-apply the current default endpoint'
Set-DefaultDevice -Id $baseline.DefId | Out-Null
Start-Sleep -Milliseconds $WaitMs
$s1 = Show-State 'after step 1'
if ($s1.SnkPeak -gt 0.001) { $result = 'step 1 (re-apply default) restored audio' }

# ---- step 2: flip the default endpoint away and back
if ($result -eq 'inconclusive') {
    $alt = Get-Alternate -CurrentId $baseline.DefId
    if ($alt) {
        $altName = Get-EpName ($alt.Id -replace '^\{0\.0\.0\.00000000\}\.', '')
        Write-Log ("-- step 2: flip default '{0}' -> '{1}' (400 ms) -> back" -f $baseline.Default, $altName)
        Set-DefaultDevice -Id $alt.Id | Out-Null
        Start-Sleep -Milliseconds 400
        Set-DefaultDevice -Id $baseline.DefId | Out-Null
        Start-Sleep -Milliseconds $WaitMs
        $s2 = Show-State 'after step 2'
        if ($s2.SnkPeak -gt 0.001) { $result = 'step 2 (default endpoint flip) restored audio' }
    }
    else {
        Write-Log '-- step 2 skipped: no alternate active render endpoint'
    }
}

# ---- step 3: restart the app (closes and reopens the A2DP connection)
if ($result -eq 'inconclusive') {
    if ($app) {
        $exe = $app[0].Path
        Write-Log ("-- step 3: restarting {0}" -f $exe)
        $app | Stop-Process -Force
        Start-Sleep -Milliseconds 800
        Start-Process -FilePath $exe
        Start-Sleep -Milliseconds 5000
        $s3 = Show-State 'after step 3'
        if ($s3.SnkPeak -gt 0.001) { $result = 'step 3 (app restart) restored audio' }
    }
    else {
        Write-Log '-- step 3 skipped: the app is not running'
    }
}

Write-Log ('==== result: ' + $result + ' ====')
Write-Log ('restore default: ' + $baseline.Default + ' -> ' + $baseline.DefId)
if ($env:HEAL_LADDER_KEEP -ne '1') {
    # leave the default where the user had it
    Set-DefaultDevice -Id $baseline.DefId | Out-Null
}
