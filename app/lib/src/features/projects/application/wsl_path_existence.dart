import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';

/// **Whether a WSL folder is still there, asked from inside the distribution.**
///
/// Never a stat over `\\wsl.localhost`: that share is slow and is what
/// Windows on-access antivirus scans. Every path
/// wanted in one turn of the event loop goes out in **one** `wsl.exe` call per
/// distribution, and an answer is kept: a row scrolled away and back asks
/// nothing.
///
/// `true`, `false`, or **`null` — not checked**, which is what a distribution
/// that is not running answers: it is never started to draw a list, and
/// nothing learned is not "missing".
class WslPathExistence {
  WslPathExistence({
    required this.host,
    required this.now,
    this.ttl = const Duration(minutes: 10),
    this.unknownTtl = const Duration(minutes: 1),
    this.floor = const Duration(seconds: 30),
  });

  /// The **Windows host**: `wsl.exe` is its program.
  final CommandRunner host;
  final DateTime Function() now;

  /// How long an answer stands while nothing asks for a fresh one.
  final Duration ttl;

  /// How long "not checked" stands: a distribution may have started since.
  final Duration unknownTtl;

  /// An answer younger than this is never re-asked, whatever the [exists]
  /// `stamp` says — a window refocused ten times is one question.
  final Duration floor;

  final _answers = <(String, String), _Answer>{};
  final _pending = <String, Map<String, Completer<bool?>>>{};
  final _inFlight = <(String, String), Completer<bool?>>{};
  bool _scheduled = false;

  /// Whether [path] is a directory in [distribution]. Answered from what is
  /// kept while that is fresh — younger than [floor], or asked under the same
  /// [stamp] and younger than its TTL — and otherwise asked with every other
  /// path wanted this turn. [fresh] takes no kept answer: for a caller that
  /// acts on "gone". Never throws.
  Future<bool?> exists(
    String distribution,
    String path, {
    Object? stamp,
    bool fresh = false,
  }) {
    if (path.isEmpty) return Future.value();
    final kept = _answers[(distribution, path)];
    if (kept != null && !fresh) {
      final age = now().difference(kept.at);
      final life = kept.exists == null ? unknownTtl : ttl;
      if (age < floor || (kept.stamp == stamp && age < life)) {
        return Future.value(kept.exists);
      }
    }
    final asking = _inFlight[(distribution, path)];
    if (asking != null) return asking.future;
    final waiting = _pending.putIfAbsent(distribution, () => {});
    final completer = waiting.putIfAbsent(path, Completer<bool?>.new);
    if (!_scheduled) {
      _scheduled = true;
      scheduleMicrotask(() => _flush(stamp));
    }
    return completer.future;
  }

  /// What is kept for [path], however old, and nothing asked: for a caller
  /// that cannot wait. Null is "not checked".
  bool? peek(String distribution, String path) =>
      _answers[(distribution, path)]?.exists;

  /// Drops what is kept for [path], so the next [exists] asks — a rescan.
  void forget(String distribution, String path) =>
      _answers.remove((distribution, path));

  /// One stamp for the turn: every row reads it from the same place.
  Future<void> _flush(Object? stamp) async {
    _scheduled = false;
    final asked = Map.of(_pending);
    _pending.clear();
    for (final MapEntry(key: distribution, value: waiting) in asked.entries) {
      for (final MapEntry(key: path, value: completer) in waiting.entries) {
        _inFlight[(distribution, path)] = completer;
      }
    }
    final running = await _running();
    await Future.wait([
      for (final MapEntry(key: distribution, value: waiting) in asked.entries)
        _ask(distribution, waiting, stamp, running: running),
    ]);
  }

  Future<void> _ask(
    String distribution,
    Map<String, Completer<bool?>> waiting,
    Object? stamp, {
    required Set<String> running,
  }) async {
    final paths = waiting.keys.toList();
    final answers = <String, bool?>{};
    // A distribution that is not running is not started for this.
    if (running.contains(distribution)) {
      for (final batch in wslExistenceBatches(paths)) {
        final found = await _askBatch(distribution, batch);
        for (final (index, path) in batch.indexed) {
          answers[path] = found?[index];
        }
      }
    }
    final at = now();
    for (final MapEntry(key: path, value: completer) in waiting.entries) {
      final exists = answers[path];
      _answers[(distribution, path)] = _Answer(exists, at, stamp);
      _inFlight.remove((distribution, path));
      completer.complete(exists);
    }
  }

  Future<List<bool>?> _askBatch(String distribution, List<String> paths) async {
    try {
      final result = await host.run(
        wslDirectoriesExistRequest(distribution: distribution, paths: paths),
      );
      if (!result.ok) return null;
      return parseWslDirectoriesExist(result.stdout, count: paths.length);
    } on Object {
      return null;
    }
  }

  /// `wsl.exe -l --running -q`: answered on the Windows side, starts nothing.
  Future<Set<String>> _running() async {
    try {
      final result = await host.run(
        const CommandRequest(
          executable: 'wsl.exe',
          arguments: ['-l', '--running', '-q'],
          timeout: Duration(seconds: 20),
        ),
      );
      if (!result.ok) return const {};
      return parseWslDistributions(result.stdout).toSet();
    } on Object {
      return const {};
    }
  }
}

class _Answer {
  const _Answer(this.exists, this.at, this.stamp);

  final bool? exists;
  final DateTime at;
  final Object? stamp;
}

final wslPathExistenceProvider = Provider<WslPathExistence>(
  (ref) => WslPathExistence(
    host: ref.watch(hostCommandRunnerProvider),
    now: ref.watch(clockProvider).nowUtc,
  ),
);
