import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import '../domain/device_action.dart';
import '../domain/device_input.dart';
import '../domain/ios_simulator.dart';
import 'adb_service.dart' show HostFileReader;
import 'simctl_parsing.dart';

/// The pid `simctl launch` printed, or null when it printed something else.
/// A guess would attach a debugger to, or kill, some other process.
int? parseSimctlLaunchPid(String output) {
  final pattern = RegExp(r':\s*(\d+)$');
  for (final line in output.split('\n')) {
    final match = pattern.firstMatch(line.trim());
    if (match != null) return int.tryParse(match.group(1)!);
  }
  return null;
}

/// Every `simctl` interaction with the iOS Simulator on one host, routed through
/// a [CommandRunner]. Off a macOS host every call throws; see [listSimulators].
class SimctlService {
  SimctlService({
    required this.runner,
    HostFileReader? readHostFile,
    this.executable = 'xcrun',
  }) : _readHostFile = readHostFile ?? _defaultReadHostFile;

  final CommandRunner runner;

  /// The launcher, not the tool: `xcrun` asks `xcode-select` where the active
  /// developer directory is, which a hardcoded Xcode path does not survive.
  final String executable;

  final HostFileReader _readHostFile;

  /// Who is recording what this service does to simulators, or null for nobody.
  /// Listing and asking a screen size are plumbing and are not reported.
  DeviceActionSink? actionSink;

  /// The shell used for the one command that needs a pipeline, [setClipboard].
  static const String _shell = '/bin/sh';

  static Future<Uint8List> _defaultReadHostFile(String path) =>
      File(path).readAsBytes();

  CommandRequest _simctl(List<String> arguments) => CommandRequest(
    executable: executable,
    arguments: ['simctl', ...arguments],
  );

  /// Lists every simulator in the device set, including unavailable ones. Empty
  /// rather than throwing: on Windows "there are none" is the right answer.
  Future<List<IosSimulator>> listSimulators() async {
    try {
      final result = await runner.run(_simctl(const ['list', 'devices', '-j']));
      if (!result.ok) return const [];
      return parseSimctlDevices(result.stdout);
    } on CommandException {
      return const [];
    }
  }

  /// The simulator's screen size in pixels, or null when `simctl` could not be
  /// asked — which reads as "ask something else", not as a plausible guess.
  Future<DeviceScreenSize?> screenSize(String udid) async {
    try {
      final result = await runner.run(_simctl(['io', udid, 'enumerate']));
      if (!result.ok) return null;
      final size = parseSimctlScreenSize(result.stdout);
      if (size == null) return null;
      return DeviceScreenSize(width: size.width, height: size.height);
    } on CommandException {
      return null;
    }
  }

  /// Captures the screen as PNG bytes. Always via a real file: `simctl io … -`
  /// creates a file named `-` and exits 0 rather than writing to stdout.
  Future<Uint8List> screenshot(String udid, {String? hostPath}) async {
    final destination =
        hostPath ??
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
            'karmashala_sim_$udid.png';
    final result = await runner.run(
      _simctl(['io', udid, 'screenshot', destination]),
    );
    if (!result.ok) {
      final error = StateError(
        'simctl screenshot failed on $udid: ${_explain(result)}',
      );
      _report(
        DeviceAction(
          verb: 'screenshot',
          serial: udid,
          summary: 'Screenshot of $udid',
        ).failed(error),
      );
      throw error;
    }
    final bytes = await _readHostFile(destination);
    _report(
      DeviceAction(
        verb: 'screenshot',
        serial: udid,
        summary: 'Screenshot of $udid',
        png: bytes,
      ),
    );
    return bytes;
  }

  /// Boots a simulator, returning as soon as `simctl` accepts — use [bootAndWait]
  /// when the next step needs it up. Already booted is success, not failure.
  Future<void> boot(String udid) => _act(
    udid,
    ['boot', udid],
    verb: 'boot',
    summary: 'Booted $udid',
    tolerate: 'current state: booted',
  );

  /// Brings up Simulator.app so the booted device has a window of its own.
  /// Booting through `simctl` is already headless, so this is an extra step.
  Future<void> showSimulatorWindow(String udid) async {
    try {
      await runner.start(
        const CommandRequest(
          executable: 'open',
          arguments: ['-a', 'Simulator'],
        ),
      );
    } on Object {
      // Nothing here is worth failing a boot over.
    }
  }

