import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Whether losing the last window ends the app. It does not.
  ///
  /// This app has a tray icon and a close-to-tray setting, and hiding to the
  /// tray is `orderOut(nil)` — the window goes away without closing. With this
  /// answering `true`, AppKit took that as the app being finished and called
  /// `applicationShouldTerminate`, which runs the ordered shutdown below: so
  /// hiding to the tray quit the app instead, whether it was reached from the
  /// window's close button or from clicking the tray icon while the window was
  /// in front. Close-to-tray could not work while this said `true`.
  ///
  /// Dart decides. Prevent-close is on unconditionally, so the window's X
  /// always reaches `onWindowClose`, which hides or quits according to the
  /// setting — and the tray's Quit and Cmd+Q both go through the same ordered
  /// path. There is no case left where the app should end merely because
  /// nothing is on screen.
  override func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// Cmd+Q, and the app menu's Quit.
  ///
  /// Handed to Dart rather than terminating here: quitting runs an ordered
  /// shutdown — the handshake file is deleted, agent hooks are rewritten, the
  /// hotkey is released and PTYs are reaped — and `terminate:` would end the
  /// process before any of it. Dart destroys the window itself when it is done,
  /// which is what actually ends us, so this cancels.
  ///
  /// If there is no engine to ask, terminating normally is better than a Quit
  /// that appears to do nothing.
  override func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    return LifecycleChannel.shared.requestQuit() ? .terminateCancel : .terminateNow
  }
}
