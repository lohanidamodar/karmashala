import 'dart:io';

import '../../../core/logging/app_logger.dart';
import '../domain/device_driver.dart';
import '../domain/device_input.dart';
import '../domain/device_target.dart';
import '../domain/simulator_backend.dart';
import 'simctl_service.dart';

/// [DeviceDriver] for an iOS Simulator: `simctl` for everything it can do, and
/// a [SimulatorBackend] for the things it cannot.
///
/// **The split is the design, not an implementation detail.** `simctl` ships
/// with Xcode and manages a simulator completely — boot, install, launch,
/// terminate, screenshot, log — but it has no touch injection and no way to
/// read the screen, and no amount of wrapping will give it one. Touch, typing
/// and the element tree come from [SimulatorBackend], which is the seam
/// `domain/simulator_backend.dart` exists to keep swappable: idb was replaced
/// by WebDriverAgent behind it without the pane or the providers changing, and
/// a CoreSimulator-based engine could replace WDA the same way. This driver is
/// therefore composed of the two rather than being a third implementation of
/// either — a future engine still only has to satisfy `SimulatorBackend`.
///
/// [backend] is nullable because that is a real state, not a defensive one: a
/// build assembled without `tool/vendor/fetch_wda.sh` ships no runner. Such a
/// build can still do most of this driver's job, so it loses three capabilities
/// rather than the whole device — which is exactly the failure the capability
/// split in `SimulatorSupport` was introduced to prevent.
class SimulatorDeviceDriver implements DeviceDriver {
  SimulatorDeviceDriver({
    required this.simctl,
    required this.backend,
    required this.target,
  });

  final SimctlService simctl;

  /// The engine that can touch the screen, or null when this build has none.
  final SimulatorBackend? backend;

  @override
  final SimulatorTarget target;

  @override
  String get id => backend == null ? 'simctl' : 'simctl+${backend!.id}';

  @override
  String get displayName =>
      backend == null ? 'simctl' : 'simctl + ${backend!.displayName}';

  String get _udid => target.id;

  @override
  Set<DeviceCapability> get capabilities => {
    DeviceCapability.screenshot,
    DeviceCapability.logs,
    DeviceCapability.installApp,
    DeviceCapability.appLifecycle,
    DeviceCapability.powerOff,
    // One decision, not three. They are the same runner: it is installed and
    // launched once, and when it is absent all three go together.
    if (backend != null) ...{
      DeviceCapability.input,
      DeviceCapability.keys,
      DeviceCapability.uiTree,
    },
  };

  @override
  bool can(DeviceCapability capability) => capabilities.contains(capability);

  @override
  String? missingReason(DeviceCapability capability) {
    if (can(capability)) return null;
    // The only way to be missing something here is to have no backend, and the
    // message says what remains rather than "unsupported" — an agent that reads
    // "unsupported" concludes iOS is a dead end, when in fact it can still
    // boot, install, launch and screenshot, which is most of a working loop.
    return 'This build ships no WebDriverAgent, so ${target.label} cannot be '
        'tapped, typed into, or read as an element tree: simctl on its own has '
        'no touch injection and no way to see the screen. Still available for '
        'this simulator: list_devices, device_boot, device_stop_emulator, '
        'device_screenshot, device_logcat, device_install_app, '
        'device_launch_app and device_terminate_app. Run '
        'tool/vendor/fetch_wda.sh and rebuild to get the rest.';
  }

  /// Points, not pixels — and this single line is the reason the whole
  /// [CoordinateSpace] type exists. See its doc comment.
  @override
  CoordinateSpace get coordinateSpace => CoordinateSpace.points;

  SimulatorBackend _requireBackend(DeviceCapability capability) {
    final engine = backend;
    if (engine == null) throw DeviceRefusal(missingReason(capability)!);
    return engine;
  }

