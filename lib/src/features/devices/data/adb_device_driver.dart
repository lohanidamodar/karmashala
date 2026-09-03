import '../domain/device_driver.dart';
import '../domain/device_files.dart';
import '../domain/device_input.dart';
import '../domain/device_target.dart';
import '../domain/logcat_entry.dart';
import 'adb_file_parsing.dart';
import 'adb_service.dart';

/// [DeviceDriver] over adb, for a phone or an emulator.
///
/// A thin composition rather than new behaviour: every verb here already
/// existed on [AdbService], which the device pane also uses, so an agent and
/// the person beside it drive one device through one service. What this adds is
/// the honest capability report and the refusals — the things a caller with no
/// eyes needs and a pane with a user in front of it does not.
class AdbDeviceDriver implements DeviceDriver {
  AdbDeviceDriver({required this.adb, required this.target});

  final AdbService adb;

  @override
  final AndroidTarget target;

  @override
  String get id => 'adb';

  @override
  String get displayName => 'adb';

  String get _serial => target.id;

  /// Everything except [DeviceCapability.powerOff] on a physical device.
  ///
  /// adb genuinely can do all of the rest against a handset as well as an
  /// emulator — that is the whole reason `adb shell` exists — so the only line
  /// this driver draws is the one it must: `emu kill` talks to an emulator's
  /// console, and there is no console on somebody's phone.
  @override
  Set<DeviceCapability> get capabilities => {
    DeviceCapability.input,
    DeviceCapability.keys,
    DeviceCapability.uiTree,
    DeviceCapability.screenshot,
    DeviceCapability.logs,
    DeviceCapability.installApp,
    DeviceCapability.appLifecycle,
    DeviceCapability.files,
    if (target.device.isEmulator) DeviceCapability.powerOff,
  };

  @override
  bool can(DeviceCapability capability) => capabilities.contains(capability);

  @override
  String? missingReason(DeviceCapability capability) {
    if (can(capability)) return null;
    if (capability == DeviceCapability.powerOff) {
      return '$_serial is a physical device, not an emulator. adb stops an '
          'emulator by talking to its console (`emu kill`), and a handset has '
          'no console — unplug it, or turn it off yourself. Everything else '
          'here works on it normally.';
    }
    return '$_serial cannot $capability through adb.';
  }

  @override
  CoordinateSpace get coordinateSpace => CoordinateSpace.devicePixels;

  @override
  Future<DeviceScreenshot> screenshot() async {
    final bytes = await adb.screenshot(_serial);
    final size = await adb.screenSize(_serial);
    return DeviceScreenshot(
      bytes: bytes,
      size: size,
      // The easy case, and the one that made the distinction easy to forget:
      // `screencap` captures the framebuffer and `input tap` takes framebuffer
      // coordinates, so a point measured off the image is directly tappable.
      imageSpace: CoordinateSpace.devicePixels,
      tapSpace: CoordinateSpace.devicePixels,
    );
  }

  @override
  Future<ScreenRead> describeScreen() async {
    final tree = await adb.dumpUiHierarchy(_serial);
    return ScreenRead(
      tree: tree,
      screen: await adb.screenSize(_serial),
      space: CoordinateSpace.devicePixels,
      app: tree.packageName,
    );
  }

  @override
  Future<void> tap(int x, int y) => adb.tap(_serial, x, y);

  @override
  Future<void> type(String text) => adb.inputText(_serial, text);

  @override
  Future<KeyPress> pressKey(DeviceKey key) async {
    // No refusals: [DeviceKey] was defined from Android's own `KEYCODE_*`
    // table, so every member of it is a key this device has.
    await adb.pressKey(_serial, key);
    return KeyPress(key: key, how: 'the ${key.keyCode} key event');
  }

