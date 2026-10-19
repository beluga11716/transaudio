<#
audio-probe.ps1 - WASAPI measurement probe for the Windows Bluetooth A2DP Sink ("Bluetooth audio receiver") path.

Why this exists
---------------
Windows implements "PC as a Bluetooth speaker" as:
    phone  --A2DP-->  capture endpoint "楹﹀厠椋?(<phone> A2DP SNK)"
                      --> Windows Audio service (svchost.exe) monitor loop
                      --> a render (playback) endpoint

AudioPlaybackConnector only opens/closes the A2DP connection; it never touches routing.
So "connected but silent" has two very different causes that look identical from the UI:

  A) nothing arrives from the phone   -> A2DP SNK capture peak stays 0.0
  B) audio arrives but is not played  -> A2DP SNK capture peak > 0 while the
                                        default render endpoint peak stays 0.0

This probe measures exactly those two numbers plus endpoint/default/mute state.

Modes
-----
  -Report              one-shot snapshot of every endpoint + defaults
  -Watch [-Seconds N]  sample peak levels once per interval and print CSV rows
  -Log <path>          also append the output to a file

Examples
--------
  powershell -ExecutionPolicy Bypass -File .\tools\audio-probe.ps1 -Report
  powershell -ExecutionPolicy Bypass -File .\tools\audio-probe.ps1 -Watch -Seconds 180 -Log .\probe.log
#>

[CmdletBinding()]
param(
    [switch]$Report,
    [switch]$Watch,
    [int]$Seconds = 60,
    [int]$IntervalMs = 1000,
    [string]$Log
)

$ErrorActionPreference = 'Stop'

$source = @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

