/// Where an SSH connection is in its lifecycle. [disconnected] is retried with
/// backoff; [failed] is terminal until the user changes something.
enum SshConnectionStatus {
  /// No connection has been attempted yet.
  idle,

  /// A connect (or reconnect) attempt is in flight.
  connecting,

  /// Authenticated and usable.
  connected,

  /// The link dropped after having been up; a reconnect will be attempted.
  disconnected,

  /// Connecting failed in a way retrying cannot fix (bad host key, bad
  /// credentials, unreachable host after the retry budget).
  failed,
}

/// A snapshot of one connection's lifecycle, safe to log and display: [error]
/// is human-readable and credentials never reach it.
class SshConnectionState {
  const SshConnectionState({
    required this.status,
    this.error,
    this.attempt = 0,
    this.nextRetryIn,
  });

  const SshConnectionState.idle() : this(status: SshConnectionStatus.idle);

  final SshConnectionStatus status;

  /// Why the connection is not up, when it is not.
  final String? error;

  /// How many consecutive failed attempts have been made.
  final int attempt;

  /// How long before the next automatic attempt, when one is scheduled.
  final Duration? nextRetryIn;

  bool get isConnected => status == SshConnectionStatus.connected;

  @override
  bool operator ==(Object other) =>
      other is SshConnectionState &&
      other.status == status &&
      other.error == error &&
      other.attempt == attempt &&
      other.nextRetryIn == nextRetryIn;

  @override
  int get hashCode => Object.hash(status, error, attempt, nextRetryIn);

  @override
  String toString() =>
      'SshConnectionState(${status.name}'
      '${attempt == 0 ? '' : ', attempt $attempt'}'
      '${error == null ? '' : ', $error'})';
}

/// Exponential backoff for reconnect attempts, capped so a long outage does not
/// wander into hour-long waits. Pure, so the schedule is unit-testable.
Duration reconnectBackoff(
  int attempt, {
  Duration base = const Duration(milliseconds: 500),
  Duration max = const Duration(seconds: 30),
}) {
  if (attempt <= 0) return Duration.zero;
  // 1 -> base, 2 -> 2*base, 3 -> 4*base ... shifting rather than pow() keeps it
  // exact, and the clamp happens before the multiply so it cannot overflow.
  final exponent = attempt - 1 > 20 ? 20 : attempt - 1;
  final millis = base.inMilliseconds << exponent;
  return millis >= max.inMilliseconds ? max : Duration(milliseconds: millis);
}
