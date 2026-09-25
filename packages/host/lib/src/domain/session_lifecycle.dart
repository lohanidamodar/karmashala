/// How a session ended, or that it has not. Three cases because a nullable int
/// cannot tell "exited 0" from "reaped by something else, code unknown".
sealed class SessionLifecycle {
  const SessionLifecycle();

  bool get hasEnded => this is! SessionRunning;

  /// When the session ended, or null while running; the registry prunes on it.
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
    SessionEndedWithoutCode(:final reason) =>
      'ended, exit code unknown ($reason)',
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

  /// The reason a record still saying *running* is read back with: the process
  /// died with its host, so there is no code to report.
  static const hostStoppedWhileRunning = 'host stopped while running';

  final DateTime at;
  final String reason;
}
