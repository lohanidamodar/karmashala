import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/follow_ups/application/follow_up_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';

/// What one sweep costs, counted in round trips rather than timed — to the
/// server (the follow-ups and sessions are this app's copy of its rows since
/// slice 1c) and to the database (what is left there: verification).
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
/// * a "have I already raised this?" request per ended session — it is one
///   read of the copy, kept in memory for the run;
/// * a verification read on the common path — a crash is a crash whatever it
///   verified, so only a *clean* finish pays for one.
void main() {
  for (final count in [10, 100, 1000]) {
    test(
      '$count ended sessions: a quiet sweep is a constant few reads',
      () async {
        final db = CountingMachine();
        final server = FakeDataServer()..runsOn(db);
        server.environmentRows.upsert(windowsEnv());
        server.projectRows.insert(project());
        server.repositoryRows.insert(repository());
        server.installationRows.insert(agentInstallation());
        final sessions = server.sessionRows;
        for (var i = 0; i < count; i++) {
          sessions.insert(session(id: 's$i', status: SessionStatus.failed));
        }

        final container = ProviderContainer(
          overrides: [
            await server.override(),
            clockProvider.overrideWithValue(FixedClock(testTime)),
          ],
        );
        addTearDown(container.dispose);
        final service = container.read(followUpServiceProvider);

        // The first sweep raises one follow-up per session and pays for it. That
        // is the once-per-ending cost the feature exists for; it is the *repeat*
        // that has to be free.
        service.sweep(sessions.getAll());
        await container.read(sessionsDataProvider).settled();
        expect(server.followUpRows.open(), hasLength(count.clamp(0, 200)));

        final rows = sessions.getAll();
        db.reset();
        final asked = server.requests.length;
        for (var pass = 0; pass < 5; pass++) {
          service.sweep(rows);
        }

        // A quiet pass reads the open list from the copy and asks nobody
        // anything: not one request per session, not one query per pass.
        expect(
          server.requests.length - asked,
          0,
          reason: '$count sessions: ${server.requests.skip(asked)}',
        );
        expect(db.count, 0, reason: '$count sessions');
      },
    );
  }
}
