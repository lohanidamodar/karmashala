import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the built-in ids name real descriptors, in registry order', () {
    expect(AgentIds.builtIn, ['claudeCode', 'codex', 'antigravity']);
    expect(
      AgentRegistry.builtIn.descriptors.map((d) => d.id),
      AgentIds.builtIn,
    );
  });

  test('displayNameFor falls back to the id for an unknown agent', () {
    expect(AgentRegistry.builtIn.displayNameFor(AgentIds.codex), 'Codex CLI');
    expect(AgentRegistry.builtIn.displayNameFor('roverCli'), 'roverCli');
  });
}
