import 'package:karmashala/src/features/agents/application/agent_status_providers.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ProviderContainer container;
  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  test('the receiver and the status service share one report store', () async {
    // If they did not, a hook callback would never reach a status query.
    container
        .read(agentHookReceiverProvider)
        .handle(
          agentId: 'claudeCode',
          event: 'Notification',
          body: '{"session_id":"s1"}',
        );

    final report = await container
        .read(agentStatusServiceProvider)
        .statusFor(
          const AgentStatusQuery(agentId: 'claudeCode', sessionId: 's1'),
        );

    expect(report.status, AgentActivityStatus.awaitingApproval);
    expect(report.source, AgentStatusSource.hook);
  });

  test('a session nothing has reported on is unknown', () async {
    final report = await container
        .read(agentStatusServiceProvider)
        .statusFor(
          const AgentStatusQuery(agentId: 'claudeCode', sessionId: 'other'),
        );

    expect(report.status, AgentActivityStatus.unknown);
    expect(report.source, AgentStatusSource.none);
  });
}
