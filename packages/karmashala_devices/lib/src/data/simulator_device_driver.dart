import 'dart:io';

import 'package:logging/logging.dart';
import '../domain/device_driver.dart';
import '../domain/device_files.dart';
import '../domain/device_input.dart';
import '../domain/device_state.dart';
import '../domain/device_target.dart';
import '../domain/simulator_backend.dart';
import 'simctl_service.dart';

/// [DeviceDriver] for an iOS Simulator: `simctl` for everything it can do, and a
/// [SimulatorBackend] for touch, typing and the element tree, which `simctl` has
/// no way to do at all. [backend] is nullable because a build assembled without
/// `fetch_wda.sh` ships no runner and loses three capabilities, not the device.
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
    DeviceCapability.deviceState,
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
    // Files are missing for a reason no backend would fix — fetching
    // WebDriverAgent does not give this app a usbmuxd client.
    if (capability == DeviceCapability.files) {
      return kIosFileAccessUnsupported;
    }
    // The message says what remains rather than "unsupported": an agent reading
    // that concludes iOS is a dead end when most of a working loop is left.
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
      // The two disagree here. `simctl io screenshot` captures the backing store
      // while a tap is delivered in points, so a coordinate measured off this
      // image lands three times too far down and right, with no error.
      imageSpace: CoordinateSpace.devicePixels,
      tapSpace: CoordinateSpace.points,
    );
  }

  @override
  Future<ScreenRead> describeScreen() async {
    final engine = _requireBackend(DeviceCapability.uiTree);
    final tree = await engine.describeUi(_udid);
    // The size comes out of the tree rather than a second round trip:
    // WebDriverAgent's root element *is* the application window.
    final root = tree.roots.firstOrNull;
    final bounds = root?.bounds;
    return ScreenRead(
      tree: tree,
      screen: bounds == null || bounds.isEmpty
          ? null
          : DeviceScreenSize(width: bounds.width, height: bounds.height),
      space: CoordinateSpace.points,
      // WDA puts the bundle id on the Application element's `name`. iOS nodes
      // carry no package, so `UiHierarchy.packageName` is always null here.
      app: root == null || root.resourceId.isEmpty ? null : root.resourceId,
    );
  }

  @override
  Future<void> tap(int x, int y) =>
      _requireBackend(DeviceCapability.input).tap(_udid, x, y);

  @override
  Future<void> type(String text) =>
      _requireBackend(DeviceCapability.input).inputText(_udid, text);

  /// [DeviceKey] onto the keyboard iOS believes is plugged in. The route matters
  /// more than the map: these go to [SimulatorBackend.pressKey] as HID events,
  /// never to [inputText], which transliterates a named key into a character.
  static const Map<DeviceKey, SimulatorKey> _keyboardKeys = {
    DeviceKey.enter: SimulatorKey.returnKey,
    DeviceKey.tab: SimulatorKey.tab,
    DeviceKey.delete: SimulatorKey.backspace,
  };

  /// A [DeviceKey] on a simulator, refusing the ones iOS does not have. Buttons
  /// go through [SimulatorBackend.pressButton], keyboard keys through
  /// [pressKey] as HID events, and back, recents and volume are refused by name.
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

  /// `simctl spawn <udid> log show` over the last few minutes. **[level] is
  /// refused, not ignored** — iOS has no verbose→fatal ladder to map onto — and
  /// **[filter] is a substring match**, which [DeviceLogRead.note] says.
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
    // Checking first turns "The application at … could not be opened" into a
    // sentence about the path that was actually passed.
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
    // The runner comes up **before** the app: WebDriverAgent is an app, so
    // attaching after a launch replaces what was just launched and the first
    // dump reports the home screen. A failure here is logged, not raised — the
    // caller asked for a launch, and the next verb that needs the backend fails.
    final engine = backend;
    if (engine != null) {
      try {
        await engine.attach(_udid);
      } on Object catch (error) {
        Logger(
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

  // Files are declared unsupported, and every method below says so rather than
  // returning an empty list: an empty root list and an empty directory both read
  // as "this device has no files on it". `kIosFileAccessUnsupported` carries the
  // reason and what a later implementation would do.

  Never _noFiles() => throw const DeviceRefusal(kIosFileAccessUnsupported);

  @override
  Future<List<DeviceFileRoot>> fileRoots() async => _noFiles();

  @override
  Future<DeviceDirectoryListing> listDirectory(String path) async => _noFiles();

  @override
  Future<DeviceFileEntry?> stat(String path) async => _noFiles();

  @override
  Future<DeviceFileTransfer> pullFile({
    required String devicePath,
    required String hostPath,
  }) async => _noFiles();

  @override
  Future<DeviceFileTransfer> pushFile({
    required String hostPath,
    required String devicePath,
    bool overwrite = false,
  }) async => _noFiles();

  @override
  Future<DeviceFileTransfer> copyWithinDevice({
    required String from,
    required String to,
    bool move = false,
    bool overwrite = false,
  }) async => _noFiles();

  @override
  Future<void> deletePath(String path, {bool recursive = false}) async =>
      _noFiles();

  @override
  Future<void> makeDirectory(String path) async => _noFiles();

  @override
  Future<String> changeState(DeviceStateChange change) async {
    final name = target.label;
    switch (change) {
      case AppearanceChange(:final dark):
        await simctl.setAppearance(_udid, dark ? 'dark' : 'light');
        return '$name is in ${dark ? 'dark' : 'light'} appearance.';
      case FontScaleChange(:final scale):
        final (category, size) = iosContentSizeFor(scale);
        await simctl.setContentSize(_udid, category);
        return 'iOS has Dynamic Type categories, not a free scale: $name is '
            'at $category, about ${size.toStringAsFixed(2)}× the default, '
            'the nearest to $scale.';
      case LocaleChange(:final tag):
        await simctl.setLanguage(_udid, tag);
        return 'Wrote AppleLanguages and AppleLocale ($tag) on $name. An app '
            'reads them at launch: relaunch it (device_launch_app with '
            'relaunch: true) to see the change.';
      case RotationChange():
        throw DeviceRefusal(
          'simctl has no way to rotate a simulator; only the Simulator '
          'window\'s own menu (⌘← / ⌘→) does. $name stays as it is.',
        );
      case NetworkChange():
        throw DeviceRefusal(
          'A simulator shares the Mac\'s network: simctl can neither cut nor '
          'throttle it for one simulator. Network Link Conditioner on the Mac '
          'shapes everything that Mac does, which Karmashala will not touch.',
        );
      case PermissionChange(:final appId, :final permission, :final grant):
        final service = permission.toLowerCase();
        if (!kSimctlPrivacyServices.contains(service)) {
          throw DeviceRefusal(
            'simctl privacy has no "$permission" service. It knows '
            '${kSimctlPrivacyServices.join(', ')}. The camera and '
            'notifications are not among them.',
          );
        }
        await simctl.setPrivacy(
          _udid,
          grant: grant,
          service: service,
          bundleId: appId,
        );
        return '${grant ? 'Granted' : 'Revoked'} $service for $appId on '
            '$name. A revoke ends the app if it is running.';
      case ClearAppDataChange():
        throw DeviceRefusal(
          'simctl has no clear-data command. To start $name\'s app from '
          'empty, uninstall it and install it again (device_install_app).',
        );
      case OpenUrlChange(:final url, :final appId):
        if (appId != null) {
          throw DeviceRefusal(
            'iOS routes a URL by its scheme or associated domain, not by an '
            'app named in the call. Drop appId; the URL alone decides.',
          );
        }
        await simctl.openUrl(_udid, url);
        return 'Opened $url on $name. Read the screen to see where it landed.';
    }
  }
}

/// The services `simctl privacy` grants and revokes.
const List<String> kSimctlPrivacyServices = [
  'all',
  'calendar',
  'contacts-limited',
  'contacts',
  'location',
  'location-always',
  'photos-add',
  'photos',
  'media-library',
  'microphone',
  'motion',
  'reminders',
  'siri',
];

/// The `simctl ui content_size` category nearest [scale], and its own scale
/// (body text size over the default 17 pt).
(String, double) iosContentSizeFor(double scale) {
  const categories = <(String, double)>[
    ('extra-small', 14 / 17),
    ('small', 15 / 17),
    ('medium', 16 / 17),
    ('large', 1.0),
    ('extra-large', 19 / 17),
    ('extra-extra-large', 21 / 17),
    ('extra-extra-extra-large', 23 / 17),
    ('accessibility-medium', 28 / 17),
    ('accessibility-large', 33 / 17),
    ('accessibility-extra-large', 40 / 17),
    ('accessibility-extra-extra-large', 47 / 17),
    ('accessibility-extra-extra-extra-large', 53 / 17),
  ];
  var best = categories[3];
  for (final candidate in categories) {
    if ((candidate.$2 - scale).abs() < (best.$2 - scale).abs()) {
      best = candidate;
    }
  }
  return best;
}
