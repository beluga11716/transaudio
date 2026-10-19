#include "pch.h"

#include <wil/com.h>
#include <wil/resource.h>
#include <mmreg.h>
#include <mmdeviceapi.h>
#include <endpointvolume.h>
#include <propidl.h>
#include <propkey.h>
#include <propsys.h>

#include "HealthMonitor.hpp"

// The state below is owned by AudioPlaybackConnector.cpp. This file deliberately
// does not include AudioPlaybackConnector.h: that header *defines* its globals and
// the helpers from Util.hpp / I18n.hpp / SettingsUtil.hpp / Direct2DSvg.hpp, so
// including it from a second translation unit fails at link time with LNK2005.
using DeviceInformation = winrt::Windows::Devices::Enumeration::DeviceInformation;
using DevicePicker = winrt::Windows::Devices::Enumeration::DevicePicker;
using AudioPlaybackConnection = winrt::Windows::Media::Audio::AudioPlaybackConnection;
using winrt::Windows::Devices::Enumeration::DevicePickerDisplayStatusOptions;
namespace fs = std::filesystem;

extern std::unordered_map<std::wstring, std::pair<DeviceInformation, AudioPlaybackConnection>> g_audioPlaybackConnections;
extern DevicePicker g_devicePicker;
const wchar_t* Translate(const wchar_t* str);

// ConnectDevice(DevicePicker, std::wstring_view) lives in AudioPlaybackConnector.cpp.
winrt::fire_and_forget ConnectDevice(DevicePicker, std::wstring_view);

