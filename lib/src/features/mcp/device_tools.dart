import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../devices/application/device_claims.dart';
import '../devices/application/device_fleet.dart';
import '../devices/application/device_screen_memory.dart';
import '../devices/domain/device_claim.dart';
import '../devices/domain/device_driver.dart';
import '../devices/domain/device_input.dart';
import '../devices/domain/device_target.dart';
import '../devices/domain/ios_simulator.dart';
import '../devices/domain/screen_observation.dart';
import '../devices/domain/ui_node.dart';
import '../devices/domain/ui_summary.dart';

/// An attached Android device, an Android emulator, or an iOS Simulator, as an
/// agent can drive it end to end: list, boot, install, launch, tap, read back.
///
/// Everything goes through the same services the device pane uses, so the agent
/// and the person beside it are looking at and touching one device rather than
/// two views of it.
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
/// So there is one family, the id is the discriminator, and `DeviceFleet` does
/// the dispatch. Every existing Android caller keeps working unchanged, because
/// an Android serial still resolves to exactly what it always did.
///
/// ## Nothing in this file knows what kind of device it is holding
///
/// Every handler below resolves a [DeviceDriver] and then speaks only that
/// interface. There is no `if (isSimulator)` here, and adding one would be the
/// bug: the engine behind a simulator has already been swapped once — idb out,
/// WebDriverAgent in — and a `CoreSimulator` or `pymobiledevice3` driver should
/// cost this file nothing. The only place that names a platform is
/// `list_devices`, which is a *listing* and whose whole job is to say which is
/// which.
///
/// ## A tool never pretends
///
/// Two mechanisms, both of them checked here before anything is attempted:
/// [DeviceCapability], for what a driver cannot do at all, and [DeviceRefusal],
/// for what it cannot do with these particular arguments. Either way the caller
/// gets a sentence naming the device, the thing that is missing, and what still
/// works. An agent has no eyes, so a verb that quietly does nothing reads to it
/// as a verb that worked.
///
/// Lifted out of `LauncherControlServer` unchanged. It was the largest family
/// still inline there, and the seam was already drawn — the terminal, browser,
/// workspace and verification tools had each been given a file of their own,
/// and the device tools' only tie to the server was the container they read
/// providers from.
///
/// ## One task per device
///
/// Everything below that changes a device goes through [DeviceClaims] first, so
/// two agents cannot interleave taps on one phone. Everything that only *reads*
/// one goes through it too, but only to say the holder is still working — a read
/// never takes a claim and is never refused. See `device_claim.dart` for why a
/// device gets a lock when a repository deliberately does not.
class DeviceControlTools {
  DeviceControlTools(this._container, {this.callerSessionId});

  final ProviderContainer _container;

