import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/process/command_runner.dart';
import '../../../core/process/process_handle.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/android_device.dart';
import '../domain/device_action.dart';
import '../domain/device_driver.dart';
import '../domain/device_files.dart';
import '../domain/device_input.dart';
import '../domain/logcat_entry.dart';
import '../domain/ui_node.dart';
import '../domain/ui_summary.dart';
import 'adb_file_parsing.dart';
import 'adb_output_parsing.dart';
import 'uiautomator_parsing.dart';

/// Reads a file from the host that adb runs on. Injectable so tests never touch
/// the filesystem.
typedef HostFileReader = Future<Uint8List> Function(String path);

/// Escapes text for `adb shell input text`.
///
/// The device's shell re-parses the argument, so a literal space would split it
/// into two arguments; Android's `input` accepts `%s` for a space. Shell
/// metacharacters are backslash-escaped for the same reason. Getting this wrong
/// silently truncates whatever an agent tries to type.
String encodeInputText(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    if (ch == ' ') {
      buffer.write('%s');
    } else if (r'\"'
            r"'"
            r'&<>;|()$`*?[]#~'
        .contains(ch)) {
      buffer.write('\\$ch');
    } else {
      buffer.write(ch);
    }
  }
  return buffer.toString();
}

/// Every adb interaction with one Android SDK, routed through a
/// [CommandRunner] so nothing in this feature touches `Process` directly
/// (architecture constraint 6).
///
/// The service is bound to one [AndroidSdk], and therefore to one execution
/// environment: a Windows adb server and a WSL adb server are different servers
/// with different device lists.
class AdbService {
  AdbService({
    required this.runner,
    required this.sdk,
    HostFileReader? readHostFile,
    this.deviceTempDirectory = '/data/local/tmp',
    this.uiDumpRetryDelay = const Duration(milliseconds: 400),
  }) : _readHostFile = readHostFile ?? _defaultReadHostFile;

  final CommandRunner runner;
  final AndroidSdk sdk;
  final HostFileReader _readHostFile;

  /// Who is recording what this service does to devices, or null for nobody.
  ///
  /// A seam rather than a recording subclass: the device pane, the `device_*`
  /// MCP tools and any harness all share one [AdbService], so installing a sink
  /// here records all of them without a second implementation to keep in step.
  /// Reads that are pure plumbing — listing devices, asking for a screen size —
  /// are deliberately *not* reported: they are how the app works, not what
  /// somebody did to the device.
  DeviceActionSink? actionSink;

  /// Writable scratch directory on the device. `/data/local/tmp` is writable by
  /// the shell user on every supported Android version, unlike `/sdcard` on
  /// devices with scoped storage.
  final String deviceTempDirectory;

  /// How long to wait before retrying a `uiautomator dump` that failed because
  /// the screen was still animating. Tests set it to zero.
  final Duration uiDumpRetryDelay;

  static Future<Uint8List> _defaultReadHostFile(String path) =>
      File(path).readAsBytes();

  CommandRequest _adb(List<String> arguments) =>
      CommandRequest(executable: sdk.adb.path, arguments: arguments);

  CommandRequest _forDevice(String serial, List<String> arguments) =>
      _adb(['-s', serial, ...arguments]);

  /// Lists devices and emulators, including ones that are not usable
  /// (`unauthorized`, `offline`) so the UI can explain them.
  Future<List<AndroidDevice>> listDevices() async {
    final result = await runner.run(_adb(['devices', '-l']));
    if (!result.ok) return const [];
    return parseAdbDevices(result.stdout, environmentId: sdk.environmentId);
  }

  /// Lists AVDs, marking any that are currently running.
  ///
  /// An emulator's serial (`emulator-5554`) does not contain the AVD name, so
  /// each running emulator is asked for it via `emu avd name`.
  Future<List<Avd>> listAvds() async {
    final emulator = sdk.emulator;
    if (emulator == null) return const [];
    final result = await runner.run(
      CommandRequest(
        executable: emulator.path,
        arguments: const ['-list-avds'],
      ),
    );
    if (!result.ok) return const [];
    final names = parseAvdNames(result.stdout);

    final running = <String, String>{}; // avd name -> serial
    for (final device in await listDevices()) {
      if (!device.isEmulator || !device.isReady) continue;
      final name = await runningAvdName(device.serial);
      if (name != null) running[name] = device.serial;
    }
    return [
      for (final name in names) Avd(name: name, runningSerial: running[name]),
    ];
  }

  /// Asks a running emulator which AVD it booted.
  Future<String?> runningAvdName(String serial) async {
    try {
      final result = await runner.run(
        _forDevice(serial, const ['emu', 'avd', 'name']),
      );
      if (!result.ok) return null;
      return firstMeaningfulLine(result.stdout);
    } on CommandException {
      return null;
    }
  }

