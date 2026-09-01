import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/process/command_runner.dart';
import '../../../core/process/process_handle.dart';
import '../domain/device_action.dart';
import '../domain/device_input.dart';
import '../domain/ios_simulator.dart';
import 'adb_service.dart' show HostFileReader;
import 'simctl_parsing.dart';

/// The pid `simctl launch` printed, or null when it printed something else.
///
/// The success line is `com.example.app: 61324` — the bundle id, a colon, the
/// pid. Anything else (a warning, an error, an empty stdout on a device that
/// exited 0 anyway) yields null rather than a guess: the pid is used to attach
/// a debugger or to kill the app, and a wrong number does both to some other
/// process.
int? parseSimctlLaunchPid(String output) {
  final pattern = RegExp(r':\s*(\d+)$');
  for (final line in output.split('\n')) {
    final match = pattern.firstMatch(line.trim());
    if (match != null) return int.tryParse(match.group(1)!);
  }
  return null;
}

/// Every `simctl` interaction with the iOS Simulator on one host, routed
/// through a [CommandRunner] so nothing in this feature touches `Process`
/// directly (architecture constraint 6).
///
/// The counterpart of `AdbService`, deliberately the same shape: one service
/// per execution environment, a mutable [actionSink] so a verification run
/// watches the *same* instance the UI and the MCP tools use, and every
/// user-visible verb reported through it.
///
/// Simulators only exist where Xcode does, so a [runner] pointed at anything
/// but a macOS host will fail every call with a [CommandException] — see
/// [listSimulators] for how that is absorbed.
class SimctlService {
  SimctlService({
    required this.runner,
    HostFileReader? readHostFile,
    this.executable = 'xcrun',
  }) : _readHostFile = readHostFile ?? _defaultReadHostFile;

  final CommandRunner runner;

  /// The launcher, not the tool. `xcrun` asks `xcode-select` where the active
  /// developer directory is, so this keeps working across an Xcode upgrade, a
  /// beta installed alongside the release, and an Xcodes-managed install —
  /// none of which a hardcoded `/Applications/Xcode.app/…/simctl` survives.
  final String executable;

  final HostFileReader _readHostFile;

  /// Who is recording what this service does to simulators, or null for
  /// nobody. Mirrors `AdbService.actionSink` down to the omissions: listing
  /// simulators and asking for a screen size are how the app works, not things
  /// somebody did to a device, so they are not reported.
  DeviceActionSink? actionSink;

  /// The shell used for the one command that needs a pipeline, [setClipboard].
  /// `/bin/sh` is present on every macOS host, which is the only host `simctl`
  /// runs on anyway.
  static const String _shell = '/bin/sh';

  static Future<Uint8List> _defaultReadHostFile(String path) =>
      File(path).readAsBytes();

  CommandRequest _simctl(List<String> arguments) => CommandRequest(
    executable: executable,
    arguments: ['simctl', ...arguments],
  );

  /// Lists every simulator in the device set, including unavailable ones.
  ///
  /// Returns empty rather than throwing when `xcrun` is missing or refuses:
  /// this app runs on Windows and Linux too, where "there are no simulators"
  /// is the correct answer and not a failure worth surfacing to the user.
  Future<List<IosSimulator>> listSimulators() async {
    try {
      final result = await runner.run(_simctl(const ['list', 'devices', '-j']));
      if (!result.ok) return const [];
      return parseSimctlDevices(result.stdout);
    } on CommandException {
      return const [];
    }
  }

  /// The simulator's screen size in pixels — the coordinate space taps use.
  ///
  /// Null when `simctl` could not be asked or answered in an unfamiliar shape,
  /// which reads as "ask something else" rather than as a plausible-looking
  /// guess about a screen the caller is about to tap on.
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

  /// Captures the screen as PNG bytes.
  ///
  /// Always writes to a real file and reads it back, because
  /// `simctl io <udid> screenshot -` does **not** write to stdout the way the
  /// dash convention suggests: it creates a file literally named `-` in the
  /// working directory and returns success, so a caller trusting stdout gets
  /// zero bytes and a stray file. [hostPath] exists for tests and for callers
  /// that want the file kept somewhere specific.
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

  /// Boots a simulator. Returns as soon as `simctl` accepts the request, which
  /// is well before the system is usable — use [bootAndWait] when the next
  /// step actually needs a booted device.
  ///
  /// A simulator that is already booted is success, not failure: the caller
  /// asked for a state and the device is in it. `simctl` disagrees and exits
  /// non-zero with `Unable to boot device in current state: Booted`, which is
  /// the only way to tell that case apart from a real refusal.
  Future<void> boot(String udid) => _act(
    udid,
    ['boot', udid],
    verb: 'boot',
    summary: 'Booted $udid',
    tolerate: 'current state: booted',
  );

