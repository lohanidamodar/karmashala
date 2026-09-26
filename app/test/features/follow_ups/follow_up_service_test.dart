import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/follow_ups/application/follow_up_providers.dart';
import 'package:karmashala/src/features/follow_ups/application/follow_up_service.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/sessions/application/decision_recorder.dart';
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
import 'package:karmashala/src/features/sessions/application/session_providers.dart';

/// The service that turns "a session ended" into an offer — and, in the last
/// group, the thing it must never do.
void main() {
  late AppDatabase db;
  late Override data;
  late ProviderContainer container;
  late FakeDataServer server;
  late FakeSessionRows sessions;
  late FakeFollowUpRows followUps;

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
    server = FakeDataServer()..mirrorInto(db);
    server.environmentRows.upsert(windowsEnv());
    data = await server.override();
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    sessions = server.sessionRows;
    followUps = server.followUpRows;
    container = freshContainer();
  });
  tearDown(() => db.close());

  FollowUpService service() => container.read(followUpServiceProvider);

  void ended(String id, SessionStatus status) =>
      sessions.insert(session(id: id, status: status));

  void child(String id, {required String of, required SessionLink link}) =>
      sessions.insert(
        session(
          id: id,
          status: SessionStatus.running,
        ).copyWith(parentSessionId: of, parentLink: link),
      );

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

  /// What the app's writes left at the server: the follow-ups it raised or
  /// resolved, answered.
  Future<void> settle() => container.read(sessionsDataProvider).settled();

  /// One pass, and its raises answered by the server.
  Future<void> sweep() async {
    service().sweep(sessions.getAll());
    await settle();
  }

  group('the ending decides', () {
    test('a session that stopped in error is offered back', () async {
      ended('s1', SessionStatus.failed);
      await sweep();

      final raised = followUps.open().single;
      expect(raised.sessionId, 's1');
      expect(raised.reason, FollowUpReason.endedInFailure);
      expect(raised.ending, SessionEnding.failed);
    });

    test('a session the user stopped is left alone', () async {
      ended('s1', SessionStatus.cancelled);
      await sweep();
      expect(followUps.open(), isEmpty);
    });

    test('a session still running is not an ending', () async {
      ended('s1', SessionStatus.running);
      ended('s2', SessionStatus.idle);
      ended('s3', SessionStatus.created);
      await sweep();
      expect(followUps.open(), isEmpty);
    });

    test('a failure that was handed on is already carried forward', () async {
      ended('s1', SessionStatus.failed);
      child('s2', of: 's1', link: SessionLink.handoff);
      await sweep();
      expect(followUps.open(), isEmpty);
    });

    test('a fork counts as carrying the work forward too', () async {
      ended('s1', SessionStatus.failed);
      child('s2', of: 's1', link: SessionLink.fork);
      await sweep();
      expect(followUps.open(), isEmpty);
    });

    test('a session an agent merely spawned is not a handoff', () async {
      // `SessionLink.spawn` is delegation, not continuation: the parent's own
      // work is still the parent's.
      ended('s1', SessionStatus.failed);
      child('s2', of: 's1', link: SessionLink.spawn);
      await sweep();
      expect(followUps.open().single.reason, FollowUpReason.endedInFailure);
    });
  });

  group('what a clean finish left', () {
    test('nothing verified means nothing said', () async {
      ended('s1', SessionStatus.completed);
      await sweep();
      expect(followUps.open(), isEmpty);
    });

    test('a pass means nothing said', () async {
      ended('s1', SessionStatus.completed);
      run('v1', verdict: VerificationVerdict.pass);
      await sweep();
      expect(followUps.open(), isEmpty);
    });

    test('a check nobody finished is offered back, in its own words', () async {
      ended('s1', SessionStatus.completed);
      run('v1');
      await sweep();

      final raised = followUps.open().single;
      expect(raised.reason, FollowUpReason.verificationAbandoned);
      expect(raised.summary, contains('the login page still loads'));
    });

    test('a verdict that was not a pass is quoted, not paraphrased', () async {
      ended('s1', SessionStatus.completed);
      run(
        'v1',
        verdict: VerificationVerdict.fail,
        reason: 'the password field never gets focus',
      );
      await sweep();

      final raised = followUps.open().single;
      expect(raised.reason, FollowUpReason.verificationNotPassed);
      expect(raised.summary, contains('the login page still loads'));
      expect(raised.summary, contains('the password field never gets focus'));
    });

    test('another session\'s run is not this session\'s residue', () async {
      ended('s1', SessionStatus.completed);
      ended('s2', SessionStatus.running);
      run('v1', sessionId: 's2');
      await sweep();
      expect(followUps.open(), isEmpty);
    });
  });

  group('the words it carries', () {
    test('a crash quotes the last decision the session recorded', () async {
      ended('s1', SessionStatus.failed);
      await container
          .read(decisionRecorderProvider)
          .recordFromAgent(
            sessionId: 's1',
            kind: DecisionKind.constraintAccepted,
            summary: 'the isolate pool deadlocks on Windows',
          );
      await sweep();

      final raised = followUps.open().single;
      expect(raised.summary, contains('the isolate pool deadlocks on Windows'));
    });

    test(
      'a session that recorded nothing says "not recorded", not a guess',
      () async {
        // An empty decision record means nobody wrote anything down. It is not
        // evidence about the session, so nothing is invented to fill the line.
        ended('s1', SessionStatus.failed);
        await sweep();
        expect(followUps.open().single.summary, isNull);
      },
    );
  });

  group('it does not repeat itself', () {
    test('sweeping again raises nothing new', () async {
      ended('s1', SessionStatus.failed);
      await sweep();
      await sweep();
      await sweep();
      expect(followUps.open(), hasLength(1));
    });

    test('a dismissed follow-up stays dismissed', () async {
      // The row still says `failed` forever, so a sweep that only checked for
      // an *open* follow-up would raise the same notice again a second later —
      // the app overruling a dismissal.
      ended('s1', SessionStatus.failed);
      await sweep();
      service().dismiss(followUps.open().single);
      await sweep();

      expect(followUps.open(), isEmpty);
      expect(followUps.all().single.resolution, FollowUpResolution.dismissed);
    });

    test('a dismissal survives a restart', () async {
      ended('s1', SessionStatus.failed);
      await sweep();
      service().dismiss(followUps.open().single);
      await settle();

      // A new container, and a new client of the same server, is what the next
      // launch sees.
      data = await server.override();
      container = freshContainer();
      await sweep();
      expect(followUps.open(), isEmpty);
    });
  });

  group('it retires what has moved on', () {
    test(
      'a session handed on after the fact carries its follow-up with it',
      () async {
        ended('s1', SessionStatus.failed);
        await sweep();
        expect(followUps.open(), hasLength(1));

        child('s2', of: 's1', link: SessionLink.handoff);
        await sweep();

        expect(followUps.open(), isEmpty);
        expect(
          followUps.all().single.resolution,
          FollowUpResolution.carriedForward,
        );
      },
    );

    test('a deleted session leaves nothing to open', () async {
      ended('s1', SessionStatus.failed);
      await sweep();
      sessions.delete('s1');
      await sweep();

      expect(followUps.open(), isEmpty);
      expect(followUps.all().single.resolution, FollowUpResolution.sessionGone);
    });
  });

  group('what it must never do', () {
    test('noticing an ending starts nothing and changes nothing', () async {
      // The hazard this feature is one wrong line away from: an environment
      // that relaunches agents by itself. A sweep may read the workspace and
      // write to its own table; it may not touch a session row, and it may not
      // bring a session into existence.
      ended('s1', SessionStatus.failed);
      ended('s2', SessionStatus.completed);
      run('v1', sessionId: 's2');
      final before = {for (final s in sessions.getAll()) s.id: s.status};

      await sweep();
      await sweep();

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
