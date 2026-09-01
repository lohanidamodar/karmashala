import '../../../core/process/command_runner.dart';
import '../../../core/process/process_handle.dart';
import '../domain/device_action.dart';
import '../domain/device_input.dart';
import 'idb_ui_parsing.dart';

/// The buttons `idb ui button` accepts. Not [DeviceKey]: that enum carries an
/// Android `KEYCODE_*` string per member, and iOS has neither those codes nor
/// most of those buttons.
enum IdbButton {
  home('HOME'),
  lock('LOCK'),
  sideButton('SIDE_BUTTON'),
  siri('SIRI'),
  applePay('APPLE_PAY');

  const IdbButton(this.wireName);

  /// What `idb ui button` is given.
  final String wireName;

  /// The nearest [DeviceKey], for the shared hardware-key row, or null where
  /// iOS has no equivalent.
  static IdbButton? forKey(DeviceKey key) => switch (key) {
    DeviceKey.home => IdbButton.home,
    DeviceKey.power => IdbButton.lock,
    // Back and recents are Android's navigation model. iOS has no system back
    // button — an app draws its own — and no recents key; offering a
    // best-effort press would silently do the wrong thing.
    _ => null,
  };
}

/// Whether `idb` is on this machine, and which one.
class IdbInstallation {
  const IdbInstallation({required this.executable, this.version});

  /// The absolute path the probe resolved.
  final String executable;

  /// What `idb --version` said, when it said anything.
  final String? version;
}

/// Drives an iOS Simulator through `idb`.
///
/// **Optional, and detected rather than bundled.** The Android side vendors
/// `scrcpy-server` as an asset and pushes it to the device; idb cannot be
/// carried that way — it is a Homebrew formula (`idb_companion`) plus a Python
/// client (`fb-idb`) — so it is found on the machine the way `adb` is, and
/// everything it provides is absent rather than broken when it is not there.
///
/// What it adds over `simctl`, which has none of it: touch, typing, hardware
/// buttons, the accessibility tree, and a live H.264 stream.
///
/// Every process goes through the injected [CommandRunner] (constraint 6), so
/// none of this needs a simulator — or idb — to be tested.
class IdbService {
  IdbService({
    required this.runner,
    required this.installation,
    this.actionSink,
  });

  final CommandRunner runner;
  final IdbInstallation installation;

  /// Where user-visible actions are recorded, for verification runs. Mutable
  /// and assigned by the recorder exactly as [AdbService.actionSink] is.
  DeviceActionSink? actionSink;

  /// Locates `idb`, or returns null when this machine has none.
  ///
  /// Run through a login shell for the same reason agent CLIs are: idb is
  /// installed by `pip`/`brew` into a directory that a non-login shell's PATH
  /// does not have, and a bare `which` reports "not installed" for an idb that
  /// works perfectly in the user's terminal.
  static Future<IdbInstallation?> discover({
    required CommandRunner runner,
    required String loginShell,
  }) async {
    final String path;
    try {
      final located = await runner.run(
        CommandRequest(
          executable: loginShell,
          arguments: ['-lc', 'command -v idb'],
        ),
      );
      if (!located.ok) return null;
      final first = located.stdout
          .split(RegExp(r'[\r\n]+'))
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty);
      if (first.isEmpty) return null;
      path = first.first;
    } on CommandException {
      return null;
    }

