import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show CapacitySnapshot;

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

/// Files each person-started wait in the inbox once, and takes it off when
/// the wait is over; an agent's or an automation's wait is not filed.
class SlotWaitInbox {
  SlotWaitInbox({required this.raise, required this.retire});

  final void Function(String sessionId, String reason) raise;
  final void Function(String sessionId) retire;
  final _filed = <String>{};

  void update(CapacitySnapshot snapshot) {
    final now = {
      for (final waiter in snapshot.waiters)
        if (waiter.personStarted && waiter.sessionId != null)
          waiter.sessionId!: waiter.reason,
    };
    for (final entry in now.entries) {
      if (_filed.add(entry.key)) raise(entry.key, entry.value);
    }
    for (final gone in _filed.where((id) => !now.containsKey(id)).toList()) {
      _filed.remove(gone);
      retire(gone);
    }
  }
}