  /// Boots [udid] if needed and waits until the system has finished booting.
  /// `bootstatus` signals completion by **exiting**; its last line is not a code.
  Future<void> bootAndWait(
    String udid, {
    Duration timeout = const Duration(minutes: 3),
  }) async {
    const summary = 'Booted and waited';
    final handle = await runner.start(
      // -b boots first when the device is shut down, so this is one race-free
      // call rather than boot-then-poll.
      _simctl(['bootstatus', udid, '-b']),
    );
    final log = <String>[];
    void keepLastWords(Stream<String> lines) {
      // Both streams must be drained even though only the tail is wanted: an
      // unread pipe blocks the process, and that looks exactly like a slow boot.
      lines.listen(
        (line) {
          log.add(line);
          if (log.length > 20) log.removeAt(0);
        },
        onError: (_) {},
        cancelOnError: false,
      );
    }

    keepLastWords(handle.stdoutLines);
    keepLastWords(handle.stderrLines);

    var timedOut = false;
    final code = await handle.exitCode.timeout(
      timeout,
      onTimeout: () async {
        timedOut = true;
        await handle.kill();
        return -1;
      },
    );
    if (timedOut || code != 0) {
      final lastWords = log.isEmpty ? '' : ' Last output: ${log.last}';
      final error = StateError(
        timedOut
            ? '$udid did not finish booting within '
                  '${timeout.inSeconds}s.$lastWords'
            : 'bootstatus failed for $udid (exit $code).$lastWords',
      );
      _report(
        DeviceAction(
          verb: 'boot',
          serial: udid,
          summary: summary,
        ).failed(error),
      );
      throw error;
    }
    _report(DeviceAction(verb: 'boot', serial: udid, summary: summary));
  }

  /// Shuts a simulator down. Already shut down is success, for the same reason
  /// [boot] treats already booted as success.
  Future<void> shutdown(String udid) => _act(
    udid,
    ['shutdown', udid],
    verb: 'shutdown',
    summary: 'Shut down $udid',
    tolerate: 'current state: shutdown',
  );

  /// Erases the simulator's contents and settings. Not undoable, and refused on
  /// a booted device by older Xcodes, so callers may need to [shutdown] first.
  Future<void> erase(String udid) =>
      _act(udid, ['erase', udid], verb: 'erase', summary: 'Erased $udid');

  /// Installs a built `.app` bundle — the simulator build, not a device `.ipa`;
  /// `simctl` rejects device slices with an architecture error.
  Future<void> installApp(String udid, String appPath) => _act(
    udid,
    ['install', udid, appPath],
    verb: 'install',
    summary: 'Installed $appPath',
  );

  /// The `CFBundleIdentifier` an `.app` declares, or null when it could not be
  /// read. `plutil -extract`, not a text parse: a built `Info.plist` is binary.
  Future<String?> readAppBundleId(String appPath) async {
    try {
      final result = await runner.run(
        CommandRequest(
          executable: '/usr/bin/plutil',
          arguments: [
            '-extract',
            'CFBundleIdentifier',
            'raw',
            '-o',
            '-',
            '$appPath/Info.plist',
          ],
        ),
      );
      if (!result.ok) return null;
      final value = result.stdout.trim();
      return value.isEmpty ? null : value;
    } on CommandException {
      return null;
    }
  }

  Future<void> uninstallApp(String udid, String bundleId) => _act(
    udid,
    ['uninstall', udid, bundleId],
    verb: 'uninstall',
    summary: 'Uninstalled $bundleId',
  );

  /// Launches [bundleId] and returns its pid, or null when `simctl` printed none.
  /// Without [relaunch] an already-running app is merely foregrounded, exit 0.
  Future<int?> launchApp(
    String udid,
    String bundleId, {
    bool relaunch = false,
  }) async {
    final result = await _act(
      udid,
      ['launch', if (relaunch) '--terminate-running-process', udid, bundleId],
      verb: 'launch',
      summary: 'Launched $bundleId',
    );
    return parseSimctlLaunchPid(result.stdout);
  }

