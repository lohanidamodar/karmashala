part of 'messages.dart';

// The lifecycle feed's payloads are JSON inside a length-prefixed string: they
// are small and rare, and a field added later must not break an older reader.

enum LifecycleEventKind { started, exited, closed }

/// One fact the host observed about one session, when it observed it.
class LifecycleEvent {
  const LifecycleEvent({
    required this.sessionId,
    required this.kind,
    required this.observedAt,
    this.exitCode,
    this.reason,
    this.pid,
    this.endedByClose = false,
  });

  final String sessionId;
  final LifecycleEventKind kind;
  final DateTime observedAt;

  /// Only a code the host actually collected; null is "unknown", never zero.
  final int? exitCode;

  /// Why it ended, on `exited` and `closed`.
  final String? reason;

  /// On `started`.
  final int? pid;

  /// On `exited` and `closed`: a close on request ended a running process —
  /// on `exited`, the code is the signal's, not the program's verdict. False
  /// on a `closed` that only let go of the record of a session that had
  /// already ended, and on every exit nobody asked for.
  final bool endedByClose;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'kind': kind.name,
    'observedAt': observedAt.toUtc().toIso8601String(),
    if (exitCode != null) 'exitCode': exitCode,
    if (reason != null) 'reason': reason,
    if (pid != null) 'pid': pid,
    if (endedByClose) 'endedByClose': true,
  };

  /// Throws [WireFormatException] on a malformed event, and on a kind this
  /// build does not know — a reader skips that one event, not the feed.
  static LifecycleEvent fromJson(Object? json) {
    final map = _object(json, 'lifecycle event');
    final kindName = _required<String>(map, 'kind');
    final kind = LifecycleEventKind.values
        .where((k) => k.name == kindName)
        .firstOrNull;
    if (kind == null) {
      throw WireFormatException('unknown lifecycle kind "$kindName"');
    }
    return LifecycleEvent(
      sessionId: _required<String>(map, 'sessionId'),
      kind: kind,
      observedAt: _time(map, 'observedAt') ?? _missing('observedAt'),
      exitCode: _optional<int>(map, 'exitCode'),
      reason: _optional<String>(map, 'reason'),
      pid: _optional<int>(map, 'pid'),
      endedByClose: _optional<bool>(map, 'endedByClose') ?? false,
    );
  }

  @override
  String toString() =>
      'LifecycleEvent($sessionId ${kind.name}'
      '${exitCode == null ? '' : ' code $exitCode'}'
      '${reason == null ? '' : ' ($reason)'})';
}

enum HostSessionState { running, exited, closed }

/// One session's current facts, as the `watching` snapshot carries them.
class HostSessionFacts {
  const HostSessionFacts({
    required this.sessionId,
    required this.state,
    this.exitCode,
    this.reason,
    this.startedAt,
    this.endedAt,
    this.endedByClose = false,
  });

  final String sessionId;
  final HostSessionState state;

  /// Only a code the host actually collected; null is "unknown", never zero.
  final int? exitCode;
  final String? reason;
  final DateTime? startedAt;
  final DateTime? endedAt;

  /// As on [LifecycleEvent.endedByClose], for an `exited` or `closed` row.
  final bool endedByClose;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'state': state.name,
    if (exitCode != null) 'exitCode': exitCode,
    if (reason != null) 'reason': reason,
    if (startedAt != null) 'startedAt': startedAt!.toUtc().toIso8601String(),
    if (endedAt != null) 'endedAt': endedAt!.toUtc().toIso8601String(),
    if (endedByClose) 'endedByClose': true,
  };

  /// Null for a state this build does not know, so a newer host's snapshot
  /// loses that one row rather than the whole answer.
  static HostSessionFacts? fromJson(Object? json) {
    final map = _object(json, 'session facts');
    final stateName = _required<String>(map, 'state');
    final state = HostSessionState.values
        .where((s) => s.name == stateName)
        .firstOrNull;
    final sessionId = _required<String>(map, 'sessionId');
    final exitCode = _optional<int>(map, 'exitCode');
    final reason = _optional<String>(map, 'reason');
    final startedAt = _time(map, 'startedAt');
    final endedAt = _time(map, 'endedAt');
    final endedByClose = _optional<bool>(map, 'endedByClose') ?? false;
    if (state == null) return null;
    return HostSessionFacts(
      sessionId: sessionId,
      state: state,
      exitCode: exitCode,
      reason: reason,
      startedAt: startedAt,
      endedAt: endedAt,
      endedByClose: endedByClose,
    );
  }
}

/// client → host: send me every session's facts, then every change to them.
class WatchMessage extends HostMessage {
  const WatchMessage(this.requestId, {this.runByClient = const []});
  final int requestId;

