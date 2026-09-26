import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/follow_ups/application/follow_up_providers.dart';
import 'package:karmashala/src/features/follow_ups/application/follow_up_service.dart';
import 'package:karmashala/src/features/follow_ups/data/follow_up_dao.dart';
import 'package:karmashala/src/features/follow_ups/domain/follow_up.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/sessions/application/decision_recorder.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_verification/store.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';

/// The service that turns "a session ended" into an offer — and, in the last
/// group, the thing it must never do.
void main() {
  late AppDatabase db;
  late Override data;
  late ProviderContainer container;
  late SessionDao sessions;
  late FollowUpDao followUps;

  ProviderContainer freshContainer() {
    final made = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        data,
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    addTearDown(made.dispose);
    return made;
  }

  setUp(() async {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    final server = FakeDataServer()..mirrorInto(db);
    data = await server.override();
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    sessions = SessionDao(db);
    followUps = FollowUpDao(db);
    container = freshContainer();
  });
  tearDown(() => db.close());

  FollowUpService service() => container.read(followUpServiceProvider);

  void ended(String id, SessionStatus status) =>
      sessions.insert(session(id: id, status: status));

  void child(String id, {required String of, required SessionLink link}) {
    sessions.insert(session(id: id, status: SessionStatus.running));
    db.execute(
      'UPDATE sessions SET parent_session_id = ?, parent_link_kind = ? '
      'WHERE id = ?;',
      [of, link.name, id],
    );
  }

  void run(
    String id, {
    String sessionId = 's1',
    VerificationVerdict? verdict,
    String? reason,
  }) {
    VerificationDao(db).insertRun(
      VerificationRun(
        id: id,
        title: 'the login page still loads',
        target: const VerificationTarget.browser('https://example.com'),
        startedAt: testTime,
        artifactDirectory: 'C:/art/$id',
        sessionId: sessionId,
      ),
    );
    if (verdict != null) {
      VerificationDao(
        db,
      ).finishRun(id, verdict: verdict, reason: reason, finishedAt: testTime);
    }
  }

  void sweep() => service().sweep(sessions.getAll());

  group('the ending decides', () {
    test('a session that stopped in error is offered back', () {
      ended('s1', SessionStatus.failed);
      sweep();

      final raised = followUps.open().single;
      expect(raised.sessionId, 's1');
      expect(raised.reason, FollowUpReason.endedInFailure);
      expect(raised.ending, SessionEnding.failed);
    });

    test('a session the user stopped is left alone', () {
      ended('s1', SessionStatus.cancelled);
      sweep();
      expect(followUps.open(), isEmpty);
    });

    test('a session still running is not an ending', () {
      ended('s1', SessionStatus.running);
      ended('s2', SessionStatus.idle);
      ended('s3', SessionStatus.created);
      sweep();
      expect(followUps.open(), isEmpty);
    });

    test('a failure that was handed on is already carried forward', () {
      ended('s1', SessionStatus.failed);
      child('s2', of: 's1', link: SessionLink.handoff);
      sweep();
      expect(followUps.open(), isEmpty);
    });

    test('a fork counts as carrying the work forward too', () {
      ended('s1', SessionStatus.failed);
      child('s2', of: 's1', link: SessionLink.fork);
      sweep();
      expect(followUps.open(), isEmpty);
    });

    test('a session an agent merely spawned is not a handoff', () {
      // `SessionLink.spawn` is delegation, not continuation: the parent's own
      // work is still the parent's.
      ended('s1', SessionStatus.failed);
      child('s2', of: 's1', link: SessionLink.spawn);
      sweep();
      expect(followUps.open().single.reason, FollowUpReason.endedInFailure);
    });
  });

  group('what a clean finish left', () {
    test('nothing verified means nothing said', () {
      ended('s1', SessionStatus.completed);
      sweep();
      expect(followUps.open(), isEmpty);
    });

    test('a pass means nothing said', () {
      ended('s1', SessionStatus.completed);
      run('v1', verdict: VerificationVerdict.pass);
      sweep();
      expect(followUps.open(), isEmpty);
    });

    test('a check nobody finished is offered back, in its own words', () {
      ended('s1', SessionStatus.completed);
      run('v1');
      sweep();

      final raised = followUps.open().single;
      expect(raised.reason, FollowUpReason.verificationAbandoned);
      expect(raised.summary, contains('the login page still loads'));
    });

    test('a verdict that was not a pass is quoted, not paraphrased', () {
      ended('s1', SessionStatus.completed);
      run(
        'v1',
        verdict: VerificationVerdict.fail,
        reason: 'the password field never gets focus',
      );
      sweep();

      final raised = followUps.open().single;
      expect(raised.reason, FollowUpReason.verificationNotPassed);
      expect(raised.summary, contains('the login page still loads'));
      expect(raised.summary, contains('the password field never gets focus'));
    });

    test('another session\'s run is not this session\'s residue', () {
      ended('s1', SessionStatus.completed);
      ended('s2', SessionStatus.running);
      run('v1', sessionId: 's2');
      sweep();
      expect(followUps.open(), isEmpty);
    });
  });

  group('the words it carries', () {
    test('a crash quotes the last decision the session recorded', () {
      ended('s1', SessionStatus.failed);
      container
          .read(decisionRecorderProvider)
          .recordFromAgent(
            sessionId: 's1',
            kind: DecisionKind.constraintAccepted,
            summary: 'the isolate pool deadlocks on Windows',
          );
      sweep();

      final raised = followUps.open().single;
      expect(raised.summary, contains('the isolate pool deadlocks on Windows'));
    });

    test(
      'a session that recorded nothing says "not recorded", not a guess',
      () {
        // An empty decision record means nobody wrote anything down. It is not
        // evidence about the session, so nothing is invented to fill the line.
        ended('s1', SessionStatus.failed);
        sweep();
        expect(followUps.open().single.summary, isNull);
      },
    );
  });

  group('it does not repeat itself', () {
    test('sweeping again raises nothing new', () {
      ended('s1', SessionStatus.failed);
      sweep();
      sweep();
      sweep();
      expect(followUps.open(), hasLength(1));
    });

    test('a dismissed follow-up stays dismissed', () {
      // The row still says `failed` forever, so a sweep that only checked for
      // an *open* follow-up would raise the same notice again a second later —
      // the app overruling a dismissal.
      ended('s1', SessionStatus.failed);
      sweep();
      service().dismiss(followUps.open().single);
      sweep();

      expect(followUps.open(), isEmpty);
      expect(db.query('SELECT resolution FROM session_follow_ups;').single, {
        'resolution': 'dismissed',
      });
    });

    test('a dismissal survives a restart', () {
      ended('s1', SessionStatus.failed);
      sweep();
      service().dismiss(followUps.open().single);

      // A new container over the same database is what the next launch sees.
      container = freshContainer();
      sweep();
      expect(followUps.open(), isEmpty);
    });
  });

  group('it retires what has moved on', () {
    test(
      'a session handed on after the fact carries its follow-up with it',
      () {
        ended('s1', SessionStatus.failed);
        sweep();
        expect(followUps.open(), hasLength(1));

        child('s2', of: 's1', link: SessionLink.handoff);
        sweep();

        expect(followUps.open(), isEmpty);
        expect(db.query('SELECT resolution FROM session_follow_ups;').single, {
          'resolution': 'carriedForward',
        });
      },
    );

    test('a deleted session leaves nothing to open', () {
      ended('s1', SessionStatus.failed);
      sweep();
      sessions.delete('s1');
      sweep();

      expect(followUps.open(), isEmpty);
      expect(db.query('SELECT resolution FROM session_follow_ups;').single, {
        'resolution': 'sessionGone',
      });
    });
  });

  group('what it must never do', () {
    test('noticing an ending starts nothing and changes nothing', () {
      // The hazard this feature is one wrong line away from: an environment
      // that relaunches agents by itself. A sweep may read the workspace and
      // write to its own table; it may not touch a session row, and it may not
      // bring a session into existence.
      ended('s1', SessionStatus.failed);
      ended('s2', SessionStatus.completed);
      run('v1', sessionId: 's2');
      final before = {for (final s in sessions.getAll()) s.id: s.status};

      sweep();
      sweep();

      expect({for (final s in sessions.getAll()) s.id: s.status}, before);
      // Two follow-ups raised, and not one process with them.
      expect(followUps.open(), hasLength(2));
    });

    test('a session that no longer resolves is answered with silence', () {
      // Not an exception, and certainly not a launch: the same silence every
      // other action in this app gives for a session that has gone.
      expect(
        () => service().notice(
          sessionId: 'never-existed',
          ending: SessionEnding.failed,
        ),
        returnsNormally,
      );
      expect(followUps.open(), isEmpty);
    });
  });
}
