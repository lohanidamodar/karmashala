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

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
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
