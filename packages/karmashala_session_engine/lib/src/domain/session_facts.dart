/// What a host says one of its sessions is doing.
enum HostSessionState { running, exited, closed }

/// What happened to a host session: the kinds of the host's lifecycle feed.
enum SessionLifecycleKind { started, exited, closed }

/// What a host said about one session, at one moment. Mirrors the host's
/// lifecycle snapshot; the app maps the wire types onto this, so the engine
/// never depends on the host package.
class SessionFacts {
  const SessionFacts({
    required this.hostSessionId,
    required this.state,
    required this.observedAt,
    this.exitCode,
    this.reason,
  });

  final String hostSessionId;
  final HostSessionState state;

  /// Only when the host saw the process exit with it. Null on an exit nobody
  /// watched — a host restarted under its session — which is never a success.
  final int? exitCode;

  /// The host's words for why it ended, e.g. `host stopped while running`.
  final String? reason;

  /// UTC.
  final DateTime observedAt;

  @override
  bool operator ==(Object other) =>
      other is SessionFacts &&
      other.hostSessionId == hostSessionId &&
      other.state == state &&
      other.exitCode == exitCode &&
      other.reason == reason &&
      other.observedAt == observedAt;

  @override
  int get hashCode =>
      Object.hash(hostSessionId, state, exitCode, reason, observedAt);

  @override
  String toString() =>
      'SessionFacts($hostSessionId, ${state.name}, exitCode: $exitCode, '
      'reason: $reason, observedAt: ${observedAt.toIso8601String()})';
}

/// One change on the host's lifecycle feed.
class SessionLifecycleEvent {
  const SessionLifecycleEvent({
    required this.hostSessionId,
    required this.kind,
    required this.observedAt,
    this.exitCode,
    this.reason,
  });

  final String hostSessionId;
  final SessionLifecycleKind kind;
  final int? exitCode;
  final String? reason;

  /// UTC.
  final DateTime observedAt;

  /// The session as this event leaves it.
  SessionFacts get facts => SessionFacts(
    hostSessionId: hostSessionId,
    state: switch (kind) {
      SessionLifecycleKind.started => HostSessionState.running,
      SessionLifecycleKind.exited => HostSessionState.exited,
      SessionLifecycleKind.closed => HostSessionState.closed,
    },
    exitCode: exitCode,
    reason: reason,
    observedAt: observedAt,
  );

  @override
  String toString() =>
      'SessionLifecycleEvent($hostSessionId, ${kind.name}, '
      'exitCode: $exitCode, reason: $reason)';
}
