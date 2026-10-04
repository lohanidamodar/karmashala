import 'package:agent_cli/descriptors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/folded_installations.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';

import '../../support/fixtures.dart';

void main() {
  const registry = AgentRegistry.builtIn;
  final terminal = agentInstallation(id: 't');
  final chat = agentInstallation(id: 'c', agentId: AgentIds.claudeAcp);
  final codex = agentInstallation(id: 'x', agentId: AgentIds.codex);
  final wslClaude = agentInstallation(id: 'w', environmentId: 'wsl:Ubuntu');

  test('one group per agent and machine, terminal form first', () {
    final groups = foldInstallations(registry, [chat, codex, terminal]);
    // Keyed by the terminal form, whichever form was listed first.
    expect(groups.map((g) => g.key), ['t', 'x']);
    final claude = groups.first;
    expect(claude.forms.agentId, AgentIds.claudeCode);
    expect(claude.installations, [terminal, chat]);
    expect(claude.first, terminal);
    expect(claude.offersChoice, isTrue);
    expect(claude.installationFor(AgentRunForm.chat), chat);
    expect(groups.last.offersChoice, isFalse);
  });

  test('the same agent on another machine is its own group', () {
    final groups = foldInstallations(registry, [terminal, wslClaude]);
    expect(groups, hasLength(2));
    expect(groups.every((g) => !g.offersChoice), isTrue);
  });

  test('an agent\'s machines sit together, in the order the agent came', () {
    final groups = foldInstallations(registry, [terminal, codex, wslClaude]);
    expect(groups.map((g) => g.key), ['t', 'w', 'x']);
  });

  test('a chosen form moves a default to that form on the same machine', () {
    const none = Settings();
    final chatChosen = none.withAgentRunForm(
      AgentIds.claudeCode,
      AgentRunForm.chat,
    );
    final all = [terminal, chat, wslClaude];
    expect(inChosenForm(terminal, all, registry, none), terminal);
    expect(inChosenForm(terminal, all, registry, chatChosen), chat);
    // Never chosen: a default set to the chat form keeps it.
    expect(inChosenForm(chat, all, registry, none), chat);
    // Not installed in that form there: unchanged.
    expect(inChosenForm(wslClaude, all, registry, chatChosen), wslClaude);
  });
}