namespace AudioProbe
{
    internal enum EDataFlow { eRender = 0, eCapture = 1, eAll = 2 }
    internal enum ERole { eConsole = 0, eMultimedia = 1, eCommunications = 2 }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    internal class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(EDataFlow dataFlow, int stateMask, out IMMDeviceCollection devices);
        int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice endpoint);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        int RegisterEndpointNotificationCallback(IntPtr client);
        int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceCollection
    {
        int GetCount(out int count);
        int Item(int index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        int Activate(ref Guid iid, uint clsCtx, IntPtr activationParams,
                     [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        int OpenPropertyStore(uint access, out IntPtr props);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetState(out int state);
    }

    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioMeterInformation
    {
        int GetPeakValue(out float peak);
        int GetMeteringChannelCount(out int channelCount);
        int GetChannelsPeakValues(int channelCount, [Out] float[] peakValues);
        int QueryHardwareSupport(out int hardwareSupportMask);
    }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioEndpointVolume
    {
        int RegisterControlChangeNotify(IntPtr notify);
        int UnregisterControlChangeNotify(IntPtr notify);
        int GetChannelCount(out int count);
        int SetMasterVolumeLevel(float level, Guid context);
        int SetMasterVolumeLevelScalar(float level, Guid context);
        int GetMasterVolumeLevel(out float level);
        int GetMasterVolumeLevelScalar(out float level);
        int SetChannelVolumeLevel(uint channel, float level, Guid context);
        int SetChannelVolumeLevelScalar(uint channel, float level, Guid context);
        int GetChannelVolumeLevel(uint channel, out float level);
        int GetChannelVolumeLevelScalar(uint channel, out float level);
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, Guid context);
        int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
    }

    public class EndpointInfo
    {
        public string Flow;       // "RENDER" | "CAPTURE"
        public string Id;         // {0.0.0.00000000}.{GUID}
        public string Guid;       // {GUID}
        public int State;         // 1 = ACTIVE, 2 = DISABLED, 4 = NOTPRESENT, 8 = UNPLUGGED
        public double Peak;
        public bool HasMeter;
        public string Mute;       // "True"/"False"/""
        public double Volume;     // 0..1, -1 when unknown
        public bool IsDefaultConsole;
        public bool IsDefaultMultimedia;
        public bool IsDefaultCommunications;
    }

    public static class Probe
    {
        static readonly Guid IID_IAudioMeterInformation = new Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064");
        static readonly Guid IID_IAudioEndpointVolume   = new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");
        const uint CLSCTX_ALL = 0x17;

        static IMMDeviceEnumerator Enumerator()
        {
            return (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
        }

        static string DefaultId(IMMDeviceEnumerator e, EDataFlow flow, ERole role)
        {
            try
            {
                IMMDevice dev;
                if (e.GetDefaultAudioEndpoint(flow, role, out dev) != 0 || dev == null) return null;
                string id;
                if (dev.GetId(out id) != 0) return null;
                Marshal.ReleaseComObject(dev);
                return id;
            }
            catch { return null; }
        }

        static EndpointInfo Describe(IMMDevice dev, string flow)
        {
            var info = new EndpointInfo();
            info.Flow = flow;
            info.HasMeter = false;
            info.Mute = "";
            info.Volume = -1;
            string id;
            if (dev.GetId(out id) != 0 || id == null) return info;
            info.Id = id;
            int brace = id.LastIndexOf('{');
            info.Guid = brace >= 0 ? id.Substring(brace).ToLowerInvariant() : id;
            int state;
            if (dev.GetState(out state) == 0) info.State = state;

            try
            {
                object o;
                Guid iid = IID_IAudioMeterInformation;
                if (dev.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out o) == 0 && o != null)
                {
                    var meter = (IAudioMeterInformation)o;
                    float peak;
                    if (meter.GetPeakValue(out peak) == 0) { info.Peak = Math.Round(peak, 5); info.HasMeter = true; }
                    Marshal.ReleaseComObject(o);
                }
            }
            catch { }

            try
            {
                object o;
                Guid iid = IID_IAudioEndpointVolume;
                if (dev.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out o) == 0 && o != null)
                {
                    var vol = (IAudioEndpointVolume)o;
                    bool mute;
                    float level;
                    if (vol.GetMute(out mute) == 0) info.Mute = mute ? "muted" : "unmuted";
                    if (vol.GetMasterVolumeLevelScalar(out level) == 0) info.Volume = Math.Round(level, 3);
                    Marshal.ReleaseComObject(o);
                }
            }
            catch { }
            return info;
        }

        /// <summary>Fast snapshot: ACTIVE endpoints only, peak + default flags (no volume reads).
        /// Used by watch mode; sampling the full state mask makes each tick take seconds because
        /// activating meters on absent endpoints blocks.</summary>
        public static List<EndpointInfo> Active(bool render)
        {
            var result = new List<EndpointInfo>();
            var e = Enumerator();
            EDataFlow flow = render ? EDataFlow.eRender : EDataFlow.eCapture;

            string defConsole = DefaultId(e, flow, ERole.eConsole);
            string defMedia   = DefaultId(e, flow, ERole.eMultimedia);

            IMMDeviceCollection col;
            if (e.EnumAudioEndpoints(flow, 0x01, out col) != 0 || col == null) return result;
            int count;
            if (col.GetCount(out count) != 0) return result;
            for (int i = 0; i < count; i++)
            {
                IMMDevice dev;
                if (col.Item(i, out dev) != 0 || dev == null) continue;
                var info = new EndpointInfo();
                info.Flow = render ? "RENDER" : "CAPTURE";
                info.Mute = "";
                info.Volume = -1;
                string id;
                if (dev.GetId(out id) == 0 && id != null)
                {
                    info.Id = id;
                    int brace = id.LastIndexOf('{');
                    info.Guid = brace >= 0 ? id.Substring(brace).ToLowerInvariant() : id;
                    int state;
                    if (dev.GetState(out state) == 0) info.State = state;
                    try
                    {
                        object o;
                        Guid iid = IID_IAudioMeterInformation;
                        if (dev.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out o) == 0 && o != null)
                        {
                            var meter = (IAudioMeterInformation)o;
                            float peak;
                            if (meter.GetPeakValue(out peak) == 0) { info.Peak = Math.Round(peak, 5); info.HasMeter = true; }
                            Marshal.ReleaseComObject(o);
                        }
                    }
                    catch { }
                    info.IsDefaultConsole = (defConsole != null && defConsole == info.Id);
                    info.IsDefaultMultimedia = (defMedia != null && defMedia == info.Id);
                }
                result.Add(info);
                Marshal.ReleaseComObject(dev);
            }
            Marshal.ReleaseComObject(col);
            Marshal.ReleaseComObject(e);
            return result;
        }

        /// <summary>Ids of the default endpoints for console/media/communications,
        /// regardless of endpoint state (a default can point at a NOTPRESENT device).</summary>
        public static string[] DefaultIds(bool render)
        {
            var e = Enumerator();
            EDataFlow flow = render ? EDataFlow.eRender : EDataFlow.eCapture;
            string c = DefaultId(e, flow, ERole.eConsole);
            string m = DefaultId(e, flow, ERole.eMultimedia);
            string k = DefaultId(e, flow, ERole.eCommunications);
            Marshal.ReleaseComObject(e);
            return new string[] { c, m, k };
        }

        /// <summary>One specific endpoint by id (0.0.1.xxx). Works even when the endpoint is
        /// missing from enumeration: GetDevice asks the audio service directly.</summary>
        public static EndpointInfo ById(string id, bool render)
        {
            var e = Enumerator();
            IMMDevice dev;
            try
            {
                if (e.GetDevice(id, out dev) != 0 || dev == null) { Marshal.ReleaseComObject(e); return null; }
                var info = Describe(dev, render ? "RENDER" : "CAPTURE");
                Marshal.ReleaseComObject(dev);
                return info;
            }
            finally { Marshal.ReleaseComObject(e); }
        }

        /// <summary>All endpoints of a flow with peak/mute/default information.</summary>
        public static List<EndpointInfo> Endpoints(bool render)
        {
            var result = new List<EndpointInfo>();
            var e = Enumerator();
            EDataFlow flow = render ? EDataFlow.eRender : EDataFlow.eCapture;

            string defConsole = DefaultId(e, flow, ERole.eConsole);
            string defMedia   = DefaultId(e, flow, ERole.eMultimedia);
            string defComm    = DefaultId(e, flow, ERole.eCommunications);

            IMMDeviceCollection col;
            // 0x0F = ACTIVE | DISABLED | NOTPRESENT | UNPLUGGED
            if (e.EnumAudioEndpoints(flow, 0x0F, out col) != 0 || col == null) return result;
            int count;
            if (col.GetCount(out count) != 0) return result;
            for (int i = 0; i < count; i++)
            {
                IMMDevice dev;
                if (col.Item(i, out dev) != 0 || dev == null) continue;
                var info = Describe(dev, render ? "RENDER" : "CAPTURE");
                info.IsDefaultConsole = (defConsole != null && defConsole == info.Id);
                info.IsDefaultMultimedia = (defMedia != null && defMedia == info.Id);
                info.IsDefaultCommunications = (defComm != null && defComm == info.Id);
                result.Add(info);
                Marshal.ReleaseComObject(dev);
            }
            Marshal.ReleaseComObject(col);
            Marshal.ReleaseComObject(e);
            return result;
        }
    }
}
'@