  /// Terminates an app, tolerating one that is not running: asking for a state a
  /// device is already in is not a failure.
  Future<void> terminateApp(String udid, String bundleId) => _act(
    udid,
    ['terminate', udid, bundleId],
    verb: 'terminate',
    summary: 'Terminated $bundleId',
    tolerate: 'found nothing to terminate',
  );

  /// Opens a URL on the simulator — a web link, or a custom scheme to reach a
  /// deep link in an installed app.
  Future<void> openUrl(String udid, String url) => _act(
    udid,
    ['openurl', udid, url],
    verb: 'openUrl',
    summary: 'Opened $url',
  );

  /// Whether [udid] is in dark appearance, or null if it will not say. Read
  /// rather than remembered: a tracked belief strands the device on a rebuild.
  Future<bool?> isDarkAppearance(String udid) async {
    try {
      final result = await runner.run(_simctl(['ui', udid, 'appearance']));
      if (!result.ok) return null;
      final answer = result.stdout.trim().toLowerCase();
      if (answer == 'dark') return true;
      if (answer == 'light') return false;
      return null;
    } on Object {
      return null;
    }
  }

  Future<void> setAppearance(String udid, String appearance) {
    final value = appearance.toLowerCase();
    if (value != 'light' && value != 'dark') {
      throw ArgumentError.value(
        appearance,
        'appearance',
        'must be "light" or "dark"',
      );
    }
    return _act(
      udid,
      ['ui', udid, 'appearance', value],
      verb: 'appearance',
      summary: 'Set appearance to $value',
    );
  }

  /// Writes [text] to the simulator's pasteboard. Needs a shell: `simctl pbcopy`
  /// reads stdin and [ProcessHandle] cannot close it, so `pbcopy` never sees EOF.
  Future<void> setClipboard(String udid, String text) => _act(
    udid,
    null,
    request: CommandRequest(
      executable: _shell,
      arguments: [
        '-c',
        'printf %s ${_shellQuote(text)} | '
            '${_shellQuote(executable)} simctl pbcopy ${_shellQuote(udid)}',
      ],
    ),
    verb: 'clipboard',
    summary: 'Set the clipboard',
  );

  /// Reads the simulator's pasteboard, verbatim — not trimmed, because
  /// trailing whitespace is part of what somebody copied.
  Future<String> readClipboard(String udid) async {
    final result = await _act(
      udid,
      ['pbpaste', udid],
      verb: 'clipboard',
      summary: 'Read the clipboard',
      text: (pasteboard) => pasteboard.stdout,
    );
    return result.stdout;
  }

  /// Sets the simulated GPS location. Device-wide and survives app launches
  /// until something clears it.
  Future<void> setLocation(String udid, double lat, double lon) => _act(
    udid,
    ['location', udid, 'set', '$lat,$lon'],
    verb: 'location',
    summary: 'Set location to $lat, $lon',
  );

  /// Delivers a push notification from a JSON payload file. The payload must
  /// name its target in `Simulator Target Bundle`; this signature has no room.
  Future<void> push(String udid, String payloadPath) => _act(
    udid,
    ['push', udid, payloadPath],
    verb: 'push',
    summary: 'Pushed $payloadPath',
  );

  /// Adds a photo or video to the simulator's photo library.
  Future<void> addMedia(String udid, String path) => _act(
    udid,
    ['addmedia', udid, path],
    verb: 'addMedia',
    summary: 'Added $path to the photo library',
  );

  /// A live device log; cancelling the subscription kills `log stream`.
  /// `--style compact` because the default format wraps one entry over lines.
  Stream<String> streamLog(String udid) {
    late final StreamController<String> controller;
    ProcessHandle? process;
    var cancelled = false;

    Future<void> begin() async {
      try {
        final handle = await runner.start(
          _simctl(['spawn', udid, 'log', 'stream', '--style', 'compact']),
        );
        process = handle;
        // The subscriber may have given up while the process was starting.
        if (cancelled) {
          await handle.kill();
          return;
        }
        handle.stdoutLines.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
          cancelOnError: false,
        );
        // Drained, not forwarded: interleaving stderr into the log would
        // corrupt the line stream, but an unread pipe blocks the process.
        handle.stderrLines.listen((_) {}, onError: (_) {});
      } on CommandException catch (error) {
        controller.addError(error);
        await controller.close();
      }
    }

