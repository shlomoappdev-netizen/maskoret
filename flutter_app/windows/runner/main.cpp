#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"
#include "app_links/app_links_plugin_c_api.h"

// Registers com.shlomodavid.maskoret:// for this user, so the browser can return to the app
// after signing in with Google (no installer or admin rights needed).
static void RegisterLinkScheme() {
  wchar_t exe[MAX_PATH];
  if (!::GetModuleFileNameW(nullptr, exe, MAX_PATH)) return;
  const wchar_t* key = L"Software\\Classes\\com.shlomodavid.maskoret";
  std::wstring command = L"\"" + std::wstring(exe) + L"\" \"%1\"";
  const wchar_t* name = L"URL:Maskoret";
  ::RegSetKeyValueW(HKEY_CURRENT_USER, key, nullptr, REG_SZ, name,
                    static_cast<DWORD>((wcslen(name) + 1) * sizeof(wchar_t)));
  ::RegSetKeyValueW(HKEY_CURRENT_USER, key, L"URL Protocol", REG_SZ, L"", sizeof(wchar_t));
  ::RegSetKeyValueW(HKEY_CURRENT_USER, (std::wstring(key) + L"\\shell\\open\\command").c_str(), nullptr, REG_SZ,
                    command.c_str(), static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // A sign-in link opened while the app is running goes to that window.
  if (SendAppLinkToInstance()) {
    return EXIT_SUCCESS;
  }
  RegisterLinkScheme();

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"\u05de\u05d7\u05e9\u05d1\u05d5\u05df \u05e9\u05db\u05e8", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