if (-not ('AudioProbe.Probe' -as [type])) {
    Add-Type -TypeDefinition $source -Language CSharp
}

$script:NameCache = @{}
function Get-EndpointName {
    param([string]$Guid)
    if ($script:NameCache.ContainsKey($Guid)) { return $script:NameCache[$Guid] }
    $resolved = '(unknown)'
    foreach ($tree in 'Render', 'Capture') {
        $key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$tree\$($Guid.ToUpper())"
        if (Test-Path $key) {
            $p = Get-ItemProperty "$key\Properties" -ErrorAction SilentlyContinue
            $dev = $p.'{a45c254e-df1c-4efd-8020-67d146a850e0},2'
            $name = $p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
            if ($dev -and $name) { $resolved = "$dev ($name)" } elseif ($name) { $resolved = $name }
            break
        }
    }
    $script:NameCache[$Guid] = $resolved
    return $resolved
}

function Format-State {
    param([int]$State)
    switch ($State) {
        1 { 'ACTIVE' }
        2 { 'DISABLED' }
        4 { 'NOTPRESENT' }
        8 { 'UNPLUGGED' }
        default { "STATE$State" }
    }
}

function Write-Out {
    param([string]$Text)
    Write-Host $Text
    if ($Log) { Add-Content -Path $Log -Value $Text -Encoding UTF8 }
}

