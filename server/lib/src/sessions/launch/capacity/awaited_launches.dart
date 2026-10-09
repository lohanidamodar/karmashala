import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show LaunchPriority;

import '../../../automations/hosted_agent_launcher.dart';
import 'launch_slots.dart';
import 'session_launch_gate.dart';

/// The gate for a launcher whose caller awaits its start — an automation's
/// run, a scheduled resume, a phone's start: the start waits in line, in
/// memory, and goes ahead when granted. A restart drops these waits; the
/// automation or the resume settles them by its own rules.
class AwaitedLaunches {
  AwaitedLaunches(this.gate) {
    gate.onGranted(
      kind,
      _granted,
      restorable: false,
      onCancelled: (ticket) => _waiting
          .remove(ticket.id)
          ?.completeError(
            StateError('It was cancelled while it waited for a slot.'),
          ),
    );
  }

  static const String kind = 'hosted.awaited';

  final SessionLaunchGate gate;
  final Map<String, Completer<LaunchReservation>> _waiting = {};

  /// [HostedAgentLauncher.admit] at [priority].
  Future<LaunchReservation?> Function(HostedLaunch launch) admitAt(
    LaunchPriority priority,
  ) =>
      (launch) => admit(launch, priority);

  Future<LaunchReservation> admit(
    HostedLaunch launch,
    LaunchPriority priority,
  ) {
    final resuming = launch.resuming;
    final directory =
        launch.existingWorktree ??
        launch.workingDirectory ??
        resuming?.workingDirectory ??
        resuming?.worktree ??
        launch.repository.path;
    final claim = sessionLaunchClaim(
      kind: kind,
      priority: priority,
      environmentId: directory.environmentId,
      installation: launch.installation,
      projectId: launch.repository.projectId,
      label:
          resuming?.title ?? (launch.title.isEmpty ? 'Session' : launch.title),
      sessionId: resuming?.id ?? launch.id,
    );
    switch (gate.acquire(claim)) {
      case LaunchGranted(:final reservation):
        return Future.value(reservation);
      case LaunchWaiting(:final ticket):
        final waiting = Completer<LaunchReservation>();
        _waiting[ticket.id] = waiting;
        return waiting.future;
    }
  }

  Future<void> _granted(LaunchTicket ticket, LaunchReservation reservation) {
    final waiting = _waiting.remove(ticket.id);
    if (waiting == null) return Future.value();
    waiting.complete(reservation);
    return reservation.released;
  }
}