    controller = StreamController<String>(
      onListen: begin,
      onCancel: () async {
        cancelled = true;
        await process?.kill();
      },
    );
    return controller.stream;
  }

  /// Starts recording the display to [hostPath]. Stop it with
  /// [ProcessHandle.interrupt]: a killed `recordVideo` writes no container index.
  Future<ProcessHandle> startRecording(String udid, String hostPath) =>
      runner.start(_simctl(['io', udid, 'recordVideo', hostPath]));

  /// Recent log lines, newest last, capped at [lines]. `log show` slices by
  /// **time**, not line count, so a window is asked for and the tail taken here.
  Future<List<String>> readLog(
    String udid, {
    int lines = 200,
    Duration window = const Duration(minutes: 5),
  }) async {
    final result = await runner.run(
      _simctl([
        'spawn',
        udid,
        'log',
        'show',
        '--style',
        'compact',
        '--last',
        '${window.inSeconds}s',
      ]),
    );
    if (!result.ok) return const [];
    final entries = [
      for (final line in result.stdout.split('\n'))
        if (line.trim().isNotEmpty && !_isLogPreamble(line)) line.trimRight(),
    ];
    final tail = entries.length > lines
        ? entries.sublist(entries.length - lines)
        : entries;
    _report(
      DeviceAction(
        verb: 'log',
        serial: udid,
        summary:
            '${tail.length} log line${tail.length == 1 ? '' : 's'} from the '
            'last ${window.inSeconds}s',
        text: tail.join('\n'),
      ),
    );
    return tail;
  }

  /// `log show` prefaces its output with a filter note and a column header;
  /// passing them on makes an empty read look like two entries.
  static bool _isLogPreamble(String line) =>
      line.startsWith('Filtering the log data using') ||
      line.startsWith('Timestamp ') ||
      line.startsWith('Skipping info and debug messages');

  /// Runs one simctl subcommand and reports it as [verb] either way. [tolerate]
  /// is the fragment that means "the device is already how you asked for it".
  Future<CommandResult> _act(
    String udid,
    List<String>? arguments, {
    required String verb,
    required String summary,
    CommandRequest? request,
    String? tolerate,
    String Function(CommandResult result)? text,
  }) async {
    final CommandResult result;
    try {
      result = await runner.run(request ?? _simctl(arguments!));
    } on CommandException catch (error) {
      // Xcode is missing, or this runner is not a Mac. Reported then rethrown:
      // unlike a listing, a caller that asked for a launch cannot carry on.
      _report(
        DeviceAction(verb: verb, serial: udid, summary: summary).failed(error),
      );
      rethrow;
    }
    final output = '${result.stdout}\n${result.stderr}'.toLowerCase();
    final alreadyThere = tolerate != null && output.contains(tolerate);
    if (!result.ok && !alreadyThere) {
      final error = StateError('$summary failed on $udid: ${_explain(result)}');
      _report(
        DeviceAction(verb: verb, serial: udid, summary: summary).failed(error),
      );
      throw error;
    }
    _report(
      DeviceAction(
        verb: verb,
        serial: udid,
        summary: summary,
        text: text?.call(result),
      ),
    );
    return result;
  }

  /// The most useful half of a failed result: `simctl` explains itself on
  /// stderr, but a few subcommands say it on stdout instead.
  static String _explain(CommandResult result) {
    final stderr = result.stderr.trim();
    return stderr.isEmpty ? result.stdout.trim() : stderr;
  }

  /// Wraps [value] in single quotes for `/bin/sh`. Without it an apostrophe in a
  /// pasteboard string hands the rest of the text to the shell as commands.
  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", r"'\''")}'";

  /// Tells [actionSink] what happened, without letting a recorder's own fault
  /// break the simulator call it was watching.
  void _report(DeviceAction action) {
    final sink = actionSink;
    if (sink == null) return;
    try {
      sink(action);
    } on Object {
      // Recording is observation. It never decides whether the action worked.
    }
  }
}
