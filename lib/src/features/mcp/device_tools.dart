import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../devices/application/device_providers.dart';
import '../devices/application/ios_device_providers.dart';
import '../devices/data/adb_service.dart';
import '../devices/data/simctl_service.dart';
import '../devices/domain/device_input.dart';
import '../devices/domain/ios_simulator.dart';
import '../devices/domain/logcat_entry.dart';
import '../devices/domain/simulator_backend.dart';
import '../devices/domain/ui_node.dart';
import '../devices/domain/ui_summary.dart';
import 'device_targets.dart';

/// An attached Android device, an Android emulator, or an iOS Simulator, as an
/// agent can drive it end to end: list, boot, install, launch, tap, read back.
///
/// Everything goes through the same `AdbService`, `SimctlService` and
/// `SimulatorBackend` the device pane uses, so the agent and the person beside
/// it are looking at and touching one device rather than two views of it.
///
/// ## One vocabulary, not two
///
/// These tools were Android-only, and every one of them took a `serial`. Adding
/// simulators could have meant a `simulator_*` family beside them — but
/// `device_tap` and `simulator_tap` are the same verb applied to the same kind
/// of object, and splitting them makes "which family do I call" a question the
/// agent has to answer *before* it knows what it is holding. The identifiers
/// give nothing away: `emulator-5554` and `70592006-11CD-…` are both just
/// strings that came out of `list_devices`.
///
/// So there is one family, the id is the discriminator, and
/// [DeviceTargetResolver] does the dispatch once. An agent pastes back whatever
/// `list_devices` gave it. Every existing Android caller keeps working
/// unchanged, because an Android serial still resolves to exactly what it
/// always did and the Android code paths below are the ones that were already
/// here.
///
/// ## Coordinate spaces are not the same on both platforms, and it matters
///
/// Android reports and accepts **device pixels**. WebDriverAgent reports
/// element frames and accepts taps in **points** — an iPhone 17 Pro is 402x874
/// points on a 1206x2622 pixel screen. Multiplying by the wrong one puts a tap
/// three times too far down and to the right, off the screen, while the call
/// still reports success. Every listing and every tap reply below therefore
/// names its own space, and [_ScreenRead.space] carries it.
///
/// Lifted out of `LauncherControlServer` unchanged. It was the largest family
/// still inline there, and the seam was already drawn — the terminal, browser,
/// workspace and verification tools had each been given a file of their own,
/// and the device tools' only tie to the server was the container they read
/// providers from.
class DeviceControlTools {
  DeviceControlTools(this._container);

  final ProviderContainer _container;

  static const Set<String> _names = <String>{
    'list_devices',
    'device_screenshot',
    'device_tap',
    'device_type',
    'device_key',
    'device_logcat',
    'device_ui_dump',
    'device_find_elements',
    'device_tap_element',
    'device_stop_emulator',
    'device_boot',
    'device_install_app',
    'device_launch_app',
    'device_terminate_app',
  };

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'list_devices' => _listDevices((args['limit'] as num?)?.round()),
        'device_screenshot' => _deviceScreenshot(_id(args)),
        'device_tap' => _deviceTap(
          _id(args),
          (args['x'] as num?)?.round(),
          (args['y'] as num?)?.round(),
        ),
        'device_type' => _deviceType(_id(args), args['text'] as String?),
        'device_key' => _deviceKey(_id(args), args['key'] as String?),
        'device_logcat' => _deviceLogcat(
          id: _id(args),
          packageName: args['package'] as String?,
          level: args['level'] as String?,
          lines: (args['lines'] as num?)?.round(),
        ),
        'device_ui_dump' => _deviceUiDump(
          id: _id(args),
          full: args['full'] == true,
          filter: args['filter'] as String?,
          limit: (args['limit'] as num?)?.round(),
        ),
        'device_find_elements' => _deviceFindElements(
          id: _id(args),
          query: _uiQuery(args),
          limit: (args['limit'] as num?)?.round(),
        ),
        'device_tap_element' => _deviceTapElement(
          id: _id(args),
          query: _uiQuery(args),
          index: (args['index'] as num?)?.round(),
        ),
        'device_stop_emulator' => _deviceStopEmulator(_id(args)),
        'device_boot' => _deviceBoot(_id(args) ?? args['name'] as String?),
        'device_install_app' => _deviceInstallApp(
          id: _id(args),
          path: args['path'] as String?,
        ),
        'device_launch_app' => _deviceLaunchApp(
          id: _id(args),
          appId: args['appId'] as String?,
          activity: args['activity'] as String?,
          relaunch: args['relaunch'] == true,
        ),
        'device_terminate_app' => _deviceTerminateApp(
          id: _id(args),
          appId: args['appId'] as String?,
        ),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  /// Which device the caller means.
  ///
  /// Three spellings for one argument. `serial` is what every existing Android
  /// caller passes and cannot change; `udid` is what `list_devices` calls a
  /// simulator's id and therefore the word an agent has in front of it when it
  /// writes the next call. Accepting both costs one line and removes a class of
  /// "I copied the field name from your own output and you rejected it".
  static String? _id(Map<String, dynamic> args) =>
      (args['serial'] ?? args['udid'] ?? args['device']) as String?;

  DeviceTargetResolver _resolver() => DeviceTargetResolver(
    adb: _container.read(adbServiceProvider),
    simctl: _container.read(simctlServiceProvider),
  );

  AdbService _requireAdb() {
    final adb = _container.read(adbServiceProvider);
    if (adb == null) {
      throw StateError(
        'No Android SDK found. Set ANDROID_HOME or install the SDK to the '
        r'default location (%LOCALAPPDATA%\Android\Sdk).',
      );
    }
    return adb;
  }

  SimctlService _requireSimctl() {
    final simctl = _container.read(simctlServiceProvider);
    if (simctl == null) {
      throw StateError(
        'iOS Simulators need macOS with Xcode installed, and this host is not '
        'one.',
      );
    }
    return simctl;
  }

  /// The thing that can actually touch a simulator, or a refusal that says
  /// exactly what is missing and what still works without it.
  ///
  /// `simctl` genuinely has no touch injection and no way to read the element
  /// tree — that is not a gap in this app, it is the boundary of the tool — so
  /// a build assembled without `tool/vendor/fetch_wda.sh` can manage a
  /// simulator completely and drive it not at all. Listing what survives is the
  /// difference between an agent rerouting and an agent concluding that iOS is
  /// unsupported.
  SimulatorBackend _requireBackend(String verb) {
    final backend = _container.read(simulatorBackendProvider);
    if (backend == null) {
      throw StateError(
        '$verb cannot drive an iOS simulator in this build: it ships no '
        'WebDriverAgent, and simctl on its own has no touch injection and no '
        'way to read the screen. Still available for simulators: '
        'list_devices, device_boot, device_stop_emulator, device_screenshot, '
        'device_logcat, device_install_app, device_launch_app and '
        'device_terminate_app. Run tool/vendor/fetch_wda.sh and rebuild to get '
        'taps, typing and the element tree.',
      );
    }
    return backend;
  }

  /// Resolves which device to act on. With exactly one ready device — of
  /// either platform — the id can be omitted, which is what a caller will want
  /// almost every time.
  Future<DeviceTarget> _resolveDevice(String? id, String verb) =>
      _resolver().require(id, verb: verb);

