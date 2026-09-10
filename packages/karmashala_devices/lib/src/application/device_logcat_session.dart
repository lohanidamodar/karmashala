import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_core/logging.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart';
import 'device_ports.dart';
import '../../devices.dart';
import 'device_providers.dart';

/// A live `logcat` for one device, over the same `AdbService` the
/// `device_logcat` tool snapshots through — `streamLogcat`, without `-d`.
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
  /// only between a line arriving and the frame that draws it.
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

  /// When the last line arrived, or null when none has: the number that
  /// tells a quiet device from a dead stream.
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

  /// Pins the stream to one package's processes, or none. Restarts, since
  /// `--pid` is fixed at spawn; the collected lines go with it, unattributed.
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

  /// Drops the stream and the process, **synchronously**: awaiting the
  /// cancellation put the kill a turn late, outliving the panel that closed.
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
/// `autoDispose` is the whole bound on cost: no watcher, no `logcat`.
final deviceLogcatSessionProvider = Provider.autoDispose
    .family<DeviceLogcatSession, String>((ref, serial) {
      final session = DeviceLogcatSession(
        serial: serial,
        adb: ref.watch(adbServiceProvider),
        clock: ref.watch(deviceClockProvider),
      );
      ref.onDispose(session.dispose);
      return session;
    });
