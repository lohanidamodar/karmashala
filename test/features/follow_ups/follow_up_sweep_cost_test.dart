import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/follow_ups/application/follow_up_providers.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// What one sweep costs, counted in database round trips rather than timed.
///
/// It matters because the bindings are synchronous: a sweep runs on the calling
/// isolate, so a query per ended session would put the whole history of the
/// workspace between a session-revision bump and the next frame. The number
/// below is therefore **constant in the size of the workspace** — a quiet sweep
/// asks the same questions of ten sessions and of a thousand.
///
/// The three things that could break that, and are guarded here:
///
/// * a `childrenOf` per session, to find out whether it was handed on — it is
///   read from the session list instead, in one pass;
/// * a "have I already raised this?" query per ended session — it is one read
///   of the whole table, kept in memory for the run;
/// * a verification read on the common path — a crash is a crash whatever it
///   verified, so only a *clean* finish pays for one.
void main() {
  for (final count in [10, 100, 1000]) {
    test('$count ended sessions: a quiet sweep is a constant few reads', () {
      final db = _CountingDatabase();
      addTearDown(db.close);
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
      AgentInstallationDao(db).insert(agentInstallation());
      final sessions = SessionDao(db);
      for (var i = 0; i < count; i++) {
        sessions.insert(session(id: 's$i', status: SessionStatus.failed));
      }

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
        ],
      );
      addTearDown(container.dispose);
      final service = container.read(followUpServiceProvider);

      // The first sweep raises one follow-up per session and pays for it. That
      // is the once-per-ending cost the feature exists for; it is the *repeat*
      // that has to be free.
      service.sweep(sessions.getAll());

      final rows = sessions.getAll();
      db.queries = 0;
      for (var pass = 0; pass < 5; pass++) {
        service.sweep(rows);
      }

      // One read of the open list per pass, and nothing else. Not one per
      // session, and not one per session per pass.
      expect(db.queries, 5, reason: '$count sessions');
    });
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
