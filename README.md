# AudioPlaybackConnector
**English** | [简体中文](https://github.com/ysc3839/AudioPlaybackConnector/blob/master/README.zh_CN.md)

Bluetooth audio playback (A2DP Sink) connector for Windows 10 2004+.

Microsoft added Bluetooth A2DP Sink to Windows 10 2004. However, a third-party app is required to manage connection.\
There is already an app can do this job. However it can't hide to notification area and it's not open-source.\
So I write this app, provide a simple, modern and open-source alternative.

# Preview
![Preview](https://cdn.jsdelivr.net/gh/ysc3839/AudioPlaybackConnector@master/AudioPlaybackConnector.gif)

# Usage
* Download and run AudioPlaybackConnector from [releases](https://github.com/ysc3839/AudioPlaybackConnector/releases).
* Add a bluetooth device in system bluetooth settings. You can right click AudioPlaybackConnector icon in notification area and select "Bluetooth Settings".
* Click AudioPlaybackConnector icon and select the device you want to connect.
* Enjoy!

# Changes in this fork

This fork adds a self-healing audio path, because Windows 11 implements the A2DP sink as a
recording endpoint plus a monitor stream owned by the audio service (`svchost.exe`), and that
bridge can die while the Bluetooth link still reports "Connected" — the phone plays, nothing
comes out, and only re-selecting the output device brings the sound back.

* **Audio health monitor** (`HealthMonitor.cpp`). While a connection is open the app samples the
  A2DP sink capture endpoint once per second (it is hidden from `EnumAudioEndpoints` on Windows 11,
  so it is opened by endpoint id). When the phone streams but the default output stays silent, or
  when the phone went silent mid-stream, the app repairs the bridge:
  1. re-apply the current default endpoint (inaudible),
  2. flip the default to another playable endpoint and back, keeping the working one
     (this is the manual workaround, automated),
  3. reopen the A2DP connection — only from the *Repair audio* menu item, because reopening
     interrupts the phone and can itself leave the bridge dead.
  Every action is logged to `AudioPlaybackConnector.health.log` next to the executable.
* **Repair audio** menu item for a manual kick.
* **Start with Windows** menu item (`HKCU\...\CurrentVersion\Run`, toggled from the app).
* **Build fixes** so the project compiles with current toolchains: `Microsoft.Windows.CppWinRT`
  bumped to 2.0.250303.1 (the old 2.0.200602.3 injects `/await`, which the current MSVC rejects),
  and a bogus `C4864` warning in a generic lambda silenced by typing the handler.
  Verified with Visual Studio 2026, `PlatformToolset=v145`, Windows SDK 10.0.26100.0.
* **`translate/po2ymo.ps1`** — PowerShell port of the translation generator, for machines without
  Python/polib.
* **`tools/`** — diagnostic scripts used to pin this down (endpoint enumeration through
  `IMMDeviceEnumerator::GetDevice`, `IPolicyConfig` default switching, health-log analysis).
  They contain machine-specific endpoint GUIDs and are meant as reference, not as a portable CLI.