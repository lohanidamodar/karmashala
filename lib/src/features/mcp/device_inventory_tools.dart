import '../devices/application/device_fleet.dart';
import 'package:karmashala_devices/devices.dart';
import 'device_tool_support.dart';

/// What exists, and whether it is running: the listing, and the two ends of a
/// virtual device's life. `device_boot` and `device_stop_emulator` both take a
/// name that survives a reboot, because a stopped emulator answers to no serial
/// at all.
class DeviceInventoryTools extends DeviceToolFamily {
  DeviceInventoryTools(super.container, {super.callerSessionId});

  static const Set<String> _names = <String>{
    'list_devices',
    'device_boot',
    'device_stop_emulator',
  };

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'list_devices' => _listDevices((args['limit'] as num?)?.round()),
        'device_boot' => _deviceBoot(
          (args['name'] as String?) ?? deviceIdIn(args),
        ),
        'device_stop_emulator' => _deviceStopEmulator(deviceIdIn(args)),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  /// How many simulators to list before saying "there are more".
  ///
  /// A device set is not a device list: this developer's machine holds 170
  /// simulators, 124 of them with no installed runtime, and printing them all
  /// turns the one useful line — which is booted — into a haystack. Booted ones
  /// are always listed; the bootable rest are truncated, newest runtime first.
  static const int _simulatorListLimit = 40;

  Future<Object?> _listDevices(int? limit) async {
    final fleet = await deviceFleet();
    // Three probes of three different things, awaited together rather than one
    // after another: they share no state, and serialising them only added the
    // slower ones to the wait — measured on this Mac, `simctl list devices` is
    // 214ms and `adb devices` 41ms.
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
    // get it: one `simctl io <udid> enumerate` per running simulator, all at
    // once.
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

    // One `adb shell wm size` per ready device, asked for all of them at once:
    // awaiting inside the list below spawned them one round trip at a time.
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
              // Named rather than measured: asking the backend for the point
              // size means installing and launching a runner inside the
              // simulator. device_ui_dump reports it, already in that space.
              'coordinateSpace': CoordinateSpace.points.label,
            },
          },
      ],
      if (bootable.length > shown.length)
        'simulatorsNotShown':
            '${bootable.length - shown.length} more simulators are installed '
            'and bootable but not listed. Raise limit, or name one directly: '
            'device_boot accepts a simulator name as well as a udid.',
      // A missing SDK is a note beside an empty list rather than a throw: on a
      // Mac with Xcode and no SDK, the one tool whose job is to say what exists
      // refused to say anything.
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

  Future<Object?> _deviceBoot(String? name) async {
    if (name == null || name.trim().isEmpty) {
      throw ArgumentError(
        'device_boot needs a name: an AVD name, an iOS simulator udid, or a '
        'simulator name. list_devices shows all three.',
      );
    }
    final booted = await (await deviceFleet()).boot(name.trim());
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

  /// Stops a running virtual device, on either platform.
  ///
  /// **Widened rather than given an iOS sibling**, and deliberately not renamed:
  /// existing callers already call `device_stop_emulator`. The id is required
  /// rather than inferred — silently defaulting a destructive action to "the
  /// only ready device" is a different thing entirely.
  Future<Object?> _deviceStopEmulator(String? id) async {
    if (id == null || id.trim().isEmpty) {
      throw ArgumentError(
        'serial is required for device_stop_emulator — an emulator serial or a '
        'simulator udid. It is not inferred, because stopping the wrong device '
        'loses whatever was on it.',
      );
    }
    final wanted = id.trim();
    final fleet = await deviceFleet();

    // An AVD name, before anything else. A *stopped* emulator answers to
    // nothing at all — the serial is assigned at boot and vanishes with the
    // process — so the AVD name is the only handle that survives, and it is the
    // name device_boot takes too.
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

    // A serial that names nothing, shaped like an emulator's. The overwhelmingly
    // likely reason is that it already stopped, and the caller has no way to
    // know the serial was never going to work a second time.
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

    // Not `driverFor`: a simulator that is already shut down is not "ready", and
    // refusing to stop something already stopped would turn asking for a state
    // into an error about being in it.
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
    // Claimed here rather than at the top of `device_stop_emulator`: an AVD name
    // is not the id a driver holds, and the two branches above change nothing.
    claims.claim(
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
}

/// The schemas for [DeviceInventoryTools].
const Map<String, dynamic> listDevicesSchema = {
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
};

const Map<String, dynamic> deviceBootSchema = {
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
};

const Map<String, dynamic> deviceStopEmulatorSchema = {
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
};