  @override
  Future<DeviceScreenshot> screenshot() async {
    final bytes = await simctl.screenshot(_udid);
    return DeviceScreenshot(
      bytes: bytes,
      size: await simctl.screenSize(_udid),
      // The two disagree here, and callers have to be told. `simctl io
      // screenshot` captures the backing store — 1206x2622 on an iPhone 17 Pro
      // — while a tap is delivered at 402x874. A coordinate measured off this
      // image and passed to `tap` lands three times too far down and right, off
      // the screen, and nothing reports an error.
      imageSpace: CoordinateSpace.devicePixels,
      tapSpace: CoordinateSpace.points,
    );
  }

  @override
  Future<ScreenRead> describeScreen() async {
    final engine = _requireBackend(DeviceCapability.uiTree);
    final tree = await engine.describeUi(_udid);
    // The size comes out of the tree rather than from a second round trip.
    // WebDriverAgent's root element *is* the application window, so its frame
    // is the screen — which is exactly how `parseWdaUiRead` derives the `screen`
    // it reports, and calling `backend.screen()` here would fetch and parse the
    // whole `/source` document again to learn the same number.
    final root = tree.roots.firstOrNull;
    final bounds = root?.bounds;
    return ScreenRead(
      tree: tree,
      screen: bounds == null || bounds.isEmpty
          ? null
          : DeviceScreenSize(width: bounds.width, height: bounds.height),
      space: CoordinateSpace.points,
      // WDA puts the bundle id on the Application element's `name`, which
      // `parseWdaUiRead` maps onto `resourceId`. iOS nodes carry no package, so
      // `UiHierarchy.packageName` is always null here and reading it would
      // report "unknown app" on every screen.
      app: root == null || root.resourceId.isEmpty ? null : root.resourceId,
    );
  }

  @override
  Future<void> tap(int x, int y) =>
      _requireBackend(DeviceCapability.input).tap(_udid, x, y);

  @override
  Future<void> type(String text) =>
      _requireBackend(DeviceCapability.input).inputText(_udid, text);

  /// [DeviceKey] onto the keyboard iOS believes is plugged in.
  ///
  /// Kept here rather than beside [SimulatorButton.forDeviceKey] in the domain,
  /// where it would sit more naturally: that file is being changed on another
  /// branch as this is written, and a three-line map is not worth a merge
  /// conflict in a file two live panes depend on.
  ///
  /// The route matters more than the map does. These go to
  /// [SimulatorBackend.pressKey], which delivers a **HID key event**, and
  /// emphatically not to [SimulatorBackend.inputText] — read [SimulatorKey]'s
  /// doc comment for the measurements. `/wda/keys` transliterates a named key
  /// into a character: Left Arrow arrives in the field as an invisible
  /// `U+F702` instead of moving the caret, and Escape is swallowed with
  /// neither an error nor an effect. Typing a key name looks like it works and
  /// does not, which is exactly the failure this surface exists to refuse.
  static const Map<DeviceKey, SimulatorKey> _keyboardKeys = {
    DeviceKey.enter: SimulatorKey.returnKey,
    DeviceKey.tab: SimulatorKey.tab,
    DeviceKey.delete: SimulatorKey.backspace,
  };

