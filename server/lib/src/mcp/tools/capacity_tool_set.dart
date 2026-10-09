import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../sessions/launch/capacity/session_launch_gate.dart';
import 'server_tool_set.dart';

/// `capacity`: the concurrency limits a person set, how full each is, and
/// the launches waiting for a slot. Read-only.
class CapacityToolSet extends ServerToolSet {
  const CapacityToolSet(this._gate);

  final SessionLaunchGate _gate;

  @override
  List<Map<String, Object?>> get schemas => capacityToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) {
    if (tool != 'capacity') return null;
    return runTool(() async {
      final snapshot = _gate.snapshot();
      final limits = snapshot.limits;
      return {
        'limitsSet': limits.hasLimits,
        'slotRule': kLaunchSlotRule,
        'holding': snapshot.running,
        'backgroundPaused': limits.pauseBackground,
        'holdBackgroundAbovePercent': ?limits.holdBackgroundAbovePercent,
        'scopes': [
          for (final scope in snapshot.scopes)
            {
              'scope': scope.scope.name,
              if (scope.key.isNotEmpty) 'key': scope.key,
              'name': scope.label,
              'used': scope.used,
              'limit': scope.limit,
              if (scope.holders.isNotEmpty) 'holders': scope.holders,
            },
        ],
        'waiting': [
          for (final waiter in snapshot.waiters)
            {
              'place': waiter.place,
              'title': waiter.label,
              'sessionId': ?waiter.sessionId,
              'priority': waiter.priority.name,
              'reason': waiter.reason,
              'since': waiter.enqueuedAt.toIso8601String(),
            },
        ],
      };
    });
  }
}

const List<Map<String, Object?>> capacityToolSchemas = [
  {
    'name': 'capacity',
    'description':
        'The concurrency limits on agent sessions (global, per machine, per '
        'agent account, per project), how many slots each uses, and the '
        'launches waiting for a slot with their reasons and places in line. '
        'Interactive starts go ahead of background ones. Read-only.',
    'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
  },
];