  @override
  Future<DeviceLogRead> readLog({
    String? filter,
    String? level,
    int lines = 200,
  }) async {
    final minLevel = _parseLevel(level);
    if (level != null && level.trim().isNotEmpty && minLevel == null) {
      throw DeviceRefusal(
        'logcat has no level called "$level". Use one of '
        '${LogLevel.values.map((l) => l.name).join(', ')}.',
      );
    }
    final entries = await adb.readLogcat(
      _serial,
      packageName: filter,
      minLevel: minLevel ?? LogLevel.verbose,
      maxLines: lines,
    );
    return DeviceLogRead(
      lines: [for (final entry in entries) entry.toString()],
      // Empty has two causes and they call for opposite next moves: launch the
      // app, or lower the level. The device is asked which it is rather than
      // guessed at — the guess was wrong on a live emulator, telling a caller
      // an app with pid 4866 was not running when the truth was that it had
      // logged nothing at `error`.
      note: entries.isEmpty && filter != null
          ? (await adb.pidsOf(_serial, filter)).isEmpty
                ? 'No output — $filter is not running on $_serial.'
                : '$filter is running, but logged nothing'
                      '${minLevel == null ? '' : ' at ${minLevel.name} or '
                            'above'} in the last $lines lines.'
          : null,
    );
  }

  @override
  Future<InstalledApp> installApp(String path) async {
    final lower = path.toLowerCase();
    if (lower.endsWith('.app') || lower.endsWith('.ipa')) {
      throw DeviceRefusal(
        '$path is an iOS build and $_serial is an Android device. Give an '
        '.apk, or install this onto a simulator — list_devices says which are '
        'booted.',
      );
    }
    if (!lower.endsWith('.apk')) {
      throw DeviceRefusal(
        'adb installs an .apk, and $path is not one. A split bundle (.aab, '
        '.apks) has to be turned into an APK first: bundletool build-apks, '
        'then install the universal APK.',
      );
    }
    await adb.installApk(_serial, path);
    return InstalledApp(
      path: path,
      // Deliberately null, and the note says so. `adb install` prints nothing
      // but `Success`, and reading the applicationId out of the APK would mean
      // aapt2 — a build-tools binary this app does not locate and may not have.
      // Guessing it from the file name would be wrong for every build that
      // renames its output, which is most of them.
      note:
          'adb does not report the applicationId an APK declares, so pass it to '
          'device_launch_app yourself — it is the applicationId in your '
          'build.gradle.',
    );
  }

  @override
  Future<LaunchedApp> launchApp(
    String appId, {
    String? activity,
    bool relaunch = false,
  }) async {
    if (activity != null && activity.trim().isNotEmpty) {
      await adb.startActivity(_serial, appId, activity.trim());
    } else {
      await adb.launchPackage(_serial, appId);
    }
    return LaunchedApp(
      appId: appId,
      // No pid: `am start` and `monkey` report an activity, not a process, and
      // inventing one by grepping `ps` afterwards would race the app's own
      // startup.
      note: relaunch
          ? 'relaunch is an iOS option and did nothing here — on Android, '
                'device_terminate_app then device_launch_app is the cold start.'
          : null,
    );
  }

  @override
  Future<void> terminateApp(String appId) =>
      adb.forceStopPackage(_serial, appId);

  // ---------------------------------------------------------------------------
  // Files
  // ---------------------------------------------------------------------------

  /// Three places, and the list is short on purpose.
  ///
  /// It would be easy to offer a dozen — Download, DCIM, Movies — but those are
  /// *inside* `/sdcard` and a browser can walk to them in one click. What earns
  /// a row here is a place you cannot reach from another one, or a place whose
  /// rules differ:
  ///
  /// * **`/sdcard`** is where a person's own files are, and the only root that
  ///   is both readable and writable on an ordinary device.
  /// * **`/data/local/tmp`** is the shell user's own scratch space. It is the
  ///   one writable spot outside shared storage on a device with scoped
  ///   storage, which is why this app already stages screenshots and the scrcpy
  ///   server there.
  /// * **`/`** is offered read-only and honestly labelled. Most of it is
  ///   readable — `/system`, `/proc`, `/vendor` — and a developer chasing a
  ///   path from a stack trace needs it. `/data` underneath it is not, and says
  ///   so when opened rather than appearing empty.
  ///
  /// An app's own directory is deliberately **not** a root: reaching it needs
  /// `run-as <package>` against a debuggable build, and this driver does not do
  /// that. Half-supporting it — offering the path and failing on most devices —
  /// would be worse than the refusal, which at least names the missing piece.
  @override
  Future<List<DeviceFileRoot>> fileRoots() async => const [
    DeviceFileRoot(
      path: '/sdcard',
      label: 'Shared storage',
      description:
          'Photos, Downloads, and anything an app wrote where you can see it. '
          'Readable and writable.',
      writable: true,
    ),
    DeviceFileRoot(
      path: '/data/local/tmp',
      label: 'Shell scratch space',
      description:
          'The shell user\'s own directory. Writable on every Android version, '
          'and where a file goes when nowhere else will take it.',
      writable: true,
    ),
    DeviceFileRoot(
      path: '/',
      label: 'Whole filesystem (read-only)',
      description:
          'System partitions, /proc and /vendor. Most of /data needs root and '
          'says so when you open it — an app\'s own directory needs '
          '`run-as`, which this build does not do.',
      writable: false,
    ),
  ];

  @override
  Future<DeviceDirectoryListing> listDirectory(String path) =>
      adb.listDirectory(_serial, path);

  @override
  Future<DeviceFileEntry?> stat(String path) => adb.statPath(_serial, path);

  @override
  Future<DeviceFileTransfer> pullFile({
    required String devicePath,
    required String hostPath,
  }) async {
    // Asked first so a directory is refused by name. `adb pull` of a directory
    // *works* — it copies the tree — and this surface offers one file at a
    // time, so silently pulling a hundred files because the user's click landed
    // on a folder is not a favour.
    final entry = await adb.statPath(_serial, devicePath);
    if (entry == null) {
      throw DeviceRefusal('There is nothing at $devicePath on $_serial.');
    }
    if (entry.isDirectory) {
      throw DeviceRefusal(
        '$devicePath is a directory. This copies one file at a time — open it '
        'and pick a file, or use `adb pull` yourself for the whole tree.',
      );
    }
    return adb.pullFile(
      _serial,
      devicePath: devicePath,
      hostPath: hostPath,
    );
  }

  @override
  Future<DeviceFileTransfer> pushFile({
    required String hostPath,
    required String devicePath,
    bool overwrite = false,
  }) async {
    final existing = await adb.statPath(_serial, devicePath);
    var destination = devicePath;
    String? note;
    if (existing != null && existing.isDirectory) {
      // `adb push file dir` already does this, and doing it here as well is
      // what lets the overwrite check below see the *real* destination. Without
      // it, pushing into a folder that already holds a file of that name
      // replaced it while reporting nothing.
      destination = devicePathJoin(devicePath, _hostBasename(hostPath));
      note =
          '$devicePath is a directory, so it went in as '
          '${devicePathBasename(destination)}.';
      final inside = await adb.statPath(_serial, destination);
      if (inside != null && !overwrite) {
        throw DeviceRefusal(_overwriteRefusal(destination, inside));
      }
    } else if (existing != null && !overwrite) {
      throw DeviceRefusal(_overwriteRefusal(destination, existing));
    }
    final moved = await adb.pushFile(
      _serial,
      hostPath: hostPath,
      devicePath: destination,
    );
    return DeviceFileTransfer(
      devicePath: moved.devicePath,
      hostPath: moved.hostPath,
      bytes: moved.bytes,
      note: note,
    );
  }

  @override
  Future<void> deletePath(String path, {bool recursive = false}) async {
    final entry = await adb.statPath(_serial, path);
    if (entry == null) {
      throw DeviceRefusal('There is nothing at $path on $_serial to delete.');
    }
    if (entry.isDirectory && !recursive) {
      throw DeviceRefusal(
        '$path is a directory. Deleting one takes everything inside it and '
        'there is no undo, so it has to be asked for explicitly.',
      );
    }
    await adb.removePath(_serial, path, recursive: recursive);
  }

  String _overwriteRefusal(String path, DeviceFileEntry existing) =>
      '$path already exists on $_serial'
      '${existing.sizeBytes == null ? '' : ' (${existing.sizeBytes} bytes'
            '${existing.modifiedLabel == null ? '' : ', '
                  '${existing.modifiedLabel}'})'}. '
      'Nothing was copied. Ask again with overwrite to replace it — there is '
      'no undo on the device.';

  /// The last segment of a **host** path, either separator, because this app
  /// runs on Windows and the file the user picked came from a Windows dialog.
  static String _hostBasename(String path) {
    final cut = path.lastIndexOf(RegExp(r'[/\\]'));
    return cut < 0 ? path : path.substring(cut + 1);
  }

  @override
  Future<String> powerOff() async {
    final stopped = await adb.stopEmulator(_serial);
    if (!stopped) {
      throw DeviceRefusal(
        '$_serial did not exit. It may be busy; try again, or close its '
        'window.',
      );
    }
    return 'Stopped. Anything the emulator had not written to a snapshot is '
        'gone.';
  }

  LogLevel? _parseLevel(String? level) {
    if (level == null) return null;
    final needle = level.trim().toLowerCase();
    if (needle.isEmpty) return null;
    for (final value in LogLevel.values) {
      if (value.name == needle || value.code.toLowerCase() == needle) {
        return value;
      }
    }
    return null;
  }
}
