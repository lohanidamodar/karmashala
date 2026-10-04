import 'package:agent_cli/descriptors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/onboarding/application/quick_start.dart';

import '../../support/fixtures.dart';

void main() {
  const registry = AgentRegistry.builtIn;

  test('an agent installed in both forms is listed once, saying so', () {
    final installs = [
      agentInstallation(),
      agentInstallation(id: 'c', agentId: AgentIds.claudeAcp, version: null),
      agentInstallation(id: 'x', agentId: AgentIds.codex, version: '0.5'),
    ];
    expect(preflightAgentsIn(registry, installs, 'windows'), [
      'Claude Code 1.0.0 + chat',
      'Codex CLI 0.5',
    ]);
  });

  test('a chat form alone is named as its agent, marked chat', () {
    final installs = [
      agentInstallation(id: 'c', agentId: AgentIds.claudeAcp, version: null),
      agentInstallation(id: 'g', agentId: AgentIds.grok, version: null),
    ];
    expect(preflightAgentsIn(registry, installs, 'windows'), [
      'Claude Code (chat)',
      'Grok',
    ]);
  });

  test('another machine\'s installs are not counted here', () {
    final installs = [agentInstallation(environmentId: 'wsl:Ubuntu')];
    expect(preflightAgentsIn(registry, installs, 'windows'), isEmpty);
  });
}