namespace
{

constexpr wchar_t kCaptureRoot[] = L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\MMDevices\\Audio\\Capture";
constexpr wchar_t kRenderRoot[] = L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\MMDevices\\Audio\\Render";
constexpr wchar_t kEndpointNameProp[] = L"{b3f8fa53-0004-438e-9003-51a46e139bfc},6";
constexpr wchar_t kDeviceDescProp[] = L"{a45c254e-df1c-4efd-8020-67d146a850e0},2";
constexpr wchar_t kSnkSuffix[] = L" A2DP SNK";

// How long a silent-but-connected endpoint is tolerated before repairing it, and
// how recent real audio must be for the silence to count as a fault (instead of
// the user simply pausing playback). The cooldown stops repair loops.
constexpr DWORD kSilenceToHealMs = 6000;
constexpr DWORD kFreshAudioWindowMs = 90 * 1000;
constexpr DWORD kHealCooldownMs = 45 * 1000;  // after a flip or a reopen
constexpr DWORD kLightCooldownMs = 12 * 1000; // after a silent re-apply
constexpr DWORD kMaxBackoffMs = 3 * 60 * 1000; // a long pause settles to this
constexpr DWORD kResolveRetryMs = 5000;
// Re-applying the default endpoint is inaudible, so it can be tried early and
// often; switching the default away and back is not, so it is reserved for a
// connection that was opened moments ago (that is exactly when the fault hits).
constexpr DWORD kFlipWindowMs = 120 * 1000;
constexpr float kSoundThreshold = 0.002f;

// Something arrives on the sink but the default endpoint stays silent for this
// long: the monitor is dumping the phone's audio into a device that cannot play
// it (a monitor HDMI output, a removed device, ...).
constexpr DWORD kMisrouteToHealMs = 3000;

// Undocumented but stable: the only way to set the default playback endpoint.
// The base has to be qualified: AudioPlaybackConnector.h brings in
// `using namespace winrt::Windows::Foundation;`, which also declares IUnknown.
struct __declspec(uuid("F8679F50-850A-41CF-9C72-430F290290C8")) IPolicyConfig : ::IUnknown
{
	virtual HRESULT STDMETHODCALLTYPE GetMixFormat(PCWSTR, WAVEFORMATEX**) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetDeviceFormat(PCWSTR, INT, WAVEFORMATEX**) = 0;
	virtual HRESULT STDMETHODCALLTYPE ResetDeviceFormat(PCWSTR) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetDeviceFormat(PCWSTR, WAVEFORMATEX*, WAVEFORMATEX*) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetProcessingPeriod(PCWSTR, INT, PINT64, PINT64) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetProcessingPeriod(PCWSTR, PINT64) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetShareMode(PCWSTR, void*) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetShareMode(PCWSTR, void*) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetPropertyValue(PCWSTR, const PROPERTYKEY&, PROPVARIANT*) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetPropertyValue(PCWSTR, const PROPERTYKEY&, PROPVARIANT*) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetDefaultEndpoint(PCWSTR, ERole) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetEndpointVisibility(PCWSTR, INT) = 0;
};

struct __declspec(uuid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")) PolicyConfigClient;

struct Track
{
	std::wstring snkId;
	DWORD lastResolve = 0;
	DWORD lastSound = 0;
	DWORD silentSince = 0;
	DWORD lastHeal = 0;
	DWORD misroutedSince = 0;
	DWORD openedAt = 0;    // when the connection was opened (0 = never seen)
	int lightTries = 0;    // silent-side re-applies since audio last worked
	DWORD backoffMs = kLightCooldownMs;
	bool flipTried = false;
	bool healing = false;
};

enum class HealKind
{
	Auto,     // cheap and silent: re-apply the default endpoint only
	AutoFlip, // switch the default endpoint away and back (audible on some setups)
	Manual,   // the user asked for it from the menu: the full ladder, reopening included
};

// Keyed by AudioPlaybackConnection device id. Entries are never erased, so
// references stay valid across co_awaits.
std::unordered_map<std::wstring, Track> g_tracks;
fs::path g_healthLogPath;

void Log(std::wstring const& text)
{
	if (g_healthLogPath.empty())
	{
		wchar_t path[MAX_PATH] = {};
		GetModuleFileNameW(GetModuleHandleW(nullptr), path, ARRAYSIZE(path));
		g_healthLogPath = fs::path(path).replace_filename(L"AudioPlaybackConnector.health.log");
	}

	SYSTEMTIME st;
	GetLocalTime(&st);

	wchar_t line[2048];
	swprintf_s(line, L"%04u-%02u-%02u %02u:%02u:%02u.%03u %s\r\n",
		st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, text.c_str());

	FILE* file = nullptr;
	if (_wfopen_s(&file, g_healthLogPath.c_str(), L"a, ccs=UTF-8") == 0 && file)
	{
		fputws(line, file);
		fclose(file);
	}
}

std::wstring RegString(wchar_t const* root, std::wstring const& subKey, wchar_t const* value)
{
	wchar_t buffer[512] = {};
	DWORD size = sizeof(buffer);
	auto fullKey = std::wstring(root) + L"\\" + subKey;
	if (RegGetValueW(HKEY_LOCAL_MACHINE, fullKey.c_str(), value, RRF_RT_REG_SZ, nullptr, buffer, &size) != ERROR_SUCCESS)
	{
		return {};
	}
	return buffer;
}

std::wstring Lowercase(std::wstring text)
{
	for (auto& c : text)
	{
		c = static_cast<wchar_t>(towlower(c));
	}
	return text;
}

std::wstring GuidPart(std::wstring const& endpointId)
{
	auto pos = endpointId.find_last_of(L'.');
	return pos == std::wstring::npos ? endpointId : endpointId.substr(pos + 1);
}

// Human readable name for an endpoint id, for the log only.
std::wstring EndpointName(std::wstring const& endpointId)
{
	auto guid = GuidPart(endpointId);
	for (auto root : { kRenderRoot, kCaptureRoot })
	{
		auto name = RegString(root, guid + L"\\Properties", kEndpointNameProp);
		if (!name.empty())
		{
			return name;
		}
		name = RegString(root, guid + L"\\Properties", kDeviceDescProp);
		if (!name.empty())
		{
			return name;
		}
	}
	return endpointId;
}

// Windows 11 hides the A2DP sink from EnumAudioEndpoints, so it has to be located
// through the registry and opened by id.
std::wstring FindSnkEndpointId(std::wstring const& deviceName)
{
	wil::unique_hkey key;
	if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, kCaptureRoot, 0, KEY_READ, key.put()) != ERROR_SUCCESS)
	{
		return {};
	}