  /// Boots an AVD. Returns immediately: booting takes tens of seconds, and the
  /// device appears in [listDevices] once it is up.
  ///
  /// [headless] passes `-no-window`, so the emulator has no window of its own
  /// and this pane's live view is the only way to see it — which is the point:
  /// the preview, its gestures and its accessibility tree are what this feature
  /// exists for, and a second floating window is in the way. A real window is
  /// still one toggle away, because the extended controls (rotation, location,
  /// simulated calls) only exist there.
  ///
  /// Use [bootAvdAndWait] when you need to know it is actually usable —
  /// headless there is nothing to watch, so "it appeared in `adb devices`" is
  /// not the same as "it has booted".
  ///
  /// [extraArguments] are appended verbatim — the emulator slimming flags come
  /// through here (`launchArguments` in `domain/android_slimming.dart`). This
  /// service deliberately knows nothing about what they mean: the argv is the
  /// caller's policy, and building it here would put a settings decision inside
  /// the process layer.
  Future<ProcessHandle> bootAvd(
    String name, {
    bool headless = true,
    List<String> extraArguments = const [],
    void Function(String line)? onLog,
  }) async {
    final emulator = sdk.emulator;
    if (emulator == null) {
      throw StateError(
        'The Android SDK at ${sdk.root.path} has no emulator package, '
        'so AVDs cannot be booted.',
      );
    }
    final handle = await runner.start(
      CommandRequest(
        executable: emulator.path,
        arguments: [
          '-avd',
          name,
          if (headless) '-no-window',
          // Nothing watches the boot animation, headless least of all.
          '-no-boot-anim',
          ...extraArguments,
        ],
      ),
    );
    // Both streams must be drained even when nobody wants the output. The
    // emulator is chatty during boot and its stdout is a pipe of a few
    // kilobytes; with no reader it fills, the emulator blocks on write, and the
    // boot simply stops — observed on this machine, and it looks exactly like a
    // slow emulator rather than a wedged one. It is also where the emulator
    // explains itself when it refuses to start.
    void drain(Stream<String> lines) {
      lines.listen(
        (line) => onLog?.call(line),
        onError: (_) {},
        cancelOnError: false,
      );
    }

    drain(handle.stdoutLines);
    drain(handle.stderrLines);
    return handle;
  }

  /// Serial of the running emulator booted from the AVD [name], or `null`.
  ///
  /// Asks each emulator which AVD it booted rather than diffing `adb devices`
  /// across the boot. The diff is wrong as soon as two emulators start close
  /// together — it cannot say which new serial is which — and it is also wrong
  /// when the AVD was already running. The console answers this even before the
  /// system has finished booting, which is exactly when it is needed.
  Future<String?> serialForAvd(String name) async {
    for (final device in await listDevices()) {
      if (!device.isEmulator) continue;
      if (await runningAvdName(device.serial) == name) return device.serial;
    }
    return null;
  }

  /// Whether Android has finished booting on [serial].
  ///
  /// `sys.boot_completed` is the property Android sets when it broadcasts
  /// `BOOT_COMPLETED`. A device answers adb well before that, so without this
  /// check the first `wm size`, `uiautomator dump` or scrcpy start can land on
  /// a half-booted system and fail in ways that look like our bugs.
  Future<bool> isBootCompleted(String serial) async {
    try {
      final result = await runner.run(
        _forDevice(serial, const ['shell', 'getprop', 'sys.boot_completed']),
      );
      return result.ok && result.stdout.trim() == '1';
    } on CommandException {
      return false;
    }
  }

  /// Boots [name] and waits until it is genuinely usable, returning its serial.
  ///
  /// Bounded: an emulator that never comes up says so rather than leaving a
  /// spinner running forever.
  Future<String> bootAvdAndWait(
    String name, {
    bool headless = true,
    List<String> extraArguments = const [],
    Duration timeout = const Duration(minutes: 3),
    Duration pollInterval = const Duration(seconds: 2),
  }) async {
    final log = <String>[];
    await bootAvd(
      name,
      headless: headless,
      extraArguments: extraArguments,
      onLog: (line) {
        // Its last words, for the failure message. The emulator normally
        // explains why it would not start.
        log.add(line);
        if (log.length > 20) log.removeAt(0);
      },
    );
    final deadline = DateTime.now().add(timeout);
    String? serial;
    while (DateTime.now().isBefore(deadline)) {
      serial ??= await serialForAvd(name);
      if (serial != null && await isBootCompleted(serial)) return serial;
      await Future<void>.delayed(pollInterval);
    }
    final lastWords = log.isEmpty ? '' : ' Last output: ${log.last}';
    throw StateError(
      serial == null
          ? '$name did not become reachable within '
                '${timeout.inSeconds}s.$lastWords'
          : '$name ($serial) did not finish booting within '
                '${timeout.inSeconds}s.$lastWords',
    );
  }

  /// The device's current screen size — the coordinate space taps use.
  Future<DeviceScreenSize?> screenSize(String serial) async {
    final result = await runner.run(
      _forDevice(serial, const ['shell', 'wm', 'size']),
    );
    if (!result.ok) return null;
    return parseScreenSize(result.stdout);
  }

  /// Captures the screen as PNG bytes.
  ///
  /// Deliberately goes device-file → `adb pull` → host-file rather than
  /// `exec-out screencap -p`: the runner decodes stdout as text, which would
  /// corrupt binary PNG data.
  Future<Uint8List> screenshot(String serial, {String? hostPath}) async {
    final devicePath = '$deviceTempDirectory/karmashala_screen.png';
    final capture = await runner.run(
      _forDevice(serial, ['shell', 'screencap', '-p', devicePath]),
    );
    if (!capture.ok) {
      throw StateError('screencap failed on $serial: ${capture.stderr.trim()}');
    }
    final destination =
        hostPath ??
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
            'karmashala_screen_$serial.png';
    final pull = await runner.run(
      _forDevice(serial, ['pull', devicePath, destination]),
    );
    if (!pull.ok) {
      throw StateError('adb pull failed for $serial: ${pull.stderr.trim()}');
    }
    await runner.run(_forDevice(serial, ['shell', 'rm', '-f', devicePath]));
    final bytes = await _readHostFile(destination);
    _report(
      DeviceAction(
        verb: 'screenshot',
        serial: serial,
        summary: 'Screenshot of $serial',
        png: bytes,
      ),
    );
    return bytes;
  }

