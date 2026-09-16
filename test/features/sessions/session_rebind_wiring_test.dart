import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_status_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/session_adoption_service.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_rebind_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **The row a `/clear` left behind.**
///
/// Measured on the owner's machine 2026-09-13: the pane titled `karmashala-2`
/// was bound to a conversation last written two and a half hours earlier, and
/// the one it was really on had never been seen — so the session read as
/// finished while its agent worked. Nothing noticed, because adoption skips
/// any pane the app launched itself.
void main() {
  late AppDatabase db;
  late SessionDao sessions;
  late AgentHookReports reports;

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    sessions = SessionDao(db);
    reports = AgentHookReports();
  });

  tearDown(() => db.close());

  /// A row in a pane the app launched, on conversation `cli-<id>`.
  void launched(String id, {required String paneId}) {
    sessions.insert(session(id: id, status: SessionStatus.running));
    sessions.updateExternalSessionId(id, 'cli-$id');
    sessions.updatePaneId(id, paneId);
  }

  void heardFrom(String conversationId, DateTime at) => reports.record(
    AgentStatusReport(
      agentId: AgentIds.claudeCode,
      sessionId: conversationId,
      status: AgentActivityStatus.working,
      source: AgentStatusSource.hook,
      observedAt: at,
    ),
  );

  ProviderContainer containerWith(List<String> livePaneIds) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        agentHookReportsProvider.overrideWithValue(reports),
        adoptablePanesProvider.overrideWithValue(
          () => [
            for (final paneId in livePaneIds)
              AdoptablePane(
                paneId: paneId,
                workingDirectory: r'C:\src\demo\app',
                isLive: true,
                hostsLaunchedSession: true,
              ),
          ],
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  String? rebind(ProviderContainer container, String conversationId) =>
      rebindSessionFromHook(
        container,
        agentId: AgentIds.claudeCode,
        conversationId: conversationId,
        body: jsonEncode({
          'session_id': conversationId,
          'cwd': r'C:\src\demo\app',
        }),
      );

  test('a hook from an unknown conversation re-points the quiet pane', () {
    launched('s1', paneId: 'pane-1');
    final container = containerWith(['pane-1']);

    expect(rebind(container, 'cli-new'), 's1');
    // The row keeps its identity; only the conversation it names changed.
    expect(sessions.getById('s1')!.externalSessionId, 'cli-new');
    expect(sessions.getById('s1')!.paneId, 'pane-1');
    expect(sessions.getById('s1')!.title, 'Work');
  });

  test('a pane still reporting keeps its conversation', () {
    launched('s1', paneId: 'pane-1');
    heardFrom('cli-s1', testTime);
    final container = containerWith(['pane-1']);

    expect(rebind(container, 'cli-new'), isNull);
    expect(sessions.getById('s1')!.externalSessionId, 'cli-s1');
  });

  test('a conversation some row already holds is left alone', () {
    launched('s1', paneId: 'pane-1');
    launched('s2', paneId: 'pane-2');
    final container = containerWith(['pane-1', 'pane-2']);

    expect(rebind(container, 'cli-s2'), isNull);
    expect(sessions.getById('s1')!.externalSessionId, 'cli-s1');
  });

  test('two quiet panes are a coin toss, and nothing is written', () {
    launched('s1', paneId: 'pane-1');
    launched('s2', paneId: 'pane-2');
    final container = containerWith(['pane-1', 'pane-2']);

    expect(rebind(container, 'cli-new'), isNull);
    expect(sessions.getById('s1')!.externalSessionId, 'cli-s1');
    expect(sessions.getById('s2')!.externalSessionId, 'cli-s2');
  });

  test('one pane still reporting leaves the other unambiguous', () {
    launched('s1', paneId: 'pane-1');
    launched('s2', paneId: 'pane-2');
    heardFrom('cli-s1', testTime);
    final container = containerWith(['pane-1', 'pane-2']);

    expect(rebind(container, 'cli-new'), 's2');
  });

  test('a pane with no live session of ours is nothing to re-point', () {
    launched('s1', paneId: 'pane-1');
    final container = containerWith(const []);

    expect(rebind(container, 'cli-new'), isNull);
  });

  test('the same unknown conversation is not re-examined every callback', () {
    launched('s1', paneId: 'pane-1');
    launched('s2', paneId: 'pane-2');
    final container = containerWith(['pane-1', 'pane-2']);

    // Refused: two quiet panes. The second callback arrives a moment later and
    // must cost a map lookup, not another pane list and another query.
    expect(rebind(container, 'cli-new'), isNull);
    heardFrom('cli-s1', testTime);
    expect(rebind(container, 'cli-new'), isNull);
  });
}
