import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/src/agents/adapter/generic_chat_protocol.dart';
import 'package:test/test.dart';

/// The four ACP agents are data: an `acp` spec and nothing terminal-shaped.
void main() {
  const acpIds = [
    AgentIds.claudeAcp,
    AgentIds.codexAcp,
    AgentIds.antigravityAcp,
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
      'antigravity-acp': 'Antigravity (ACP)',
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
        // Each is reachable without an adapter of its own to install: an npm
        // package, a registry archive Karmashala installs, or the agent's
        // own binary spoken to through a native bridge.
        expect(
          descriptor.acp!.npxPackage != null ||
              descriptor.acp!.registryId != null ||
              descriptor.acp!.nativeBridge != null,
          isTrue,
        );
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
        // An agent whose modes were never read off a session declares none,
        // rather than a guess.
        expect(support.isKnown, descriptor.acp!.modeNames.isNotEmpty);
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
    const spec = AcpLaunchSpec(
      modeNames: {
        PermissionRisk.acceptEdits: ['auto_edit', 'autoEdit'],
      },
    );
    expect(
      spec.modeFor(PermissionRisk.acceptEdits, ['default', 'AUTOEDIT']),
      'AUTOEDIT',
    );
    expect(
      spec.modeFor(PermissionRisk.acceptEdits, ['auto_edit', 'autoEdit']),
      'auto_edit',
    );
    expect(spec.modeFor(PermissionRisk.readOnly, ['default']), isNull);
    // Grok has no read-only rung at all.
    expect(
      grokDescriptor.acp!.modeFor(PermissionRisk.readOnly, ['plan']),
      isNull,
    );
    // Antigravity's modes have not been read: it offers none yet.
    expect(antigravityAcpDescriptor.acp!.modeNames, isEmpty);
    expect(antigravityAcpDescriptor.launch.permission.isKnown, isFalse);
  });

  test('Antigravity (ACP) is the registry\'s archive, found where it is '
      'installed, with --uid= on Linux only', () {
    final acp = antigravityAcpDescriptor.acp!;
    expect(acp.registryId, 'antigravity-acp');
    expect(acp.npxPackage, isNull);
    expect(acp.arguments, isEmpty);
    expect(acp.linuxArguments, ['--uid=']);
    expect(acp.argumentsFor(linux: true), ['--uid=']);
    expect(acp.argumentsFor(linux: false), isEmpty);
    expect(antigravityAcpDescriptor.binaries.posix, [
      'agy_acp_server.par',
      'agy_acp_server',
    ]);
    expect(antigravityAcpDescriptor.binaries.windows, ['agy_acp_server.exe']);
    // `--version` prints a build stamp, not a version: read over ACP instead.
    expect(antigravityAcpDescriptor.discovery.probeVersion, isFalse);
    expect(
      antigravityAcpDescriptor.store?.homeDirectoryName,
      '.gemini/antigravity-acp',
    );
    // The others carry no Linux-only argv.
    for (final other in [
      claudeAcpDescriptor,
      codexAcpDescriptor,
      grokDescriptor,
    ]) {
      expect(other.acp!.linuxArguments, isEmpty, reason: other.id);
      expect(
        other.acp!.argumentsFor(linux: true),
        other.acp!.arguments,
        reason: other.id,
      );
    }
  });

  test('the declared argv and packages', () {
    // Claude chat is the person's own `claude` over its stream-json mode,
    // translated in-process: no adapter package.
    expect(claudeAcpDescriptor.binaries.windows, ['claude']);
    expect(claudeAcpDescriptor.binaries.posix, ['claude']);
    expect(claudeAcpDescriptor.acp!.npxPackage, isNull);
    expect(
      claudeAcpDescriptor.acp!.nativeBridge,
      AcpNativeBridge.claudeStreamJson,
    );
    expect(claudeAcpDescriptor.acp!.arguments, [
      '-p',
      '--input-format',
      'stream-json',
      '--output-format',
      'stream-json',
      '--verbose',
      '--include-partial-messages',
      '--permission-prompt-tool',
      'stdio',
      '--allow-dangerously-skip-permissions',
    ]);
    expect(codexAcpDescriptor.acp!.arguments, isEmpty);
    expect(
      codexAcpDescriptor.acp!.npxPackage,
      '@agentclientprotocol/codex-acp',
    );
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