  // ---------------------------------------------------------------------------
  // Listing
  // ---------------------------------------------------------------------------

  /// How many simulators to list before saying "there are more".
  ///
  /// A device set is not a device list. This developer's machine holds 170
  /// simulators, 124 of them with no installed runtime, and printing all of
  /// them turns the one useful line — which is booted — into a haystack. Booted
  /// ones are always listed; the bootable rest are truncated, newest runtime
  /// first, because that is the order somebody wants them in.
  static const int _simulatorListLimit = 40;

  Future<Object?> _listDevices(int? limit) async {
    final adb = _container.read(adbServiceProvider);
    final simctl = _container.read(simctlServiceProvider);

    // Not `_requireAdb()`. list_devices used to throw when no Android SDK was
    // found, which on a Mac with Xcode and no SDK meant an agent could never
    // discover the simulators sitting right there — the one tool whose job is
    // to say what exists refused to say anything. A missing SDK is now a note
    // beside an empty Android list.
    final devices = adb == null ? const [] : await adb.listDevices();
    final avds = adb == null ? const [] : await adb.listAvds();

    final simulators = simctl == null
        ? const <IosSimulator>[]
        : await simctl.listSimulators();
    final booted = [
      for (final simulator in simulators)
        if (simulator.state.isReady || simulator.state == SimulatorState.booting)
          simulator,
    ];
    final bootable =
        [
          for (final simulator in simulators)
            if (!booted.contains(simulator) &&
                simulator.isAvailable &&
                simulator.state == SimulatorState.shutdown)
              simulator,
        ]..sort((a, b) {
          final runtime = b.runtime.compareTo(a.runtime);
          return runtime != 0 ? runtime : a.name.compareTo(b.name);
        });
    final cap = (limit ?? _simulatorListLimit).clamp(1, 1000);
    final shownBootable = bootable.take((cap - booted.length).clamp(0, cap));

    return {
      'devices': [
        for (final device in devices)
          {
            'serial': device.serial,
            'name': device.displayName,
            'platform': 'android',
            'state': device.state.name,
            'ready': device.isReady,
            'emulator': device.isEmulator,
            'environmentId': device.environmentId,
            if (device.isReady)
              'screenSize': (await adb!.screenSize(device.serial))?.toString(),
            if (device.isReady) 'coordinateSpace': 'device px',
          },
      ],
      'avds': [
        for (final avd in avds) {'name': avd.name, 'running': avd.isRunning},
      ],
      'simulators': [
        for (final simulator in [...booted, ...shownBootable])
          {
            'udid': simulator.udid,
            'name': simulator.name,
            'platform': 'ios',
            'runtime': simulator.runtimeName,
            'state': simulator.state.name,
            'running': simulator.state.isReady,
            'available': simulator.isAvailable,
            if (simulator.state.isReady)
              'screenSizePixels': (await simctl!.screenSize(
                simulator.udid,
              ))?.toString(),
            // Named rather than measured. Asking WebDriverAgent for the point
            // size means installing and launching the runner inside the
            // simulator, which is seconds of work and a foreground app change —
            // far too much for a listing. device_ui_dump reports it, and its
            // coordinates are already in the right space.
            if (simulator.state.isReady) 'coordinateSpace': 'points',
          },
      ],
      if (bootable.length > shownBootable.length)
        'simulatorsNotShown':
            '${bootable.length - shownBootable.length} more simulators are '
            'installed and bootable but not listed. Raise limit, or name one '
            'directly: device_boot accepts a simulator name as well as a udid.',
      if (adb == null)
        'androidNote':
            'No Android SDK was found, so no Android device or emulator could '
            r'be listed. Set ANDROID_HOME (or install to %LOCALAPPDATA%\'
            'Android\\Sdk on Windows, ~/Library/Android/sdk on macOS).',
      if (simctl == null)
        'iosNote':
            'iOS Simulators need macOS with Xcode, and this host is not one.',
    };
  }

  // ---------------------------------------------------------------------------
  // Looking at a screen
  // ---------------------------------------------------------------------------

  Future<Object?> _deviceScreenshot(String? id) async {
    final target = await _resolveDevice(id, 'device_screenshot');
    final file = File(
      p.join(
        Directory.systemTemp.path,
        'karmashala_${target.id}_'
            '${DateTime.now().millisecondsSinceEpoch}.png',
      ),
    );

    final String note;
    switch (target) {
      case AndroidTarget():
        final adb = _requireAdb();
        final bytes = await adb.screenshot(target.id);
        await file.writeAsBytes(bytes, flush: true);
        final size = await adb.screenSize(target.id);
        note =
            'Screenshot of ${target.label} (${target.id})'
            '${size == null ? '' : ', screen $size device px'}. '
            'Saved to ${file.path}. Tap coordinates are in device pixels.';
        return _screenshotContent(bytes, note);
      case SimulatorTarget():
        final simctl = _requireSimctl();
        final bytes = await simctl.screenshot(target.id, hostPath: file.path);
        final pixels = await simctl.screenSize(target.id);
        // The warning is the point of this branch. `simctl` captures the
        // backing store in pixels, WebDriverAgent takes taps in points, and on
        // a 3x phone the two differ by a factor of three — a coordinate read
        // off this image and handed to device_tap lands off the bottom of the
        // screen while the call reports success.
        note =
            'Screenshot of ${target.label} (${target.id})'
            '${pixels == null ? '' : ', $pixels pixels'}. '
            'Saved to ${file.path}. WARNING: this image is in PIXELS, but '
            'device_tap on a simulator takes POINTS — on a 3x device they '
            'differ by a factor of three. Use device_ui_dump or '
            'device_tap_element, whose coordinates are already in points, '
            'rather than measuring off this picture.';
        return _screenshotContent(bytes, note);
    }
  }

  /// Returned as MCP content blocks so the model actually sees the image
  /// instead of a wall of base64 in a JSON string.
  Object _screenshotContent(List<int> bytes, String note) => {
    '_mcpContent': [
      {'type': 'image', 'data': base64Encode(bytes), 'mimeType': 'image/png'},
      {'type': 'text', 'text': note},
    ],
  };

  // ---------------------------------------------------------------------------
  // Touching one
  // ---------------------------------------------------------------------------

  Future<Object?> _deviceTap(String? id, int? x, int? y) async {
    if (x == null || y == null) throw ArgumentError('x and y are required.');
    final target = await _resolveDevice(id, 'device_tap');
    switch (target) {
      case AndroidTarget():
        await _requireAdb().tap(target.id, x, y);
      case SimulatorTarget():
        await _requireBackend('device_tap').tap(target.id, x, y);
    }
    return {
      'tapped': '($x, $y)',
      'serial': target.id,
      'platform': target.platform.name,
      'coordinateSpace': _spaceOf(target),
    };
  }

  Future<Object?> _deviceType(String? id, String? text) async {
    if (text == null) throw ArgumentError('text is required.');
    final target = await _resolveDevice(id, 'device_type');
    switch (target) {
      case AndroidTarget():
        await _requireAdb().inputText(target.id, text);
      case SimulatorTarget():
        await _requireBackend('device_type').inputText(target.id, text);
    }
    return {'typed': text, 'serial': target.id, 'platform': target.platform.name};
  }

