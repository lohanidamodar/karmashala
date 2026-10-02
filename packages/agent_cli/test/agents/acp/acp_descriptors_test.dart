import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/src/agents/adapter/generic_chat_protocol.dart';
import 'package:test/test.dart';

/// The four ACP agents are data: an `acp` spec and nothing terminal-shaped.
void main() {
  const acpIds = [
    AgentIds.claudeAcp,
    AgentIds.codexAcp,
    AgentIds.geminiCli,
    AgentIds.grok,
  ];

  AgentAdapter adapterOf(String id) => AgentRegistry.builtIn.adapterFor(id)!;

  test('they are registered after the three terminal agents', () {
    expect(builtInAgentAdapters.map((a) => a.id), [
      AgentIds.claudeCode,
      AgentIds.codex,
      AgentIds.antigravity,
      ...acpIds,
    ]);
    expect(builtInAgentDescriptors.map((d) => d.id), AgentIds.builtIn);
  });

  test('ids and display names', () {
    final names = {
      for (final id in acpIds) id: AgentRegistry.builtIn.displayNameFor(id),
    };
    expect(names, {
      'claude-acp': 'Claude (ACP)',
      'codex-acp': 'Codex (ACP)',
      'gemini-cli': 'Gemini CLI',
      'grok': 'Grok',
    });
  });

  for (final id in acpIds) {
    group(id, () {
      final adapter = adapterOf(id);
      final descriptor = adapter.descriptor;

      test('declares acp, and the adapter and capability say so', () {
        expect(descriptor.acp, isNotNull);
        expect(adapter.acp, same(descriptor.acp));
        expect(adapter.capabilities, contains(AgentCapability.acp));
        expect(descriptor.acp!.clientName, 'Karmashala');
        expect(descriptor.acp!.npxPackage, isNotNull);
      });

      test('declares nothing terminal-shaped', () {
        expect(adapter, isA<DataOnlyAgentAdapter>());
        expect(descriptor.statusStrategy, AgentStatusStrategy.none);
        expect(descriptor.hooks, isNull);
        expect(descriptor.stateFile, isNull);
        expect(descriptor.grid.isEmpty, isTrue);
        expect(descriptor.approval.isEmpty, isTrue);
        expect(descriptor.questions, isNull);
        expect(descriptor.menus, isNull);
        expect(adapter.transcripts, isNull);
        expect(
          adapter.chatProtocol((_) => throw StateError('unused')),
          isA<GenericChatProtocol>(),
        );
      });

      test('its permission values put nothing on argv', () {
        // The mode travels over the protocol (`session/set_mode`), so every
        // value is argument-less and `argumentsFor` is always empty.
        final support = descriptor.launch.permission;
        expect(support.isKnown, isTrue);
        for (final selection in support.selections()) {
          expect(support.argumentsFor(selection), isEmpty);
        }
      });

      test('every mode the picker offers is reachable over the protocol', () {
        // The axis is what the picker shows; `modeNames` is what the runtime
        // sends. A value the runtime could never name would be a mode that
        // looks chosen and is not.
        final named = {
          for (final candidates in descriptor.acp!.modeNames.values)
            for (final candidate in candidates) candidate.toLowerCase(),
        };
        for (final axis in descriptor.launch.permission.axes) {
          for (final value in axis.values) {
            expect(
              named,
              contains(value.id.toLowerCase()),
              reason: '$id offers ${value.id} but never sends it',
            );
            // And the rung it is sent for is the rung it is declared at.
            expect(
              descriptor.acp!.modeFor(value.permits, [value.id]),
              value.id,
              reason: '$id/${value.id} is not named at ${value.permits.name}',
            );
          }
        }
      });
    });
  }

  test('mode names are matched case-insensitively, first candidate wins', () {
    final gemini = geminiCliDescriptor.acp!;
    expect(
      gemini.modeFor(PermissionRisk.acceptEdits, ['default', 'AUTOEDIT']),
      'AUTOEDIT',
    );
    expect(
      gemini.modeFor(PermissionRisk.acceptEdits, ['auto_edit', 'autoEdit']),
      'auto_edit',
    );
    expect(gemini.modeFor(PermissionRisk.readOnly, ['default']), isNull);
    // Grok has no read-only rung at all.
    expect(
      grokDescriptor.acp!.modeFor(PermissionRisk.readOnly, ['plan']),
      isNull,
    );
  });

  test('the declared argv and packages', () {
    expect(claudeAcpDescriptor.acp!.arguments, isEmpty);
    expect(
      claudeAcpDescriptor.acp!.npxPackage,
      '@agentclientprotocol/claude-agent-acp',
    );
    expect(codexAcpDescriptor.acp!.arguments, isEmpty);
    expect(
      codexAcpDescriptor.acp!.npxPackage,
      '@agentclientprotocol/codex-acp',
    );
    expect(geminiCliDescriptor.acp!.arguments, ['--acp']);
    expect(geminiCliDescriptor.acp!.npxPackage, '@google/gemini-cli');
    expect(grokDescriptor.acp!.arguments, ['agent', 'stdio']);
    expect(grokDescriptor.acp!.npxPackage, '@xai-official/grok');
  });

  test('the terminal agents declare no acp', () {
    for (final id in [
      AgentIds.claudeCode,
      AgentIds.codex,
      AgentIds.antigravity,
    ]) {
      expect(adapterOf(id).acp, isNull, reason: id);
      expect(adapterOf(id).capabilities, isNot(contains(AgentCapability.acp)));
    }
  });
}