if ($Report -or (-not $Watch)) {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Out "# audio-probe report  $stamp"

    $render = [AudioProbe.Probe]::Endpoints($true)
    $capture = [AudioProbe.Probe]::Endpoints($false)

    Write-Out "`n== RENDER (playback) =="
    Write-Out ("{0,-12} {1,-10} {2,-9} {3,-9} {4,-8} {5}" -f 'state', 'peak', 'volume', 'mute', 'default', 'endpoint')
    foreach ($e in $render) {
        $def = @()
        if ($e.IsDefaultConsole) { $def += 'console' }
        if ($e.IsDefaultMultimedia) { $def += 'media' }
        if ($e.IsDefaultCommunications) { $def += 'comm' }
        $vol = if ($e.Volume -ge 0) { '{0:P0}' -f $e.Volume } else { '-' }
        Write-Out ("{0,-12} {1,-10} {2,-9} {3,-9} {4,-8} {5}  {6}" -f (Format-State $e.State), $e.Peak, $vol, $e.Mute, ($def -join ','), (Get-EndpointName $e.Guid), $e.Id)
    }

    Write-Out "`n== CAPTURE (recording) =="
    Write-Out ("{0,-12} {1,-10} {2,-9} {3,-9} {4,-8} {5}" -f 'state', 'peak', 'volume', 'mute', 'default', 'endpoint')
    foreach ($e in $capture) {
        $def = @()
        if ($e.IsDefaultConsole) { $def += 'console' }
        if ($e.IsDefaultMultimedia) { $def += 'media' }
        if ($e.IsDefaultCommunications) { $def += 'comm' }
        $vol = if ($e.Volume -ge 0) { '{0:P0}' -f $e.Volume } else { '-' }
        Write-Out ("{0,-12} {1,-10} {2,-9} {3,-9} {4,-8} {5}  {6}" -f (Format-State $e.State), $e.Peak, $vol, $e.Mute, ($def -join ','), (Get-EndpointName $e.Guid), $e.Id)
    }

    Write-Out "`n== A2DP SNK endpoints (the Bluetooth receiver path) =="
    $snk = @($capture | Where-Object { (Get-EndpointName $_.Guid) -match 'A2DP' })
    if ($snk.Count -eq 0) {
        Write-Out '  none - the phone has never been received on this PC, or the SNK node is not enumerated'
    } else {
        foreach ($e in $snk) {
            Write-Out ("  {0}  state={1} peak={2} {3}" -f (Get-EndpointName $e.Guid), (Format-State $e.State), $e.Peak, $e.Id)
        }
    }

    Write-Out "`n== related services / processes =="
    foreach ($svc in 'Audiosrv', 'AudioEndpointBuilder', 'bthserv', 'BTAGService', 'BthAvctpSvc', 'BthHFSrv') {
        $s = Get-Service $svc -ErrorAction SilentlyContinue
        if ($s) { Write-Out ("  {0,-20} {1}" -f $s.Name, $s.Status) }
    }
    foreach ($proc in 'AudioPlaybackConnector', 'svchost') {
        $p = Get-Process $proc -ErrorAction SilentlyContinue
        if ($proc -eq 'svchost') {
            Write-Out ("  svchost instances       {0}" -f ($p | Measure-Object).Count)
        } elseif ($p) {
            Write-Out ("  {0,-20} pid={1} path={2}" -f $proc, ($p.Id -join ','), ($p.Path -join ','))
        } else {
            Write-Out ("  {0,-20} not running" -f $proc)
        }
    }

    Write-Out "`n== bluetooth A2DP sink device node =="
    $node = Get-PnpDevice -Class MEDIA -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'A2DP SNK' }
    if ($node) {
        foreach ($n in $node) { Write-Out ("  {0}  status={1} problem={2}" -f $n.FriendlyName, $n.Status, $n.Problem) }
    } else {
        Write-Out '  no MEDIA-class A2DP SNK node (phone not streaming right now)'
    }

    if (-not $Watch) { return }
}

# ---- watch mode -------------------------------------------------------------
# Tracks the A2DP SNK capture endpoint by id (GetDevice), because Windows 11 hides
# the SNK from EnumAudioEndpoints. Also tracks the default render endpoint (even when
# it is not present) and every ACTIVE render endpoint's peak.
$deadline = (Get-Date).AddSeconds($Seconds)
Write-Out '# time | snk=<peak>(<state>) | default=<name>[<state>]=<peak> | x41q=<peak> | loudest=<name> <peak> | verdict'
if ($Log -and -not (Test-Path $Log)) { New-Item -ItemType File -Path $Log -Force | Out-Null }

# Discover every A2DP SNK capture endpoint id from the registry (one per paired source).
$snkIds = @()
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture' -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-ItemProperty ($_.PSPath + '\Properties') -ErrorAction SilentlyContinue
    $nm = $p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
    if ($nm -match 'A2DP SNK') { $snkIds += ('{0.0.1.00000000}.' + $_.PSChildName.ToLower()) }
}
Write-Out ("# tracking SNK ids: " + ($snkIds -join ', '))