  /// A [DeviceKey] on a simulator, refusing the ones iOS does not have.
  ///
  /// Three groups, and the split is the whole content of this method:
  ///
  /// * **Buttons the hardware has.** home and power (lock) map onto
  ///   [SimulatorButton] and go through [SimulatorBackend.pressButton].
  /// * **Keyboard keys.** enter, tab and delete are not device buttons at all;
  ///   they are keys on a keyboard, and they go through
  ///   [SimulatorBackend.pressKey] as HID events. That is what makes "type a
  ///   query, then press enter" submit the field rather than insert a newline
  ///   into it.
  /// * **Buttons iOS does not have.** back, recents and the volume rocker.
  ///   [SimulatorButton.forDeviceKey] returns null for these deliberately: iOS
  ///   has no system back button (an app draws its own), the app switcher is a
  ///   system gesture WebDriverAgent's synthesized touches never reach — see
  ///   the long note in `simulator_backend.dart` — and the HID route used here
  ///   is the keyboard page, which has no volume on it. Each is refused by
  ///   name with what to do instead, because the alternative is pressing a
  ///   plausible substitute and reporting success.
  @override
  Future<KeyPress> pressKey(DeviceKey key) async {
    final engine = _requireBackend(DeviceCapability.keys);
    final button = SimulatorButton.forDeviceKey(key);
    if (button != null) {
      await engine.pressButton(_udid, button);
      return KeyPress(key: key, how: 'the ${button.name} button');
    }
    if (_keyboardKeys[key] case final keyboardKey?) {
      await engine.pressKey(_udid, keyboardKey);
      return KeyPress(
        key: key,
        how:
            'the ${keyboardKey.name} key on the keyboard, delivered as a real '
            'key event — iOS has no hardware ${key.name}. Tap a field first if '
            'nothing has focus.',
      );
    }
    throw DeviceRefusal(switch (key) {
      DeviceKey.back =>
        'iOS has no system back button, so there is nothing to press on '
            '${target.label}. Apps draw their own — find it with '
            'device_find_elements(text: "Back") and tap it, or press home to '
            'leave the app.',
      DeviceKey.recents =>
        'The iOS app switcher cannot be opened this way on ${target.label}. '
            'It is a system gesture, and WebDriverAgent\'s synthesized touches '
            'are delivered into the foreground application, so they never '
            'reach SpringBoard — tried against a real device and confirmed by '
            'screenshot. Press home, then launch the other app with '
            'device_launch_app.',
      DeviceKey.volumeUp || DeviceKey.volumeDown =>
        'WebDriverAgent exposes no volume control, so ${key.name} cannot be '
            'honoured on ${target.label}. home and power are the two '
            'hardware buttons it can press.',
      _ =>
        '${key.name} has no iOS equivalent on ${target.label}. home and power '
            'are the hardware buttons; enter, tab and delete go to the '
            'keyboard.',
    });
  }

