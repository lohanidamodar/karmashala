import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/process/process_handle.dart';
import '../../../core/util/clock.dart';
import '../../../core/util/clock_provider.dart';
import '../data/adb_output_parsing.dart';
import '../data/adb_service.dart';
import '../domain/logcat_entry.dart';
import '../domain/logcat_tail.dart';
import 'device_providers.dart';

/// **A live `logcat` for one device**, over the same `AdbService` the
/// `device_logcat` tool reads through.
///
/// The tool takes a *snapshot* — `logcat -d -t N` — because a tool call has to
/// answer and stop. A person watching a device wants the next line, so this
/// takes the other method the service already had and nothing used:
/// [AdbService.streamLogcat], which is `logcat` without `-d`. One service, two
/// readings of it; there is no second path to a device here.
///
/// Three things it must not get wrong:
///
/// * **Nothing polls.** Lines arrive because the process emits them. The only
///   timer is [_flushWindow], and it is armed by a line and disarmed by the
///   flush — a repaint window, not a question asked on a tick. At rest there is
///   no timer at all.
/// * **The tail is bounded and says so.** [LogcatTail] keeps the newest lines
///   and counts what it dropped, and the view prints that count.
/// * **An empty view is never silently empty.** A package filter that matches
///   no running process is reported in words — the same distinction
///   `AdbDeviceDriver.readLog` draws with its `note`, because "not running" and
///   "running quietly" look identical on screen and need opposite responses.
///
/// Reading a device is never claimed. `DeviceClaims` blocks the acting verbs
/// and lets `device_logcat` through while somebody else is driving; a view that
/// took a claim to watch a log would be stricter than the tool it mirrors.
class DeviceLogcatSession extends ChangeNotifier {
  DeviceLogcatSession({
    required this.serial,
    required AdbService? adb,
    required Clock clock,
    int capacity = 2000,
    // Public parameter names over private fields: nothing outside a session
    // reads its service or its clock, and `_adb:` would be a poor argument.
    // ignore: prefer_initializing_formals
  }) : _adb = adb,
       // ignore: prefer_initializing_formals
       _clock = clock,
       _tail = LogcatTail(capacity: capacity);

  /// How long lines are collected before one repaint. Not a poll: it exists
  /// only between a line arriving and the frame that draws it, and a device
  /// under load emits far faster than a person reads.
  static const Duration flushWindow = Duration(milliseconds: 100);

  final String serial;
  final AdbService? _adb;
  final Clock _clock;
  final LogcatTail _tail;
  final _log = AppLogger.named('logcat');

  ProcessHandle? _process;
  StreamSubscription<String>? _lines;
  Timer? _flush;
  int _generation = 0;

  String? _package;
  LogLevel _minLevel = LogLevel.verbose;
  bool _starting = false;
  DateTime? _startedAt;
  DateTime? _lastLineAt;
  String? _problem;

  /// The package whose process the stream is pinned to, or null for everything
  /// on the device.
  String? get packageFilter => _package;

  LogLevel get minLevel => _minLevel;

  /// Whether a `logcat` process is attached right now.
  bool get streaming => _process != null;

  bool get starting => _starting;

  /// When this reading began, or null before it has begun. Never a stand-in
  /// timestamp: an unstarted stream has no age, and zero would be a lie.
  DateTime? get startedAt => _startedAt;

  /// When the last line arrived, or null when none has. The number that
  /// distinguishes a quiet device from a dead stream, and the reason a bare
  /// "streaming" badge would not be enough.
  DateTime? get lastLineAt => _lastLineAt;

  /// Why there is nothing to read, in words, or null when there is no problem
  /// to report.
  String? get problem => _problem;

  int get dropped => _tail.dropped;

  int get kept => _tail.length;

  List<LogcatEntry> lines({int limit = 400}) =>
      _tail.tail(limit: limit, minLevel: _minLevel);