  /// Dumps the current accessibility (view) hierarchy.
  ///
  /// Goes device-file → `shell cat` rather than `uiautomator dump /dev/tty`:
  /// `/dev/tty` interleaves uiautomator's own log line with the XML, and older
  /// devices do not accept it at all. `cat` is safe here in a way it is not for
  /// screenshots — the payload is text, so the runner decoding stdout as text
  /// costs nothing.
  ///
  /// Retries while the failure is retryable. The common one is
  /// `ERROR: could not get idle state.`, which means the screen was animating;
  /// it is transient by definition, and uiautomator reports it with **exit code
  /// 0**, so the retry decision cannot be made from the exit status.
  Future<UiHierarchy> dumpUiHierarchy(String serial, {int attempts = 3}) async {
    final devicePath = '$deviceTempDirectory/karmashala_ui_dump.xml';
    UiDumpFailure? failure;
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (attempt > 0 && uiDumpRetryDelay > Duration.zero) {
        await Future<void>.delayed(uiDumpRetryDelay);
      }
      final dump = await runner.run(
        _forDevice(serial, ['shell', 'uiautomator', 'dump', devicePath]),
      );
      failure = uiDumpFailure('${dump.stdout}\n${dump.stderr}', ok: dump.ok);
      if (failure != null) {
        if (!failure.retryable) break;
        continue;
      }
      final read = await runner.run(
        _forDevice(serial, ['shell', 'cat', devicePath]),
      );
      if (!read.ok) {
        failure = UiDumpFailure(
          message: 'Could not read the dump back: ${read.stderr.trim()}',
          retryable: false,
        );
        break;
      }
      final hierarchy = parseUiAutomatorXml(read.stdout);
      if (hierarchy.isEmpty) {
        // A syntactically fine dump with no nodes in it. Seen mid-transition;
        // trying again usually catches the settled screen.
        failure = const UiDumpFailure(
          message:
              'The dump contained no nodes. The screen was probably '
              'mid-transition.',
          retryable: true,
        );
        continue;
      }
      await runner.run(_forDevice(serial, ['shell', 'rm', '-f', devicePath]));
      _report(
        DeviceAction(
          verb: 'uiDump',
          serial: serial,
          summary:
              'Read the UI tree — ${hierarchy.nodeCount} nodes in '
              '${hierarchy.packageName ?? 'an unknown package'}',
          text: renderUiTree(hierarchy),
        ),
      );
      return hierarchy;
    }
    final error = UiDumpException(
      failure?.message ?? 'uiautomator dump produced nothing usable.',
      serial: serial,
      attempts: attempts,
    );
    _report(
      DeviceAction(
        verb: 'uiDump',
        serial: serial,
        summary: 'Read the UI tree',
      ).failed(error),
    );
    throw error;
  }

  /// Installs an APK, replacing any build of the same package already there.
  ///
  /// `-r` rather than a clean install: an agent's loop is build, install, look,
  /// and wiping the app's data between iterations would throw away the state
  /// it just spent five taps setting up. `-t` allows an APK whose manifest is
  /// marked `testOnly`, which is what `flutter build apk --debug` and every
  /// `assembleDebug` produce — without it the ordinary output of a debug build
  /// is refused with `INSTALL_FAILED_TEST_ONLY`, and the message does not say
  /// that a flag would have fixed it.
  ///
  /// The decision is made on the output as well as the exit status. adb has
  /// returned 0 for `Failure [INSTALL_FAILED_*]` on and off across releases —
  /// it is the same trap [launchPackage] documents below — and an install that
  /// reported success without installing anything sends the caller on to a
  /// launch that fails for a reason that looks unrelated.
  Future<void> installApk(String serial, String apkPath) async {
    const verb = 'install';
    final summary = 'Installed $apkPath';
    final result = await runner.run(
      _forDevice(serial, ['install', '-r', '-t', apkPath]),
    );
    final output = '${result.stdout}\n${result.stderr}';
    if (!result.ok || output.contains('Failure [')) {
      // A full /data reports as `IOException: Requested internal only, but not
      // enough space`, which names neither the partition nor the remedy. The
      // number is worth one extra call on a path that has already failed.
      var advice = '';
      if (installFailedForSpace(output)) {
        final df = await runner.run(
          _forDevice(serial, ['shell', 'df', '/data']),
        );
        final use = dataPartitionUse(df.stdout);
        advice =
            '\nThe device is out of space${use == null ? '' : ' (/data is $use full)'}. '
            'Free some and retry: `adb -s $serial shell pm trim-caches 2G`, or '
            'uninstall an app you are not using — note that uninstalling wipes '
            'that app\'s data.';
      }
      final error = StateError(
        'adb install failed on $serial: '
        '${output.trim().isEmpty ? 'exit ${result.exitCode}' : output.trim()}'
        '$advice',
      );
      _report(
        DeviceAction(
          verb: verb,
          serial: serial,
          summary: summary,
        ).failed(error),
      );
      throw error;
    }
    _report(DeviceAction(verb: verb, serial: serial, summary: summary));
  }

  /// Removes an app and its data.
  Future<void> uninstallPackage(String serial, String packageName) async {
    const verb = 'uninstall';
    final summary = 'Uninstalled $packageName';
    final result = await runner.run(
      _forDevice(serial, ['uninstall', packageName]),
    );
    final output = '${result.stdout}\n${result.stderr}';
    if (!result.ok || output.contains('Failure [')) {
      final error = StateError(
        'adb uninstall failed on $serial: '
        '${output.trim().isEmpty ? 'exit ${result.exitCode}' : output.trim()}',
      );
      _report(
        DeviceAction(
          verb: verb,
          serial: serial,
          summary: summary,
        ).failed(error),
      );
      throw error;
    }
    _report(DeviceAction(verb: verb, serial: serial, summary: summary));
  }

  /// Starts one named activity: `am start -n <package>/<activity>`.
  ///
  /// The explicit counterpart of [launchPackage], for the cases where the
  /// launcher activity is the wrong entry point — a deep-linked screen, or one
  /// of several activities in a test harness. `.MainActivity` is accepted as
  /// well as a fully-qualified class, because that is the shorthand every
  /// AndroidManifest is written in and `am` expands it against the package.
  ///
  /// `am start` **exits 0 when the activity does not exist** and says so only
  /// on stdout (`Error: Activity class {…} does not exist.`), so the exit code
  /// alone would report a successful launch of nothing.
  Future<void> startActivity(
    String serial,
    String packageName,
    String activity,
  ) async {
    const verb = 'launch';
    final component =
        '$packageName/${activity.contains('.') ? activity : '.$activity'}';
    final summary = 'Launched $component';
    final result = await runner.run(
      _forDevice(serial, ['shell', 'am', 'start', '-n', component]),
    );
    final output = '${result.stdout}\n${result.stderr}';
    if (!result.ok || output.contains('Error:')) {
      final error = StateError(
        'Could not start $component on $serial: '
        '${output.trim().isEmpty ? 'exit ${result.exitCode}' : output.trim()}',
      );
      _report(
        DeviceAction(
          verb: verb,
          serial: serial,
          summary: summary,
        ).failed(error),
      );
      throw error;
    }
    _report(DeviceAction(verb: verb, serial: serial, summary: summary));
  }

  /// Stops every process of [packageName].
  ///
  /// `am force-stop` is silent and exits 0 whether the app was running or not,
  /// which is the behaviour a caller wants: asking for a state the app is
  /// already in is not a failure — the same rule `SimctlService.terminateApp`
  /// follows. Nothing is asserted about the output because there is none.
  Future<void> forceStopPackage(String serial, String packageName) async {
    final result = await runner.run(
      _forDevice(serial, ['shell', 'am', 'force-stop', packageName]),
    );
    const verb = 'terminate';
    final summary = 'Stopped $packageName';
    if (!result.ok) {
      final error = StateError(
        'am force-stop failed on $serial: ${result.stderr.trim()}',
      );
      _report(
        DeviceAction(
          verb: verb,
          serial: serial,
          summary: summary,
        ).failed(error),
      );
      throw error;
    }
    _report(DeviceAction(verb: verb, serial: serial, summary: summary));
  }

  /// Launches [packageName]'s launcher activity.
  ///
  /// Goes through `monkey`, which resolves the launcher activity itself, so the
  /// caller does not have to know the activity name. `monkey` **exits 0 when it
  /// finds no activity**, so the decision is made on its output and not on the
  /// exit status — the same trap `uiautomator dump` sets above.
  Future<void> launchPackage(String serial, String packageName) async {
    final result = await runner.run(
      _forDevice(serial, [
        'shell',
        'monkey',
        '-p',
        packageName,
        '-c',
        'android.intent.category.LAUNCHER',
        '1',
      ]),
    );
    final output = '${result.stdout}\n${result.stderr}';
    final missing =
        output.contains('No activities found') ||
        output.contains('monkey aborted');
    if (!result.ok || missing) {
      final error = StateError(
        missing
            ? '$packageName has no launcher activity on $serial (or is not '
                  'installed).'
            : 'Could not launch $packageName on $serial: '
                  '${result.stderr.trim()}',
      );
      _report(
        DeviceAction(
          verb: 'launch',
          serial: serial,
          summary: 'Launched $packageName',
        ).failed(error),
      );
      throw error;
    }
    _report(
      DeviceAction(
        verb: 'launch',
        serial: serial,
        summary: 'Launched $packageName',
      ),
    );
  }

  Future<void> tap(String serial, int x, int y) async {
    await _runInput(serial, ['tap', '$x', '$y'], 'tap', 'Tapped ($x, $y)');
  }

  Future<void> swipe(
    String serial, {
    required int fromX,
    required int fromY,
    required int toX,
    required int toY,
    Duration duration = const Duration(milliseconds: 200),
  }) async {
    await _runInput(
      serial,
      [
        'swipe',
        '$fromX',
        '$fromY',
        '$toX',
        '$toY',
        '${duration.inMilliseconds}',
      ],
      'swipe',
      'Swiped ($fromX, $fromY) → ($toX, $toY) over '
          '${duration.inMilliseconds} ms',
    );
  }

  Future<void> inputText(String serial, String text) async {
    if (text.isEmpty) return;
    await _runInput(
      serial,
      ['text', encodeInputText(text)],
      'type',
      'Typed "$text"',
    );
  }

  Future<void> pressKey(String serial, DeviceKey key) async {
    await _runInput(
      serial,
      ['keyevent', key.keyCode],
      'key',
      'Pressed ${key.name}',
    );
  }

  /// Presses a raw Android `KEYCODE_*` value.
  ///
  /// Numeric because the keyboard-forwarding path works in numbers all the way
  /// down — scrcpy's `INJECT_KEYCODE` carries an int, and `input keyevent`
  /// accepts one — and because [DeviceKey] only names the handful of keys the
  /// hardware-button row offers.
  Future<void> pressKeyCode(String serial, int keyCode) async {
    await _runInput(
      serial,
      ['keyevent', '$keyCode'],
      'key',
      'Pressed keycode $keyCode',
    );
  }

  Future<void> _runInput(
    String serial,
    List<String> arguments,
    String verb,
    String summary,
  ) async {
    final result = await runner.run(
      _forDevice(serial, ['shell', 'input', ...arguments]),
    );
    if (!result.ok) {
      final error = StateError(
        'input ${arguments.first} failed on $serial: ${result.stderr.trim()}',
      );
      _report(
        DeviceAction(
          verb: verb,
          serial: serial,
          summary: summary,
        ).failed(error),
      );
      throw error;
    }
    _report(DeviceAction(verb: verb, serial: serial, summary: summary));
  }

  /// Whether the device is in dark mode, or `null` when it will not say.
  ///
  /// Read rather than remembered. The appearance can be changed from the
  /// device's own Quick Settings tile or by a scheduled switch at dusk, so a
  /// toggle that trusted its last write would sit inverted — offering "dark"
  /// on a device that is already dark. `cmd uimode night` answers with one
  /// line, `Night mode: yes`, which is why this is a cheap thing to ask before
  /// every flip rather than something to cache.
  Future<bool?> isNightMode(String serial) async {
    final result = await runner.run(
      _forDevice(serial, const ['shell', 'cmd', 'uimode', 'night']),
    );
    if (!result.ok) return null;
    return parseNightMode(result.stdout);
  }

  /// Switches the device between light and dark.
  ///
  /// `cmd uimode night`, not `settings put secure ui_night_mode`. The setting
  /// is only half the story: it records the preference, but the running system
  /// UI and every foreground app keep the appearance they were configured with
  /// until something tells them otherwise. `cmd` goes through the same
  /// `UiModeManager` call the Quick Settings tile makes, so what is on screen
  /// changes with it.
  Future<void> setNightMode(String serial, {required bool dark}) async {
    final value = dark ? 'yes' : 'no';
    final summary = 'Set night mode to $value';
    final result = await runner.run(
      _forDevice(serial, ['shell', 'cmd', 'uimode', 'night', value]),
    );
    if (!result.ok) {
      final error = StateError(
        '$summary failed on $serial: ${result.stderr.trim()}',
      );
      _report(
        DeviceAction(
          verb: 'appearance',
          serial: serial,
          summary: summary,
        ).failed(error),
      );
      throw error;
    }
    _report(DeviceAction(verb: 'appearance', serial: serial, summary: summary));
  }

  /// Opens a URL — a web link, or a custom scheme to reach a deep link in an
  /// installed app.
  ///
  /// The exit code is **not** the answer here, which is the whole reason this
  /// does not go through the usual "ok or throw" shape. Measured against an
  /// API 34 emulator: an intent nothing can handle still exits 0, printing
  ///
  /// ```
  /// Error: Activity not started, unable to resolve Intent { … }
  /// ```
  ///
  /// to stderr. A deep link typed with the wrong scheme — the single most
  /// likely thing to get wrong here — would otherwise report success and do
  /// nothing at all, which is the failure this control exists to make visible.
  Future<void> openUrl(String serial, String url) async {
    final summary = 'Opened $url';
    final result = await runner.run(
      _forDevice(serial, [
        'shell',
        'am',
        'start',
        '-a',
        'android.intent.action.VIEW',
        '-d',
        url,
      ]),
    );
    if (!result.ok || result.stderr.contains('Error:')) {
      final complaint = result.stderr.trim().isEmpty
          ? result.stdout.trim()
          : result.stderr.trim();
      final error = StateError('am start failed on $serial: $complaint');
      _report(
        DeviceAction(
          verb: 'openUrl',
          serial: serial,
          summary: summary,
        ).failed(error),
      );
      throw error;
    }
    _report(DeviceAction(verb: 'openUrl', serial: serial, summary: summary));
  }

  /// Reads recent log lines, newest last.
  ///
  /// When [packageName] is given the log is filtered to that package's live
  /// processes; a package that is not running yields an empty list rather than
  /// the whole system log.
  /// The pids [packageName] is running under, empty when it is not running.
  ///
  /// Exposed rather than left inside [readLogcat] because "no log lines" and
  /// "no process" are different answers and a caller has to be able to tell
  /// them apart. `device_logcat` used to report an empty read as "the app does
  /// not appear to be running", which is a statement about the device it had
  /// not checked — and it was wrong the moment a level filter was the real
  /// reason nothing came back. Seen on a live emulator: the app was up, its pid
  /// was 4866, and the tool said it was not running.
  Future<List<int>> pidsOf(String serial, String packageName) async {
    final result = await runner.run(
      _forDevice(serial, ['shell', 'pidof', packageName]),
    );
    return result.ok ? parsePidsFromPidof(result.stdout) : const [];
  }

  Future<List<LogcatEntry>> readLogcat(
    String serial, {
    String? packageName,
    LogLevel minLevel = LogLevel.verbose,
    int maxLines = 200,
  }) async {
    List<int> pids = const [];
    if (packageName != null) {
      final found = await runner.run(
        _forDevice(serial, ['shell', 'pidof', packageName]),
      );
      pids = found.ok ? parsePidsFromPidof(found.stdout) : const [];
      if (pids.isEmpty) return const [];
    }
    final result = await runner.run(
      _forDevice(serial, [
        'shell',
        'logcat',
        '-d',
        '-v',
        'threadtime',
        '-t',
        '$maxLines',
        ...pids.expand((pid) => ['--pid', '$pid']),
      ]),
    );
    if (!result.ok) return const [];
    final entries = [
      for (final line in result.stdout.split(RegExp(r'[\r\n]+')))
        if (parseLogcatLine(line) case final entry?)
          if (entry.level.atLeast(minLevel)) entry,
    ];
    _report(
      DeviceAction(
        verb: 'logcat',
        serial: serial,
        summary:
            '${entries.length} log line${entries.length == 1 ? '' : 's'}'
            '${packageName == null ? '' : ' from $packageName'}'
            '${minLevel == LogLevel.verbose ? '' : ' at ${minLevel.name} or above'}',
        text: entries.map((e) => e.toString()).join('\n'),
      ),
    );
    return entries;
  }

  /// Starts a live `logcat` stream. The caller owns the handle and must kill it.
  Future<ProcessHandle> streamLogcat(
    String serial, {
    List<int> pids = const [],
  }) => runner.start(
    _forDevice(serial, [
      'shell',
      'logcat',
      '-v',
      'threadtime',
      ...pids.expand((pid) => ['--pid', '$pid']),
    ]),
  );

  /// Pushes a file to the device.
  Future<void> push(
    String serial,
    EnvironmentPath source,
    String devicePath,
  ) async {
    final result = await runner.run(
      _forDevice(serial, ['push', source.path, devicePath]),
    );
    if (!result.ok) {
      throw StateError('adb push failed: ${result.stderr.trim()}');
    }
  }

  /// Creates a host→device tunnel, returning the local port.
  Future<void> forward(String serial, int localPort, String remote) async {
    final result = await runner.run(
      _forDevice(serial, ['forward', 'tcp:$localPort', remote]),
    );
    if (!result.ok) {
      throw StateError('adb forward failed: ${result.stderr.trim()}');
    }
  }

  Future<void> removeForward(String serial, int localPort) async {
    await runner.run(
      _forDevice(serial, ['forward', '--remove', 'tcp:$localPort']),
    );
  }

  /// Every `adb forward` currently registered, across all devices.
  ///
  /// Not filtered by serial here: `adb forward --list` ignores `-s` and always
  /// prints the whole table, so the filtering is [parseScrcpyForwards]'s job.
  Future<String> listForwards() async {
    final result = await runner.run(_adb(const ['forward', '--list']));
    return result.ok ? result.stdout : '';
  }

  /// The device's process table with full command lines.
  Future<String> processList(String serial) async {
    final result = await runner.run(
      _forDevice(serial, const ['shell', 'ps', '-A', '-o', 'PID,ARGS']),
    );
    return result.ok ? result.stdout : '';
  }

  /// Tells [actionSink] what happened, without letting a recorder's own fault
  /// break the device call it was watching.
  void _report(DeviceAction action) {
    final sink = actionSink;
    if (sink == null) return;
    try {
      sink(action);
    } on Object {
      // Recording is observation. It never decides whether the action worked.
    }
  }

  // ---------------------------------------------------------------------------
  // Files
  //
  // Every path that reaches the device's own shell goes through [shellQuote];
  // every path handed to `adb pull`/`adb push` deliberately does **not**,
  // because those use adb's sync service and never see a shell. Getting that
  // backwards quotes the quotes into the filename.
  // ---------------------------------------------------------------------------

  /// Lists one directory on the device.
  ///
  /// **A directory that cannot be read throws rather than coming back empty.**
  /// That is the whole reason this returns a listing and not a `List` — an
  /// empty folder and a refusal look identical in a file browser, and this
  /// codebase has been bitten by that class of silence more than once.
  ///
  /// The trailing slash is load-bearing. `/sdcard` is a symlink on every
  /// Android device, and `ls -l /sdcard` prints *the link*, one row, rather
  /// than what is inside it — measured on the owner's handset, which answered
  /// `lrw-r--r-- … /sdcard -> /storage/self/primary` and nothing else. A
  /// trailing slash dereferences the argument alone, which `-L` would not: that
  /// dereferences every entry in the listing too, and a browser would then show
  /// `/system/bin` as a directory the user cannot navigate back out of by the
  /// name they clicked.
  Future<DeviceDirectoryListing> listDirectory(
    String serial,
    String path,
  ) async {
    final directory = path.endsWith('/') ? path : '$path/';
    final read = await _readDeviceText(
      serial,
      'ls -la ${shellQuote(directory)}',
    );
    final failure = classifyLsFailure(read.combined, ok: read.ok);
    if (failure != null) {
      throw DeviceRefusal(_lsRefusal(failure, serial: serial, path: path));
    }
    final listing = parseLsLong(
      read.text,
      directory: _withoutTrailingSlash(path),
    );
    return read.note == null
        ? listing
        : DeviceDirectoryListing(
            path: listing.path,
            entries: listing.entries,
            skipped: listing.skipped,
            note: read.note,
          );
  }

  /// What [path] is, or null when nothing is there.
  ///
  /// `ls -lad`: `-d` reports the entry itself rather than a directory's
  /// contents, and no trailing slash, so a symlink is reported as a symlink.
  /// A missing path is null; a path that exists but cannot be reached throws,
  /// because the two lead to opposite next moves.
  Future<DeviceFileEntry?> statPath(String serial, String path) async {
    final read = await _readDeviceText(serial, 'ls -lad ${shellQuote(path)}');
    final failure = classifyLsFailure(read.combined, ok: read.ok);
    if (failure == LsFailure.missing) return null;
    if (failure != null) {
      throw DeviceRefusal(_lsRefusal(failure, serial: serial, path: path));
    }
    final listing = parseLsLong(
      read.text,
      directory: devicePathParent(path) ?? '/',
    );
    return listing.entries.firstOrNull;
  }

  /// Runs a device command **whose output contains filenames**, and gets those
  /// filenames back intact.
  ///
  /// The problem this exists for is real and was measured, not anticipated. A
  /// device's filesystem is UTF-8; `CommandRunner` decodes a process's output
  /// with `SystemEncoding`, which on Windows is the machine's ANSI code page.
  /// So a file the emulator lists as `my file नेपाली.txt` arrived here as
  /// `my file à¤¨à¥‡à¤ªà¤¾à¤²à¥€.txt` — a name that cannot be clicked, cannot
  /// be pulled, and looks like the device is broken rather than the pipe.
  /// Every non-Latin filename on the machine of the developer this app is
  /// written for would have come out that way.
  ///
  /// The fix is to make the wire ASCII: `… | base64` on the device, decoded
  /// here. base64 is in toybox and is present on every device this app
  /// supports — checked on an Android 11 handset and an Android 14 emulator —
  /// and it costs no extra round trip, because the pipe runs inside the one
  /// `adb shell` that was happening anyway.
  ///
  /// Two fallbacks, because a device without `base64` must still list its
  /// files: if the shell says it has no such command, or if what comes back is
  /// not base64 at all, the plain output is used and [_DeviceText.note] says
  /// the names may be wrong. Wrong-and-labelled beats a directory that refuses
  /// to open.
  ///
  /// **Not fixed globally**, deliberately. `LocalCommandRunner`'s
  /// `SystemEncoding` is what several Windows tools need — `wsl.exe` emits
  /// UTF-16 — and changing it would reach every process this app runs for the
  /// sake of one surface.
  Future<_DeviceText> _readDeviceText(String serial, String command) async {
    final encoded = await runner.run(
      _forDevice(serial, ['shell', '$command | base64']),
    );
    final combined = '${encoded.stdout}\n${encoded.stderr}';
    if (!_base64Missing(combined)) {
      final decoded = _decodeBase64(encoded.stdout);
      if (decoded != null) {
        return _DeviceText(text: decoded, combined: combined, ok: encoded.ok);
      }
      // Output that is neither an error nor base64. Nothing seen does this,
      // but reporting "cannot read" for a directory that listed fine would be
      // a worse answer than showing it with a warning.
      if (encoded.stdout.trim().isEmpty) {
        return _DeviceText(text: '', combined: combined, ok: encoded.ok);
      }
    }
    final plain = await runner.run(_forDevice(serial, ['shell', command]));
    return _DeviceText(
      text: plain.stdout,
      combined: '${plain.stdout}\n${plain.stderr}',
      ok: plain.ok,
      note:
          'This device has no `base64`, so names came back in this computer\'s '
          'console encoding. Anything not plain ASCII may be spelled wrong '
          'here — and a wrongly-spelled name will not open or copy.',
    );
  }

  static bool _base64Missing(String output) => RegExp(
    r'base64[^\n]*(not found|inaccessible|No such file|Permission denied)',
    caseSensitive: false,
  ).hasMatch(output);

  /// Decodes base64 that a shell wrapped at 76 columns, or null when the text
  /// is not base64 at all.
  static String? _decodeBase64(String output) {
    final packed = output.replaceAll(RegExp(r'\s+'), '');
    if (packed.isEmpty) return null;
    try {
      return utf8.decode(base64.decode(packed), allowMalformed: true);
    } on FormatException {
      return null;
    }
  }

  /// Copies a file off the device.
  ///
  /// No progress is reported, and that is measured rather than lazy: adb draws
  /// its `[ 47%]` bar only when stdout is a terminal, and here it is a pipe, so
  /// there is nothing to read until the transfer finishes. Inventing a
  /// percentage from the file size would be a bar that is wrong for the whole
  /// of a slow pull. Callers show that a transfer is running and how big it is;
  /// [DeviceFileTransfer.bytes] is what adb actually moved.
  Future<DeviceFileTransfer> pullFile(
    String serial, {
    required String devicePath,
    required String hostPath,
  }) async {
    final result = await runner.run(
      _forDevice(serial, ['pull', devicePath, hostPath]),
    );
    // The summary lands on **stderr with exit code 0** — measured against a
    // real device. Reading only stdout sees an empty string and concludes
    // nothing moved; treating stderr as failure reports a good pull as broken.
    final combined = '${result.stdout}\n${result.stderr}';
    if (!result.ok || !transferSucceeded(combined)) {
      final error = DeviceRefusal(
        'Could not copy $devicePath off $serial: ${cleanAdbError(combined)}',
      );
      _report(
        DeviceAction(
          verb: 'pullFile',
          serial: serial,
          summary: 'Copy $devicePath to this computer',
        ).failed(error),
      );
      throw error;
    }
    final bytes = parseTransferredBytes(combined);
    _report(
      DeviceAction(
        verb: 'pullFile',
        serial: serial,
        summary:
            'Copied $devicePath to $hostPath'
            '${bytes == null ? '' : ' ($bytes bytes)'}',
      ),
    );
    return DeviceFileTransfer(
      devicePath: devicePath,
      hostPath: hostPath,
      bytes: bytes,
    );
  }

  /// Copies a file onto the device. Overwrites whatever is at [devicePath] —
  /// the *decision* not to belongs one layer up, in the driver, which is where
  /// the destination is checked and where the refusal is worded.
  Future<DeviceFileTransfer> pushFile(
    String serial, {
    required String hostPath,
    required String devicePath,
  }) async {
    final result = await runner.run(
      _forDevice(serial, ['push', hostPath, devicePath]),
    );
    final combined = '${result.stdout}\n${result.stderr}';
    if (!result.ok || !transferSucceeded(combined)) {
      final error = DeviceRefusal(
        'Could not copy $hostPath onto $serial: ${cleanAdbError(combined)}',
      );
      _report(
        DeviceAction(
          verb: 'pushFile',
          serial: serial,
          summary: 'Copy $hostPath to $devicePath',
        ).failed(error),
      );
      throw error;
    }
    final bytes = parseTransferredBytes(combined);
    _report(
      DeviceAction(
        verb: 'pushFile',
        serial: serial,
        summary:
            'Copied $hostPath to $devicePath on $serial'
            '${bytes == null ? '' : ' ($bytes bytes)'}',
      ),
    );
    return DeviceFileTransfer(
      devicePath: devicePath,
      hostPath: hostPath,
      bytes: bytes,
    );
  }

  /// Removes a path on the device. There is no undo on the other side of this.
  ///
  /// `rm` without `-f`, so a path that is not there is an error rather than a
  /// silent success: a delete that reports "done" for a path it never found
  /// tells the user their file is gone when it is somewhere else.
  Future<void> removePath(
    String serial,
    String path, {
    bool recursive = false,
  }) async {
    final flags = recursive ? '-r' : '';
    final result = await runner.run(
      _forDevice(serial, [
        'shell',
        'rm $flags ${shellQuote(path)}'.replaceAll('  ', ' '),
      ]),
    );
    final combined = '${result.stdout}\n${result.stderr}'.trim();
    // `rm` says nothing when it works, so any output at all is the failure —
    // which is just as well, because a device from before Android 7 does not
    // forward the exit code.
    if (!result.ok || combined.isNotEmpty) {
      final error = DeviceRefusal(
        'Could not delete $path on $serial: '
        '${combined.isEmpty ? 'rm exited ${result.exitCode}.' : cleanAdbError(combined)}',
      );
      _report(
        DeviceAction(
          verb: 'deletePath',
          serial: serial,
          summary: 'Delete $path',
        ).failed(error),
      );
      throw error;
    }
    _report(
      DeviceAction(
        verb: 'deletePath',
        serial: serial,
        summary: 'Deleted $path on $serial',
      ),
    );
  }

  String _lsRefusal(
    LsFailure failure, {
    required String serial,
    required String path,
  }) => switch (failure) {
    LsFailure.permissionDenied => _appPrivate(path)
        // The one refusal worth explaining rather than reporting, because the
        // path looks like it should work and the reason it does not is a
        // property of the *build on the device*, not of this app.
        ? '$path is an app\'s own directory, and adb\'s shell user cannot read '
              'one. Reaching it needs `run-as <package>`, which only works on a '
              'debuggable build of that app — this build does not do it. '
              'Everything under /sdcard is readable, and so is '
              '/data/local/tmp.'
        : '$path is not readable on $serial. Most of /data needs root, which '
              'an ordinary device does not give adb. /sdcard and '
              '/data/local/tmp are readable.',
    LsFailure.missing => 'There is nothing at $path on $serial.',
    LsFailure.notADirectory => '$path on $serial is a file, not a directory.',
    LsFailure.unknown =>
      '$serial would not list $path, and did not say why in a way this build '
          'recognises.',
  };

  /// Whether a path is inside some app's private storage — the case where
  /// "permission denied" has a specific explanation rather than a general one.
  static bool _appPrivate(String path) =>
      path.startsWith('/data/data/') ||
      path.startsWith('/data/user/') ||
      path.startsWith('/data/user_de/');

  static String _withoutTrailingSlash(String path) =>
      path.length > 1 && path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;

  /// Sends SIGKILL to [pids] on the device. Best effort: a pid that has already
  /// gone is not an error.
  Future<void> killPids(String serial, List<int> pids) async {
    if (pids.isEmpty) return;
    await runner.run(
      _forDevice(serial, ['shell', 'kill', '-9', ...pids.map((pid) => '$pid')]),
    );
  }

  /// Shuts a running emulator down.
  ///
  /// `emu kill` talks to the emulator's own console rather than to the device,
  /// so it does nothing on a physical phone — callers must check
  /// [AndroidDevice.isEmulator] first. Returns whether the emulator actually
  /// went away, rather than whether the command was accepted: the console
  /// answers `OK` before the process has finished exiting.
  Future<bool> stopEmulator(
    String serial, {
    Duration timeout = const Duration(seconds: 20),
    Duration pollInterval = const Duration(milliseconds: 500),
  }) async {
    final result = await runner.run(_forDevice(serial, const ['emu', 'kill']));
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final devices = await listDevices();
      if (!devices.any((device) => device.serial == serial)) return true;
      await Future<void>.delayed(pollInterval);
    }
    if (!result.ok) {
      throw StateError(
        'Could not stop $serial: ${result.stderr.trim().isEmpty ? result.stdout.trim() : result.stderr.trim()}',
      );
    }
    return false;
  }
}

