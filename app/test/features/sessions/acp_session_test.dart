import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/sessions/application/acp_session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_view_providers.dart';
import 'package:karmashala_session/transcript.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **An ACP session is one whose installation's adapter declares `acp`** —
/// read off the adapter, never off the agent's id, so a custom agent added
/// from the registry is one too.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(
        id: 'acp',
        agentId: AgentIds.claudeAcp,
        path: r'C:\Users\me\.bin\claude-agent-acp.exe',
      ),
    );
    server.installationRows.insert(agentInstallation(id: 'pty'));
    db.server.sessionRows
      ..insert(session(id: 'via-acp', agentInstallationId: 'acp'))
      ..insert(session(id: 'via-pty', agentInstallationId: 'pty'));
  });

  test(
    'true for a built-in ACP agent, false for a PTY one or no row',
    () async {
      final container = ProviderContainer(overrides: [await server.override()]);
      addTearDown(container.dispose);

      expect(container.read(isAcpSessionProvider('via-acp')), isTrue);
      expect(container.read(isAcpSessionProvider('via-pty')), isFalse);
      expect(container.read(isAcpSessionProvider('nobody')), isFalse);
    },
  );

  test('answered through the adapter: a custom ACP agent counts', () async {
    // The registry a server composes from built-ins plus `acp_agents` rows.
    const custom = DataOnlyAgentAdapter(
      AgentDescriptor(
        id: 'acp:row-1',
        displayName: 'My agent',
        binaries: AgentBinaries(windows: ['my-agent'], posix: ['my-agent']),
        acp: AcpLaunchSpec(arguments: ['--acp']),
      ),
    );
    server.installationRows.insert(
      agentInstallation(id: 'custom', agentId: 'acp:row-1', path: r'C:\a.exe'),
    );
    db.server.sessionRows.insert(
      session(id: 'via-custom', agentInstallationId: 'custom'),
    );
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        agentRegistryProvider.overrideWithValue(const AgentRegistry([custom])),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(isAcpSessionProvider('via-custom')), isTrue);
    // Built-ins are not in this registry, so nothing is assumed from the id.
    expect(container.read(isAcpSessionProvider('via-acp')), isFalse);
  });

  test('an ACP session has a chat view with no store and no CLI id', () async {
    final container = ProviderContainer(overrides: [await server.override()]);
    addTearDown(container.dispose);

    final acp = container.read(sessionChatViewProvider('via-acp'));
    expect(acp.hasChatView, isTrue);
    expect(acp.evidence, ChatViewEvidence.unread);
    // The PTY row has no CLI id yet, so its reading is the gap it always was.
    final pty = container.read(sessionChatViewProvider('via-pty'));
    expect(pty.hasChatView, isFalse);
    expect(pty.evidence, ChatViewEvidence.noSessionRecord);
  });
}