  Future<Object?> _deviceKey(String? id, String? key) async {
    if (key == null) throw ArgumentError('key is required.');
    final parsed = DeviceKey.parse(key);
    if (parsed == null) {
      throw ArgumentError(
        'Unknown key "$key". Valid keys: '
        '${DeviceKey.values.map((k) => k.name).join(', ')}.',
      );
    }
    final target = await _resolveDevice(id, 'device_key');
    switch (target) {
      case AndroidTarget():
        await _requireAdb().pressKey(target.id, parsed);
        return {'pressed': parsed.name, 'serial': target.id};
      case SimulatorTarget():
        return _simulatorKey(target, parsed);
    }
  }

  /// [DeviceKey] on a simulator, refusing the ones iOS does not have.
  ///
  /// Three groups, and the split is the whole content of this method:
  ///
  /// * **Buttons the hardware has.** home and power (lock) map onto
  ///   [SimulatorButton] and go through the backend.
  /// * **Keyboard keys.** enter, tab and delete are not buttons at all — they
  ///   are characters the iOS keyboard produces, and XCUITest types them as
  ///   `\n`, `\t` and `\b` through the same `/wda/keys` route ordinary text
  ///   takes. Routing them there is what lets "type a query, press enter" work.
  /// * **Buttons iOS does not have.** back, recents and the volume rocker.
  ///   [SimulatorButton.forDeviceKey] returns null for these deliberately: iOS
  ///   has no system back button (an app draws its own), the app switcher is a
  ///   system gesture WebDriverAgent's synthesized touches never reach — see
  ///   the long note in `simulator_backend.dart` — and WDA exposes no volume
  ///   control. Each is refused by name with what to do instead, because the
  ///   alternative is pressing a plausible substitute and reporting success.
  Future<Object?> _simulatorKey(SimulatorTarget target, DeviceKey key) async {
    final backend = _requireBackend('device_key');
    const keyboard = <DeviceKey, String>{
      DeviceKey.enter: '\n',
      DeviceKey.tab: '\t',
      DeviceKey.delete: '',
    };
    final button = SimulatorButton.forDeviceKey(key);
    if (button != null) {
      await backend.pressButton(target.id, button);
      return {
        'pressed': key.name,
        'serial': target.id,
        'platform': 'ios',
        'as': 'the ${button.name} button',
      };
    }
    if (keyboard[key] case final character?) {
      await backend.inputText(target.id, character);
      return {
        'pressed': key.name,
        'serial': target.id,
        'platform': 'ios',
        'as':
            'the keyboard key, typed into the focused field — iOS has no '
            'hardware ${key.name}. Tap a field first if nothing has focus.',
      };
    }
    throw StateError(
      switch (key) {
        DeviceKey.back =>
          'iOS has no system back button, so device_key(back) has nothing to '
              'press on ${target.label}. Apps draw their own — find it with '
              'device_find_elements(text: "Back") and tap it, or use '
              'device_key(home) to leave the app.',
        DeviceKey.recents =>
          'device_key(recents) cannot open the iOS app switcher. It is a '
              'system gesture, and WebDriverAgent\'s synthesized touches are '
              'delivered into the foreground application, so they never reach '
              'SpringBoard — tested against a real device and confirmed by '
              'screenshot. Use device_key(home) and launch the other app with '
              'device_launch_app.',
        DeviceKey.volumeUp || DeviceKey.volumeDown =>
          'WebDriverAgent exposes no volume control on a simulator, so '
              'device_key(${key.name}) cannot be honoured on ${target.label}. '
              'home and power are the two hardware buttons it can press.',
        _ =>
          'device_key(${key.name}) has no iOS equivalent on ${target.label}. '
              'home and power are the hardware buttons; enter, tab and delete '
              'go to the keyboard.',
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Logs
  // ---------------------------------------------------------------------------

  Future<Object?> _deviceLogcat({
    String? id,
    String? packageName,
    String? level,
    int? lines,
  }) async {
    final target = await _resolveDevice(id, 'device_logcat');
    switch (target) {
      case AndroidTarget():
        final minLevel = _parseLogLevel(level) ?? LogLevel.verbose;
        final entries = await _requireAdb().readLogcat(
          target.id,
          packageName: packageName,
          minLevel: minLevel,
          maxLines: lines ?? 200,
        );
        if (entries.isEmpty && packageName != null) {
          return {
            'serial': target.id,
            'package': packageName,
            'lines': <String>[],
            'note': 'No output — $packageName does not appear to be running.',
          };
        }
        return {
          'serial': target.id,
          'package': ?packageName,
          'lines': [for (final entry in entries) entry.toString()],
        };
      case SimulatorTarget():
        return _simulatorLog(target, packageName: packageName, level: level, lines: lines);
    }
  }

  /// `device_logcat` against a simulator, over `simctl spawn <udid> log show`.
  ///
  /// Wired rather than refused: iOS does have a device log, this app already
  /// reads it for the log panel, and "no iOS equivalent" would have been a
  /// convenient falsehood. What it is *not* is logcat, and the two differences
  /// that would silently mislead a caller are handled explicitly.
  ///
  /// **level is refused, not ignored.** `log show --style compact` labels lines
  /// with its own type letters, which are not Android's verbose/debug/info/
  /// warn/error ladder — `Default`, `Info`, `Debug`, `Error`, `Fault`. Mapping
  /// "warning" onto that means choosing which lines to throw away on the
  /// caller's behalf and being wrong about it, so it says so instead.
  ///
  /// **package is a substring match, and the reply says so.** There is no
  /// per-bundle-id filter to pass along; the process name appears in the line,
  /// so filtering here does something useful and predictable, but calling it a
  /// package filter would overstate it.
  Future<Object?> _simulatorLog(
    SimulatorTarget target, {
    String? packageName,
    String? level,
    int? lines,
  }) async {
    if (level != null && level.trim().isNotEmpty) {
      throw ArgumentError(
        'device_logcat cannot filter a simulator log by level. iOS labels each '
        'line Default/Info/Debug/Error/Fault, which is not Android\'s '
        'verbose→fatal ladder, and mapping "$level" onto it would quietly drop '
        'lines you asked for. Drop level, or pass package to narrow by text.',
      );
    }
    final maxLines = lines ?? 200;
    final all = await _requireSimctl().readLog(target.id, lines: maxLines);
    if (packageName == null || packageName.trim().isEmpty) {
      return {
        'serial': target.id,
        'platform': 'ios',
        'lines': all,
        'note':
            'The whole device log for the last 5 minutes, newest last — every '
            'process on the simulator, not one app. Pass package to narrow it.',
      };
    }
    final needle = packageName.trim().toLowerCase();
    final matched = [
      for (final line in all)
        if (line.toLowerCase().contains(needle)) line,
    ];
    return {
      'serial': target.id,
      'platform': 'ios',
      'package': packageName,
      'lines': matched,
      'note':
          'iOS has no per-bundle-id log filter, so "$packageName" was matched '
          'as a plain substring of each line (the process name is in there). '
          '${matched.length} of ${all.length} lines from the last 5 minutes '
          'matched${matched.isEmpty ? ' — the app may not be running, or may '
                    'log under a different process name' : ''}.',
    };
  }

  // ---------------------------------------------------------------------------
  // Lifecycle: boot, install, launch, terminate, stop
  // ---------------------------------------------------------------------------

  /// Starts a virtual device and waits until it can actually be talked to.
  ///
  /// Takes a **name or an id**, because the two platforms name the thing you
  /// boot differently and neither name is the one you drive afterwards. An AVD
  /// is booted by name and then answers to `emulator-5554`; a simulator is
  /// booted by udid and keeps it. Accepting an AVD name, a udid, or a
  /// simulator's own name means an agent can act on a task description
  /// ("start an iPhone 17 Pro") without a lookup step, and the reply always
  /// carries the id every other tool wants.
  ///
  /// Booted through the same providers the pane uses, not straight through
  /// `simctl`: that is what makes the device the agent started the device the
  /// person watching is shown, and it is what applies their slimming setting.
  Future<Object?> _deviceBoot(String? name) async {
    if (name == null || name.trim().isEmpty) {
      throw ArgumentError(
        'device_boot needs a name: an AVD name, an iOS simulator udid, or a '
        'simulator name. list_devices shows all three.',
      );
    }
    final wanted = name.trim();
    final resolver = _resolver();
    final existing = await resolver.find(wanted);

    switch (existing) {
      case SimulatorTarget():
        return _bootSimulator(existing);
      case AndroidTarget():
        // The id already names a device adb can see, so it is up. Booting is a
        // request for a state, and it is in it.
        return {
          'serial': existing.id,
          'platform': 'android',
          'booted': existing.isReady,
          'note': existing.isReady
              ? '${existing.id} is already running.'
              : 'was already running but is ${existing.device.state.name}: '
                    '${existing.notReadyReason}',
        };
      case null:
        break;
    }

    // Not a device, so it may be an AVD — which is a name in a different
    // namespace from every serial and udid above, and only exists while
    // stopped.
    final adb = _container.read(adbServiceProvider);
    if (adb != null) {
      final avds = await adb.listAvds();
      for (final avd in avds) {
        if (avd.name != wanted) continue;
        if (avd.runningSerial case final serial?) {
          return {
            'serial': serial,
            'platform': 'android',
            'booted': true,
            'note': '$wanted is already running as $serial.',
          };
        }
        final serial = await adb.bootAvdAndWait(wanted, headless: true);
        _container.invalidate(devicesProvider);
        _container.invalidate(avdsProvider);
        return {
          'serial': serial,
          'name': wanted,
          'platform': 'android',
          'booted': true,
          'note':
              'Booted headless — it has no window of its own. Use '
              'device_screenshot and device_ui_dump to see it.',
        };
      }
    }
    throw StateError(
      'Nothing bootable is called "$wanted". '
      '${await _bootableSummary(resolver, adb)}',
    );
  }

  Future<Object?> _bootSimulator(SimulatorTarget target) async {
    if (!target.simulator.isAvailable) {
      throw StateError(
        '${target.label} cannot be booted: its runtime '
        '(${target.simulator.runtimeName}) is not installed. Install it in '
        'Xcode, or boot a simulator list_devices reports as available.',
      );
    }
    if (target.isReady) {
      return {
        'udid': target.id,
        'serial': target.id,
        'name': target.simulator.name,
        'platform': 'ios',
        'booted': true,
        'note': '${target.label} is already booted.',
      };
    }
    final transitions = _container.read(simulatorTransitionsProvider.notifier);
    // The notifier returns silently when a boot is already in flight for this
    // udid, which for the UI is right — a second click on a spinning button is
    // nothing — but for a tool it would be a call that reported success having
    // done nothing at all.
    if (transitions.isBusy(target.id)) {
      throw StateError(
        '${target.label} is already being started or stopped by this app. Wait '
        'for that to finish, then call list_devices to see where it got to.',
      );
    }
    await transitions.boot(target.id);
    final booted = await _resolver().find(target.id);
    return {
      'udid': target.id,
      'serial': target.id,
      'name': target.simulator.name,
      'platform': 'ios',
      'booted': booted?.isReady ?? false,
      'state': switch (booted) {
        SimulatorTarget(simulator: final s) => s.state.name,
        _ => 'unknown',
      },
      'note':
          'Booted headless — simctl opens no window, and this pane mirrors it. '
          'Coordinates for device_tap on this device are in POINTS; '
          'device_ui_dump reports them in the right space.',
    };
  }

  Future<String> _bootableSummary(
    DeviceTargetResolver resolver,
    AdbService? adb,
  ) async {
    final parts = <String>[];
    if (adb == null) {
      parts.add('There is no Android SDK here, so there are no AVDs.');
    } else {
      final stopped = [
        for (final avd in await adb.listAvds())
          if (!avd.isRunning) avd.name,
      ];
      parts.add(
        stopped.isEmpty
            ? 'No stopped AVDs.'
            : 'AVDs: ${stopped.take(20).join(', ')}'
                  '${stopped.length > 20 ? ', …' : ''}.',
      );
    }
    final simulators = await resolver.simulatorTargets();
    final bootable = [
      for (final target in simulators)
        if (target.simulator.isAvailable &&
            target.simulator.state == SimulatorState.shutdown)
          target.label,
    ];
    parts.add(
      bootable.isEmpty
          ? 'No bootable simulators.'
          : '${bootable.length} bootable simulators, e.g. '
                '${bootable.take(6).join(', ')}. Call list_devices for the '
                'rest.',
    );
    return parts.join(' ');
  }

  /// Installs a build onto a device or simulator.
  ///
  /// The half of the loop that was missing. An agent could tap and read a
  /// screen but could not put its own build in front of itself, which made the
  /// whole surface useful only for apps somebody had already installed by hand.
  ///
  /// The artifact kinds are checked here rather than left to the tool
  /// underneath, because both tools fail obscurely on the other platform's
  /// file: `adb install` on a `.app` directory reports a parse failure, and
  /// `simctl install` on an `.ipa` reports an architecture mismatch. Neither
  /// says "you gave this to the wrong device", which is the actual mistake.
  Future<Object?> _deviceInstallApp({String? id, String? path}) async {
    if (path == null || path.trim().isEmpty) {
      throw ArgumentError(
        'path is required: an .apk for Android, or a simulator .app bundle for '
        'iOS.',
      );
    }
    final artifact = path.trim();
    final lower = artifact.toLowerCase();
    final target = await _resolveDevice(id, 'device_install_app');

    switch (target) {
      case AndroidTarget():
        if (lower.endsWith('.app') || lower.endsWith('.ipa')) {
          throw ArgumentError(
            '$artifact is an iOS build, and ${target.id} is an Android device. '
            'Give an .apk, or install this onto a simulator — list_devices '
            'shows which are booted.',
          );
        }
        if (!lower.endsWith('.apk')) {
          throw ArgumentError(
            'device_install_app installs an .apk on Android, and $artifact is '
            'not one. Split builds (.aab, .apks) have to be turned into an APK '
            'first — bundletool build-apks, then install the universal APK.',
          );
        }
        await _requireAdb().installApk(target.id, artifact);
        return {
          'serial': target.id,
          'platform': 'android',
          'installed': artifact,
          'note':
              'Launch it with device_launch_app(appId: "<applicationId>"). '
              'adb does not report the package name an APK declares, so pass '
              'the applicationId from the build — this tool cannot infer it.',
        };
      case SimulatorTarget():
        if (lower.endsWith('.apk')) {
          throw ArgumentError(
            '$artifact is an Android build, and ${target.label} is an iOS '
            'simulator. Give a simulator .app bundle, or install this onto an '
            'Android device.',
          );
        }
        if (lower.endsWith('.ipa')) {
          throw ArgumentError(
            'simctl cannot install an .ipa. An .ipa carries the device slice '
            '(arm64 built against the iOS SDK) and a simulator needs the '
            'simulator slice — they are different binaries, not different '
            'packaging. Build for the simulator '
            '(flutter build ios --simulator, or xcodebuild -sdk '
            'iphonesimulator) and pass the .app.',
          );
        }
        if (!lower.endsWith('.app')) {
          throw ArgumentError(
            'device_install_app installs a .app bundle on a simulator, and '
            '$artifact is not one.',
          );
        }
        // simctl is always local — it only exists on this Mac — so the
        // filesystem here is the filesystem it will look at, and checking
        // first turns "The application at … could not be opened" into a
        // sentence about the path that was actually passed.
        if (!Directory(artifact).existsSync()) {
          throw ArgumentError(
            'There is no .app bundle at $artifact. A .app is a directory, not '
            'a file — check the path, and note that a Flutter simulator build '
            'lands in build/ios/iphonesimulator/Runner.app.',
          );
        }
        final simctl = _requireSimctl();
        await simctl.installApp(target.id, artifact);
        final bundleId = await simctl.readAppBundleId(artifact);
        return {
          'udid': target.id,
          'serial': target.id,
          'platform': 'ios',
          'installed': artifact,
          'bundleId': ?bundleId,
          'note': bundleId == null
              ? 'Could not read CFBundleIdentifier out of the bundle, so '
                    'device_launch_app needs the bundle id from you.'
              : 'Launch it with device_launch_app(appId: "$bundleId").',
        };
    }
  }

  Future<Object?> _deviceLaunchApp({
    String? id,
    String? appId,
    String? activity,
    bool relaunch = false,
  }) async {
    if (appId == null || appId.trim().isEmpty) {
      throw ArgumentError(
        'appId is required: an Android applicationId (com.example.app) or an '
        'iOS bundle id (com.example.App).',
      );
    }
    final app = appId.trim();
    final target = await _resolveDevice(id, 'device_launch_app');
    switch (target) {
      case AndroidTarget():
        final adb = _requireAdb();
        if (activity != null && activity.trim().isNotEmpty) {
          await adb.startActivity(target.id, app, activity.trim());
        } else {
          await adb.launchPackage(target.id, app);
        }
        return {
          'serial': target.id,
          'platform': 'android',
          'launched': app,
          'activity': ?activity,
          'note':
              'Give it a moment to draw, then read it with device_ui_dump.'
              '${relaunch ? ' (relaunch is an iOS-only option and was ignored '
                        'here — on Android, device_terminate_app then '
                        'device_launch_app does the same thing.)' : ''}',
        };
      case SimulatorTarget():
        if (activity != null && activity.trim().isNotEmpty) {
          throw ArgumentError(
            'activity is an Android idea and ${target.label} is a simulator: '
            'an iOS app has one entry point, not a set of activities. Drop '
            'activity to launch the app, or reach a particular screen through '
            'its URL scheme.',
          );
        }
        final pid = await _requireSimctl().launchApp(
          target.id,
          app,
          relaunch: relaunch,
        );
        return {
          'udid': target.id,
          'serial': target.id,
          'platform': 'ios',
          'launched': app,
          'pid': ?pid,
          'note':
              'Give it a moment to draw, then read it with device_ui_dump. '
              '${relaunch ? 'Any running copy was terminated first, so this is '
                        'a cold start.' : 'An already-running app is brought to '
                        'the front rather than restarted — pass relaunch=true '
                        'for a cold start.'}',
        };
    }
  }

  Future<Object?> _deviceTerminateApp({String? id, String? appId}) async {
    if (appId == null || appId.trim().isEmpty) {
      throw ArgumentError('appId is required.');
    }
    final app = appId.trim();
    final target = await _resolveDevice(id, 'device_terminate_app');
    switch (target) {
      case AndroidTarget():
        await _requireAdb().forceStopPackage(target.id, app);
      case SimulatorTarget():
        await _requireSimctl().terminateApp(target.id, app);
    }
    return {
      'serial': target.id,
      'platform': target.platform.name,
      'terminated': app,
      // Both platforms treat "it was not running" as success, and saying so is
      // the difference between a caller trusting this reply and a caller
      // re-checking with a UI dump.
      'note':
          'An app that was not running is not an error — this asks for a '
          'state, and reports the state it left behind.',
    };
  }

  /// Stops a running virtual device, on either platform.
  ///
  /// **Widened rather than given an iOS sibling.** The name is Android's word,
  /// and a `device_shutdown_simulator` beside it would have read more
  /// naturally — but it would also mean an agent holding an id out of
  /// `list_devices` has to work out which platform it belongs to before it can
  /// choose a verb, which is the exact failure the one-family decision above
  /// exists to prevent. Renaming the tool was the other option and was rejected
  /// outright: `device_stop_emulator` is what existing callers already call.
  /// So the verb keeps its name and grows a second meaning, and its description
  /// says both.
  ///
  /// The id is required rather than inferred: every other device tool defaults
  /// to "the only ready device", and silently defaulting a destructive action
  /// is a different thing entirely.
  Future<Object?> _deviceStopEmulator(String? id) async {
    if (id == null || id.trim().isEmpty) {
      throw ArgumentError(
        'serial is required for device_stop_emulator — an emulator serial or a '
        'simulator udid. It is not inferred, because stopping the wrong device '
        'loses whatever was on it.',
      );
    }
    final target = await _resolver().requireExisting(
      id,
      verb: 'device_stop_emulator',
    );
    switch (target) {
      case AndroidTarget():
        if (!target.device.isEmulator) {
          throw StateError(
            '${target.id} is a physical device. Only emulators and simulators '
            'can be stopped this way — unplug it, or turn it off yourself.',
          );
        }
        final stopped = await _requireAdb().stopEmulator(target.id);
        if (!stopped) {
          throw StateError(
            '${target.id} did not exit. It may be busy; try again, or close '
            'its window.',
          );
        }
        return {'serial': target.id, 'platform': 'android', 'stopped': true};
      case SimulatorTarget():
        if (!target.isReady && target.simulator.state == SimulatorState.shutdown) {
          return {
            'udid': target.id,
            'serial': target.id,
            'platform': 'ios',
            'stopped': true,
            'note': '${target.label} was already shut down.',
          };
        }
        final transitions = _container.read(
          simulatorTransitionsProvider.notifier,
        );
        if (transitions.isBusy(target.id)) {
          throw StateError(
            '${target.label} is already being started or stopped by this app. '
            'Wait for that to finish, then check list_devices.',
          );
        }
        await transitions.shutdown(target.id);
        final after = await _resolver().find(target.id);
        return {
          'udid': target.id,
          'serial': target.id,
          'platform': 'ios',
          'stopped': after == null || !after.isReady,
          'note':
              'Shut down, not erased — its apps and data are still there for '
              'the next boot. device_boot brings it back.',
        };
    }
  }

  // ---------------------------------------------------------------------------
  // The accessibility tree
  //
  // `device_tap` needs coordinates, and the only way an agent could previously
  // get them was to read them off a screenshot — which cannot say what is
  // tappable, and is one scale factor away from tapping the wrong thing while
  // reporting success. These three tools hand it the view hierarchy instead:
  // what is on screen, and exactly where to hit it.
  //
  // On iOS this is the *only* honest way to get a coordinate, because the
  // screenshot is in pixels and the tap is in points. See [_ScreenRead].
  // ---------------------------------------------------------------------------

  UiElementQuery _uiQuery(Map<String, dynamic> args) => UiElementQuery(
    text: args['text'] as String?,
    resourceId: args['resourceId'] as String?,
    contentDescription: args['contentDesc'] as String?,
    className: args['className'] as String?,
    exact: args['exact'] == true,
    clickableOnly: args['clickable'] == true,
  );

  /// One read of what is on a screen, with the coordinate space it is in.
  ///
  /// The space is carried rather than assumed because the two platforms differ
  /// and the difference is invisible in the numbers: `(201, 437)` is a
  /// plausible point on either device, and only one of them is right.
  Future<_ScreenRead> _readScreen(DeviceTarget target, String verb) async {
    switch (target) {
      case AndroidTarget():
        final adb = _requireAdb();
        final tree = await adb.dumpUiHierarchy(target.id);
        return _ScreenRead(
          tree: tree,
          screen: await adb.screenSize(target.id),
          space: 'device px',
          app: tree.packageName,
        );
      case SimulatorTarget():
        final tree = await _requireBackend(verb).describeUi(target.id);
        // The size comes out of the tree rather than from a second round trip.
        // WebDriverAgent's root element *is* the application window, so its
        // frame is the screen — which is precisely how `parseWdaUiRead` derives
        // the `screen` it reports, and asking the backend again would fetch and
        // parse the whole `/source` document a second time to learn the same
        // number.
        final root = tree.roots.firstOrNull;
        final bounds = root?.bounds;
        return _ScreenRead(
          tree: tree,
          screen: bounds == null || bounds.isEmpty
              ? null
              : DeviceScreenSize(width: bounds.width, height: bounds.height),
          space: 'points',
          // WDA puts the bundle id on the Application element's `name`, which
          // this build maps onto `resourceId`. iOS nodes carry no package, so
          // `UiHierarchy.packageName` is always null here.
          app: root == null || root.resourceId.isEmpty ? null : root.resourceId,
        );
    }
  }

  /// One line naming the device, the foreground app and the coordinate space.
  String _uiHeader(DeviceTarget target, _ScreenRead read) =>
      '${target.id} · ${read.app ?? 'unknown app'} · '
      'screen ${read.screen ?? 'unknown'} ${read.space} · '
      'rotation ${read.tree.rotation}';

  Future<Object?> _deviceUiDump({
    String? id,
    bool full = false,
    String? filter,
    int? limit,
  }) async {
    final target = await _resolveDevice(id, 'device_ui_dump');
    final read = await _readScreen(target, 'device_ui_dump');
    final tree = read.tree;
    final screen = read.screen;

    if (full && filter == null) {
      final body = renderUiTree(tree, screen: screen);
      return _uiText([
        'Full UI hierarchy · ${_uiHeader(target, read)}',
        '${tree.nodeCount} nodes, indented by depth.',
        uiListingLegend,
        _spaceLine(read),
        '',
        body,
      ]);
    }

    var nodes = full ? tree.allNodes.toList() : interestingNodes(tree);
    if (filter != null && filter.trim().isNotEmpty) {
      final needle = filter.trim().toLowerCase();
      bool has(String value) => value.toLowerCase().contains(needle);
      nodes = [
        for (final node in nodes)
          if (has(node.text) ||
              has(node.contentDescription) ||
              has(node.resourceId) ||
              has(node.className))
            node,
      ];
    }
    final rendered = renderUiElements(
      nodes,
      screen: screen,
      limit: limit ?? 200,
    );
    return _uiText([
      'UI hierarchy · ${_uiHeader(target, read)}',
      '${rendered.shown} of ${tree.nodeCount} nodes'
          '${full ? '' : ' (text-bearing or interactable)'}'
          '${filter == null ? '' : ', filtered by "$filter"'}'
          '${rendered.truncated == 0 ? '.' : ', ${rendered.truncated} more not '
                    'shown — raise limit.'}',
      uiListingLegend,
      _spaceLine(read),
      '',
      rendered.listing.isEmpty ? '(nothing matched)' : rendered.listing,
      '',
      'Tap one with device_tap_element(text: "…"), which re-reads the screen '
          'and hits the element itself. The coordinates above also work with '
          'device_tap.',
    ]);
  }

