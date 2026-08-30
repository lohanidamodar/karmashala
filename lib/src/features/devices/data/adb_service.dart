import 'dart:io';
import 'dart:typed_data';

import '../../../core/process/command_runner.dart';
import '../../../core/process/process_handle.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/android_device.dart';
import '../domain/device_input.dart';
import '../domain/logcat_entry.dart';
import '../domain/ui_node.dart';
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
  Future<void> bootAvd(String name) async {
    final emulator = sdk.emulator;
    if (emulator == null) {
      throw StateError(
        'The Android SDK at ${sdk.root.path} has no emulator package, '
        'so AVDs cannot be booted.',
      );
    }
    await runner.start(
      CommandRequest(executable: emulator.path, arguments: ['-avd', name]),
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
    final devicePath = '$deviceTempDirectory/chitragupta_screen.png';
    final capture = await runner.run(
      _forDevice(serial, ['shell', 'screencap', '-p', devicePath]),
    );
    if (!capture.ok) {
      throw StateError('screencap failed on $serial: ${capture.stderr.trim()}');
    }
    final destination =
        hostPath ??
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
            'chitragupta_screen_$serial.png';
    final pull = await runner.run(
      _forDevice(serial, ['pull', devicePath, destination]),
    );
    if (!pull.ok) {
      throw StateError('adb pull failed for $serial: ${pull.stderr.trim()}');
    }
    await runner.run(_forDevice(serial, ['shell', 'rm', '-f', devicePath]));
    return _readHostFile(destination);
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
    final devicePath = '$deviceTempDirectory/chitragupta_ui_dump.xml';
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
      return hierarchy;
    }
    throw UiDumpException(
      failure?.message ?? 'uiautomator dump produced nothing usable.',
      serial: serial,
      attempts: attempts,
    );
  }

  Future<void> tap(String serial, int x, int y) async {
    await _runInput(serial, ['tap', '$x', '$y']);
  }

  Future<void> swipe(
    String serial, {
    required int fromX,
    required int fromY,
    required int toX,
    required int toY,
    Duration duration = const Duration(milliseconds: 200),
  }) async {
    await _runInput(serial, [
      'swipe',
      '$fromX',
      '$fromY',
      '$toX',
      '$toY',
      '${duration.inMilliseconds}',
    ]);
  }

  Future<void> inputText(String serial, String text) async {
    if (text.isEmpty) return;
    await _runInput(serial, ['text', encodeInputText(text)]);
  }

  Future<void> pressKey(String serial, DeviceKey key) async {
    await _runInput(serial, ['keyevent', key.keyCode]);
  }

  Future<void> _runInput(String serial, List<String> arguments) async {
    final result = await runner.run(
      _forDevice(serial, ['shell', 'input', ...arguments]),
    );
    if (!result.ok) {
      throw StateError(
        'input ${arguments.first} failed on $serial: ${result.stderr.trim()}',
      );
    }
  }

  /// Reads recent log lines, newest last.
  ///
  /// When [packageName] is given the log is filtered to that package's live
  /// processes; a package that is not running yields an empty list rather than
  /// the whole system log.
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
    return [
      for (final line in result.stdout.split(RegExp(r'[\r\n]+')))
        if (parseLogcatLine(line) case final entry?)
          if (entry.level.atLeast(minLevel)) entry,
    ];
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
}
