import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import '../domain/android_device.dart';
import '../domain/device_action.dart';
import '../domain/device_driver.dart';
import '../domain/device_files.dart';
import '../domain/device_input.dart';
import '../domain/device_target.dart';
import '../domain/logcat_entry.dart';
import '../domain/ui_node.dart';
import '../domain/ui_summary.dart';
import '../domain/wireless_pairing.dart';
import 'adb_file_parsing.dart';
import 'adb_output_parsing.dart';
import 'adb_wireless_parsing.dart';
import 'uiautomator_parsing.dart';

/// Reads a file from the host that adb runs on. Injectable so tests never touch
/// the filesystem.
typedef HostFileReader = Future<Uint8List> Function(String path);

/// Whether a host path exists, and how to remove one: the pair that lets a
/// failed `adb pull` take its partial file away without touching a pre-existing one.
typedef HostFileProbe = Future<bool> Function(String path);
typedef HostFileRemover = Future<void> Function(String path);

/// Escapes text for `adb shell input text`: the device's shell re-parses the
/// argument, so a literal space would split it and `%s` is the escape.
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
/// [CommandRunner]. A Windows adb server and a WSL one list different devices.
class AdbService {
  AdbService({
    required this.runner,
    required this.sdk,
    HostFileReader? readHostFile,
    HostFileProbe? hostFileExists,
    HostFileRemover? removeHostFile,
    this.deviceTempDirectory = '/data/local/tmp',
    this.uiDumpRetryDelay = const Duration(milliseconds: 400),
  }) : _readHostFile = readHostFile ?? _defaultReadHostFile,
       _hostFileExists = hostFileExists ?? _defaultHostFileExists,
       _removeHostFile = removeHostFile ?? _defaultRemoveHostFile;

  final CommandRunner runner;
  final AndroidSdk sdk;
  final HostFileReader _readHostFile;
  final HostFileProbe _hostFileExists;
  final HostFileRemover _removeHostFile;

  /// Who is recording what this service does to devices, or null for nobody.
  /// Plumbing reads — listing devices, asking a screen size — are not reported.
  DeviceActionSink? actionSink;

  /// Writable scratch directory. `/data/local/tmp` is writable by the shell user
  /// on every supported Android version, unlike `/sdcard` under scoped storage.
  final String deviceTempDirectory;

  /// How long to wait before retrying a `uiautomator dump` that failed because
  /// the screen was still animating. Tests set it to zero.
  final Duration uiDumpRetryDelay;

  static Future<Uint8List> _defaultReadHostFile(String path) =>
      File(path).readAsBytes();

  // Synchronous on purpose: async `dart:io` never completes under a widget
  // test's FakeAsync, and the files dialog runs this path inside one.
  static Future<bool> _defaultHostFileExists(String path) async =>
      File(path).existsSync();

  static Future<void> _defaultRemoveHostFile(String path) async {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  }

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

  /// Whether this adb server can discover services over mDNS. Three answers: an
  /// adb that could not be run has *not* told us discovery is off (§19).
  Future<MdnsAvailability> mdnsAvailability() async {
    try {
      return parseMdnsCheck(await runner.run(_adb(const ['mdns', 'check'])));
    } on CommandException {
      return MdnsAvailability.unknown;
    }
  }

  /// One reading of what is advertising itself on the local network. `run`, not
  /// `start`: the process is created on the spawner's isolate, not the caller's.
  Future<MdnsScan> mdnsServices() async {
    try {
      return parseMdnsServices(
        await runner.run(_adb(const ['mdns', 'services'])),
      );
    } on CommandException {
      return const MdnsScan.unknown();
    }
  }

  /// Completes the wireless-debugging pairing handshake with [address]. Neither
  /// [code] nor anything derived from it is logged.
  Future<AdbPairResult> pair(
    PairingAddress address, {
    required String code,
  }) async {
    try {
      return parsePairResult(
        await runner.run(_adb(['pair', address.argument, code])),
      );
    } on CommandException catch (error) {
      return AdbPairRefused(
        cause: AdbPairFailure.unknown,
        message: 'adb could not be run: ${error.message}',
      );
    }
  }

  /// Attaches a paired device at [address] — its **connect** port, which is not
  /// the port it was paired on.
  Future<AdbConnectOutcome> connect(PairingAddress address) async {
    try {
      return parseConnectResult(
        await runner.run(_adb(['connect', address.argument])),
      );
    } on CommandException {
      return AdbConnectOutcome.refused;
    }
  }

  /// Lists AVDs, marking any that are running. An emulator's serial does not
  /// contain the AVD name, so each running one is asked via `emu avd name`.
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