	std::wstring loose;
	for (DWORD index = 0;; ++index)
	{
		wchar_t name[256] = {};
		DWORD length = ARRAYSIZE(name);
		auto status = RegEnumKeyExW(key.get(), index, name, &length, nullptr, nullptr, nullptr, nullptr);
		if (status == ERROR_NO_MORE_ITEMS)
		{
			break;
		}
		if (status != ERROR_SUCCESS)
		{
			break;
		}

		auto endpointName = RegString(kCaptureRoot, std::wstring(name) + L"\\Properties", kEndpointNameProp);
		if (endpointName.empty() || endpointName.find(kSnkSuffix) == std::wstring::npos)
		{
			continue;
		}

		auto id = std::wstring(L"{0.0.1.00000000}.") + Lowercase(name);
		if (!deviceName.empty() && endpointName == deviceName + kSnkSuffix)
		{
			return id;
		}
		if (loose.empty() && !deviceName.empty() && endpointName.rfind(deviceName, 0) == 0)
		{
			loose = id;
		}
	}
	return loose;
}

float GetPeak(std::wstring const& endpointId, bool& ok)
{
	ok = false;

	wil::com_ptr<IMMDeviceEnumerator> enumerator;
	if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(enumerator.put()))))
	{
		return 0;
	}

	wil::com_ptr<IMMDevice> device;
	if (FAILED(enumerator->GetDevice(endpointId.c_str(), device.put())))
	{
		return 0;
	}

	wil::com_ptr<IAudioMeterInformation> meter;
	if (FAILED(device->Activate(__uuidof(IAudioMeterInformation), CLSCTX_ALL, nullptr, meter.put_void())))
	{
		return 0;
	}

	float peak = 0;
	if (FAILED(meter->GetPeakValue(&peak)))
	{
		return 0;
	}

	ok = true;
	return peak;
}

// Human readable meter value, so the log shows whether audio really was flowing.
std::wstring PeakText(std::wstring const& endpointId)
{
	bool ok = false;
	const float peak = GetPeak(endpointId, ok);
	if (!ok)
	{
		return L"n/a";
	}
	wchar_t buffer[32];
	swprintf_s(buffer, L"%.4f", peak);
	return buffer;
}

std::wstring GetDefaultId(ERole role){
	wil::com_ptr<IMMDeviceEnumerator> enumerator;
	if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(enumerator.put()))))
	{
		return {};
	}

	wil::com_ptr<IMMDevice> device;
	if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, role, device.put())))
	{
		return {};
	}

	wil::unique_cotaskmem_string id;
	if (FAILED(device->GetId(id.put())))
	{
		return {};
	}
	return id.get();
}

void SetDefaultId(std::wstring const& endpointId, ERole role)
{
	if (endpointId.empty())
	{
		return;
	}

	wil::com_ptr<IPolicyConfig> policy;
	if (FAILED(CoCreateInstance(__uuidof(PolicyConfigClient), nullptr, CLSCTX_ALL, IID_PPV_ARGS(policy.put()))))
	{
		LOG_LAST_ERROR();
		return;
	}
	policy->SetDefaultEndpoint(endpointId.c_str(), role);
}

void SetDefaultAllRoles(std::wstring const& endpointId)
{
	SetDefaultId(endpointId, eConsole);
	SetDefaultId(endpointId, eMultimedia);
	SetDefaultId(endpointId, eCommunications);
}

// A real device is preferred over virtual ones; the flip only lasts 500 ms.
std::wstring PickAlternate(std::wstring const& currentId)
{
	wil::com_ptr<IMMDeviceEnumerator> enumerator;
	if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(enumerator.put()))))
	{
		return {};
	}

	wil::com_ptr<IMMDeviceCollection> collection;
	if (FAILED(enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, collection.put())))
	{
		return {};
	}

	UINT count = 0;
	collection->GetCount(&count);

	std::wstring fallback;
	for (UINT index = 0; index < count; ++index)
	{
		wil::com_ptr<IMMDevice> device;
		if (FAILED(collection->Item(index, device.put())))
		{
			continue;
		}

		wil::unique_cotaskmem_string rawId;
		if (FAILED(device->GetId(rawId.put())))
		{
			continue;
		}

		std::wstring id = rawId.get();
		if (_wcsicmp(id.c_str(), currentId.c_str()) == 0)
		{
			continue;
		}

		auto name = EndpointName(id);
		if (name.find(L"Realtek") != std::wstring::npos)
		{
			return id;
		}
		if (fallback.empty() && name.find(L"Steam") == std::wstring::npos && name.find(L"Nahimic") == std::wstring::npos && name.find(L"Virtual") == std::wstring::npos)
		{
			fallback = id;
		}
	}
	return fallback;
}

