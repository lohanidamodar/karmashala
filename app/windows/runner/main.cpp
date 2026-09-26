#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
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
  if (!window.Create(L"karmashala", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // Tear the engine down here, before the window object starts unwinding.
  //
  // The loop can end with the window never having been destroyed: quitting goes
  // through `windowManager.destroy()`, which posts WM_QUIT rather than
  // destroying the window, so WM_DESTROY — the only thing that would otherwise
  // run `FlutterWindow::OnDestroy` — never arrives. Leaving the view controller
  // to `~FlutterWindow`'s implicit member destruction is *not* the same
  // teardown: `flutter_controller_ = nullptr` clears the member before deleting
  // the controller, while `~unique_ptr` deletes it with the member still
  // pointing at it. A window message delivered during that delete re-enters
  // `FlutterWindow::MessageHandler`, which hands it to the controller it is in
  // the middle of deleting, and faults inside flutter_windows.dll. The fault
  // lands in a window procedure the kernel called, which Windows cannot unwind:
  // the process sits there for ~20 s and is then killed with
  // STATUS_FATAL_USER_CALLBACK_EXCEPTION (0xC000041D). That is the quit the
  // owner was timing.
  //
  // `Destroy()` is idempotent, so an exit that did come through WM_DESTROY
  // finds the controller and the handle already cleared and does nothing.
  window.Destroy();

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
