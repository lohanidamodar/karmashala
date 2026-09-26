import Cocoa
import FlutterMacOS
import ServiceManagement

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // `launch_at_startup` ships no macOS implementation of its own: the
    // package's macOS class just calls this channel and expects the host app to
    // answer it. Without this, every launch logged
    // `MissingPluginException(No implementation found for method
    // launchAtStartupIsEnabled)` and SystemIntegrationService retried it on a
    // schedule, forever, for a setting the user could never change.
    //
    // The package's own README wires this to the LaunchAtLogin Swift package.
    // `SMAppService` is the same mechanism without the dependency — it is what
    // LaunchAtLogin itself uses on macOS 13+, and it needs nothing added to the
    // Xcode project.
    LaunchAtLoginChannel.register(
      messenger: flutterViewController.engine.binaryMessenger)

    // Cmd+Q has to reach Dart rather than killing the process where it stands.
    // `window_manager`'s prevent-close — which the ordered shutdown depends on,
    // because it is what makes the window's X reach Dart at all — answers
    // `applicationShouldTerminate` with `.terminateCancel` and reports a window
    // *close* instead. With close-to-tray on, that hid the window: Cmd+Q looked
    // like it did nothing.
    LifecycleChannel.shared.attach(
      messenger: flutterViewController.engine.binaryMessenger)

    CommandChordChannel.shared.attach(
      messenger: flutterViewController.engine.binaryMessenger)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  /// Cmd+Q, caught before the Flutter view can eat it.
  ///
  /// AppKit offers a key equivalent to the key window's view hierarchy *before*
  /// the main menu. The terminal keeps a hidden text field focused for its
  /// keyboard input, and Flutter's macOS text-input plugin answers
  /// `performKeyEquivalent:` for the whole window while a field is active — so
  /// with a terminal open, Cmd+Q was consumed there and the menu's Quit never
  /// ran. Handling it here, ahead of `super`, is the only place that is
  /// reliably in front of the engine.
  ///
  /// `applicationShouldTerminate` still handles the menu item being clicked;
  /// this is only about the keystroke.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let onlyCommand =
      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
    if onlyCommand, event.charactersIgnoringModifiers?.lowercased() == "q" {
      if LifecycleChannel.shared.requestQuit() {
        return true
      }
    }
    // Everything else the app binds to Cmd, for the same reason and in the same
    // place. Moving the shortcuts from Ctrl to Cmd for macOS put every one of
    // them on this path: Ctrl+K was never a key equivalent, so the text-input
    // plugin never saw it, and Cmd+K is and does. Only chords Dart has actually
    // registered are taken, so Cmd+A/C/V in a real text field still reach it.
    if CommandChordChannel.shared.handle(event) {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}

/// The `launch_at_startup` platform channel, backed by `SMAppService`.
enum LaunchAtLoginChannel {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "launch_at_startup", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "launchAtStartupIsEnabled":
        result(isEnabled())
      case "launchAtStartupSetEnabled":
        guard let arguments = call.arguments as? [String: Any],
          let wanted = arguments["setEnabledValue"] as? Bool
        else {
          result(
            FlutterError(
              code: "bad_arguments",
              message: "launchAtStartupSetEnabled needs setEnabledValue",
              details: nil))
          return
        }
        setEnabled(wanted, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func isEnabled() -> Bool {
    // The deployment target is macOS 12, one below SMAppService. Reporting
    // "off" there is the truthful answer for a build that has no way to turn it
    // on, and it keeps the settings toggle consistent with what will happen.
    guard #available(macOS 13.0, *) else { return false }
    return SMAppService.mainApp.status == .enabled
  }

  private static func setEnabled(_ wanted: Bool, result: @escaping FlutterResult) {
    guard #available(macOS 13.0, *) else {
      result(
        FlutterError(
          code: "unsupported",
          message: "Opening at login needs macOS 13 or later.",
          details: nil))
      return
    }
    do {
      // Registering twice throws, as does unregistering something that was
      // never registered; both are the state the caller asked for.
      if wanted {
        if SMAppService.mainApp.status != .enabled {
          try SMAppService.mainApp.register()
        }
      } else {
        if SMAppService.mainApp.status == .enabled {
          try SMAppService.mainApp.unregister()
        }
      }
      result(nil)
    } catch {
      // Surfaced rather than swallowed: an unsigned or relocated build cannot
      // register, and a toggle that silently does nothing is worse than one
      // that says why.
      result(
        FlutterError(
          code: "sm_app_service",
          message: error.localizedDescription,
          details: nil))
    }
  }
}


/// The channel `applicationShouldTerminate` uses to ask Dart to quit.
final class LifecycleChannel {
  static let shared = LifecycleChannel()

  private var channel: FlutterMethodChannel?

  func attach(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "karmashala/lifecycle", binaryMessenger: messenger)
  }

  /// Asks Dart to run its ordered shutdown. Returns false when there is no
  /// engine to ask, in which case the caller should terminate normally rather
  /// than leave the user with a Quit that does nothing.
  func requestQuit() -> Bool {
    guard let channel else { return false }
    channel.invokeMethod("quitRequested", arguments: nil)
    return true
  }
}


/// The app's own Cmd chords, claimed before the Flutter view can eat them.
///
/// Dart registers exactly what it binds; nothing else is intercepted. That
/// matters — swallowing every Cmd combination here would take Cmd+A, Cmd+C and
/// Cmd+V away from every text field in the app.
final class CommandChordChannel {
  static let shared = CommandChordChannel()

  private var channel: FlutterMethodChannel?

  /// Lower-cased characters, keyed by whether Shift is part of the chord.
  private var plain: Set<String> = []
  private var shifted: Set<String> = []

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "karmashala/command_chords", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "register",
        let arguments = call.arguments as? [String: Any]
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.plain = Set((arguments["plain"] as? [String] ?? []))
      self?.shifted = Set((arguments["shifted"] as? [String] ?? []))
      result(nil)
    }
    self.channel = channel
  }

  /// Whether [event] is one of the registered chords. Sends it to Dart if so.
  func handle(_ event: NSEvent) -> Bool {
    guard let channel, let characters = event.charactersIgnoringModifiers
    else { return false }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let key = characters.lowercased()
    if modifiers == .command, plain.contains(key) {
      channel.invokeMethod("chord", arguments: ["key": key, "shift": false])
      return true
    }
    if modifiers == [.command, .shift], shifted.contains(key) {
      channel.invokeMethod("chord", arguments: ["key": key, "shift": true])
      return true
    }
    return false
  }
}