  /// Boots [udid] if needed and waits until the system has finished booting.
  ///
  /// Goes through [CommandRunner.start] rather than `run` so the wait can be
  /// bounded: `run` cannot be cancelled, so a simulator that never comes up
  /// would hang this call forever and leave the `bootstatus` process behind.
  ///
  /// `bootstatus` signals completion by **exiting**. Its last line is the odd
  /// `Status=4294967295, isTerminal=YES`; that number is not an error code and
  /// is deliberately not parsed.
  Future<void> bootAndWait(
    String udid, {
    Duration timeout = const Duration(minutes: 3),
  }) async {
    const summary = 'Booted and waited';
    final handle = await runner.start(
      // -b boots the device first when it is shut down, so this is one call
      // rather than boot-then-poll, and it is race-free when something else
      // booted the same simulator a moment ago.
      _simctl(['bootstatus', udid, '-b']),
    );
    final log = <String>[];
    void keepLastWords(Stream<String> lines) {
      // Both streams must be drained even though only the tail is wanted: an
      // unread pipe fills and blocks the process it belongs to, and a wedged
      // bootstatus looks exactly like a slow boot.
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

  /// Erases the simulator's contents and settings.
  ///
  /// Destructive and not undoable: apps, data and granted permissions all go.
  /// `simctl` refuses on a booted device on older Xcodes, so callers that want
  /// a clean device should [shutdown] first.
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

  Future<void> uninstallApp(String udid, String bundleId) => _act(
    udid,
    ['uninstall', udid, bundleId],
    verb: 'uninstall',
    summary: 'Uninstalled $bundleId',
  );

  /// Launches [bundleId] and returns its pid, or null when `simctl` did not
  /// print one in the shape [parseSimctlLaunchPid] understands.
  ///
  /// [relaunch] passes `--terminate-running-process`, which is what makes
  /// "run it again" mean a fresh process. Without it `simctl launch` on an
  /// already-running app exits 0 and merely foregrounds it, so a test that
  /// expects to see a cold start silently observes the old process instead.
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

  Future<void> terminateApp(String udid, String bundleId) => _act(
    udid,
    ['terminate', udid, bundleId],
    verb: 'terminate',
    summary: 'Terminated $bundleId',
  );

  /// Opens a URL on the simulator — a web link, or a custom scheme to reach a
  /// deep link in an installed app.
  Future<void> openUrl(String udid, String url) => _act(
    udid,
    ['openurl', udid, url],
    verb: 'openUrl',
    summary: 'Opened $url',
  );

  /// Switches between light and dark mode.
  ///
  /// Rejects anything else here rather than passing it on: `simctl ui` reports
  /// an unknown appearance on stderr in a form that reads like a device fault,
  /// and the caller ends up debugging the simulator instead of their typo.
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

  /// Writes [text] to the simulator's pasteboard.
  ///
  /// The one command here that is not a bare `xcrun`: `simctl pbcopy` reads the
  /// text from **stdin**, and [ProcessHandle] can write to stdin but cannot
  /// close it, so `pbcopy` would wait for an EOF that never arrives. A shell
  /// builds the pipeline instead — still through the [CommandRunner], so
  /// constraint 6 holds and the test sees the exact command line.
  ///
  /// `printf %s` rather than `echo`: `echo` appends a newline and, on some
  /// shells, interprets backslash escapes, both of which change what the user
  /// pasted.
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

  /// Sets the simulated GPS location.
  ///
  /// Applies to the whole device rather than to one app, and survives until
  /// something clears it — including across app launches, which is what makes
  /// it useful for testing a location-dependent flow.
  Future<void> setLocation(String udid, double lat, double lon) => _act(
    udid,
    ['location', udid, 'set', '$lat,$lon'],
    verb: 'location',
    summary: 'Set location to $lat, $lon',
  );

  /// Delivers a push notification from a JSON payload file.
  ///
  /// The payload must name its target app in `Simulator Target Bundle`; this
  /// signature has no bundle id to pass, and `simctl` fails with
  /// `No appropriate bundle identifier` when the key is missing.
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

  /// A live device log. The process is owned by the subscription: cancelling
  /// it kills `log stream`, so a closed log panel does not leave one running.
  ///
  /// `--style compact` because the default `log stream` format wraps each entry
  /// over several lines with a metadata block, and a line-oriented consumer
  /// then shows fragments instead of entries.
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

  /// Recent log lines, newest last, capped at [lines].
  ///
  /// `log show` slices by **time**, not by line count — there is no `-t 200` —
  /// so a window is asked for and the tail is taken here. A window that is too
  /// wide costs seconds of `log show` work, which is why it is bounded rather
  /// than "since boot".
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

  /// `log show` prefaces its output with a filter note and a column header.
  /// They are not log lines, and passing them on makes every read look like it
  /// found two entries when it found none.
  static bool _isLogPreamble(String line) =>
      line.startsWith('Filtering the log data using') ||
      line.startsWith('Timestamp ') ||
      line.startsWith('Skipping info and debug messages');

  /// Runs one simctl subcommand and reports it as [verb] either way.
  ///
  /// [tolerate] is a lowercase fragment of the failure message that means "the
  /// device is already how you asked for it" — see [boot]. [request] overrides
  /// the built request for the one command that needs a shell.
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
      // Xcode is not installed, or this runner is not a Mac. Reported as a
      // failed action so a recording shows what was attempted, then rethrown:
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

  /// Wraps [value] in single quotes for `/bin/sh`, ending and reopening the
  /// quoting around any quote of its own. Without this a pasteboard string
  /// containing an apostrophe would end the quoted section and hand the rest
  /// of the text to the shell as commands.
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