winrt::Windows::Foundation::IAsyncOperation<bool> SampleLiveAsync(std::wstring snkId)
{
	for (int attempt = 0; attempt < 3; ++attempt)
	{
		co_await winrt::resume_after(std::chrono::milliseconds(250));

		bool ok = false;
		if (GetPeak(snkId, ok) > kSoundThreshold && ok)
		{
			co_return true;
		}
	}
	co_return false;
}

bool IsRenderEndpointUsable(std::wstring const& endpointId)
{
	if (endpointId.empty())
	{
		return false;
	}

	wil::com_ptr<IMMDeviceEnumerator> enumerator;
	if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(enumerator.put()))))
	{
		return false;
	}

	wil::com_ptr<IMMDevice> device;
	if (FAILED(enumerator->GetDevice(endpointId.c_str(), device.put())))
	{
		return false;
	}

	DWORD state = 0;
	if (FAILED(device->GetState(&state)))
	{
		return false;
	}
	return state == DEVICE_STATE_ACTIVE;
}

// The default endpoint can be opened and still be unusable: a monitor's HDMI
// output reports a fine meter (the monitor stream is mirrored into it 1:1) but no
// sound ever comes out, because the monitor has no speakers. Such an endpoint is
// left in the NOTPRESENT / UNPLUGGED state by Windows when the display sleeps.
winrt::fire_and_forget RerouteConnection(std::wstring deviceId)
{
	auto it = g_tracks.find(deviceId);
	if (it == g_tracks.end())
	{
		co_return;
	}
	auto& track = it->second;

	const auto current = GetDefaultId(eConsole);
	const auto target = PickAlternate(current);
	if (target.empty())
	{
		Log(L"route: no usable endpoint to switch to");
		track.healing = false;
		co_return;
	}

	Log(L"route: the phone is streaming but the default endpoint (" + EndpointName(current) + L") cannot play, switching to " + EndpointName(target));
	SetDefaultAllRoles(target);
	co_await winrt::resume_after(std::chrono::milliseconds(700));

	// Switching the default endpoint rebuilds the monitor bridge, so the sink
	// should be fed again even if this reroute was not strictly needed.
	bool ok = false;
	const float peak = GetPeak(track.snkId, ok);
	Log(ok && peak > kSoundThreshold ? L"route: ok" : L"route: done, still no audio from the phone");

	track.lastHeal = GetTickCount();
	track.healing = false;
}