  /// Which of our sessions is calling, when one is. Established by the
  /// transport, never by an argument — see `McpCallerRegistry`.
  final String? callerSessionId;

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
    'device_files_list',
    'device_file_pull',
    'device_file_push',
  };

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'list_devices' => _listDevices((args['limit'] as num?)?.round()),
        'device_screenshot' => _deviceScreenshot(_id(args)),
        'device_files_list' => _filesList(
          _id(args),
          args['path'] as String?,
        ),
        'device_file_pull' => _filePull(
          _id(args),
          args['device_path'] as String?,
          args['destination_directory'] as String?,
        ),
        'device_file_push' => _filePush(
          _id(args),
          args['host_path'] as String?,
          args['device_path'] as String?,
          args['overwrite'] == true,
        ),
        'device_tap' => _deviceTap(
          _id(args),
          (args['x'] as num?)?.round(),
          (args['y'] as num?)?.round(),
          // Default on. The check is skipped only when the caller says so, so a
          // screen with nothing in its hierarchy is a decision rather than a
          // silent gap.
          verify: args['verify'] != false,
        ),
        'device_type' => _deviceType(
          _id(args),
          args['text'] as String?,
          submit: args['submit'] == true,
        ),
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
        'device_boot' => _deviceBoot((args['name'] as String?) ?? _id(args)),
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
  /// "I copied the field name out of your own output and you rejected it".
  static String? _id(Map<String, dynamic> args) =>
      (args['serial'] ?? args['udid'] ?? args['device']) as String?;

  Future<DeviceFleet> _fleet() => _container.read(deviceFleetProvider)();

  DeviceClaims get _claims => _container.read(deviceClaimsProvider);

  DeviceScreenMemory get _screens =>
      _container.read(deviceScreenMemoryProvider);

  /// Files a screen this call has just read, so the next coordinate tap has
  /// something to be checked against.
  ScreenObservation _recordLook(DeviceDriver driver, ScreenRead read) =>
      _screens.record(
        deviceId: driver.target.id,
        tree: read.tree,
        app: read.app,
        bySessionId: callerSessionId,
      );

  /// The driver for this call, or a refusal naming the device.
  Future<DeviceDriver> _driver(String? id, String verb) async =>
      (await _fleet()).driverFor(id, verb: verb);

  /// The driver for a call that only **reads** this device.
  ///
  /// The capability is checked up front rather than left to fail inside the
  /// driver, so the refusal names the capability that is missing and what still
  /// works — the driver's own error would name whatever step happened to fall
  /// over first.
  ///
  /// A read renews a claim this caller already holds and never takes one, so
  /// looking at a phone somebody else is driving is always allowed. It has to
  /// be: an agent that has just been refused needs to be able to see what the
  /// holder is doing.
  Future<DeviceDriver> _driverThatCan(
    String? id,
    String verb,
    DeviceCapability capability,
  ) async {
    final driver = await _driver(id, verb);
    _require(driver, verb, capability);
    _claims.observed(
      deviceId: driver.target.id,
      sessionId: callerSessionId,
    );
    return driver;
  }

  /// The driver for a call that will **change** this device, with the device
  /// taken for this caller — or [DeviceBusy] naming whoever is driving it.
  ///
  /// Ordered deliberately. The driver resolves first so the claim is keyed on
  /// the canonical id: two agents naming one phone two different ways
  /// (`emulator-5554` and an AVD name, a serial and a udid) must collide rather
  /// than miss each other. The capability is checked before the claim, so a
  /// device that cannot do the thing is not held while it is being told so.
  Future<DeviceDriver> _driverToDrive(
    String? id,
    String verb,
    DeviceCapability capability,
  ) async {
    final driver = await _driver(id, verb);
    _require(driver, verb, capability);
    _claims.claim(
      deviceId: driver.target.id,
      sessionId: callerSessionId,
      verb: verb,
    );
    return driver;
  }

  void _require(
    DeviceDriver driver,
    String verb,
    DeviceCapability capability,
  ) {
    if (!driver.can(capability)) {
      throw DeviceRefusal('$verb: ${driver.missingReason(capability)!}');
    }
  }

  // ---------------------------------------------------------------------------
  // Listing
  //
  // The one handler that names platforms, because saying which is which is its
  // entire job.
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
    final fleet = await _fleet();
    // Three probes of three different things — adb, simctl, and the SDK's AVD
    // list — awaited together rather than one after another. They share no
    // state and neither orders the other, so serialising them only added the
    // slower ones to the wait: measured on this Mac, `simctl list devices` is
    // 214ms and `adb devices` 41ms, so a caller waited 255ms for something
    // 214ms wide.
    final (android, simulators, avds) = await (
      fleet.androidTargets(),
      fleet.simulatorTargets(),
      fleet.avds(),
    ).wait;

    final booted = [
      for (final target in simulators)
        if (target.isReady || target.simulator.state == SimulatorState.booting)
          target,
    ];
    final bootable =
        [
          for (final target in simulators)
            if (!booted.contains(target) &&
                target.simulator.isAvailable &&
                target.simulator.state == SimulatorState.shutdown)
              target,
        ]..sort((a, b) {
          final runtime = b.simulator.runtime.compareTo(a.simulator.runtime);
          return runtime != 0
              ? runtime
              : a.simulator.name.compareTo(b.simulator.name);
        });
    final cap = (limit ?? _simulatorListLimit).clamp(1, 1000);
    final shown = bootable.take((cap - booted.length).clamp(0, cap)).toList();

    // The same batching as the Android sizes above, in the branch that did not
    // get it: one `simctl io <udid> enumerate` per running simulator, all asked
    // at once rather than one round trip at a time inside the list below.
    final onScreen = [...booted, ...shown];
    final simulatorSizes = Map.fromIterables(
      [for (final target in onScreen) target.id],
      await [
        for (final target in onScreen)
          if (target.isReady)
            fleet.simctl!.screenSize(target.id)
          else
            Future<DeviceScreenSize?>.value(),
      ].wait,
    );

    // One `adb shell wm size` per ready device, asked for all of them at once.
    // Awaiting inside the list below spawned them one at a time, so a phone and
    // two emulators paid three round trips end to end to answer a question
    // nobody had ordered.
    final ready = [
      for (final target in android)
        if (target.isReady) target,
    ];
    final sizes = Map.fromIterables(
      [for (final target in ready) target.id],
      await [for (final target in ready) fleet.adb!.screenSize(target.id)].wait,
    );

    return {
      'devices': [
        for (final target in android)
          {
            'serial': target.id,
            'name': target.label,
            'platform': 'android',
            'state': target.device.state.name,
            'ready': target.isReady,
            'emulator': target.device.isEmulator,
            'environmentId': target.device.environmentId,
            if (target.isReady) ...{
              'screenSize': sizes[target.id]?.toString(),
              'coordinateSpace': CoordinateSpace.devicePixels.label,
            },
          },
      ],
      'avds': [
        for (final avd in avds) {'name': avd.name, 'running': avd.isRunning},
      ],
      'simulators': [
        for (final target in onScreen)
          {
            'udid': target.id,
            'name': target.simulator.name,
            'platform': 'ios',
            'runtime': target.simulator.runtimeName,
            'state': target.simulator.state.name,
            'running': target.isReady,
            'available': target.simulator.isAvailable,
            if (target.isReady) ...{
              'screenSizePixels': simulatorSizes[target.id]?.toString(),
              // Named rather than measured. Asking the backend for the point
              // size means installing and launching a runner inside the
              // simulator — seconds of work and a foreground app change, far
              // too much for a listing. device_ui_dump reports it, and its
              // coordinates are already in the right space.
              'coordinateSpace': CoordinateSpace.points.label,
            },
          },
      ],
      if (bootable.length > shown.length)
        'simulatorsNotShown':
            '${bootable.length - shown.length} more simulators are installed '
            'and bootable but not listed. Raise limit, or name one directly: '
            'device_boot accepts a simulator name as well as a udid.',
      // list_devices used to throw when no Android SDK was found, which on a
      // Mac with Xcode and no SDK meant an agent could never discover the
      // simulators sitting right there — the one tool whose job is to say what
      // exists refused to say anything. A missing SDK is now a note beside an
      // empty list.
      if (fleet.adb == null)
        'androidNote':
            'No Android SDK was found, so no Android device or emulator could '
            r'be listed. Set ANDROID_HOME (or install to %LOCALAPPDATA%\'
            'Android\\Sdk on Windows, ~/Library/Android/sdk on macOS).',
      if (fleet.simctl == null)
        'iosNote':
            'iOS Simulators need macOS with Xcode, and this host is not one.',
    };
  }

  // ---------------------------------------------------------------------------
  // Looking at a screen
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Files

  /// **Roots when no path is given, a listing when one is.**
  ///
  /// One tool rather than two because the roots are not a directory: the driver
  /// says which places it can reach and they are not branches of one tree —
  /// see `domain/device_files.dart`. An agent that had to guess `/` first would
  /// be wrong on an iOS device, where the only reachable places are the
  /// containers of development-signed apps.
  Future<Object?> _filesList(String? id, String? path) async {
    final driver = await _driverThatCan(
      id,
      'device_files_list',
      DeviceCapability.files,
    );
    if (path == null || path.isEmpty) {
      final roots = await driver.fileRoots();
      return {
        'device': driver.target.id,
        'roots': [
          for (final root in roots)
            {
              'path': root.path,
              'label': root.label,
              'description': root.description,
              'writable': root.writable,
            },
        ],
        'note':
            'Pass one of these paths back as `path` to list it. These are the '
            'places this device can reach, not branches of one filesystem.',
      };
    }
    final listing = await driver.listDirectory(path);
    return {
      'device': driver.target.id,
      'path': listing.path,
      'entries': [
        for (final entry in listing.entries)
          {
            'name': entry.name,
            'path': entry.path,
            'kind': entry.kind.name,
            'readable': entry.readable,
            'size_bytes': ?entry.sizeBytes,
            'modified': ?entry.modifiedLabel,
            'mode': ?entry.mode,
            'link_target': ?entry.linkTarget,
          },
      ],
      // Never dropped. `ls -l` differs by device and Android version, so a line
      // this build cannot parse is a known unknown — omitting it silently would
      // tell the agent the directory is shorter than it is.
      if (listing.skipped.isNotEmpty)
        'unparsed': [
          for (final skipped in listing.skipped)
            {'line': skipped.line, 'reason': skipped.reason},
        ],
      'note': ?listing.note,
    };
  }

  /// Copies a file off the device to somewhere this agent can then read.
  ///
  /// Defaults to the system temp directory under the device's own name, the
  /// same place and shape `device_screenshot` uses, so the reply's `host_path`
  /// can be handed straight to a file read.
  Future<Object?> _filePull(
    String? id,
    String? devicePath,
    String? destinationDirectory,
  ) async {
    final driver = await _driverThatCan(
      id,
      'device_file_pull',
      DeviceCapability.files,
    );
    if (devicePath == null || devicePath.isEmpty) {
      throw DeviceRefusal(
        'device_file_pull: device_path is required. Call device_files_list '
        'first to find one.',
      );
    }
    final directory = destinationDirectory ?? Directory.systemTemp.path;
    final moved = await driver.pullFile(
      devicePath: devicePath,
      hostPath: p.join(
        directory,
        'karmashala_${driver.target.fileSafeId}_'
        '${p.posix.basename(devicePath)}',
      ),
    );
    return {
      'device': driver.target.id,
      'device_path': moved.devicePath,
      'host_path': moved.hostPath,
      'bytes': ?moved.bytes,
      'note': ?moved.note,
    };
  }

  /// Copies a file from this computer onto the device.
  ///
  /// [overwrite] is off unless asked for, and the driver refuses rather than
  /// replacing: there is no undo on the far side, and a push that silently
  /// replaced somebody's file would be indistinguishable from one that worked.
  Future<Object?> _filePush(
    String? id,
    String? hostPath,
    String? devicePath,
    bool overwrite,
  ) async {
    final driver = await _driverToDrive(
      id,
      'device_file_push',
      DeviceCapability.files,
    );
    if (hostPath == null || hostPath.isEmpty || devicePath == null ||
        devicePath.isEmpty) {
      throw DeviceRefusal(
        'device_file_push: host_path and device_path are both required.',
      );
    }
    if (!File(hostPath).existsSync()) {
      throw DeviceRefusal('device_file_push: no file at $hostPath.');
    }
    final moved = await driver.pushFile(
      hostPath: hostPath,
      devicePath: devicePath,
      overwrite: overwrite,
    );
    return {
      'device': driver.target.id,
      'host_path': moved.hostPath,
      'device_path': moved.devicePath,
      'bytes': ?moved.bytes,
      'note': ?moved.note,
    };
  }

  // **No delete tool, deliberately.** `deletePath` exists on the driver and the
  // pane offers it behind a confirmation, which is the only thing standing
  // between a path typed one character wrong and an unrecoverable `rm -rf` on
  // somebody's phone. A tool has no such affordance: the model would be both
  // the one that typed the path and the one that confirmed it. The driver's own
  // comment calls this "the single most expensive mistake this surface can
  // make", and an agent that genuinely needs it can ask the user, who has a
  // button for it.

  Future<Object?> _deviceScreenshot(String? id) async {
    final driver = await _driverThatCan(
      id,
      'device_screenshot',
      DeviceCapability.screenshot,
    );
    final shot = await driver.screenshot();
    final file = File(
      p.join(
        Directory.systemTemp.path,
        'karmashala_${driver.target.fileSafeId}_'
        '${DateTime.now().millisecondsSinceEpoch}.png',
      ),
    );
    await file.writeAsBytes(shot.bytes, flush: true);

    // The warning is the whole reason DeviceScreenshot carries two spaces. On a
    // simulator the capture is the pixel backing store and the tap is in
    // points; a coordinate measured off this image and handed to device_tap
    // lands off the bottom of the screen while the call reports success.
    final spaces = shot.spacesAgree
        ? 'Tap coordinates are in ${shot.tapSpace.label}, the same space as '
              'this image.'
        : 'WARNING: this image is in ${shot.imageSpace.label}, but device_tap '
              'on this device takes ${shot.tapSpace.label} — on a 3x display '
              'they differ by a factor of three. Use device_ui_dump or '
              'device_tap_element, whose coordinates are already in '
              '${shot.tapSpace.label}, rather than measuring off this picture.';

    // Returned as MCP content blocks so the model actually sees the image
    // instead of a wall of base64 in a JSON string.
    return {
      '_mcpContent': [
        {
          'type': 'image',
          'data': base64Encode(shot.bytes),
          'mimeType': 'image/png',
        },
        {
          'type': 'text',
          'text':
              'Screenshot of ${driver.target.label} (${driver.target.id})'
              '${shot.size == null ? '' : ', ${shot.size} '
                        '${shot.imageSpace.label}'}. '
              'Saved to ${file.path}. $spaces',
        },
      ],
    };
  }

  // ---------------------------------------------------------------------------
  // Touching one
  // ---------------------------------------------------------------------------

  /// Taps a raw coordinate, having first looked at what is under it.
  ///
  /// ## The safety net, and why it is on the fallback tool
  ///
  /// This is the one tool that acts on numbers a caller worked out earlier, so
  /// it is the one tool that can tap where an element *was*. The check is a
  /// single [DeviceDriver.describeScreen] immediately before the touch — the
  /// very same read [_deviceTapElement] already pays — which is the argument
  /// that matters: **vetting the fallback costs exactly what the preferred path
  /// costs**, so there is no longer a speed reason to prefer coordinates.
  ///
  /// It refuses on *positive* evidence and never on the absence of it. A screen
  /// whose structure has moved since this app last read it is evidence; having
  /// never read the screen is not, and produces a note rather than a refusal —
  /// the coordinates may have come from a screenshot, or from the person
  /// sitting there. Same rule as everywhere else in this codebase: an unknown
  /// is not a zero.
  ///
  /// It also never turns a working call into a refusal for a reason of its own.
  /// A driver with no [DeviceCapability.uiTree] cannot be checked and is tapped
  /// anyway, and a screen read that *fails* — uiautomator does fall over
  /// mid-animation and on secure windows — is reported, not raised. The one
  /// thing that was silently wrong before and is now refused is a coordinate
  /// off the display, which used to be sent and reported as a success.
  ///
  /// `verify: false` is the documented way out, and the same one Artemis takes
  /// for its fast-action bursts: a custom-painted surface exposes nothing to
  /// the hierarchy, so there is nothing there for a check to be about.
  Future<Object?> _deviceTap(
    String? id,
    int? x,
    int? y, {
    bool verify = true,
  }) async {
    if (x == null || y == null) throw ArgumentError('x and y are required.');
    final driver = await _driverToDrive(
      id,
      'device_tap',
      DeviceCapability.input,
    );
    // After the claim, on purpose: a refusal below tells the caller to look
    // again, and it should still be holding the device when it does.
    final checked = verify
        ? await _vetCoordinate(driver, x, y)
        : const _CoordinateCheck(
            verdict:
                'not checked — verify: false. Nothing was read before the tap, '
                'so this reply says only that the event was sent.',
          );
    await driver.tap(x, y);
    return {
      'tapped': '($x, $y)',
      'serial': driver.target.id,
      'platform': driver.target.platform.name,
      'coordinateSpace': driver.coordinateSpace.label,
      'checked': checked.verdict,
      'under': ?checked.under,
      'prefer': ?checked.prefer,
    };
  }

  /// Reads the screen and says what ([x], [y]) is about to hit, or refuses.
  Future<_CoordinateCheck> _vetCoordinate(
    DeviceDriver driver,
    int x,
    int y,
  ) async {
    if (!driver.can(DeviceCapability.uiTree)) {
      return _CoordinateCheck(
        verdict:
            'not checked — ${driver.missingReason(DeviceCapability.uiTree)!} '
            'The tap was sent unverified.',
      );
    }
    final ScreenRead read;
    try {
      read = await driver.describeScreen();
    } on Object catch (error) {
      // Broad on purpose. Every way a screen read can fail — uiautomator
      // mid-animation, a secure window, a device that went away between the
      // claim and the read — ends the same way here: the check could not be
      // performed, which is not the same as the tap being wrong. Turning an
      // unavailable check into a refusal would break a tool that works today.
      return _CoordinateCheck(
        verdict:
            'not checked — reading the screen failed ($error). The tap was '
            'sent unverified.',
      );
    }

    final screen = read.screen;
    if (screen != null && (x < 0 || y < 0 || x >= screen.width || y >= screen.height)) {
      throw DeviceRefusal(
        'device_tap: ($x, $y) is off a $screen ${read.space.label} screen on '
        '${driver.target.id}. A tap outside the display does nothing and '
        'reports success, which is why this is refused rather than sent. '
        'device_ui_dump reports coordinates already in the right space for '
        'this device.',
      );
    }

    // Read before the new one is filed, or the comparison is with itself.
    final earlier = _screens.lastLookAt(driver.target.id);
    final seen = _screens.observationOf(
      deviceId: driver.target.id,
      tree: read.tree,
      app: read.app,
      bySessionId: callerSessionId,
    );

    String? staleness;
    if (earlier != null && !seen.matches(earlier)) {
      final age = seen.at.difference(earlier.at);
      if (age <= kDeviceLookWindow) {
        // Deliberately *not* filed. A refusal that recorded the new screen
        // would let the identical retry through against a screen the caller
        // never looked at, which is the same blind tap one round trip later.
        throw DeviceRefusal(
          'device_tap: the screen has moved since this app last read it, so '
          '($x, $y) is a coordinate for a screen that is gone. '
          '${driver.target.id} was read '
          '${describeDriveAge(age)} and ${seen.differenceFrom(earlier)}. A '
          'coordinate computed against the old screen lands wherever the new '
          'one happens to put something, and the reply would say it worked.\n'
          'Read it again and act on what is there: device_find_elements then '
          'device_tap_element, which re-reads the screen, hits the element '
          'itself, costs exactly what this call costs and survives the next '
          'change too. To tap blind anyway — a canvas, a game, a '
          'custom-painted surface with nothing in the hierarchy — pass '
          'verify: false.',
        );
      }
      staleness =
          'the screen has changed since it was last read '
          '${describeDriveAge(age)}, but that reading is older than '
          '${kDeviceLookWindow.inMinutes}m and so is not evidence about where '
          'these coordinates came from — not refused for that reason';
    } else if (earlier == null) {
      staleness =
          'nothing this app has read says where ($x, $y) came from — no '
          'device_ui_dump or device_find_elements has been run on '
          '${driver.target.id}, so it was checked against the screen as it is '
          'now and nothing else';
    }

    _screens.file(seen);

    final node = read.tree.at(x, y);
    return _CoordinateCheck(
      verdict: staleness == null
          ? 'against a read taken just now, which matches the screen last read '
                '${describeDriveAge(seen.at.difference(earlier!.at))}'
          : 'against a read taken just now — $staleness',
      under: node == null
          ? 'nothing in the hierarchy covers ($x, $y); on a custom-painted '
                'surface that is normal, elsewhere it means the tap lands on '
                'no element'
          : describeUiNode(node, screen: screen),
      prefer: node == null ? null : _preferElementOver(node),
    );
  }

  /// One line when this screen is not the one this app last read, or null.
  ///
  /// A note and never a refusal, and that asymmetry is the locating policy
  /// stated as behaviour: a dynamic locator is resolved against the screen in
  /// front of it, so a change is something it *survives* — while the same
  /// change makes a raw coordinate wrong, which is why `device_tap` refuses on
  /// it. Said anyway, because the caller's wider plan was built on the older
  /// screen and this tap succeeding is not evidence the rest of it will.
  List<String>? _screenMovedSince(DeviceDriver driver, ScreenRead read) {
    final earlier = _screens.lastLookAt(driver.target.id);
    if (earlier == null) return null;
    final seen = _screens.observationOf(
      deviceId: driver.target.id,
      tree: read.tree,
      app: read.app,
      bySessionId: callerSessionId,
    );
    if (seen.matches(earlier)) return null;
    return [
      'NOTE: the screen changed since it was last read '
          '${describeDriveAge(seen.at.difference(earlier.at))} — '
          '${seen.differenceFrom(earlier)}. This tap resolved against the '
          'screen as it is now, so it is right; any coordinate you are still '
          'holding from that read is not.',
    ];
  }

  /// The `device_tap_element` call that would have found [node], said where the
  /// caller is already reading — the locating policy at the moment it applies.
  String? _preferElementOver(UiNode node) {
    final ({String field, String value})? locator = switch (node) {
      _ when node.text.isNotEmpty => (field: 'text', value: node.text),
      _ when node.contentDescription.isNotEmpty => (
        field: 'text',
        value: node.contentDescription,
      ),
      _ when node.resourceId.isNotEmpty => (
        field: 'resourceId',
        value: node.resourceId,
      ),
      _ => null,
    };
    if (locator == null) return null;
    return 'device_tap_element(${locator.field}: "${locator.value}") hits that '
        'element by name: it survives a layout change, cannot be off by a '
        'scale factor, and costs exactly what this call costs.';
  }

  Future<Object?> _deviceType(
    String? id,
    String? text, {
    bool submit = false,
  }) async {
    if (text == null) throw ArgumentError('text is required.');
    final driver = await _driverToDrive(
      id,
      'device_type',
      DeviceCapability.input,
    );
    await driver.type(text);
    if (!submit) {
      return {
        'typed': text,
        'serial': driver.target.id,
        'platform': driver.target.platform.name,
      };
    }
    // A real Enter key rather than the IME's action. A view that handles its
    // own key events — a Flutter `TextInputClient`, an embedded terminal —
    // receives committed text but never the action, so an IME-only submit is a
    // silent no-op there and the reply still says "typed". Pressing the key is
    // what the caller would have done next anyway.
    if (!driver.can(DeviceCapability.keys)) {
      throw DeviceRefusal(
        'device_type(submit: true): ${driver.missingReason(DeviceCapability.keys)!} '
        'The text was typed; send the newline yourself.',
      );
    }
    final press = await driver.pressKey(DeviceKey.enter);
    return {
      'typed': text,
      'submitted': true,
      'submittedAs': press.how,
      'serial': driver.target.id,
      'platform': driver.target.platform.name,
    };
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
    final driver = await _driverToDrive(
      id,
      'device_key',
      DeviceCapability.keys,
    );
    // The driver refuses the individual keys its device does not have. That is
    // per-key rather than a capability because a device with *some* of them is
    // the normal case — see SimulatorDeviceDriver.pressKey.
    final press = await driver.pressKey(parsed);
    return {
      'pressed': press.key.name,
      'serial': driver.target.id,
      'platform': driver.target.platform.name,
      'as': press.how,
    };
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
    final driver = await _driverThatCan(
      id,
      'device_logcat',
      DeviceCapability.logs,
    );
    final read = await driver.readLog(
      filter: packageName,
      level: level,
      lines: lines ?? 200,
    );
    return {
      'serial': driver.target.id,
      'platform': driver.target.platform.name,
      'package': ?packageName,
      'lines': read.lines,
      'note': ?read.note,
    };
  }

  // ---------------------------------------------------------------------------
  // Lifecycle: boot, install, launch, terminate, stop
  // ---------------------------------------------------------------------------

  Future<Object?> _deviceBoot(String? name) async {
    if (name == null || name.trim().isEmpty) {
      throw ArgumentError(
        'device_boot needs a name: an AVD name, an iOS simulator udid, or a '
        'simulator name. list_devices shows all three.',
      );
    }
    final booted = await (await _fleet()).boot(name.trim());
    return {
      // Both spellings, because the id is what every following call needs and
      // an agent should not have to know which key its platform uses.
      'serial': booted.id,
      if (booted.platform == DevicePlatform.ios) 'udid': booted.id,
      'name': booted.name,
      'platform': booted.platform.name,
      'booted': booted.booted,
      'note': booted.note,
    };
  }

  Future<Object?> _deviceInstallApp({String? id, String? path}) async {
    if (path == null || path.trim().isEmpty) {
      throw ArgumentError(
        'path is required: an .apk for Android, or a simulator .app bundle for '
        'iOS.',
      );
    }
    final driver = await _driverToDrive(
      id,
      'device_install_app',
      DeviceCapability.installApp,
    );
    final installed = await driver.installApp(path.trim());
    return {
      'serial': driver.target.id,
      'platform': driver.target.platform.name,
      'installed': installed.path,
      'appId': ?installed.appId,
      'note': ?installed.note,
    };
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
    final driver = await _driverToDrive(
      id,
      'device_launch_app',
      DeviceCapability.appLifecycle,
    );
    final launched = await driver.launchApp(
      appId.trim(),
      activity: activity,
      relaunch: relaunch,
    );
    return {
      'serial': driver.target.id,
      'platform': driver.target.platform.name,
      'launched': launched.appId,
      'pid': ?launched.pid,
      'note':
          'Give it a moment to draw, then read it with device_ui_dump.'
          '${launched.note == null ? '' : ' ${launched.note}'}',
    };
  }

  Future<Object?> _deviceTerminateApp({String? id, String? appId}) async {
    if (appId == null || appId.trim().isEmpty) {
      throw ArgumentError('appId is required.');
    }
    final driver = await _driverToDrive(
      id,
      'device_terminate_app',
      DeviceCapability.appLifecycle,
    );
    await driver.terminateApp(appId.trim());
    return {
      'serial': driver.target.id,
      'platform': driver.target.platform.name,
      'terminated': appId.trim(),
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
  /// outright: `device_stop_emulator` is what existing callers already call. So
  /// the verb keeps its name and grows a second meaning, and its description
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
    final wanted = id.trim();
    final fleet = await _fleet();

    // An AVD name, before anything else. A running emulator answers to
    // `emulator-5554`, but a *stopped* one answers to nothing at all — the
    // serial is assigned at boot and vanishes with the process — so the serial
    // that worked a moment ago is not a name this verb can be asked about
    // twice. The AVD name is the only handle that survives, which is also the
    // name device_boot takes, so the two halves of the lifecycle are spelled
    // the same way.
    if (await fleet.avdNamed(wanted) case final avd?) {
      if (!avd.isRunning) {
        return {
          'name': avd.name,
          'platform': 'android',
          'stopped': true,
          'note': '${avd.name} was already stopped.',
        };
      }
      return _stopVirtualDevice(fleet, avd.runningSerial!, name: avd.name);
    }

    // A serial that names nothing, shaped like an emulator's. Saying only "no
    // device is called that" is true and unhelpful: the overwhelmingly likely
    // reason is that it already stopped, and the caller has no way to know the
    // serial was never going to work a second time.
    if (await fleet.find(wanted) == null &&
        RegExp(r'^emulator-\d+$').hasMatch(wanted)) {
      final stopped = [
        for (final avd in await fleet.avds())
          if (!avd.isRunning) avd.name,
      ];
      throw DeviceRefusal(
        'No emulator is running as $wanted. A stopped emulator keeps no '
        'serial — it is assigned at boot — so if you are stopping one you '
        'already stopped, it is gone. Pass the AVD name instead, which is '
        'stable and is what device_boot takes'
        '${stopped.isEmpty ? '' : ': ${stopped.take(10).join(', ')}'}.',
      );
    }

    // Not `driverFor`: a simulator that is already shut down is not "ready",
    // and refusing to stop something that is already stopped would turn asking
    // for a state into an error about being in it.
    return _stopVirtualDevice(fleet, wanted);
  }

  /// Stops the device [id] names, whichever platform it is on.
  Future<Object?> _stopVirtualDevice(
    DeviceFleet fleet,
    String id, {
    String? name,
  }) async {
    final target = await fleet.requireTarget(id, verb: 'device_stop_emulator');
    final driver = fleet.driverForTarget(target);
    if (!target.isReady &&
        target is SimulatorTarget &&
        target.simulator.state == SimulatorState.shutdown) {
      return {
        'serial': target.id,
        'udid': target.id,
        'platform': 'ios',
        'stopped': true,
        'note': '${target.label} was already shut down.',
      };
    }
    // Claimed here rather than at the top of `device_stop_emulator`: an AVD
    // name is not the id a driver holds, and the two branches above change
    // nothing — refusing to be told a stopped device is stopped would be a
    // refusal about somebody else's drive of a device nobody is driving.
    _claims.claim(
      deviceId: target.id,
      sessionId: callerSessionId,
      verb: 'device_stop_emulator',
    );
    final outcome = await fleet.powerOff(driver);
    return {
      'serial': target.id,
      if (target.platform == DevicePlatform.ios) 'udid': target.id,
      'name': ?name,
      'platform': target.platform.name,
      'stopped': true,
      'note': outcome,
    };
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
  // On a simulator this is the *only* honest way to get a coordinate, because
  // the screenshot is in pixels and the tap is in points.
  // ---------------------------------------------------------------------------

  UiElementQuery _uiQuery(Map<String, dynamic> args) => UiElementQuery(
    text: args['text'] as String?,
    resourceId: args['resourceId'] as String?,
    contentDescription: args['contentDesc'] as String?,
    className: args['className'] as String?,
    exact: args['exact'] == true,
    clickableOnly: args['clickable'] == true,
  );

  /// One line naming the device, the foreground app and the coordinate space.
  String _uiHeader(DeviceDriver driver, ScreenRead read) =>
      '${driver.target.id} · ${read.app ?? 'unknown app'} · '
      'screen ${read.screen ?? 'unknown'} ${read.space.label} · '
      'rotation ${read.tree.rotation}';

  /// The coordinate space, said once per listing where it cannot be missed.
  String _spaceLine(ScreenRead read) => read.space == CoordinateSpace.points
      ? 'Coordinates are in POINTS, which is what device_tap and '
            'device_tap_element take on this device — NOT the pixels a '
            'device_screenshot image is in.'
      : 'Coordinates are in device pixels.';

  Future<Object?> _deviceUiDump({
    String? id,
    bool full = false,
    String? filter,
    int? limit,
  }) async {
    final driver = await _driverThatCan(
      id,
      'device_ui_dump',
      DeviceCapability.uiTree,
    );
    final read = await driver.describeScreen();
    _recordLook(driver, read);
    final tree = read.tree;
    final screen = read.screen;

    if (full && filter == null) {
      final body = renderUiTree(tree, screen: screen);
      return _uiText([
        'Full UI hierarchy · ${_uiHeader(driver, read)}',
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
      'UI hierarchy · ${_uiHeader(driver, read)}',
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
      // Said here rather than only in the tool description, because the moment
      // it is needed is the moment a dump has come back looking complete and
      // empty.
      ...?_canvasHint(tree, screen),
      'Tap one with device_tap_element(text: "…"), which re-reads the screen '
          'and hits the element itself. The coordinates above also work with '
          'device_tap.',
    ]);
  }

  /// One line warning that the screen is painted, not composed of widgets.
  List<String>? _canvasHint(UiHierarchy tree, DeviceScreenSize? screen) {
    final node = canvasLikeNode(tree, screen);
    if (node == null) return null;
    return [
      'NOTE: ${describeUiNode(node, screen: screen)} is a large view with no '
          'text of its own — a custom-painted surface (Flutter CustomPaint, a '
          'canvas game, a terminal) exposes nothing to this dump. Read its '
          'content with device_screenshot instead of dumping again.',
      '',
    ];
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
    final driver = await _driverThatCan(
      id,
      'device_find_elements',
      DeviceCapability.uiTree,
    );
    final read = await driver.describeScreen();
    _recordLook(driver, read);
    final tree = read.tree;
    final screen = read.screen;
    final matches = tree.find(query);
    if (matches.isEmpty) {
      return _uiText([
        'No element matches $query on ${_uiHeader(driver, read)}',
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
          '$query · ${_uiHeader(driver, read)}',
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
    // Both capabilities, checked before the read: a driver that could describe
    // a screen but not touch it would otherwise dump the tree, pick a target
    // and fail at the last step, having spent the round trip.
    final driver = await _driverToDrive(
      id,
      'device_tap_element',
      DeviceCapability.uiTree,
    );
    _require(driver, 'device_tap_element', DeviceCapability.input);
    // The read *is* this tool's safety net: it resolves the locator against the
    // screen as it is now, so a dialog that arrived between look and tap is
    // caught here rather than by the user. What the note below adds is the
    // other half — that the plan the caller built is stale even though this
    // call succeeded.
    final read = await driver.describeScreen();
    final moved = _screenMovedSince(driver, read);
    _recordLook(driver, read);
    final tree = read.tree;
    final screen = read.screen;
    final matches = tree.find(query);

    if (matches.isEmpty) {
      throw DeviceRefusal(
        'Nothing matches $query on ${driver.target.id}. On screen now:\n'
        '${renderUiElements(interestingNodes(tree), screen: screen, limit: 60).listing}',
      );
    }

    final UiNode element;
    if (index != null) {
      if (index < 0 || index >= matches.length) {
        throw ArgumentError(
          'index $index is out of range: there are ${matches.length} matches.',
        );
      }
      element = matches[index];
    } else if (matches.length == 1) {
      element = matches.first;
    } else {
      // Several matches. One unambiguous exact label is still a decision we can
      // make; anything else is a guess, and a wrong tap is worse than an error
      // because the agent cannot tell it happened.
      final exact = [
        for (final node in matches)
          if (query.rank(node) == 0) node,
      ];
      if (exact.length == 1) {
        element = exact.single;
      } else {
        throw DeviceRefusal(
          '$query matches ${matches.length} elements on ${driver.target.id}. '
          'Pass index to choose, or narrow the query:\n'
          '${_indexed(matches, screen)}',
        );
      }
    }

    final bounds = element.tapBounds;
    if (bounds == null) {
      throw DeviceRefusal(
        'The matched element reports no bounds, so there is nowhere to tap: '
        '${describeUiNode(element, screen: screen)}',
      );
    }
    // A node covering nearly the whole screen is a scrim or a modal barrier,
    // never the thing anybody meant. Android exposes one as a clickable node
    // called "Dismiss" spanning the display, directly behind the dialog whose
    // button the caller asked for — so tapping it closes the dialog and throws
    // away the state under test, and the reply would read like a success.
    // Refused rather than ranked down: there is no query for which the right
    // answer is the barrier.
    if (screen != null && bounds.coversMostOf(screen)) {
      throw DeviceRefusal(
        'The best match is ${describeUiNode(element, screen: screen)}, which '
        'covers the whole $screen screen. That is a scrim or a modal barrier, '
        'and tapping one dismisses whatever is in front of it. Name the '
        'control you want instead — if it has gone, the screen has moved on:\n'
        '${renderUiElements(interestingNodes(tree), screen: screen, limit: 60).listing}',
      );
    }
    if (screen != null && !bounds.centerIsOnScreen(screen)) {
      throw DeviceRefusal(
        'The matched element is off screen at ${bounds.raw} on a $screen '
        '${read.space.label} display — it is scrolled out of view. Scroll it '
        'into view first; tapping its centre would hit whatever is really at '
        'that point.',
      );
    }

    final point = bounds.center;
    await driver.tap(point.x, point.y);
    return _uiText([
      'Tapped (${point.x}, ${point.y}) ${read.space.label} on '
          '${describeUiNode(element, screen: screen)}',
      ...?moved,
      'Device ${driver.target.id}, ${read.app ?? 'unknown app'}'
          '${matches.length == 1 ? '' : ', chosen from ${matches.length} matches'}'
          // The runner-up by name: reading "chosen from 2" is what tells you a
          // pick went wrong, and saying which one lost turns that into a
          // diagnosis without a second round trip.
          '${_runnerUp(matches, element, screen)}.'
          '${element.enabled ? '' : ' NOTE: this element is disabled.'}',
      'Take a screenshot or dump again to confirm what changed.',
    ]);
  }

  /// ` (also: …)` naming the best match that was not taken, or empty.
  String _runnerUp(
    List<UiNode> matches,
    UiNode chosen,
    DeviceScreenSize? screen,
  ) {
    for (final node in matches) {
      if (identical(node, chosen)) continue;
      return ' (also: ${describeUiNode(node, screen: screen)})';
    }
    return '';
  }

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
}

/// What the pre-tap check found, as the three fields the reply carries.
///
/// A record rather than a sentence because the three answer different
/// questions and an agent skims: what was checked, what is under the finger,
/// and what it should have called instead.
class _CoordinateCheck {
  const _CoordinateCheck({required this.verdict, this.under, this.prefer});

  /// What was compared against what, always said — including when the answer
  /// is "nothing was".
  final String verdict;

  /// The element the coordinate lands on.
  final String? under;

  /// The dynamic locator that would have found it. Null when the element has
  /// no name to be found by, which is itself the answer.
  final String? prefer;
}

/// **The locating policy, written once and spliced into every tool it governs.**
///
/// Stated on the tools themselves for the reason `mcp_tool_catalogue.dart`
/// gives for its four hints: a rule that lives in one file is a survey, and a
/// rule an agent meets at the moment it is choosing is a rule. It is the *same*
/// sentence on all four rather than four tailored variants, because four
/// wordings of one rule read as four hints.
///
/// The third sentence is the one that changes behaviour. "Prefer the robust
/// thing" loses to "the other one is faster" every time, and until
/// `device_tap` started reading the screen before it acted, the other one
/// genuinely was faster. It no longer is — counted, a vetted `device_tap` and
/// a `device_tap_element` are the same six adb invocations — so the policy can
/// state it as a fact rather than an exhortation.
const String kDeviceLocatingPolicy =
    'LOCATING POLICY — dynamic first, coordinates as a checked fallback. '
    'Prefer device_tap_element: it resolves the element against the screen as '
    'it is at the instant of the tap, so it survives a layout change, a '
    'different screen size and a scale factor, and it tells you what it hit. '
    'Use device_tap only when the dynamic attempt has failed, and only with '
    'coordinates you verified during exploration — device_ui_dump and '
    'device_find_elements report them in the space this device actually takes. '
    'There is no speed reason to skip the dynamic path: device_tap reads the '
    'screen before it acts, so the two cost the same, and device_tap is the '
    'one that gets refused when the screen has moved since you looked.';

/// The schemas for [DeviceControlTools].
const List<Map<String, dynamic>> deviceControlToolSchemas = [
  {
    'name': 'list_devices',
    'description':
        'List everything this machine can drive: connected Android devices '
        'and running emulators, plus iOS Simulators (every booted one, and the '
        'bootable ones newest-runtime-first). Android devices appear under '
        '"devices" keyed by serial; simulators under "simulators" keyed by '
        'udid, with "running" saying which are up. Either identifier can be '
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
        'Capture the current screen of an Android device or iOS simulator as a '
        'PNG image. Use this to see what an app is actually showing. serial '
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
        'screenshot is NOT in. Reads the screen immediately before it acts and '
        'refuses when the structure has changed since this app last read the '
        'device — a coordinate for a screen that is gone lands wherever the '
        'new one happens to put something. Pass verify: false for a surface '
        'with nothing in its hierarchy. $kDeviceLocatingPolicy',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'serial': {'type': 'string'},
        'udid': {'type': 'string', 'description': 'Alias for serial.'},
        'x': {'type': 'number'},
        'y': {'type': 'number'},
        'verify': {
          'type': 'boolean',
          'description':
              'Read the screen immediately before tapping and refuse if it has '
              'moved since it was last read. Default true. Pass false only for '
              'a surface with nothing in its hierarchy — a canvas, a game, a '
              'custom-painted view — where there is nothing for the check to '
              'be about; the reply then says the tap was sent unverified.',
        },
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
        'keyboard can produce travels as itself. Pass submit to press Enter '
        'after the text, which is what runs a command or sends a form.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'serial': {'type': 'string'},
        'udid': {'type': 'string', 'description': 'Alias for serial.'},
        'text': {'type': 'string'},
        'submit': {
          'type': 'boolean',
          'description':
              'Press Enter after typing. A real key press, not the keyboard\'s '
              'own action button, so it also reaches views that handle their '
              'own keys — a Flutter text field, an embedded terminal. The '
              'reply says submitted: true only when the key actually went.',
        },
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
              'back | home | recents | power | volumeUp | volumeDown | enter | '
              'tab | delete',
        },
      },
      'required': ['key'],
    },
  },
  {
    'name': 'device_files_list',
    'description':
        "Look at a device's storage. Called with no path it returns the "
        'places this device can reach, each with whether it is writable — '
        'these are not branches of one filesystem, so do not assume "/". '
        'Called with a path it lists that directory. A directory this device '
        'will not let us read comes back as a refusal, never as an empty '
        'listing, and any lines the listing could not be parsed from are '
        'reported under `unparsed` rather than dropped.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'serial': {'type': 'string'},
        'udid': {'type': 'string', 'description': 'Alias for serial.'},
        'path': {
          'type': 'string',
          'description':
              'A directory on the device. Omit to get the reachable roots.',
        },
      },
    },
  },
  {
    'name': 'device_file_pull',
    'description':
        'Copy a file off the device onto this computer. Returns `host_path`, '
        'which is a real path on this machine that can be read straight '
        'afterwards. Defaults to the system temp directory; pass '
        'destination_directory to choose somewhere else.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'serial': {'type': 'string'},
        'udid': {'type': 'string', 'description': 'Alias for serial.'},
        'device_path': {
          'type': 'string',
          'description':
              'The file on the device. Use device_files_list to find one.',
        },
        'destination_directory': {
          'type': 'string',
          'description': 'Where to put it on this computer. Optional.',
        },
      },
      'required': ['device_path'],
    },
  },
  {
    'name': 'device_file_push',
    'description':
        'Copy a file from this computer onto the device. Refuses rather than '
        'replacing an existing file unless overwrite is true, because there '
        'is no undo on the device. If device_path names a directory the file '
        'lands inside it under its own name, and the reply says so.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'serial': {'type': 'string'},
        'udid': {'type': 'string', 'description': 'Alias for serial.'},
        'host_path': {
          'type': 'string',
          'description': 'The file on this computer.',
        },
        'device_path': {
          'type': 'string',
          'description': 'Destination path on the device.',
        },
        'overwrite': {
          'type': 'boolean',
          'description': 'Replace an existing file. Default false.',
        },
      },
      'required': ['host_path', 'device_path'],
    },
  },
  {
    'name': 'device_logcat',
    'description':
        'Read recent device log output, newest last. On Android this is '
        'logcat: filter to one app with package (strongly recommended — the '
        'unfiltered system log is huge and mostly noise) and raise level to '
        'see only warnings or errors. On an iOS simulator it is `log show` '
        'over the last 5 minutes: level is refused (iOS levels are not Android '
        'levels) and package is matched as a plain substring of each line, '
        'which the reply says.',
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
        'for device_launch_app; on Android adb does not report one, so pass '
        'your applicationId.',
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
        'Launch an installed app by Android applicationId or iOS bundle id. On '
        'Android the launcher activity is resolved for you; pass activity to '
        'start a specific one instead. On iOS pass relaunch=true to terminate '
        'any running copy first, which is what makes it a cold start rather '
        'than a switch to the front.',
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
              'Android only. Activity to start, e.g. .MainActivity. Refused on '
              'iOS, which has no activities.',
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
              'Emulator serial (emulator-5554), AVD name, or simulator udid. '
              'Prefer the AVD name: a stopped emulator keeps no serial, so the '
              'name is the only handle that survives a stop.',
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
        'is on it, what each element says, and the exact point to tap for each '
        'one. Works on Android (uiautomator) and on an iOS simulator '
        '(WebDriverAgent). Prefer this over device_screenshot when you intend '
        'to touch something — a screenshot cannot tell you what is tappable, '
        'coordinates read off an image are guesswork, and on iOS the image is '
        'in a different unit from the tap. By default only nodes that carry '
        'text or accept input are listed; pass full=true for every node, '
        'including layout containers. Custom-painted views — Flutter '
        'CustomPaint, canvas games, embedded terminals — expose no text here '
        'at all and appear as one empty View; read those with '
        'device_screenshot rather than dumping again. $kDeviceLocatingPolicy',
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
              'Keep only nodes whose text, content-description, resource id or '
              'class contains this (case-insensitive).',
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
        'Matching is case-insensitive and by substring unless exact=true. text '
        'matches BOTH the text and the content-description, which is what '
        'makes it work on Flutter apps: they put their labels in content-desc '
        'and leave text empty. On iOS the same query runs against the XCUITest '
        'tree, where an element\'s value and label are mapped onto those same '
        'two fields. $kDeviceLocatingPolicy',
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
        'an element that is scrolled off screen. $kDeviceLocatingPolicy',
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
