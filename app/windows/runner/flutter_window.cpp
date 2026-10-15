#include "flutter_window.h"

#include <commctrl.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Whether the Flutter view answers accessibility clients — screen readers, the
// touch keyboard, anything asking through UI Automation or MSAA. Off until
// Dart says otherwise (Settings → Screen reader support): once a client asks,
// the engine turns semantics on, and its Windows accessibility bridge can
// erase a child id its old parent no longer lists
// (`AccessibilityBridge::CreateRemoveReparentedNodesUpdate`, whose check is
// compiled out in release), and the copy that follows runs off the end of the
// buffer: the access violations and heap corruption of 2026-10-09 to -15.
bool g_accessibility_allowed = false;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  // Clear the member before the controller is deleted. Letting `~unique_ptr` do
  // it deletes while the member still points at the controller, and a window
  // message arriving mid-delete re-enters MessageHandler and dereferences it.
  // See the note in main.cpp.
  flutter_controller_ = nullptr;
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  accessibility_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "karmashala/windows_accessibility",
          &flutter::StandardMethodCodec::GetInstance());
  accessibility_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const auto* allowed = std::get_if<bool>(call.arguments());
        if (call.method_name() != "setAllowed" || allowed == nullptr) {
          result->NotImplemented();
          return;
        }
        g_accessibility_allowed = *allowed;
        result->Success();
      });
  ::SetWindowSubclass(flutter_controller_->view()->GetNativeWindow(),
                      ViewSubclassProc, 1, 0);
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  accessibility_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT CALLBACK FlutterWindow::ViewSubclassProc(HWND hwnd, UINT message,
                                                 WPARAM wparam, LPARAM lparam,
                                                 UINT_PTR id, DWORD_PTR data) {
  switch (message) {
    case WM_GETOBJECT:
      // The window's own default object, never the engine's tree.
      if (!g_accessibility_allowed) {
        return ::DefWindowProc(hwnd, message, wparam, lparam);
      }
      break;
    case WM_NCDESTROY:
      ::RemoveWindowSubclass(hwnd, ViewSubclassProc, id);
      break;
  }
  return ::DefSubclassProc(hwnd, message, wparam, lparam);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