$x41qId = '{0.0.0.00000000}.{bebe75d0-6347-49a3-aff6-1380faf82170}'
$lastVerdict = ''
$lastTopo = ''
$tick = 0
while ((Get-Date) -lt $deadline) {
    $tick++
    $render = [AudioProbe.Probe]::Active($true)

    # --- SNK: ask for it by id so a hidden endpoint is still measured ---
    $snk = $null
    foreach ($id in $snkIds) {
        $cand = [AudioProbe.Probe]::ById($id, $false)
        if ($cand -and ($cand.State -eq 1) -and (-not $snk -or $cand.Peak -gt $snk.Peak)) { $snk = $cand }
    }

    # --- default render endpoint, present or not ---
    $defIds  = [AudioProbe.Probe]::DefaultIds($true)
    $defId   = if ($defIds[0]) { $defIds[0] } else { $defIds[1] }
    $defGuid = if ($defId) { $defId.Substring($defId.LastIndexOf('{')).ToLowerInvariant() } else { '' }
    $defName = if ($defGuid) { Get-EndpointName $defGuid } else { '(none)' }
    $defEntry = if ($defId) { @($render | Where-Object { $_.Id -eq $defId }) | Select-Object -First 1 } else { $null }
    $defState = if ($defEntry) { 'present' } else { 'NOT-PRESENT' }

    $x41q = @($render | Where-Object { $_.Id -eq $x41qId }) | Select-Object -First 1
    $x41qPeak = if ($x41q) { $x41q.Peak } else { -1 }
    $loud = @($render | Where-Object { $_.Peak -gt 0.002 } | Sort-Object Peak -Descending) | Select-Object -First 1

    $snkPeak  = if ($snk) { $snk.Peak } else { 0 }
    $snkState = if ($snk) { 'ACTIVE' } else { 'ABSENT' }
    $defPeak  = if ($defEntry) { $defEntry.Peak } else { 0 }
    $loudText = if ($loud) { '{0} {1}' -f (Get-EndpointName $loud.Guid), $loud.Peak } else { '(silent)' }

    $arriving = ($snkPeak -gt 0.002)
    $playing  = ($defPeak -gt 0.002)
    $verdict = if ($arriving -and $playing) { 'OK: phone audio rendered on ' + $defName }
               elseif ($arriving -and $defState -eq 'NOT-PRESENT') { 'BROKEN: phone audio arrives, default device is NOT PRESENT: ' + $defName }
               elseif ($arriving -and $loud) { 'MISROUTED: phone audio arrives, default silent, sound flows to ' + (Get-EndpointName $loud.Guid) }
               elseif ($arriving) { 'BROKEN: phone audio arrives on SNK, no render endpoint carries it' }
               elseif ($playing) { 'render busy, no phone audio' }
               else { 'idle: no phone audio' }

    $stamp = (Get-Date -Format 'HH:mm:ss.fff')
    $row = '{0} | {1}({2}) | {3}[{4}]={5} | {6} | {7} | {8}' -f $stamp, $snkPeak, $snkState, $defName, $defState, $defPeak, $x41qPeak, $loudText, $verdict
    if ($Log) { Add-Content -Path $Log -Value $row -Encoding UTF8 }

    $topo = (@($render | ForEach-Object { (Get-EndpointName $_.Guid) }) | Sort-Object) -join ' / '
    if ($topo -ne $lastTopo) {
        $detail = '# {0} TOPOLOGY CHANGED: {1}' -f $stamp, $topo
        Write-Host $detail
        if ($Log) { Add-Content -Path $Log -Value $detail -Encoding UTF8 }
        $lastTopo = $topo
    }

    if ($verdict -ne $lastVerdict) {
        Write-Host "# $stamp -> $verdict"
        if ($Log) {
            Add-Content -Path $Log -Value "# $stamp -> $verdict" -Encoding UTF8
            foreach ($r in @($render | Sort-Object Peak -Descending)) {
                Add-Content -Path $Log -Value ('#    render {0,-52} peak={1}' -f (Get-EndpointName $r.Guid), $r.Peak) -Encoding UTF8
            }
        }
        $lastVerdict = $verdict
    }
    if ($tick % 60 -eq 0) { Write-Host "  [$stamp] tick=$tick snk=$snkPeak def=$defName/$defPeak x41q=$x41qPeak $verdict" }

    Start-Sleep -Milliseconds $IntervalMs
}
Write-Host "# watch finished after $tick ticks"
if ($Log) { Add-Content -Path $Log -Value "# watch finished after $tick ticks" -Encoding UTF8 }
