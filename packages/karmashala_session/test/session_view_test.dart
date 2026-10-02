import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_session/launch.dart';
import 'package:test/test.dart';

void main() {
  final registry = AgentRegistry.builtIn;

  group('a chat view is a capability of the agent, not a second runtime', () {
    test('an agent whose transcript we can read has one', () {
      expect(
        agentSupportsChatView(registry.adapterFor(AgentIds.claudeCode)),
        isTrue,
      );
      expect(
        agentSupportsChatView(registry.adapterFor(AgentIds.codex)),
        isTrue,
      );
    });

    test('Antigravity has a protocol and no chat view', () {
      // The distinction that matters: the capability is "can we read this
      // agent's own record of the conversation", not "does it speak a chat
      // protocol". Antigravity has the second and not the first, and correctly
      // gets the terminal only.
      final antigravity = registry.adapterFor(AgentIds.antigravity)!;
      expect(
        antigravity.capabilities,
        contains(AgentCapability.structuredChat),
      );
      expect(agentSupportsChatView(antigravity), isFalse);
      expect(defaultViewFor(antigravity), SessionView.terminal);
    });

    test('an agent that exists only as registry data has none', () {
      const rover = DataOnlyAgentAdapter(
        AgentDescriptor(
          id: 'roverCli',
          displayName: 'Rover',
          binaries: AgentBinaries(windows: ['rover'], posix: ['rover']),
        ),
      );
      expect(agentSupportsChatView(rover), isFalse);
      expect(defaultViewFor(rover), SessionView.terminal);
    });

    test(
      'an agent declaring a store home and no store capability has none',
      () {
        const opaque = DataOnlyAgentAdapter(
          AgentDescriptor(
            id: 'opaque',
            displayName: 'Opaque',
            binaries: AgentBinaries(windows: ['o'], posix: ['o']),
            store: AgentStoreSpec(homeDirectoryName: '.opaque'),
          ),
        );
        expect(agentSupportsChatView(opaque), isFalse);
      },
    );

    test('an agent spoken to over ACP has one, with no transcript file', () {
      // The server keeps its conversation as rows (ACP design, C3), so the
      // chat view is built without a store — asked of the adapter, never of
      // the id.
      const acp = DataOnlyAgentAdapter(
        AgentDescriptor(
          id: 'acp:custom',
          displayName: 'Custom ACP agent',
          binaries: AgentBinaries(windows: ['agent'], posix: ['agent']),
          acp: AcpLaunchSpec(arguments: ['--acp']),
        ),
      );
      expect(acp.transcripts?.buildsChatView ?? false, isFalse);
      expect(agentSupportsChatView(acp), isTrue);
      expect(defaultViewFor(acp), SessionView.chat);
      for (final id in [
        AgentIds.claudeAcp,
        AgentIds.codexAcp,
        AgentIds.geminiCli,
        AgentIds.grok,
      ]) {
        expect(
          agentSupportsChatView(registry.adapterFor(id)),
          isTrue,
          reason: id,
        );
      }
    });

    test('an unknown agent has none, and does not throw', () {
      expect(agentSupportsChatView(null), isFalse);
      expect(defaultViewFor(null), SessionView.terminal);
    });

    test('the default is chat where one can be built', () {
      expect(
        defaultViewFor(registry.adapterFor(AgentIds.claudeCode)),
        SessionView.chat,
      );
    });
  });

  test('the two views are renderings of one session, and toggle', () {
    // Nothing here starts or stops anything: `other` is the whole of the
    // switch, because both views are over the same PTY.
    expect(SessionView.chat.other, SessionView.terminal);
    expect(SessionView.terminal.other, SessionView.chat);
    expect(SessionView.chat.other.other, SessionView.chat);
  });

  test('the surface is where the process is, not how it is drawn', () {
    // Two enums because they answer two questions. Conflating them is what
    // would recreate "two kinds of session".
    expect(SessionSurface.values, [
      SessionSurface.pane,
      SessionSurface.external,
    ]);
    expect(SessionView.values, [SessionView.chat, SessionView.terminal]);
  });
}