  Future<Object?> _deviceFindElements({
    String? id,
    required UiElementQuery query,
    int? limit,
  }) async {
    if (query.isEmpty) {
      throw ArgumentError(
        'Give at least one of text, resourceId, contentDesc or className. '
        'Use device_ui_dump to see the whole screen.',
      );
    }
    final target = await _resolveDevice(id, 'device_find_elements');
    final read = await _readScreen(target, 'device_find_elements');
    final tree = read.tree;
    final screen = read.screen;
    final matches = tree.find(query);
    if (matches.isEmpty) {
      return _uiText([
        'No element matches $query on ${_uiHeader(target, read)}',
        '',
        'What is on screen instead:',
        uiListingLegend,
        _spaceLine(read),
        renderUiElements(
          interestingNodes(tree),
          screen: screen,
          limit: 60,
        ).listing,
      ]);
    }
    final rendered = renderUiElements(
      matches,
      screen: screen,
      limit: limit ?? 50,
    );
    return _uiText([
      '${matches.length} element${matches.length == 1 ? '' : 's'} match '
          '$query · ${_uiHeader(target, read)}',
      'Best match first; an exact label beats a substring.',
      uiListingLegend,
      _spaceLine(read),
      '',
      rendered.listing,
    ]);
  }

  Future<Object?> _deviceTapElement({
    String? id,
    required UiElementQuery query,
    int? index,
  }) async {
    if (query.isEmpty) {
      throw ArgumentError(
        'Give at least one of text, resourceId, contentDesc or className.',
      );
    }
    final target = await _resolveDevice(id, 'device_tap_element');
    final read = await _readScreen(target, 'device_tap_element');
    final tree = read.tree;
    final screen = read.screen;
    final matches = tree.find(query);

    if (matches.isEmpty) {
      throw StateError(
        'Nothing matches $query on ${target.id}. On screen now:\n'
        '${renderUiElements(interestingNodes(tree), screen: screen, limit: 60).listing}',
      );
    }

    final UiNode target0;
    if (index != null) {
      if (index < 0 || index >= matches.length) {
        throw ArgumentError(
          'index $index is out of range: there are ${matches.length} matches.',
        );
      }
      target0 = matches[index];
    } else if (matches.length == 1) {
      target0 = matches.first;
    } else {
      // Several matches. One unambiguous exact label is still a decision we can
      // make; anything else is a guess, and a wrong tap is worse than an error
      // because the agent cannot tell it happened.
      final exact = [
        for (final node in matches)
          if (query.rank(node) == 0) node,
      ];
      if (exact.length == 1) {
        target0 = exact.single;
      } else {
        throw StateError(
          '$query matches ${matches.length} elements on ${target.id}. '
          'Pass index to choose, or narrow the query:\n'
          '${_indexed(matches, screen)}',
        );
      }
    }

    final bounds = target0.tapBounds;
    if (bounds == null) {
      throw StateError(
        'The matched element reports no bounds, so there is nowhere to tap: '
        '${describeUiNode(target0, screen: screen)}',
      );
    }
    if (screen != null && !bounds.centerIsOnScreen(screen)) {
      throw StateError(
        'The matched element is off screen at ${bounds.raw} on a $screen '
        '${read.space} display — it is scrolled out of view. Scroll it into '
        'view first; tapping its centre would hit whatever is really at that '
        'point.',
      );
    }

    final point = bounds.center;
    switch (target) {
      case AndroidTarget():
        await _requireAdb().tap(target.id, point.x, point.y);
      case SimulatorTarget():
        await _requireBackend('device_tap_element').tap(
          target.id,
          point.x,
          point.y,
        );
    }
    return _uiText([
      'Tapped (${point.x}, ${point.y}) ${read.space} on '
          '${describeUiNode(target0, screen: screen)}',
      'Device ${target.id}, ${read.app ?? 'unknown app'}'
          '${matches.length == 1 ? '' : ', chosen from ${matches.length} matches'}.'
          '${target0.enabled ? '' : ' NOTE: this element is disabled.'}',
      'Take a screenshot or dump again to confirm what changed.',
    ]);
  }

