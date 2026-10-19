<#
.SYNOPSIS
    One-shot health check for the "PC as Bluetooth speaker" setup.

.DESCRIPTION
    Prints, in plain language:
      1. whether the speakerless X41Q (NVIDIA HDMI) endpoint is still disabled
      2. which endpoint is the current default output
      3. whether phone audio is really arriving and being rendered right now
    Exit code 0 = healthy, 1 = something is off. Run it any time audio goes quiet.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\verify-receiver.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\verify-receiver.ps1 -Seconds 10
#>
param(
    [int] $Seconds = 5
)

$ErrorActionPreference = 'Continue'
$probeFile = Join-Path $PSScriptRoot 'audio-probe.ps1'
$ctlFile = Join-Path $PSScriptRoot 'audio-ctl.ps1'

if (-not ('AudioProbe.Probe' -as [type])) {
    $m = [regex]::Match((Get-Content $probeFile -Raw), "(?s)\`$source = @'\r?\n(.*?)\r?\n'@")
    if (-not $m.Success) { throw "cannot load probe source from $probeFile" }
    Add-Type -TypeDefinition $m.Groups[1].Value -Language CSharp
}
. $ctlFile | Out-Null

$x41qId = '{0.0.0.00000000}.{bebe75d0-6347-49a3-aff6-1380faf82170}'
$snkId = '{0.0.1.00000000}.{e2bac6db-d4cf-42ec-93f8-fcf5a6ecacc9}'

function Get-EpName([string]$guid) {
    if (-not $guid) { return '(unknown)' }
    foreach ($tree in 'Render', 'Capture') {
        $key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$tree\$($guid.ToUpper())"
        if (Test-Path $key) {
            $p = Get-ItemProperty "$key\Properties" -ErrorAction SilentlyContinue
            $dev = $p.'{a45c254e-df1c-4efd-8020-67d146a850e0},2'
            $nm  = $p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
            if ($dev -and $nm) { return "$dev ($nm)" }
            if ($nm) { return $nm }
            return '(unknown)'
        }
    }
    return '(unknown)'
}

function NameOf([string]$id) {
    if (-not $id) { return '(none)' }
    return (Get-EpName ($id.Substring($id.LastIndexOf('{'))))
}

$problems = New-Object System.Collections.Generic.List[string]

Write-Host '--- 1) X41Q (NVIDIA HDMI, no speakers) ---'
$x41q = [AudioProbe.Probe]::ById($x41qId, $true)
if (-not $x41q) {
    Write-Host '  OK: 已禁用/隐藏（Windows 无法再把它设为默认输出）' -ForegroundColor Green
} elseif ($x41q.State -eq 2) {
    Write-Host '  OK: DISABLED' -ForegroundColor Green
} elseif ($x41q.State -eq 4) {
    Write-Host '  注意: 端点存在但当前不呈现（NOTPRESENT）。没被禁用，仍可能抢默认。' -ForegroundColor Yellow
    $problems.Add('X41Q 未被禁用')
} else {
    Write-Host ('  问题: X41Q 处于可播放状态 (state={0})，可能再次抢走默认输出' -f $x41q.State) -ForegroundColor Red
    $problems.Add('X41Q 处于可用状态')
}

Write-Host '--- 2) 默认输出设备 ---'
$ids = [AudioProbe.Probe]::DefaultIds($true)
$labels = @('控制台', '多媒体', '通信')
for ($i = 0; $i -lt 3; $i++) {
    $nm = NameOf $ids[$i]
    $bad = ($ids[$i] -eq $x41qId) -or ($nm -match 'NVIDIA|X41Q|Steam Streaming|DP ')
    Write-Host ('  {0}: {1}' -f $labels[$i], $nm) -ForegroundColor $(if ($bad) { 'Red' } else { 'Green' })
    if ($bad) { $problems.Add("默认输出($($labels[$i])) = $nm") }
}

Write-Host ('--- 3) 实测 {0} 秒：手机音频在不在送、有没有被放出来 ---' -f $Seconds)
$snkMax = 0.0; $defMax = 0.0; $deadline = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $deadline) {
    $snk = [AudioProbe.Probe]::ById($snkId, $false)
    if ($snk -and $snk.State -eq 1 -and $snk.Peak -gt $snkMax) { $snkMax = $snk.Peak }
    $render = @([AudioProbe.Probe]::Active($true))
    foreach ($r in $render) {
        if ($ids[0] -and $r.Id -eq $ids[0] -and $r.Peak -gt $defMax) { $defMax = $r.Peak }
    }
    Start-Sleep -Milliseconds 400
}

if ($snkMax -le 0.002) {
    Write-Host '  手机没有在送音频（没连上，或者手机上没播放）' -ForegroundColor Yellow
} elseif ($defMax -gt 0.002) {
    Write-Host ('  正常: 手机音频到达 {0:N5}，默认设备同时有输出 {1:N5}' -f $snkMax, $defMax) -ForegroundColor Green
} else {
    Write-Host ('  异常: 手机音频已到达 ({0:N5})，但默认设备一点输出都没有 → 回放桥断了，在 App 里断开再连接' -f $snkMax) -ForegroundColor Red
    $problems.Add('回放桥断了')
}

Write-Host ''
if ($problems.Count -gt 0) {
    Write-Host ('结论: 发现 {0} 个问题 -> {1}' -f $problems.Count, ($problems -join '；')) -ForegroundColor Red
    exit 1
}
if ($snkMax -le 0.002) {
    Write-Host '结论: 系统配置没问题（X41Q 已禁用、默认输出正常），但手机这会儿没在送音频，没法验证回放。放首歌再跑一次。' -ForegroundColor Yellow
    exit 0
}
Write-Host '结论: 这条链路当前是健康的（配置正常 + 手机音频确实被放出来了）。' -ForegroundColor Green
exit 0