/// Whether an `adb install` failure is about free space rather than the APK.
///
/// The wording varies by API level — the package installer says
/// `INSUFFICIENT_STORAGE`, the newer one wraps an `IOException: Requested
/// internal only, but not enough space` — so this matches on the idea rather
/// than on one string.
bool installFailedForSpace(String output) {
  final upper = output.toUpperCase();
  return upper.contains('INSUFFICIENT_STORAGE') ||
      upper.contains('NOT ENOUGH SPACE') ||
      upper.contains('NO SPACE LEFT');
}

/// The `Use%` column for `/data` out of `df` output, e.g. `92%`.
///
/// Returns null rather than guessing when the layout is not the expected one:
/// a wrong number in an error message is worse than no number.
String? dataPartitionUse(String dfOutput) {
  for (final line in const LineSplitter().convert(dfOutput)) {
    if (!line.contains('/data')) continue;
    final columns = line.trim().split(RegExp(r'\s+'));
    for (final column in columns) {
      if (column.endsWith('%') &&
          int.tryParse(column.substring(0, column.length - 1)) != null) {
        return column;
      }
    }
  }
  return null;
}

/// Device output that has been brought back to UTF-8, with what it cost.
///
/// [combined] is stdout *and* stderr of whichever attempt produced [text], and
/// exists because every failure decision in this file is made on the output
/// rather than the exit status — `adb shell` did not forward a remote exit code
/// before Android 7, and a pipe replaces it with the last command's anyway.
class _DeviceText {
  const _DeviceText({
    required this.text,
    required this.combined,
    required this.ok,
    this.note,
  });

  final String text;
  final String combined;
  final bool ok;

  /// What the caller should tell the user about how this was read, or null
  /// when nothing had to be worked around.
  final String? note;
}