  /// The coordinate space, said once per listing where it cannot be missed.
  String _spaceLine(_ScreenRead read) => read.space == 'points'
      ? 'Coordinates are in POINTS (iOS), which is what device_tap and '
            'device_tap_element take on a simulator — NOT the pixels a '
            'device_screenshot image is in.'
      : 'Coordinates are in device pixels.';

  static String _spaceOf(DeviceTarget target) =>
      target.platform == DevicePlatform.ios ? 'points' : 'device px';

  /// The matches numbered, so the caller can pass `index`.
  String _indexed(List<UiNode> matches, DeviceScreenSize? screen) => [
    for (var i = 0; i < matches.length && i < 20; i++)
      '[$i] ${describeUiNode(matches[i], screen: screen)}',
  ].join('\n');

  /// Wraps a listing as an MCP text block.
  ///
  /// Deliberately not returned as a JSON map: the bridge pretty-prints every
  /// map result, and one JSON object per node costs several times what one line
  /// per node does. The whole point of this surface is that a screen fits in a
  /// few hundred tokens.
  Object _uiText(List<String> sections) => {
    '_mcpContent': [
      {'type': 'text', 'text': sections.join('\n')},
    ],
  };

  LogLevel? _parseLogLevel(String? level) {
    if (level == null) return null;
    final needle = level.trim().toLowerCase();
    for (final value in LogLevel.values) {
      if (value.name == needle || value.code.toLowerCase() == needle) {
        return value;
      }
    }
    return null;
  }
}

