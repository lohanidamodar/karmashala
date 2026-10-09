import 'session_launch_gate.dart';

/// Which sessions wait for a slot, for the tools made before the gate is.
class SlotWaits {
  SessionLaunchGate? gate;

  /// Each waiting session's reason and place, by session id.
  Map<String, String> all() => {
    for (final waiter in gate?.snapshot().waiters ?? const [])
      if (waiter.sessionId != null)
        waiter.sessionId!: '${waiter.reason} (place ${waiter.place} in line)',
  };

  String? of(String sessionId) => all()[sessionId];
}
