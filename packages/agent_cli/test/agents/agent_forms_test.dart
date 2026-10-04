import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show AgentInstallation;
import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:test/test.dart';

void main() {
  const registry = AgentRegistry.builtIn;

  test('each shipped chat form names the terminal agent it is a form of', () {
    expect(registry.byId(AgentIds.claudeAcp)!.chatFormOf, AgentIds.claudeCode);
    expect(registry.byId(AgentIds.codexAcp)!.chatFormOf, AgentIds.codex);
    expect(
      registry.byId(AgentIds.antigravityAcp)!.chatFormOf,
      AgentIds.antigravity,
    );
    expect(registry.byId(AgentIds.grok)!.chatFormOf, isNull);
  });

  test('folded, a paired agent is listed once, under its terminal id', () {
    expect(registry.folded.map((f) => f.agentId), [
      AgentIds.claudeCode,
      AgentIds.codex,
      AgentIds.antigravity,
      AgentIds.grok,
    ]);
    final claude = registry.formsOf(AgentIds.claudeAcp);
    expect(claude.agentId, AgentIds.claudeCode);
    expect(claude.terminalId, AgentIds.claudeCode);
    expect(claude.chatId, AgentIds.claudeAcp);
    expect(claude.hasBoth, isTrue);
    expect(claude.idFor(AgentRunForm.chat), AgentIds.claudeAcp);
    expect(registry.foldedIdOf(AgentIds.codexAcp), AgentIds.codex);
    expect(registry.foldedNameOf(AgentIds.claudeAcp), 'Claude Code');
  });

  test('a single-form agent folds to itself, with no choice', () {
    final grok = registry.formsOf(AgentIds.grok);
    expect(grok.agentId, AgentIds.grok);
    expect(grok.terminalId, isNull);
    expect(grok.chatId, AgentIds.grok);
    expect(grok.hasBoth, isFalse);
    expect(grok.forms, [AgentRunForm.chat]);
    expect(registry.formOf(AgentIds.grok), AgentRunForm.chat);
    expect(registry.formOf(AgentIds.codex), AgentRunForm.terminal);
  });

  test('a chat form whose terminal agent is absent stands alone', () {
    final lone = AgentRegistry(
      builtInAgentAdapters.where((a) => a.id != AgentIds.codex).toList(),
    );
    expect(lone.foldedIdOf(AgentIds.codexAcp), AgentIds.codexAcp);
    expect(lone.formsOf(AgentIds.codexAcp).hasBoth, isFalse);
    expect(
      lone.folded.map((f) => f.agentId),
      contains(AgentIds.codexAcp),
    );
  });

  test('a session names its agent and, for a paired one, its form', () {
    expect(registry.formLabelOf(AgentIds.claudeAcp), 'Claude Code · Chat');
    expect(registry.formLabelOf(AgentIds.claudeCode), 'Claude Code');
    expect(registry.formLabelOf(AgentIds.grok), 'Grok');
    expect(registry.formLabelOf('roverCli'), 'roverCli');
  });

  group('forms that are one program', () {
    // A chat form run by the terminal form's own binary, as Claude's is once
    // it speaks stream-json.
    const sameBinary = AgentDescriptor(
      id: 'claude-chat',
      displayName: 'Claude chat',
      binaries: AgentBinaries(windows: ['claude'], posix: ['claude']),
      acp: AcpLaunchSpec(),
      chatFormOf: AgentIds.claudeCode,
    );
    final composed = AgentRegistry([
      builtInAgentAdapters.firstWhere((a) => a.id == AgentIds.claudeCode),
      const DataOnlyAgentAdapter(sameBinary),
    ]);

    test('a chat form on the terminal form\'s binary is the same program, '
        'both ways', () {
      expect(composed.sameProgramFormsOf(AgentIds.claudeCode), ['claude-chat']);
      expect(composed.sameProgramFormsOf('claude-chat'), [AgentIds.claudeCode]);
    });

    test('a chat form on a binary of its own is a different program', () {
      expect(registry.sameProgramFormsOf(AgentIds.antigravity), isEmpty);
      expect(registry.sameProgramFormsOf(AgentIds.antigravityAcp), isEmpty);
      expect(registry.sameProgramFormsOf(AgentIds.grok), isEmpty);
    });
  });

  group('an installation in another form', () {
    AgentInstallation install(String id, String agentId, String env) =>
        AgentInstallation(
          id: id,
          agentId: agentId,
          executable: EnvironmentPath(environmentId: env, path: '/bin/$id'),
          createdAt: DateTime.utc(2026),
        );
    final terminal = install('t', AgentIds.claudeCode, 'local');
    final chat = install('c', AgentIds.claudeAcp, 'local');
    final farChat = install('f', AgentIds.claudeAcp, 'wsl');
    final all = [terminal, chat, farChat];

    test('is the same agent\'s installation of that form on that machine', () {
      expect(registry.inForm(terminal, all, AgentRunForm.chat), chat);
      expect(registry.inForm(chat, all, AgentRunForm.terminal), terminal);
      expect(registry.inForm(terminal, all, AgentRunForm.terminal), terminal);
    });

    test('is null where that form is not installed there', () {
      expect(
        registry.inForm(terminal, [terminal, farChat], AgentRunForm.chat),
        isNull,
      );
      final grok = install('g', AgentIds.grok, 'local');
      expect(registry.inForm(grok, [grok], AgentRunForm.terminal), isNull);
    });
  });

  test('an unknown id folds to itself and has no forms', () {
    final unknown = registry.formsOf('roverCli');
    expect(unknown.agentId, 'roverCli');
    expect(unknown.forms, isEmpty);
  });

  test('AgentRunForm round-trips by name, defaulting to terminal', () {
    expect(AgentRunForm.parse('chat'), AgentRunForm.chat);
    expect(AgentRunForm.parse('terminal'), AgentRunForm.terminal);
    expect(AgentRunForm.parse(null), AgentRunForm.terminal);
    expect(AgentRunForm.parse('nonsense'), AgentRunForm.terminal);
  });
}
