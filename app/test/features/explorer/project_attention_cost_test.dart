import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala/src/features/explorer/application/session_diff_stat.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../../support/fakes.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/workspace_mirror.dart';

/// What one attention-inbox publication costs across project headers.
///
/// A notification belongs to one session in one project. The count below is
/// therefore project summaries recomputed, not elapsed time: the useful curve
/// is one affected header at N=1/10/100, not a machine-dependent duration.
void main() {
  for (final count in [1, 10, 100]) {
    test(
      '$count projects: one waiting session recomputes one summary',
      () async {
        final db = _CountingDatabase();
        addTearDown(db.close);
        final server = FakeDataServer()..mirrorInto(db);
        ExecutionEnvironmentDao(db).upsert(windowsEnv());
        AgentInstallationDao(db).insert(agentInstallation());
        for (var i = 0; i < count; i++) {
          server.projectRows.insert(
            project(id: 'p$i', name: 'Project $i', path: 'C:\\workspace\\p$i'),
          );
          server.repositoryRows.insert(
            repository(
              id: 'r$i',
              projectId: 'p$i',
              name: 'repo$i',
              path: 'C:\\workspace\\p$i',
            ),
          );
          SessionDao(db).insert(
            Session(
              id: 's$i',
              repositoryId: 'r$i',
              agentInstallationId: 'a1',
              title: 'Session $i',
              useWorktree: false,
              status: SessionStatus.running,
              createdAt: testTime,
            ),
          );
        }

        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            await server.override(),
            clockProvider.overrideWithValue(FixedClock(testTime)),
          ],
        );
        addTearDown(container.dispose);
        final subscriptions = [
          for (var i = 0; i < count; i++)
            container.listen(projectSummaryProvider('p$i'), (_, _) {}),
        ];
        addTearDown(() {
          for (final subscription in subscriptions) {
            subscription.close();
          }
        });
        db.queries = 0;

        const watched = WatchedSession(
          key: AgentSessionKey('claudeCode', 'external-0'),
          label: 'Session 0',
          openId: 's0',
          imported: false,
        );
        container
            .read(attentionInboxProvider.notifier)
            .apply(
              InboxUpdate(
                watched: {watched.key},
                waiting: [
                  SessionAttention(
                    session: watched,
                    kind: AttentionKind.needsInput,
                  ),
                ],
              ),
            );
        await container.pump();

        // ignore: avoid_print
        print('PROJECT-ATTENTION-COST projects=$count queries=${db.queries}');
        // The two session counts. Its repositories are not re-read: a waiting
        // session is not a repository fact (`projectRepositoriesProvider`).
        expect(
          db.queries,
          2,
          reason: 'one project changed, so unrelated summaries must not query',
        );
      },
    );
  }
}

class _CountingDatabase extends AppDatabase {
  _CountingDatabase() : super(sqlite3.openInMemory());

  int queries = 0;

  @override
  List<Map<String, Object?>> query(
    String sql, [
    List<Object?> params = const [],
  ]) {
    queries++;
    return super.query(sql, params);
  }
}