    String? version;
    try {
      final probed = await runner.run(
        CommandRequest(executable: path, arguments: ['--version']),
      );
      if (probed.ok) {
        final line = probed.stdout.trim().split(RegExp(r'[\r\n]+')).first.trim();
        if (line.isNotEmpty) version = line;
      }
    } on CommandException {
      // Located but would not say its version. Still usable.
    }
    return IdbInstallation(executable: path, version: version);
  }

  CommandRequest _for(String udid, List<String> arguments) => CommandRequest(
    executable: installation.executable,
    arguments: [...arguments, '--udid', udid],
  );

  Future<CommandResult> _run(
    String udid,
    List<String> arguments, {
    String? verb,
    String? summary,
  }) async {
    final result = await runner.run(_for(udid, arguments));
    if (verb != null) {
      actionSink?.call(
        DeviceAction(
          verb: verb,
          serial: udid,
          summary: summary ?? verb,
          detail: result.ok ? null : _reason(result),
          ok: result.ok,
        ),
      );
    }
    if (!result.ok) {
      throw CommandException('idb ${arguments.first} failed: ${_reason(result)}');
    }
    return result;
  }

  String _reason(CommandResult result) {
    final stderr = result.stderr.trim();
    if (stderr.isNotEmpty) return stderr;
    final stdout = result.stdout.trim();
    return stdout.isNotEmpty ? stdout : 'exit ${result.exitCode}';
  }

  /// Taps a point, **in points** — the space `idb ui describe-all` reports
  /// frames in, which is not the pixel space `simctl io enumerate` reports.
  Future<void> tap(String udid, int x, int y) => _run(
    udid,
    ['ui', 'tap', '$x', '$y'],
    verb: 'tap',
    summary: 'tap ($x, $y)',
  );

  Future<void> swipe(
    String udid, {
    required int fromX,
    required int fromY,
    required int toX,
    required int toY,
    Duration? duration,
  }) => _run(
    udid,
    [
      'ui',
      'swipe',
      '$fromX',
      '$fromY',
      '$toX',
      '$toY',
      if (duration != null) ...[
        '--duration',
        (duration.inMilliseconds / 1000).toStringAsFixed(3),
      ],
    ],
    verb: 'swipe',
    summary: 'swipe ($fromX, $fromY) → ($toX, $toY)',
  );

  /// Types [text] into whatever has focus.
  ///
  /// Unlike `adb shell input text`, nothing has to be escaped here: idb takes
  /// the string as one argument rather than pasting it into a shell command
  /// line, so spaces and metacharacters travel as themselves.
  Future<void> inputText(String udid, String text) => _run(
    udid,
    ['ui', 'text', text],
    verb: 'type',
    summary: 'type ${text.length} character(s)',
  );

  Future<void> pressButton(String udid, IdbButton button) => _run(
    udid,
    ['ui', 'button', button.wireName],
    verb: 'key',
    summary: 'press ${button.wireName}',
  );

  /// A raw HID key code, for the keys `idb ui button` does not name.
  Future<void> pressKey(String udid, int keyCode) => _run(
    udid,
    ['ui', 'key', '$keyCode'],
    verb: 'key',
    summary: 'key $keyCode',
  );

  /// The accessibility tree of whatever is on screen.
  ///
  /// `--format complete` carries the screen bounds the frames are relative to,
  /// which is the only trustworthy source for the point-space size a tap needs.
  /// `--api axbridge-persistent` reads from inside the simulator, so a composed
  /// view reports as the elements the app actually built rather than as one
  /// opaque box — and the reader is kept warm, which takes a read from ~3.5s to
  /// ~0.2s.
  Future<IdbUiRead> describeAll(
    String udid, {
    bool detailed = true,
  }) async {
    final result = await _run(udid, [
      'ui',
      'describe-all',
      '--format',
      'complete',
      if (detailed) ...['--api', 'axbridge-persistent'],
    ]);
    return parseIdbUiRead(result.stdout);
  }

  /// A live H.264 stream on the process's stdout.
  ///
  /// Annex-B access units, which is exactly what scrcpy produces and what
  /// `TsMuxer` already consumes — the whole pipeline downstream of this is
  /// shared with the Android live view.
  Future<ProcessHandle> videoStream(
    String udid, {
    int fps = 30,
    double compressionQuality = 1.0,
    double? scaleFactor,
  }) => runner.start(
    _for(udid, [
      'video-stream',
      '--format',
      'h264',
      '--fps',
      '$fps',
      '--compression-quality',
      compressionQuality.toStringAsFixed(2),
      if (scaleFactor != null) ...[
        '--scale-factor',
        scaleFactor.toStringAsFixed(2),
      ],
    ]),
  );
}
