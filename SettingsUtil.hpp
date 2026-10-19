#pragma once

#include <wil/resource.h>

constexpr auto CONFIG_NAME = L"AudioPlaybackConnector.json";
constexpr auto BUFFER_SIZE = 4096;

// Autostart lives in the registry rather than in the settings file, so it keeps
// working when the settings file is deleted or the executable is moved.
constexpr auto AUTOSTART_RUN_KEY = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr auto AUTOSTART_VALUE_NAME = L"AudioPlaybackConnector";

std::wstring AutoStartCommand()
{
	return L"\"" + GetModuleFsPath(g_hInst).wstring() + L"\"";
}

bool IsAutoStartEnabled()
{
	wil::unique_hkey hKey;
	if (RegOpenKeyExW(HKEY_CURRENT_USER, AUTOSTART_RUN_KEY, 0, KEY_READ, hKey.put()) != ERROR_SUCCESS)
	{
		return false;
	}

	wchar_t buffer[1024]{};
	DWORD size = sizeof(buffer);
	if (RegQueryValueExW(hKey.get(), AUTOSTART_VALUE_NAME, nullptr, nullptr, reinterpret_cast<LPBYTE>(buffer), &size) != ERROR_SUCCESS)
	{
		return false;
	}

	if (size % sizeof(wchar_t) != 0 || size == 0)
	{
		return false;
	}
	return std::wstring(buffer, size / sizeof(wchar_t) - 1) == AutoStartCommand();
}

void SetAutoStart(bool enable)
{
	wil::unique_hkey hKey;
	THROW_IF_WIN32_ERROR(RegCreateKeyExW(HKEY_CURRENT_USER, AUTOSTART_RUN_KEY, 0, nullptr, 0, KEY_SET_VALUE, nullptr, hKey.put(), nullptr));
	if (enable)
	{
		auto command = AutoStartCommand();
		THROW_IF_WIN32_ERROR(RegSetValueExW(hKey.get(), AUTOSTART_VALUE_NAME, 0, REG_SZ, reinterpret_cast<const BYTE*>(command.c_str()),
			static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t))));
	}
	else
	{
		auto error = RegDeleteValueW(hKey.get(), AUTOSTART_VALUE_NAME);
		if (error != ERROR_SUCCESS && error != ERROR_FILE_NOT_FOUND)
		{
			THROW_WIN32(error);
		}
	}
}

void DefaultSettings()
{
	g_reconnect = false;
	g_lastDevices.clear();
}

void LoadSettings()
{
	try
	{
		DefaultSettings();

		wil::unique_hfile hFile(CreateFileW((GetModuleFsPath(g_hInst).remove_filename() / CONFIG_NAME).c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
		THROW_LAST_ERROR_IF(!hFile);

		std::string string;
		while (1)
		{
			size_t size = string.size();
			string.resize(size + BUFFER_SIZE);
			DWORD read = 0;
			THROW_IF_WIN32_BOOL_FALSE(ReadFile(hFile.get(), string.data() + size, BUFFER_SIZE, &read, nullptr));
			string.resize(size + read);
			if (read == 0)
				break;
		}

		std::wstring utf16 = Utf8ToUtf16(string);
		auto jsonObj = JsonObject::Parse(utf16);
		g_reconnect = jsonObj.Lookup(L"reconnect").GetBoolean();

		auto lastDevices = jsonObj.Lookup(L"lastDevices").GetArray();
		g_lastDevices.reserve(lastDevices.Size());
		for (const auto& i : lastDevices)
		{
			if (i.ValueType() == JsonValueType::String)
				g_lastDevices.push_back(std::wstring(i.GetString()));
		}
	}
	CATCH_LOG();
}

void SaveSettings()
{
	try
	{
		JsonObject jsonObj;
		jsonObj.Insert(L"reconnect", JsonValue::CreateBooleanValue(g_reconnect));

		JsonArray lastDevices;
		for (const auto& i : g_audioPlaybackConnections)
		{
			lastDevices.Append(JsonValue::CreateStringValue(i.first));
		}
		jsonObj.Insert(L"lastDevices", lastDevices);

		wil::unique_hfile hFile(CreateFileW((GetModuleFsPath(g_hInst).remove_filename() / CONFIG_NAME).c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
		THROW_LAST_ERROR_IF(!hFile);

		std::string utf8 = Utf16ToUtf8(jsonObj.Stringify());
		DWORD written = 0;
		THROW_IF_WIN32_BOOL_FALSE(WriteFile(hFile.get(), utf8.data(), static_cast<DWORD>(utf8.size()), &written, nullptr));
		THROW_HR_IF(E_FAIL, written != utf8.size());
	}
	CATCH_LOG();
}
