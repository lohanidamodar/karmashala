/// How a session ended, or that it has not.
///
/// The three cases exist because the second and third are not the same and a
/// single nullable int cannot tell them apart. A session whose child was
/// reaped by something else has no exit code, and reporting 0 for it would be
/// the confident false statement this codebase spends its effort deleting.
sealed class SessionLifecycle {
  const SessionLifecycle();

  bool get hasEnded => this is! SessionRunning;

  /// When the session ended, or null while it is running. The registry sorts
  /// on this when it decides which ended sessions it can afford to forget.
  DateTime? get endedAt => switch (this) {
    SessionExited(:final at) => at,
    SessionEndedWithoutCode(:final at) => at,
    _ => null,
  };

  /// Null while running, and null when the code is genuinely unknown.
  int? get exitCode => switch (this) {
    SessionExited(:final code) => code,
    _ => null,
  };

  String describe() => switch (this) {
    SessionRunning() => 'running',
    SessionExited(:final code) => 'exited $code',
    SessionEndedWithoutCode(:final reason) => 'ended, exit code unknown ($reason)',
  };
}

class SessionRunning extends SessionLifecycle {
  const SessionRunning();
}

class SessionExited extends SessionLifecycle {
  const SessionExited(this.code, this.at);
  final int code;
  final DateTime at;
}

class SessionEndedWithoutCode extends SessionLifecycle {
  const SessionEndedWithoutCode(this.at, this.reason);
  final DateTime at;
  final String reason;
}
