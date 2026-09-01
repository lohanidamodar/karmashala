import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
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
