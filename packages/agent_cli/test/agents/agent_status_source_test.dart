import 'package:agent_cli/src/agents/domain/agent_status.dart';
import 'package:test/test.dart';

/// Status sources cross the wire by name (`AgentStatusSource.values.byName`,
/// in the data protocol and the hosted status keeper), so a new member must
/// keep its name stable and round-trip like the others.
void main() {
  test('protocol is a source, and every source round-trips by name', () {
    expect(AgentStatusSource.values, contains(AgentStatusSource.protocol));
    for (final source in AgentStatusSource.values) {
      expect(AgentStatusSource.values.byName(source.name), source);
    }
    expect(AgentStatusSource.protocol.name, 'protocol');
  });

  test('a protocol-sourced report reads like a hook one', () {
    final report = AgentStatusReport(
      agentId: 'claude-acp',
      sessionId: 's1',
      status: AgentActivityStatus.working,
      source: AgentStatusSource.protocol,
      observedAt: DateTime.utc(2026, 10, 2),
    );
    expect(report.source, AgentStatusSource.protocol);
    expect(report.toString(), contains('protocol'));
  });
}