  /// Session rows the client runs in its own panes, which no host holds: the
  /// daemon leaves them alone when it marks the rows it does not hold.
  final List<String> runByClient;

  @override
  Frame toFrame() => Frame(
    MessageType.watch,
    0,
    (WireWriter()
          ..u32(requestId)
          ..strings(runByClient))
        .take(),
  );

  static WatchMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    return WatchMessage(r.u32(), runByClient: r.strings());
  }
}

/// host → client: the answer to `watch`. Events follow it on the same link.
class WatchingMessage extends HostMessage {
  const WatchingMessage({
    required this.requestId,
    required this.observedAt,
    required this.sessions,
    this.hooks = const [],
    this.statuses = const [],
  });

  final int requestId;
  final DateTime observedAt;
  final List<HostSessionFacts> sessions;

  /// The latest hook per agent session, so a watcher that was away catches up.
  final List<AgentHookEvent> hooks;

  /// What the agent in each session the host holds is doing, as
  /// `HostedAgentStatus.toJson` — a watcher renders from these, not its own.
  final List<Map<String, Object?>> statuses;

  @override
  Frame toFrame() {
    final body = {
      'observedAt': observedAt.toUtc().toIso8601String(),
      'sessions': [for (final s in sessions) s.toJson()],
      'hooks': [for (final h in hooks) h.toJson()],
      'statuses': statuses,
    };
    final w = WireWriter()
      ..u32(requestId)
      ..str(jsonEncode(body));
    return Frame(MessageType.watching, 0, w.take());
  }

  static WatchingMessage decode(Frame frame) {
    final r = WireReader(frame.payload);
    final requestId = r.u32();
    final map = _object(_decodeJson(r.str()), 'watching');
    final rows = map['sessions'];
    if (rows is! List) throw const WireFormatException('watching: no sessions');
    final hooks = map['hooks'];
    if (hooks is! List) throw const WireFormatException('watching: no hooks');
    // Absent from a host that keeps no agent status (no store).
    final statuses = map['statuses'] ?? const <Object?>[];
    if (statuses is! List) {
      throw const WireFormatException('watching: statuses is not a list');
    }
    return WatchingMessage(
      requestId: requestId,
      observedAt: _time(map, 'observedAt') ?? _missing('observedAt'),
      sessions: [for (final row in rows) ?HostSessionFacts.fromJson(row)],
      hooks: [for (final hook in hooks) AgentHookEvent.fromJson(hook)],
      statuses: [
        for (final status in statuses) _object(status, 'watching: status'),
      ],
    );
  }
}

/// host → client: one event, pushed to every watching connection.
class LifecycleMessage extends HostMessage {
  const LifecycleMessage(this.event);
  final LifecycleEvent event;

  @override
  Frame toFrame() => Frame(
    MessageType.lifecycle,
    0,
    (WireWriter()..str(jsonEncode(event.toJson()))).take(),
  );

  static LifecycleMessage decode(Frame frame) => LifecycleMessage(
    LifecycleEvent.fromJson(_decodeJson(WireReader(frame.payload).str())),
  );
}

/// host → client: the daemon wrote [status] to the row [sessionId]; the row
/// is the record, this only says to read it again.
class SessionChangedMessage extends HostMessage {
  const SessionChangedMessage({required this.sessionId, required this.status});

  final String sessionId;

  /// The status's name as the store keeps it, e.g. `completed`.
  final String status;

  @override
  Frame toFrame() => Frame(
    MessageType.sessionChanged,
    0,
    (WireWriter()..str(jsonEncode({'sessionId': sessionId, 'status': status})))
        .take(),
  );

  static SessionChangedMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'session changed',
    );
    return SessionChangedMessage(
      sessionId: _required<String>(map, 'sessionId'),
      status: _required<String>(map, 'status'),
    );
  }
}

Object? _decodeJson(String text) {
  try {
    return jsonDecode(text);
  } on FormatException catch (e) {
    throw WireFormatException('not JSON: ${e.message}');
  }
}

Map<String, Object?> _object(Object? json, String what) {
  if (json is Map<String, Object?>) return json;
  throw WireFormatException('$what is not an object');
}

T _required<T>(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is T) return value;
  throw WireFormatException('"$key" is missing or not a $T');
}

T? _optional<T>(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value == null || value is T) return value as T?;
  throw WireFormatException('"$key" is not a $T');
}

DateTime? _time(Map<String, Object?> map, String key) {
  final text = _optional<String>(map, key);
  if (text == null) return null;
  final parsed = DateTime.tryParse(text);
  if (parsed == null) throw WireFormatException('"$key" is not a time');
  return parsed.toUtc();
}

Never _missing(String key) => throw WireFormatException('"$key" is missing');
