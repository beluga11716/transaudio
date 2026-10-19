#pragma once

// Audio health monitor for the A2DP receiver (see HealthMonitor.cpp).
//
// Windows implements the A2DP sink as a *capture* endpoint ("<phone> A2DP SNK")
// plus a monitor stream owned by the audio service that renders it to whatever
// the current default playback device is. That bridge can die on its own: the
// Bluetooth link and the endpoint both stay connected, but zero samples flow, and
// nothing recovers until the default playback device is changed by hand.
// This monitor watches the SNK meter and repairs the bridge.

constexpr UINT_PTR TIMER_HEALTH = 0x4150;

// Log file next to the executable, created on first write.
void HealthInit();

// Called from WM_TIMER; samples every open connection and heals when needed.
void HealthOnTimer();

// Called after a connection was opened successfully. Marks the start of the
// window in which the bridge is known to be freshly built, which is when the
// "connected but silent" fault shows up.
void HealthNoteOpened(std::wstring const& deviceId);

// Menu action: run the repair ladder for every open connection right now.
void HealthHealNow();