  /// `simctl spawn <udid> log show` over the last few minutes.
  ///
  /// Wired rather than refused: iOS does have a device log, this app already
  /// reads it for the log panel, and "there is no iOS equivalent" would have
  /// been a convenient falsehood. What it is *not* is logcat, and the two
  /// differences that would silently mislead a caller are handled explicitly.
  ///
  /// **[level] is refused, not ignored.** `log show --style compact` labels
  /// lines Default/Info/Debug/Error/Fault, which is not Android's
  /// verbose→fatal ladder. Mapping "warning" onto it means choosing which lines
  /// to throw away on the caller's behalf and being wrong about it.
  ///
  /// **[filter] is a substring match, and the note says so.** There is no
  /// per-bundle-id filter to pass along; the process name is in the line, so
  /// matching text here is useful and predictable — but calling it a package
  /// filter would overstate it.
  @override
  Future<DeviceLogRead> readLog({
    String? filter,
    String? level,
    int lines = 200,
  }) async {
    if (level != null && level.trim().isNotEmpty) {
      throw DeviceRefusal(
        'A simulator log cannot be filtered by level. iOS labels each line '
        'Default/Info/Debug/Error/Fault, which is not Android\'s '
        'verbose→fatal ladder, and mapping "$level" onto it would quietly drop '
        'lines you asked for. Drop level, or pass package to narrow by text.',
      );
    }
    final all = await simctl.readLog(_udid, lines: lines);
    if (filter == null || filter.trim().isEmpty) {
      return DeviceLogRead(
        lines: all,
        note:
            'The whole device log for the last 5 minutes, newest last — every '
            'process on the simulator, not one app. Pass package to narrow it.',
      );
    }
    final needle = filter.trim().toLowerCase();
    final matched = [
      for (final line in all)
        if (line.toLowerCase().contains(needle)) line,
    ];
    return DeviceLogRead(
      lines: matched,
      note:
          'iOS has no per-bundle-id log filter, so "$filter" was matched as a '
          'plain substring of each line (the process name is in there). '
          '${matched.length} of ${all.length} lines from the last 5 minutes '
          'matched${matched.isEmpty ? ' — the app may not be running, or may '
                    'log under a different process name' : ''}.',
    );
  }

  @override
  Future<InstalledApp> installApp(String path) async {
    final lower = path.toLowerCase();
    if (lower.endsWith('.apk')) {
      throw DeviceRefusal(
        '$path is an Android build and ${target.label} is an iOS simulator. '
        'Give a simulator .app bundle, or install this onto an Android device.',
      );
    }
    if (lower.endsWith('.ipa')) {
      throw DeviceRefusal(
        'simctl cannot install an .ipa. An .ipa carries the device slice — '
        'arm64 built against the iOS SDK — and a simulator needs the simulator '
        'slice; they are different binaries, not different packaging. Build for '
        'the simulator (flutter build ios --simulator, or xcodebuild -sdk '
        'iphonesimulator) and pass the .app.',
      );
    }
    if (!lower.endsWith('.app')) {
      throw DeviceRefusal(
        'simctl installs a .app bundle, and $path is not one.',
      );
    }
    // simctl only exists on this Mac, so the filesystem here is the filesystem
    // it will look at. Checking first turns "The application at … could not be
    // opened" into a sentence about the path that was actually passed.
    if (!Directory(path).existsSync()) {
      throw DeviceRefusal(
        'There is no .app bundle at $path. A .app is a directory, not a file — '
        'check the path, and note that a Flutter simulator build lands in '
        'build/ios/iphonesimulator/Runner.app.',
      );
    }
    await simctl.installApp(_udid, path);
    final bundleId = await simctl.readAppBundleId(path);
    return InstalledApp(
      path: path,
      appId: bundleId,
      note: bundleId == null
          ? 'Could not read CFBundleIdentifier out of the bundle, so '
                'device_launch_app needs the bundle id from you.'
          : 'Launch it with device_launch_app(appId: "$bundleId").',
    );
  }

  @override
  Future<LaunchedApp> launchApp(
    String appId, {
    String? activity,
    bool relaunch = false,
  }) async {
    if (activity != null && activity.trim().isNotEmpty) {
      throw DeviceRefusal(
        'activity is an Android idea and ${target.label} is a simulator: an '
        'iOS app has one entry point, not a set of activities. Drop activity '
        'to launch the app, or reach a particular screen through its URL '
        'scheme.',
      );
    }
    // The runner comes up **before** the app, and the order is the whole
    // point. WebDriverAgent is an app: starting it puts it in the foreground,
    // and iOS then drops back to SpringBoard when it settles. Attaching after
    // a launch therefore replaces the app that was just launched, and the
    // first `device_ui_dump` of a session reports the home screen — observed
    // exactly that way against an iPhone 17 Pro on iOS 26.4 before this line
    // existed. Attaching first means the launch is the last thing to touch the
    // foreground, so install → launch → dump reads the app, which is the order
    // the whole surface tells a caller to work in.
    //
    // [SimulatorBackend.attach] is idempotent and returns immediately once the
    // runner is up, so this costs one round trip after the first call. A
    // failure is logged rather than raised: the caller asked for a launch, not
    // for a runner, and refusing to start their app because the *driving*
    // engine would not come up would break the one half that still works. The
    // next verb that genuinely needs the backend fails loudly with the real
    // reason.
    final engine = backend;
    if (engine != null) {
      try {
        await engine.attach(_udid);
      } on Object catch (error) {
        AppLogger.named(
          'simulator',
        ).info('Launching $appId with no driving engine attached: $error');
      }
    }
    final pid = await simctl.launchApp(_udid, appId, relaunch: relaunch);
    return LaunchedApp(
      appId: appId,
      pid: pid,
      note: relaunch
          ? 'Any running copy was terminated first, so this is a cold start.'
          : 'An already-running app is brought to the front rather than '
                'restarted — pass relaunch=true for a cold start.',
    );
  }

  @override
  Future<void> terminateApp(String appId) => simctl.terminateApp(_udid, appId);

  @override
  Future<String> powerOff() async {
    await simctl.shutdown(_udid);
    return 'Shut down, not erased — its apps and data are still there for the '
        'next boot. device_boot brings it back.';
  }
}
