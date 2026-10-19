# AudioPlaybackConnector
[English](https://github.com/ysc3839/AudioPlaybackConnector/blob/master/README.md) | **简体中文**

Windows 10 2004+ 蓝牙音频接收 (A2DP Sink) 连接工具。

微软在 Windows 10 2004 加入了蓝牙 A2DP Sink 支持。但是需要第三方软件来管理连接。\
已经有了一个可以实现此功能的 app。但是它不可以隐藏到通知区域，而且不开源。\
所以我写了这个 app，提供一个简单的，现代且开源的替代品。

# 预览
![预览](https://cdn.jsdelivr.net/gh/ysc3839/AudioPlaybackConnector@master/AudioPlaybackConnector.gif)

# 使用方法
* 从 [releases](https://github.com/ysc3839/AudioPlaybackConnector/releases) 下载并运行 AudioPlaybackConnector。
* 在系统蓝牙设置中添加蓝牙设备。你可以右键点击通知区域的 AudioPlaybackConnector 图标然后选择“蓝牙设置”。
* 点击 AudioPlaybackConnector 图标然后选择想要连接的设备。
* 尽情享受吧！

# 本分支的改动

Windows 11 把 A2DP Sink 实现成“录音端点 + 由音频服务（svchost.exe）负责的监听回放”。这条桥
可能在蓝牙仍显示“已连接”的情况下死掉：手机在放歌，电脑没声音，只有重新选一次输出设备才会恢复。
本分支针对这个问题加入了自愈逻辑。

* **音频健康监控**（`HealthMonitor.cpp`）：连接期间每秒采样 A2DP Sink 录音端点（Win11 的
  `EnumAudioEndpoints` 不返回它，因此按端点 ID 直接打开）。当手机有音频而默认输出没有声音，
  或播放中途突然断流时，自动修复：
  1. 重新应用当前默认播放设备（不会有声音打断）；
  2. 把默认设备切到另一个可用设备再切回来，必要时保留真正能出声的那个（即手动操作的自动化）；
  3. 重开 A2DP 连接——只在菜单里的“修复音频”执行，因为重开会打断手机，本身也可能让桥再次死掉。
  所有动作记录在同目录的 `AudioPlaybackConnector.health.log`。
* **“修复音频”菜单项**：手动触发一次修复。
* **“开机自启”菜单项**（写入 `HKCU\...\CurrentVersion\Run`，程序内开关）。
* **编译修复**：`Microsoft.Windows.CppWinRT` 升级到 2.0.250303.1（旧版 2.0.200602.3 会注入
  `/await`，当前 MSVC 直接报错），并给泛型 lambda 补上显式参数以消除误报的 `C4864`。
  已在 Visual Studio 2026 / `PlatformToolset=v145` / Windows SDK 10.0.26100.0 上验证。
* **`translate/po2ymo.ps1`**：翻译生成脚本的 PowerShell 版，无 Python/polib 的环境也能用。
* **`tools/`**：定位该问题用的诊断脚本（通过 `IMMDeviceEnumerator::GetDevice` 枚举端点、
  用 `IPolicyConfig` 切换默认设备、分析 health log）。其中含本机端点 GUID，仅作参考。