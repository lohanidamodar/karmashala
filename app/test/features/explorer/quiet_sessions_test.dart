import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_state_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';

import '../../support/fixtures.dart';

class _Live extends LiveAgentStatuses {
  @override
  Map<String, AgentActivityStatus> build() => const {
    's1': AgentActivityStatus.working,
  };
}

/// The server marks a session quiet; the page reads the mark off the
/// session's own status, the moment it moves — no clock of its own.
void main() {
  AgentStatusReport report({DateTime? quietSince}) => AgentStatusReport(
    agentId: AgentIds.claudeCode,
    sessionId: 's1',
    status: AgentActivityStatus.working,
    observedAt: testTime.subtract(const Duration(hours: 3)),
    source: AgentStatusSource.hook,
    quietSince: quietSince,
  );

  test('a session reads quiet once the server marks it, and not once the '
      'mark clears', () async {
    final reports = StreamController<AgentStatusReport>.broadcast();
    addTearDown(reports.close);
    final c = ProviderContainer(
      overrides: [
        liveAgentStatusesProvider.overrideWith(_Live.new),
        agentSessionStatusProvider.overrideWith((ref, id) => reports.stream),
      ],
    );
    addTearDown(c.dispose);
    final sub = c.listen(quietSessionsProvider, (_, _) {});

    reports.add(report());
    await pumpEventQueue();
    expect(sub.read(), isEmpty, reason: 'however old: the server decides');

    reports.add(report(quietSince: testTime));
    await pumpEventQueue();
    expect(sub.read(), {'s1'});

    reports.add(report());
    await pumpEventQueue();
    expect(sub.read(), isEmpty);
  });
}
