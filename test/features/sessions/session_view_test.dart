import 'package:chitragupta/src/features/agents/domain/agent_descriptor.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/sessions/domain/session_launch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final registry = AgentRegistry.builtIn;

  group('a chat view is a capability of the agent, not a second runtime', () {
    test('an agent whose transcript we can read has one', () {
      expect(agentSupportsChatView(registry.byId(AgentIds.claudeCode)), isTrue);
      expect(agentSupportsChatView(registry.byId(AgentIds.codex)), isTrue);
    });

    test('Antigravity has a protocol adapter and no chat view', () {
      // The distinction that matters: the capability is "can we read this
      // agent's own record of the conversation", not "did someone write an
      // AgentAdapter subclass". Antigravity has the second and not the first,
      // and correctly gets the terminal only.
      final antigravity = registry.byId(AgentIds.antigravity)!;
      expect(antigravity.kind, isNotNull);
      expect(agentSupportsChatView(antigravity), isFalse);
      expect(defaultViewFor(antigravity), SessionView.terminal);
    });

    test('an agent that exists only as registry data has none', () {
      const rover = AgentDescriptor(
        id: 'roverCli',
        displayName: 'Rover',
        binaries: AgentBinaries(windows: ['rover'], posix: ['rover']),
      );
      expect(agentSupportsChatView(rover), isFalse);
      expect(defaultViewFor(rover), SessionView.terminal);
    });

    test('an agent declaring an unreadable store has none', () {
      const opaque = AgentDescriptor(
        id: 'opaque',
        displayName: 'Opaque',
        binaries: AgentBinaries(windows: ['o'], posix: ['o']),
        store: AgentStoreSpec(
          homeDirectoryName: '.opaque',
          format: AgentStoreFormat.none,
        ),
      );
      expect(agentSupportsChatView(opaque), isFalse);
    });

    test('an unknown agent has none, and does not throw', () {
      expect(agentSupportsChatView(null), isFalse);
      expect(defaultViewFor(null), SessionView.terminal);
    });

    test('the default is chat where one can be built', () {
      expect(
        defaultViewFor(registry.byId(AgentIds.claudeCode)),
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
