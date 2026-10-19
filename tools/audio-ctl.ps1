<#
.SYNOPSIS
    Switch the default audio endpoint (all three roles) and hide/show an endpoint,
    the same way the Windows Sound UI does it (undocumented IPolicyConfig).

.DESCRIPTION
    Used by the diagnosis in V:\audiofix\AudioPlaybackConnector to move the default
    render endpoint around while measuring the A2DP SNK, without touching the GUI.

.EXAMPLE
    . .\tools\audio-ctl.ps1
    Set-DefaultDevice '{0.0.0.00000000}.{f5a2f8e9-7243-4cec-9df4-e816cab402ce}'
#>

$ctlSource = @'
using System;
using System.Runtime.InteropServices;

namespace AudioCtl
{
    [StructLayout(LayoutKind.Sequential)]
    public struct DeviceShareMode { public int mode; }

    [ComImport, Guid("F8679F50-850A-41CF-9C72-430F290290C8"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPolicyConfig
    {
        [PreserveSig] int GetMixFormat(string deviceId, out IntPtr format);
        [PreserveSig] int GetDeviceFormat(string deviceId, int def, out IntPtr format);
        [PreserveSig] int ResetDeviceFormat(string deviceId);
        [PreserveSig] int SetDeviceFormat(string deviceId, IntPtr endFormat, IntPtr mixFormat);
        [PreserveSig] int GetProcessingPeriod(string deviceId, int def, out long defPeriod, out long minPeriod);
        [PreserveSig] int SetProcessingPeriod(string deviceId, ref long period);
        [PreserveSig] int GetShareMode(string deviceId, out DeviceShareMode mode);
        [PreserveSig] int SetShareMode(string deviceId, ref DeviceShareMode mode);
        [PreserveSig] int GetPropertyValue(string deviceId, ref PROPERTYKEY key, out PROPVARIANT value);
        [PreserveSig] int SetPropertyValue(string deviceId, ref PROPERTYKEY key, ref PROPVARIANT value);
        [PreserveSig] int SetDefaultEndpoint(string deviceId, int role);      // 0 console, 1 multimedia, 2 communications
        [PreserveSig] int SetEndpointVisibility(string deviceId, int visible);
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROPERTYKEY { public Guid fmtid; public int pid; }

    [StructLayout(LayoutKind.Explicit)]
    public struct PROPVARIANT { [FieldOffset(0)] public short vt; [FieldOffset(8)] public IntPtr p; }

    public static class Policy
    {
        static IPolicyConfig Client()
        {
            var type = Type.GetTypeFromCLSID(new Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9"));
            return (IPolicyConfig)Activator.CreateInstance(type);
        }

        /// <summary>Make one endpoint the default for every role.</summary>
        public static string SetDefault(string id)
        {
            var c = Client();
            var sb = new System.Text.StringBuilder();
            for (int role = 0; role < 3; role++) sb.Append("role" + role + "=" + c.SetDefaultEndpoint(id, role) + " ");
            Marshal.ReleaseComObject(c);
            return sb.ToString().Trim();
        }

        /// <summary>Hide (visible=0) or show (visible=1) an endpoint in the Sound UI.</summary>
        public static int SetVisible(string id, int visible)
        {
            var c = Client();
            int hr = c.SetEndpointVisibility(id, visible);
            Marshal.ReleaseComObject(c);
            return hr;
        }
    }
}
'@

if (-not ('AudioCtl.Policy' -as [type])) {
    Add-Type -TypeDefinition $ctlSource -Language CSharp
}

function Set-DefaultDevice {
    param([Parameter(Mandatory)][string]$Id)
    $hr = [AudioCtl.Policy]::SetDefault($Id)
    [pscustomobject]@{ Id = $Id; Result = $hr }
}

function Set-EndpointVisible {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][bool]$Visible)
    [AudioCtl.Policy]::SetVisible($Id, [int]$Visible)
}