// Tries, in order: re-applying the default endpoint (silent), flipping the default
// endpoint away and back, and finally reopening the A2DP connection.
winrt::fire_and_forget HealConnection(std::wstring deviceId, HealKind kind)
{
	auto it = g_tracks.find(deviceId);
	if (it == g_tracks.end())
	{
		co_return;
	}
	auto& track = it->second;

	auto snkId = track.snkId;
	if (snkId.empty())
	{
		if (auto connection = g_audioPlaybackConnections.find(deviceId); connection != g_audioPlaybackConnections.end())
		{
			snkId = FindSnkEndpointId(std::wstring(connection->second.first.Name()));
		}
		if (snkId.empty())
		{
			track.healing = false;
			co_return;
		}
		track.snkId = snkId;
	}

	const auto current = GetDefaultId(eConsole);
	Log(L"heal: start (" + EndpointName(snkId) + L" peak " + PeakText(snkId) + L" -> " + EndpointName(current) + L")");

	// Step 1: re-apply the current default endpoint. This rebuilds the monitor
	// stream through the audio service and is completely inaudible, so it is the
	// only thing an automatic heal does on a first try.
	SetDefaultAllRoles(current);
	if (co_await SampleLiveAsync(snkId))
	{
		Log(L"heal: step 1 ok (re-applied the default endpoint, peak " + PeakText(snkId) + L")");
		track.silentSince = 0;
		track.lastSound = GetTickCount();
		track.lightTries = 0;
		track.flipTried = false;
		track.healing = false;
		co_return;
	}

	if (kind == HealKind::Auto)
	{
		Log(L"heal: step 1 did not revive it (peak " + PeakText(snkId) + L")");
		track.healing = false;
		co_return;
	}

	// Step 2: flip the default endpoint away and back. This is what the user does
	// by hand in the Sound settings, and on this machine it is the only repair that
	// reliably revives a bridge that died while the link stayed up.
	const auto alternate = PickAlternate(current);
	if (!alternate.empty())
	{
		Log(L"heal: step 2 (flip through " + EndpointName(alternate) + L")");
		SetDefaultAllRoles(alternate);
		co_await winrt::resume_after(std::chrono::milliseconds(500));
		const bool alternateLive = co_await SampleLiveAsync(snkId);

		SetDefaultAllRoles(current);
		co_await winrt::resume_after(std::chrono::milliseconds(400));
		const bool currentLive = co_await SampleLiveAsync(snkId);

		if (currentLive)
		{
			Log(L"heal: step 2 ok (default endpoint flip)");
			track.silentSince = 0;
			track.lastSound = GetTickCount();
			track.lightTries = 0;
			track.flipTried = false;
			track.healing = false;
			co_return;
		}
		if (alternateLive)
		{
			// Going back re-broke it, so keep the endpoint that actually plays -
			// exactly what the user ends up doing by hand.
			SetDefaultAllRoles(alternate);
			Log(L"heal: step 2 ok (default endpoint moved to " + EndpointName(alternate) + L")");
			track.silentSince = 0;
			track.lastSound = GetTickCount();
			track.lightTries = 0;
			track.flipTried = false;
			track.healing = false;
			co_return;
		}
	}

	// Step 3: close and reopen the A2DP connection. Measured on the reporting
	// machine, reopening is what *kills* the audio after a manual reconnect, so an
	// automatic heal never does it; only the "Repair audio" menu item does.
	if (kind != HealKind::Manual)
	{
		Log(L"heal: steps 1-2 did not revive it (peak " + PeakText(snkId) + L"), leaving the connection alone (use Repair audio)");
		track.healing = false;
		co_return;
	}

	Log(L"heal: step 3 (reopening the connection)");
	if (auto connection = g_audioPlaybackConnections.find(deviceId); connection != g_audioPlaybackConnections.end())
	{
		auto device = connection->second.first;
		connection->second.second.Close();
		g_audioPlaybackConnections.erase(connection);
		g_devicePicker.SetDisplayStatus(device, Translate(L"Connecting"), DevicePickerDisplayStatusOptions::ShowProgress);
	}

	co_await winrt::resume_after(std::chrono::milliseconds(1000));
	ConnectDevice(g_devicePicker, std::wstring_view(deviceId));
	co_await winrt::resume_after(std::chrono::milliseconds(5000));

	bool ok = false;
	const bool live = GetPeak(track.snkId, ok) > kSoundThreshold && ok;
	Log(live ? L"heal: step 3 ok (connection reopened)" : L"heal: gave up, the phone may not be streaming");

	if (live)
	{
		track.lightTries = 0;
			track.flipTried = false;
	}
	track.silentSince = 0;
	track.lastHeal = GetTickCount();
	track.healing = false;
}

} // namespace

void HealthInit()
{
	wchar_t path[MAX_PATH] = {};
	GetModuleFileNameW(GetModuleHandleW(nullptr), path, ARRAYSIZE(path));
	g_healthLogPath = fs::path(path).replace_filename(L"AudioPlaybackConnector.health.log");
	Log(L"monitor: started");
}