/// What one screen read produced, and which coordinate space it is in.
class _ScreenRead {
  const _ScreenRead({
    required this.tree,
    required this.screen,
    required this.space,
    required this.app,
  });

  final UiHierarchy tree;

  /// The screen, in [space]. Null when the platform would not say.
  final DeviceScreenSize? screen;

  /// `device px` on Android, `points` on iOS.
  final String space;

  /// The foreground app: a package name on Android, a bundle id on iOS.
  final String? app;
}

/// The schemas for [DeviceControlTools].
const List<Map<String, dynamic>> deviceControlToolSchemas = [
  {
    'name': 'list_devices',
    'description':
        'List everything this machine can drive: connected Android devices '
        'and running emulators, plus iOS Simulators (every booted one, and '
        'the bootable ones newest-runtime-first). Android devices appear '
        'under "devices" keyed by serial; simulators under "simulators" keyed '
        'by udid, with "running" saying which are up. Either identifier can be '
        'passed to every other device_* tool. Devices that are not usable '
        '(unauthorized, offline, no installed runtime) are included and marked '
        'so you can explain the problem rather than reporting no devices. '
        'Coordinates: Android is device pixels, a simulator is points.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'limit': {
          'type': 'number',
          'description':
              'Max simulators to list (default 40). A Mac can hold hundreds; '
              'booted ones are always listed.',
        },
      },
    },
  },
  {
    'name': 'device_screenshot',
    'description':
        'Capture the current screen of an Android device or iOS simulator as '
        'a PNG image. Use this to see what an app is actually showing. serial '
        '(or udid) is optional when exactly one device is ready. NOTE on a '
        'simulator the image is in PIXELS while taps are in POINTS — prefer '
        'device_ui_dump when you intend to touch something.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'serial': {
          'type': 'string',
          'description': 'Android serial or simulator udid from list_devices.',
        },
        'udid': {'type': 'string', 'description': 'Alias for serial.'},
      },
    },
  },
  {
    'name': 'device_tap',
    'description':
        'Tap the screen at (x, y). On Android these are DEVICE PIXELS (the '
        'space list_devices reports as screen size, not the size of any '
        'screenshot you scaled). On an iOS simulator they are POINTS, which a '
        'screenshot is NOT in. Prefer device_tap_element; if you must use '
        'coordinates, take them from device_ui_dump, which reports them in '
        'the right space for the device.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'serial': {'type': 'string'},
        'udid': {'type': 'string', 'description': 'Alias for serial.'},
        'x': {'type': 'number'},
        'y': {'type': 'number'},
      },
      'required': ['x', 'y'],
    },
  },
  {
    'name': 'device_type',
    'description':
        'Type text into whatever field currently has focus, on Android or on '
        'an iOS simulator. Tap the field first. Android escapes shell '
        'characters for you; iOS types through XCUITest, so anything the '
        'keyboard can produce travels as itself.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'serial': {'type': 'string'},
        'udid': {'type': 'string', 'description': 'Alias for serial.'},
        'text': {'type': 'string'},
      },
      'required': ['text'],
    },
  },
  {
    'name': 'device_key',
    'description':
        'Press a hardware button: back, home, recents, power, volumeUp, '
        'volumeDown, enter, tab or delete. All nine work on Android. On an iOS '
        'simulator home and power are real buttons, enter/tab/delete are typed '
        'into the focused field, and back/recents/volume are refused with a '
        'reason — iOS has no system back button and its app switcher cannot be '
        'reached by injected touches.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'serial': {'type': 'string'},
        'udid': {'type': 'string', 'description': 'Alias for serial.'},
        'key': {
          'type': 'string',
          'description':
              'back | home | recents | power | volumeUp | '
              'volumeDown | enter | tab | delete',
        },
      },
      'required': ['key'],
    },
  },
  {
    'name': 'device_logcat',
    'description':
        'Read recent device log output, newest last. On Android this is '
        'logcat: filter to one app with package (strongly recommended) and '
        'raise level to see only warnings or errors. On an iOS simulator it is '
        '`log show` over the last 5 minutes: level is refused (iOS levels are '
        'not Android levels) and package is matched as a plain substring of '
        'each line, which the reply says.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'serial': {'type': 'string'},
        'udid': {'type': 'string', 'description': 'Alias for serial.'},
        'package': {
          'type': 'string',
          'description':
              'Android application id, e.g. com.example.app. On iOS, a '
              'substring to match in each line.',
        },
        'level': {
          'type': 'string',
          'description':
              'Android only. Minimum level: verbose, debug, info, warning, '
              'error, fatal.',
        },
        'lines': {'type': 'number', 'description': 'Max lines (default 200).'},
      },
    },
  },
  {
    'name': 'device_boot',
    'description':
        'Start a virtual device and wait until it can actually be talked to — '
        'not just until it appears. Takes an AVD name, an iOS simulator udid, '
        'or a simulator name ("iPhone 17 Pro") when that names exactly one. '
        'Boots headless: no window of its own, which is what device_screenshot '
        'and device_ui_dump are for. Already running is success. Returns the '
        'id every other device_* tool wants — an emulator serial, or the udid.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'name': {
          'type': 'string',
          'description': 'AVD name, simulator udid, or simulator name.',
        },
        'serial': {'type': 'string', 'description': 'Alias for name.'},
        'udid': {'type': 'string', 'description': 'Alias for name.'},
      },
      'required': ['name'],
    },
  },
  {
    'name': 'device_install_app',
    'description':
        'Install a build onto a device or simulator: an .apk on Android '
        '(reinstalling over any existing copy and keeping its data), or a '
        'simulator .app bundle on iOS. This is what turns build-run-drive into '
        'one loop. An .ipa is refused — it carries the device slice, and a '
        'simulator needs the simulator slice (flutter build ios --simulator). '
        'On iOS the reply carries the bundle id read out of the bundle, ready '
        'for device_launch_app.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'serial': {'type': 'string'},
        'udid': {'type': 'string', 'description': 'Alias for serial.'},
        'path': {
          'type': 'string',
          'description':
              'Absolute path to the .apk or the .app bundle directory.',
        },
      },
      'required': ['path'],
    },
  },
  {
    'name': 'device_launch_app',
    'description':
        'Launch an installed app by Android applicationId or iOS bundle id. '
        'On Android the launcher activity is resolved for you; pass activity '
        'to start a specific one instead. On iOS pass relaunch=true to '
        'terminate any running copy first, which is what makes it a cold '
        'start rather than a switch to the front.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'serial': {'type': 'string'},
        'udid': {'type': 'string', 'description': 'Alias for serial.'},
        'appId': {
          'type': 'string',
          'description': 'com.example.app (Android) or com.example.App (iOS).',
        },
        'activity': {
          'type': 'string',
          'description':
              'Android only. Activity to start, e.g. .MainActivity. Refused '
              'on iOS, which has no activities.',
        },
        'relaunch': {
          'type': 'boolean',
          'description': 'iOS only. Terminate a running copy first.',
        },
      },
      'required': ['appId'],
    },
  },
  {
    'name': 'device_terminate_app',
    'description':
        'Stop a running app — force-stop on Android, simctl terminate on a '
        'simulator. An app that was not running is not an error.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'serial': {'type': 'string'},
        'udid': {'type': 'string', 'description': 'Alias for serial.'},
        'appId': {'type': 'string'},
      },
      'required': ['appId'],
    },
  },
  {
    'name': 'device_stop_emulator',
    'description':
        'Shut a running Android emulator OR iOS simulator down, freeing its '
        'memory and CPU. Virtual devices only — a physical phone cannot be '
        'stopped this way. On Android anything the emulator has not written to '
        'a snapshot is lost; a simulator keeps its apps and data for the next '
        'boot. The id is required and never inferred.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'serial': {
          'type': 'string',
          'description':
              'Emulator serial (emulator-5554) or simulator udid.',
        },
        'udid': {'type': 'string', 'description': 'Alias for serial.'},
      },
      'required': ['serial'],
    },
  },
  {
    'name': 'device_ui_dump',
    'description':
        'Read the accessibility (view) hierarchy of the current screen: what '
        'is on it, what each element says, and the exact point to tap for '
        'each one. Works on Android (uiautomator) and on an iOS simulator '
        '(WebDriverAgent). Prefer this over device_screenshot when you intend '
        'to touch something — a screenshot cannot tell you what is tappable, '
        'coordinates read off an image are guesswork, and on iOS the image is '
        'in a different unit from the tap. By default only nodes that carry '
        'text or accept input are listed; pass full=true for every node.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'serial': {'type': 'string'},
        'udid': {'type': 'string', 'description': 'Alias for serial.'},
        'full': {
          'type': 'boolean',
          'description':
              'Include every node instead of only the useful ones. Much '
              'larger; use it only when the default listing is missing '
              'something.',
        },
        'filter': {
          'type': 'string',
          'description':
              'Keep only nodes whose text, content-description, resource id '
              'or class contains this (case-insensitive).',
        },
        'limit': {
          'type': 'number',
          'description': 'Max nodes to list (default 200).',
        },
      },
    },
  },
  {
    'name': 'device_find_elements',
    'description':
        'Find elements on the current screen by text, resource id, '
        'content-description or class, and get the point to tap for each. '
        'Matching is case-insensitive and by substring unless exact=true. '
        'text matches BOTH the text and the content-description, which is '
        'what makes it work on Flutter apps: they put their labels in '
        'content-desc and leave text empty. On iOS the same query runs against '
        'the XCUITest tree, where an element\'s label and value are mapped '
        'onto the same two fields.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'serial': {'type': 'string'},
        'udid': {'type': 'string', 'description': 'Alias for serial.'},
        'text': {
          'type': 'string',
          'description': 'Visible text or content-description to look for.',
        },
        'resourceId': {
          'type': 'string',
          'description': 'Resource id, in full (com.app:id/ok) or short (ok).',
        },
        'contentDesc': {
          'type': 'string',
          'description': 'Content-description only, ignoring text.',
        },
        'className': {
          'type': 'string',
          'description': 'Class, in full or by last segment (Button).',
        },
        'exact': {
          'type': 'boolean',
          'description': 'Require the whole value to match, not a substring.',
        },
        'clickable': {
          'type': 'boolean',
          'description': 'Keep only elements marked clickable.',
        },
        'limit': {'type': 'number', 'description': 'Max matches (default 50).'},
      },
    },
  },
  {
    'name': 'device_tap_element',
    'description':
        'Tap the element matching a query rather than a coordinate — '
        'tap_element(text: "Sign in") instead of tap(357, 126). This is far '
        'more reliable: it survives layout changes, it cannot be off by a '
        'scale factor — which on iOS is a factor of three — and it tells you '
        'what it actually hit. It re-reads the hierarchy first, so it acts on '
        'the screen as it is now. Refuses rather than guessing when the query '
        'matches several elements (pass index) or nothing, and refuses to tap '
        'an element that is scrolled off screen.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'serial': {'type': 'string'},
        'udid': {'type': 'string', 'description': 'Alias for serial.'},
        'text': {
          'type': 'string',
          'description': 'Visible text or content-description to tap.',
        },
        'resourceId': {'type': 'string'},
        'contentDesc': {'type': 'string'},
        'className': {'type': 'string'},
        'exact': {'type': 'boolean'},
        'clickable': {
          'type': 'boolean',
          'description': 'Only consider elements marked clickable.',
        },
        'index': {
          'type': 'number',
          'description':
              'Which match to tap (0-based) when the query is ambiguous.',
        },
      },
    },
  },
];
