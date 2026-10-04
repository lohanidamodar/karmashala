import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_signals.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_subagents_providers.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

/// The status line's count: a session's child sessions, read from rows and
/// statuses the app already holds, and how many of them are working.
void main() {
  Session child(
    String id, {
    SessionStatus status = SessionStatus.running,
    DateTime? archivedAt,
    String parent = 's1',
  }) => Session(
    id: id,
    repositoryId: 'r1',
    agentInstallationId: 'a1',
    title: 'Child $id',
    useWorktree: false,
    status: status,
    createdAt: testTime,
    parentSessionId: parent,
    parentLink: SessionLink.spawn,
    archivedAt: archivedAt,
  );

  test('counts children not archived, and the ones working', () async {
    final server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(
            AgentStatusReport(
              agentId: AgentIds.claudeCode,
              sessionId: id,
              status: id == 'c1'
                  ? AgentActivityStatus.working
                  : AgentActivityStatus.idle,
              observedAt: testTime,
              source: AgentStatusSource.none,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final rows = container.read(sessionsDataProvider)
      ..insert(session(status: SessionStatus.running));
    final count = container.listen(sessionChildCountProvider('s1'), (_, _) {});
    expect(count.read(), (count: 0, running: 0));

    rows
      ..insert(child('c1'))
      ..insert(child('c2'))
      ..insert(child('c3', status: SessionStatus.cancelled))
      ..insert(child('gone', archivedAt: testTime))
      ..insert(child('other', parent: 's9'));
    // A row's writer announces it; this test is that writer.
    container.read(sessionsRevisionProvider.notifier).bump();
    await pumpEventQueue();
    expect(count.read(), (count: 3, running: 1));
  });
}