void HealthOnTimer()
{
	if (g_audioPlaybackConnections.empty())
	{
		return;
	}

	const DWORD now = GetTickCount();
	std::vector<std::wstring> heal;
	std::vector<std::wstring> healFlip;
	std::vector<std::wstring> reroute;

	for (auto const& [deviceId, connection] : g_audioPlaybackConnections)
	{
		auto& track = g_tracks[deviceId];

		if (track.snkId.empty())
		{
			if (track.lastResolve != 0 && now - track.lastResolve < kResolveRetryMs)
			{
				continue;
			}
			track.lastResolve = now;
			track.snkId = FindSnkEndpointId(std::wstring(connection.first.Name()));
			if (track.snkId.empty())
			{
				continue;
			}
			Log(L"monitor: tracking " + EndpointName(track.snkId) + L" for " + std::wstring(connection.first.Name()));
		}

		bool ok = false;
		const float peak = GetPeak(track.snkId, ok);
		if (!ok)
		{
			// endpoint went away (disconnected); re-resolve on the next tick
			track.snkId.clear();
			track.lastResolve = 0;
			continue;
		}

		const bool streaming = peak > kSoundThreshold;
		if (streaming)
		{
			track.lastSound = now;
			track.silentSince = 0;
			track.lightTries = 0;
			track.backoffMs = kLightCooldownMs;
			track.flipTried = false;
		}

		if (track.healing)
		{
			continue;
		}
		const DWORD cooldown = track.flipTried ? kHealCooldownMs : track.backoffMs;
		if (track.lastHeal != 0 && now - track.lastHeal < cooldown)
		{
			continue;
		}

		if (streaming)
		{
			// The phone is definitely sending audio. If the default endpoint stays
			// silent, the monitor is rendering into a device that cannot play.
			const auto current = GetDefaultId(eConsole);
			bool renderOk = false;
			const float renderPeak = current.empty() ? 0 : GetPeak(current, renderOk);

			if (renderOk && renderPeak > kSoundThreshold)
			{
				track.misroutedSince = 0;
				continue;
			}

			if (track.misroutedSince == 0)
			{
				track.misroutedSince = now;
				continue;
			}
			if (now - track.misroutedSince < kMisrouteToHealMs)
			{
				continue;
			}

			track.misroutedSince = 0;
			track.healing = true;
			track.lastHeal = now;
			if (!IsRenderEndpointUsable(current))
			{
				reroute.push_back(deviceId);
			}
			else
			{
				track.flipTried = true;
				healFlip.push_back(deviceId);
			}
			continue;
		}

		// Nothing arrives on the sink. That is also what a paused phone looks like,
		// and the two cannot be told apart from the meter, so the repair has to be
		// harmless when the user is merely on pause: the first tries only re-apply
		// the default endpoint (inaudible), with a backoff so a long pause settles
		// into one probing attempt every few minutes.
		track.misroutedSince = 0;
		if (track.silentSince == 0)
		{
			track.silentSince = now;
			continue;
		}
		if (now - track.silentSince < kSilenceToHealMs)
		{
			continue;
		}

		// If the default endpoint is busy with something else while the phone is
		// quiet, the user is most likely just paused: a flip would be audible.
		const auto current = GetDefaultId(eConsole);
		bool renderOk = false;
		if (!current.empty() && GetPeak(current, renderOk) > kSoundThreshold && renderOk)
		{
			continue;
		}

		// Only when the cheap re-apply keeps failing right after a connection was
		// opened - exactly the "connected but silent" fault - is the audible flip
		// attempted, and only once per episode.
		if (track.lightTries >= 2)
		{
			if (track.flipTried || track.openedAt == 0 || now - track.openedAt > kFlipWindowMs)
			{
				continue;
			}
			track.flipTried = true;
			track.healing = true;
			track.lastHeal = now;
			healFlip.push_back(deviceId);
			continue;
		}

		++track.lightTries;
		track.healing = true;
		track.lastHeal = now;
		track.backoffMs = min(track.backoffMs * 2, kMaxBackoffMs);
		heal.push_back(deviceId);
	}

	for (auto const& deviceId : reroute)
	{
		RerouteConnection(deviceId);
	}
	for (auto const& deviceId : heal)
	{
		HealConnection(deviceId, HealKind::Auto);
	}
	for (auto const& deviceId : healFlip)
	{
		HealConnection(deviceId, HealKind::AutoFlip);
	}
}

void HealthNoteOpened(std::wstring const& deviceId)
{
	auto& track = g_tracks[deviceId];
	track.openedAt = GetTickCount();
	track.silentSince = 0;
	track.lastHeal = 0;
	track.lightTries = 0;
	track.flipTried = false;
	track.healing = false;
	track.snkId.clear();
	track.lastResolve = 0;
	Log(L"monitor: connection opened, watching for silence");
}

void HealthHealNow()
{
	if (g_audioPlaybackConnections.empty())
	{
		return;
	}

	const DWORD now = GetTickCount();
	std::vector<std::wstring> ready;

	for (auto const& [deviceId, connection] : g_audioPlaybackConnections)
	{
		auto& track = g_tracks[deviceId];
		if (track.healing)
		{
			continue;
		}
		track.healing = true;
		track.lastHeal = now;
		track.lightTries = 0;
			track.flipTried = false;
		ready.push_back(deviceId);
	}

	for (auto const& deviceId : ready)
	{
		HealConnection(deviceId, HealKind::Manual);
	}
}
