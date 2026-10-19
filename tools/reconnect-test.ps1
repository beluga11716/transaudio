#requires -Version 5.1
<#
  Reproduces the "reconnect leaves the receiver silent" fault in a controlled way
  and measures how long the patched build needs to bring the audio back.

  It kills the tray app (which closes the A2DP connection), starts it again (the
  app reopens the connection on its own when "reconnect" is enabled), then samples
  the phone's A2DP SNK meter every 400 ms and reports the first moment audio flows
  again plus whatever the patched app wrote to its health log.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File reconnect-test.ps1 -Cycles 3
#>
param(
    [int]$Cycles = 3,
    [int]$SecondsPerCycle = 25,
    [string]$Exe = 'C:\Users\22317\Desktop\AudioPlaybackConnector64.exe',
    [string]$Log = 'V:\audiofix\reconnect-test.log'
)

$ErrorActionPreference = 'Stop'

$match = [regex]::Match((Get-Content (Join-Path $PSScriptRoot 'audio-probe.ps1') -Raw), "(?s)\`$source = @'\r?\n(.*?)\r?\n'@")
if (-not $match.Success) { throw 'cannot extract the C# block from audio-probe.ps1' }
if (-not ('AudioProbe.Probe' -as [type])) {
    Add-Type -TypeDefinition $match.Groups[1].Value -Language CSharp
}

$healthLog = Join-Path (Split-Path $Exe) 'AudioPlaybackConnector.health.log'
$snk = '{0.0.1.00000000}.{e2bac6db-d4cf-42ec-93f8-fcf5a6ecacc9}'
$threshold = 0.002

function Write-Both([string]$text) {
    Write-Host $text
    Add-Content -Path $Log -Value $text -Encoding UTF8
}

function Get-HealthTail([int]$lines) {
    if (-not (Test-Path $healthLog)) { return @() }
    return @(Get-Content $healthLog -Tail $lines -ErrorAction SilentlyContinue)
}

Set-Content -Path $Log -Value "=== reconnect test $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" -Encoding UTF8

for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
    Write-Both ("--- cycle {0} ---" -f $cycle)

    Get-Process -Name 'AudioPlaybackConnector64' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 1500
    $before = (Get-HealthTail 1000).Count
    Start-Process 'explorer.exe' -ArgumentList "`"$Exe`""
    $start = Get-Date

    $firstSoundAt = $null
    $deadline = $start.AddSeconds($SecondsPerCycle)
    while ((Get-Date) -lt $deadline) {
        $ep = [AudioProbe.Probe]::ById($snk, $false)
        $peak = if ($ep -and $ep.HasMeter) { $ep.Peak } else { 0 }
        if ($peak -gt $threshold -and $null -eq $firstSoundAt) {
            $firstSoundAt = ((Get-Date) - $start).TotalSeconds
            Write-Both ("    audio flowing after {0:N1} s (peak {1:N5})" -f $firstSoundAt, $peak)
        }
        Start-Sleep -Milliseconds 400
    }

    if ($null -eq $firstSoundAt) {
        Write-Both ("    NO audio within {0} s" -f $SecondsPerCycle)
    }

    foreach ($line in (Get-HealthTail 1000) | Select-Object -Skip $before) {
        if ($line -match 'heal:|monitor: (connection opened|tracking)') {
            Write-Both ("    log: " + $line.Trim())
        }
    }
}

Write-Both "=== done ==="
