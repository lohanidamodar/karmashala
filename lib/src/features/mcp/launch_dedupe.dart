import 'dart:convert';

import 'package:karmashala_core/util.dart';

/// How long a *settled* launch stays on the ledger.
///
/// It has to outlast the MCP client's own retry, and that timeout is not ours:
/// Claude Code gave up on `open_new_session` after 60s and re-sent the identical
/// call, which started a second agent. Two minutes clears one full retry cycle,
/// and an attempt still running never expires whatever this says.
const Duration launchDedupeWindow = Duration(minutes: 2);

/// Whether repeating [tool] would start something in the world: the calls a
/// retry cannot be allowed to make twice. `open_sessions_in_tmux` belongs with
/// the launches because `buildTmuxScript` *appends* — a repeat adds a second
/// window per id. A preview starts nothing and is not one.
bool startsAnAgent(String tool, Map<String, dynamic> arguments) =>
    switch (tool) {
      'open_new_session' || 'open_sessions_in_tmux' => true,
      'session_handoff' || 'session_fork' => arguments['preview'] != true,
      _ => false,
    };

/// A stable key for one launch request. Every argument counts rather than a
/// chosen few: a client's retry repeats the call verbatim, so a tool that grows
/// an argument later is covered without anyone remembering to come back here.
/// Keys are sorted so the encoding does not depend on map order.
String launchFingerprint(
  String tool,
  Map<String, dynamic> arguments,
  String? callerSessionId,
) => jsonEncode([tool, callerSessionId, _canonical(arguments)]);

Object? _canonical(Object? value) {
  if (value is Map) {
    final entries = [
      for (final entry in value.entries)
        MapEntry('${entry.key}', _canonical(entry.value)),
    ]..sort((a, b) => a.key.compareTo(b.key));
    return Map<String, Object?>.fromEntries(entries);
  }
  if (value is List) return [for (final item in value) _canonical(item)];
  if (value == null || value is num || value is bool || value is String) {
    return value;
  }
  // Unreachable for a decoded JSON payload; named rather than encoded so an
  // unexpected type cannot throw inside a dispatch.
  return '$value';
}

/// One remembered launch.
class _Attempt {
  /// The single call every duplicate awaits. Assigned by [LaunchDedupe.run]
  /// immediately after this is put on the ledger.
  late final Future<Object?> result;

  /// When the launch finished, or null while it is still running — which is
  /// when it can never expire.
  DateTime? settledAt;
}

/// Collapses a repeated launch request onto the one already made, keyed on the
/// request itself because the client's retry carries nothing new.
///
/// The ledger records the **attempt**, not the outcome, and that ordering is the
/// whole fix: the duplicate that started a second agent arrived 55s in, while
/// the first launch was still creating its worktree. A duplicate gets the first
/// attempt's own result; a **failed** attempt is forgotten at once, so one
/// transient failure does not become two minutes of the same wrong answer.
class LaunchDedupe {
  LaunchDedupe({
    required this.clock,
    this.window = launchDedupeWindow,
    this.onCollapsed,
  });

  final Clock clock;

  /// How long a settled attempt is remembered. See [launchDedupeWindow].
  final Duration window;

  /// Told the name of a tool whose repeat was collapsed, so the next incident
  /// leaves a line in the log rather than only a missing session.
  final void Function(String tool)? onCollapsed;
  final Map<String, _Attempt> _attempts = <String, _Attempt>{};

  /// Runs [start], or returns the result of the identical launch already made.
  Future<Object?> run({
    required String tool,
    required Map<String, dynamic> arguments,
    required String? callerSessionId,
    required Future<Object?> Function() start,
  }) {
    _forgetExpired();
    final key = launchFingerprint(tool, arguments, callerSessionId);
    final remembered = _attempts[key];
    if (remembered != null) {
      onCollapsed?.call(tool);
      return remembered.result;
    }
    final attempt = _Attempt();
    _attempts[key] = attempt;
    return attempt.result = _watch(key, attempt, start);
  }

  Future<Object?> _watch(
    String key,
    _Attempt attempt,
    Future<Object?> Function() start,
  ) async {
    try {
      final value = await start();
      attempt.settledAt = clock.nowUtc();
      return value;
    } on Object {
      _attempts.remove(key);
      rethrow;
    }
  }

  void _forgetExpired() {
    final now = clock.nowUtc();
    _attempts.removeWhere((_, attempt) {
      final settled = attempt.settledAt;
      return settled != null && now.difference(settled) > window;
    });
  }
}