  /// Boots an AVD and returns immediately; use [bootAvdAndWait] to know it is
  /// usable. [headless] passes `-no-window`; [extraArguments] are appended as-is.
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
    // Both streams must be drained even when nobody wants the output: the
    // emulator's stdout pipe fills during boot and the boot silently stops.
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

  /// Serial of the running emulator booted from AVD [name], or `null`. Asks each
  /// emulator which AVD it booted; diffing `adb devices` races two boots.
  Future<String?> serialForAvd(String name) async {
    for (final device in await listDevices()) {
      if (!device.isEmulator) continue;
      if (await runningAvdName(device.serial) == name) return device.serial;
    }
    return null;
  }

  /// Whether Android has finished booting on [serial]. A device answers adb well
  /// before `sys.boot_completed`, and half-booted calls fail like our own bugs.
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
  /// Bounded: an emulator that never comes up says so.
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
        // Its last words: the emulator normally explains why it would not start.
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

  /// Captures the screen as PNG bytes. Goes device-file → `adb pull` rather than
  /// `exec-out screencap -p`: the runner decodes stdout as text and corrupts it.
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
            'karmashala_screen_${fileSafeDeviceId(serial)}.png';
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

  /// Dumps the accessibility hierarchy via device-file → `shell cat`; a dump to
  /// `/dev/tty` interleaves uiautomator's own log line. Retryable errors exit 0.
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
        // A syntactically fine dump with no nodes: seen mid-transition, retry.
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