  /// Attaches to the device's log, replacing any stream already attached.
  Future<void> start() async {
    final adb = _adb;
    if (adb == null) {
      _problem =
          'No Android SDK was found, so there is no adb to read the log with.';
      notifyListeners();
      return;
    }
    _detach();
    final generation = ++_generation;
    _starting = true;
    _problem = null;
    notifyListeners();
    try {
      final package = _package;
      final pids = package == null
          ? const <int>[]
          : await adb.pidsOf(serial, package);
      if (generation != _generation) return;
      if (package != null && pids.isEmpty) {
        // Not an empty log: `logcat --pid` with no pids would stream the whole
        // device, which is the opposite of what was asked for.
        _starting = false;
        _problem =
            '$package is not running on $serial, so there is no process to '
            'follow. Launch it and start again.';
        notifyListeners();
        return;
      }
      final process = await adb.streamLogcat(serial, pids: pids);
      if (generation != _generation) {
        await process.kill();
        return;
      }
      _process = process;
      _startedAt = _clock.nowUtc();
      _starting = false;
      _lines = process.stdoutLines.listen(
        _onLine,
        onError: (Object error) => _stopped(generation, '$error'),
        onDone: () => _stopped(generation, null),
      );
      notifyListeners();
    } catch (error, stack) {
      if (generation != _generation) return;
      _log.warning('Could not start logcat on $serial.', error, stack);
      _starting = false;
      _problem = 'logcat could not be started: $error';
      notifyListeners();
    }
  }

  /// Detaches from the log. The lines already read stay on screen — they are a
  /// reading with an age, not a live view that has to be blanked.
  void stop() {
    _generation++;
    _detach();
    notifyListeners();
  }

  /// Pins the stream to one package's processes, or to none.
  ///
  /// Restarts, because `--pid` is chosen when `logcat` is spawned. The lines
  /// already collected are cleared with it: keeping another package's lines
  /// under a filter that says this one would misattribute every one of them.
  Future<void> filterByPackage(String? package) async {
    final trimmed = package?.trim();
    _package = trimmed == null || trimmed.isEmpty ? null : trimmed;
    _tail.clear();
    _lastLineAt = null;
    if (_process == null && !_starting) {
      notifyListeners();
      return;
    }
    await start();
  }

  /// The lowest priority drawn. Applied to what is already collected rather
  /// than at adb, so raising and lowering it costs no restart and loses nothing.
  void setMinLevel(LogLevel level) {
    if (_minLevel == level) return;
    _minLevel = level;
    notifyListeners();
  }

  void clear() {
    _tail.clear();
    _lastLineAt = null;
    notifyListeners();
  }

  void _onLine(String line) {
    final entry = parseLogcatLine(line);
    // Separator banners and anything that does not parse are dropped, exactly
    // as the snapshot reader drops them.
    if (entry == null) return;
    _tail.add(entry);
    _lastLineAt = _clock.nowUtc();
    _flush ??= Timer(flushWindow, () {
      _flush = null;
      notifyListeners();
    });
  }

  void _stopped(int generation, String? error) {
    if (generation != _generation) return;
    _process = null;
    _lines = null;
    if (error != null) _problem = 'The log stream ended: $error';
    notifyListeners();
  }

  /// Drops the stream and the process, **synchronously**.
  ///
  /// Nothing here is awaited on purpose. A restart and a dispose both have to
  /// leave the old process dead the instant they are asked, and awaiting a
  /// subscription's cancellation put the kill behind an event-loop turn — long
  /// enough for a closing panel to be gone with its `logcat` still running.
  /// Ordering is the generation counter's job, not the await's.
  void _detach() {
    _flush?.cancel();
    _flush = null;
    unawaited(_lines?.cancel());
    _lines = null;
    final process = _process;
    _process = null;
    _startedAt = null;
    _starting = false;
    unawaited(process?.kill());
  }

  @override
  void dispose() {
    _generation++;
    _detach();
    super.dispose();
  }
}

/// One session per device, disposed with the last widget watching it.
///
/// `autoDispose` is the whole bound on cost: a collapsed logcat view holds no
/// subscription, so the provider is disposed, so the `logcat` process is
/// killed. Nothing keeps a device talking to a panel nobody has open.
final deviceLogcatSessionProvider = Provider.autoDispose
    .family<DeviceLogcatSession, String>((ref, serial) {
      final session = DeviceLogcatSession(
        serial: serial,
        adb: ref.watch(adbServiceProvider),
        clock: ref.watch(clockProvider),
      );
      ref.onDispose(session.dispose);
      return session;
    });