  /// Installs an APK over any build of the same package. `-t` allows the
  /// `testOnly` manifest every debug build produces; adb can exit 0 on failure.
  Future<void> installApk(String serial, String apkPath) async {
    const verb = 'install';
    final summary = 'Installed $apkPath';
    final result = await runner.run(
      _forDevice(serial, ['install', '-r', '-t', apkPath]),
    );
    final output = '${result.stdout}\n${result.stderr}';
    if (!result.ok || output.contains('Failure [')) {
      // A full /data reports as an IOException naming neither partition nor
      // remedy, so the number is worth one extra call on a path that failed.
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

  /// Starts one named activity: `am start -n <package>/<activity>`. It **exits 0
  /// when the activity does not exist**, so the exit code alone is not a verdict.
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

  /// Stops every process of [packageName]. `am force-stop` is silent and exits 0
  /// whether the app was running or not, so there is no output to assert on.
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

  /// Launches [packageName]'s launcher activity through `monkey`, which resolves
  /// it. `monkey` **exits 0 when it finds no activity**, so the output decides.
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

  /// Presses a raw Android `KEYCODE_*` value. Numeric because the whole
  /// keyboard-forwarding path is, down to scrcpy's `INJECT_KEYCODE`.
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

  /// Whether the device is in dark mode, or `null` when it will not say. Read
  /// rather than remembered: Quick Settings or a dusk schedule flips it too.
  Future<bool?> isNightMode(String serial) async {
    final result = await runner.run(
      _forDevice(serial, const ['shell', 'cmd', 'uimode', 'night']),
    );
    if (!result.ok) return null;
    return parseNightMode(result.stdout);
  }

  /// Switches the device between light and dark. `cmd uimode night`, not
  /// `settings put`: the setting alone does not repaint the running system UI.
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

  /// Opens a URL, or a custom scheme to reach a deep link. An intent nothing can
  /// handle still **exits 0**, so this is not shaped as ok-or-throw.
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

  /// The pids [packageName] is running under, empty when it is not running.
  /// Exposed because "no log lines" and "no process" are different answers.
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
  /// [tags] narrows the stream at adb with `-s`, silencing every other tag.
  Future<ProcessHandle> streamLogcat(
    String serial, {
    List<int> pids = const [],
    List<String> tags = const [],
  }) => runner.start(
    _forDevice(serial, [
      'shell',
      'logcat',
      '-v',
      'threadtime',
      ...pids.expand((pid) => ['--pid', '$pid']),
      if (tags.isNotEmpty) ...['-s', ...tags],
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

  /// Forwards to a device port, letting adb pick the host port, and returns the
  /// port — or null when adb refused. Picking one ourselves races every tool.
  Future<int?> forwardToFreePort(String serial, int devicePort) async {
    final result = await runner.run(
      _forDevice(serial, ['forward', 'tcp:0', 'tcp:$devicePort']),
    );
    if (!result.ok) return null;
    return int.tryParse(result.stdout.trim());
  }

  Future<void> removeForward(String serial, int localPort) async {
    await runner.run(
      _forDevice(serial, ['forward', '--remove', 'tcp:$localPort']),
    );
  }

  /// Every `adb forward` currently registered, across all devices: `--list`
  /// ignores `-s`, so filtering by serial is [parseScrcpyForwards]'s job.
  Future<String> listForwards() async {
    final result = await runner.run(_adb(const ['forward', '--list']));
    return result.ok ? result.stdout : '';
  }

  /// The removable volumes mounted now — an SD card, a USB drive — as `sm`
  /// reports them, falling back to the volume-id directories under `/storage`
  /// where `sm` will not answer. Empty when there are none.
  Future<List<RemovableVolume>> removableVolumes(String serial) async {
    final listed = await runner.run(
      _forDevice(serial, const ['shell', 'sm', 'list-volumes', 'public']),
    );
    if (listed.ok) {
      final volumes = parsePublicVolumes(listed.stdout);
      if (volumes.isNotEmpty) return volumes;
    }
    final storage = await runner.run(
      _forDevice(serial, const ['shell', 'ls', '/storage']),
    );
    return storage.ok ? parseStorageVolumeIds(storage.stdout) : const [];
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

  // Every path reaching the device's own shell goes through [shellQuote]; every
  // path handed to `adb pull`/`push` must not — those never see a shell.

  /// Lists one directory. **A directory that cannot be read throws** rather than
  /// listing empty. The trailing slash dereferences `/sdcard`'s symlink; `-L`
  /// would dereference every entry too.
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

  /// What [path] is, or null when nothing is there. `ls -lad` reports the entry
  /// itself, so a symlink stays one; unreachable throws rather than answering.
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

  /// Runs a device command **whose output contains filenames** and gets them
  /// back intact: `CommandRunner` decodes with `SystemEncoding`, which mangles
  /// non-Latin names on Windows, so the wire is base64 with two fallbacks.
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
      // Neither an error nor base64: better shown with a warning than refused.
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

  /// Starts `screenrecord` writing the display to [devicePath] on the device.
  /// It ends on its own at its time limit (180 s by default), or when
  /// [stopScreenRecord] interrupts it — the interrupt, never a kill, or the
  /// MP4 is left without its index.
  Future<ProcessHandle> startScreenRecord(String serial, String devicePath) =>
      runner.start(_forDevice(serial, ['shell', 'screenrecord', devicePath]));

  /// Interrupts every `screenrecord` on [serial], so each writes its file's
  /// index and exits. Killing the local `adb shell` would leave the device's
  /// process running and the file unplayable.
  Future<void> stopScreenRecord(String serial) async {
    try {
      await runner.run(
        _forDevice(serial, ['shell', 'pkill', '-INT', 'screenrecord']),
      );
    } on CommandException {
      // Nothing left to interrupt: it already ended on its own.
    }
  }

  /// Copies a file off the device. No progress is reported: adb draws its bar
  /// only when stdout is a terminal, and here it is a pipe.
  Future<DeviceFileTransfer> pullFile(
    String serial, {
    required String devicePath,
    required String hostPath,
  }) async {
    // Only a file this pull created is ours to take away again.
    final existedBefore = await _hostFileExists(hostPath);
    final CommandResult result;
    try {
      result = await runner.run(
        _forDevice(serial, ['pull', devicePath, hostPath]),
      );
    } on Object {
      if (!existedBefore) await _discardPartial(hostPath);
      rethrow;
    }
    // The summary lands on **stderr with exit code 0**, so neither stream alone
    // is the answer.
    final combined = '${result.stdout}\n${result.stderr}';
    if (!result.ok || !transferSucceeded(combined)) {
      if (!existedBefore) await _discardPartial(hostPath);
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

  Future<void> _discardPartial(String hostPath) async {
    try {
      await _removeHostFile(hostPath);
    } on Object {
      // The pull's own failure is the one to report.
    }
  }

  /// Copies a file onto the device, overwriting [devicePath]. The decision not
  /// to belongs in the driver, where the destination is checked.
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

  /// Removes a path on the device. There is no undo. No `-f`, so a path that is
  /// not there is an error rather than a silent success.
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
    // `rm` says nothing when it works, so any output is the failure — a device
    // before Android 7 does not forward the exit code anyway.
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

  /// Makes the directory [path] on the device; its parent must be there.
  /// `mkdir` refuses a name already taken, which is the refusal wanted.
  Future<void> makeDirectory(String serial, String path) async {
    final result = await runner.run(
      _forDevice(serial, ['shell', 'mkdir ${shellQuote(path)}']),
    );
    final combined = '${result.stdout}\n${result.stderr}'.trim();
    // Silent when it works; output is the failure, as for `rm`.
    if (!result.ok || combined.isNotEmpty) {
      final error = DeviceRefusal(
        'Could not make $path on $serial: '
        '${combined.isEmpty ? 'mkdir exited ${result.exitCode}.' : cleanAdbError(combined)}',
      );
      _report(
        DeviceAction(
          verb: 'makeDirectory',
          serial: serial,
          summary: 'Make $path',
        ).failed(error),
      );
      throw error;
    }
    _report(
      DeviceAction(
        verb: 'makeDirectory',
        serial: serial,
        summary: 'Made $path on $serial',
      ),
    );
  }

  /// Copies a path **within** the device — nothing crosses the wire. `cp -p`
  /// keeps timestamp and mode; `-r` is the caller's decision, refused above.
  Future<void> copyPath(
    String serial,
    String from,
    String to, {
    bool recursive = false,
  }) => _moveOrCopy(
    serial,
    from,
    to,
    argv: 'cp -p${recursive ? ' -r' : ''}',
    verb: 'copyPath',
    what: 'Copy',
    past: 'Copied',
  );

  /// Moves a path within the device. Within one filesystem `mv` is a rename, so
  /// it cannot half-finish the way copy-then-delete can.
  Future<void> movePath(String serial, String from, String to) => _moveOrCopy(
    serial,
    from,
    to,
    argv: 'mv',
    verb: 'movePath',
    what: 'Move',
    past: 'Moved',
  );

  /// The shared half of [copyPath] and [movePath]. Neither says anything when it
  /// works, so **any output at all is the failure**.
  Future<void> _moveOrCopy(
    String serial,
    String from,
    String to, {
    required String argv,
    required String verb,
    required String what,
    required String past,
  }) async {
    final result = await runner.run(
      _forDevice(serial, [
        'shell',
        '$argv ${shellQuote(from)} ${shellQuote(to)}',
      ]),
    );
    final combined = '${result.stdout}\n${result.stderr}'.trim();
    if (!result.ok || combined.isNotEmpty) {
      final error = DeviceRefusal(
        'Could not ${what.toLowerCase()} $from to $to on $serial: '
        '${combined.isEmpty ? 'it exited ${result.exitCode}.' : cleanAdbError(combined)}',
      );
      _report(
        DeviceAction(
          verb: verb,
          serial: serial,
          summary: '$what $from to $to',
        ).failed(error),
      );
      throw error;
    }
    _report(
      DeviceAction(
        verb: verb,
        serial: serial,
        summary: '$past $from to $to on $serial',
      ),
    );
  }

  String _lsRefusal(
    LsFailure failure, {
    required String serial,
    required String path,
  }) => switch (failure) {
    LsFailure.permissionDenied =>
      _appPrivate(path)
          // Worth explaining rather than reporting: the path looks like it works.
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

  /// Shuts a running emulator down. `emu kill` reaches the emulator's console,
  /// so it does nothing on a handset; returns whether it actually went away.
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
/// The wording varies by API level, so this matches the idea, not one string.
bool installFailedForSpace(String output) {
  final upper = output.toUpperCase();
  return upper.contains('INSUFFICIENT_STORAGE') ||
      upper.contains('NOT ENOUGH SPACE') ||
      upper.contains('NO SPACE LEFT');
}

/// The `Use%` column for `/data` out of `df` output, e.g. `92%`. Null rather
/// than a guess when the layout is not the expected one.
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

/// Device output brought back to UTF-8, with what it cost. [combined] is stdout
/// *and* stderr: `adb shell` forwarded no remote exit code before Android 7.
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

/// A removable volume: its mount point and what kind of drive it is.
class RemovableVolume {
  const RemovableVolume({required this.path, required this.kind});

  /// `/storage/<volume id>`, e.g. `/storage/9016-4EF8`.
  final String path;

  /// "SD card", "USB drive", or "Removable storage" when the block device
  /// does not say.
  final String kind;
}

/// A volume id as Android names a FAT or exFAT volume (`9016-4EF8`), or a
/// full UUID for other filesystems.
final _volumeId = RegExp(
  r'^(?:[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}|[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})$',
);

/// The mounted volumes in `sm list-volumes public` output, one per line:
/// `public:179:1 mounted 9016-4EF8`. The block device's major number says
/// what the drive is: 179 is an MMC/SD card, 8 a SCSI disk (a USB drive).
List<RemovableVolume> parsePublicVolumes(String output) => [
  for (final line in output.split('\n'))
    if (line.trim().split(RegExp(r'\s+')) case [
      final id,
      'mounted',
      final uuid,
    ] when id.startsWith('public:') && _volumeId.hasMatch(uuid))
      RemovableVolume(
        path: '/storage/$uuid',
        kind: switch (id.split(':').elementAtOrNull(1)) {
          '179' => 'SD card',
          '8' => 'USB drive',
          _ => 'Removable storage',
        },
      ),
];

/// The volume-id directories in `ls /storage`: everything that is not the
/// emulated (internal) storage, `self`, or a vendor link.
List<RemovableVolume> parseStorageVolumeIds(String output) => [
  for (final name in output.split(RegExp(r'\s+')))
    if (_volumeId.hasMatch(name))
      RemovableVolume(path: '/storage/$name', kind: 'Removable storage'),
];
