import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/follow_ups/domain/follow_up.dart';
import 'package:karmashala/src/features/follow_ups/domain/follow_up_policy.dart';
import 'package:karmashala/src/features/follow_ups/domain/session_ending.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/verification/domain/verification_run.dart';
import 'package:karmashala/src/features/verification/domain/verification_target.dart';
import 'package:flutter_test/flutter_test.dart';

/// The whole rule, with no database, no agent and no window — the shape
/// `detach_policy.dart` uses, and for the same reason: the interesting part of
/// this feature is the decision, so the decision is a pure function.
void main() {
  final t0 = DateTime.utc(2026, 9, 1, 10);

  VerificationRun run({
    String id = 'v1',
    VerificationVerdict? verdict,
    DateTime? finishedAt,
  }) => VerificationRun(
    id: id,
    title: 'the login page still loads',
    target: const VerificationTarget.browser('https://example.com'),
    startedAt: t0,
    finishedAt: finishedAt ?? (verdict == null ? null : t0),
    verdict: verdict,
    artifactDirectory: '/tmp/$id',
    sessionId: 's1',
  );

  group('what counts as an ending', () {
    test('a terminal row status is one; a live one is not', () {
      expect(endingOfStatus(SessionStatus.completed), SessionEnding.completed);
      expect(endingOfStatus(SessionStatus.failed), SessionEnding.failed);
      expect(endingOfStatus(SessionStatus.cancelled), SessionEnding.cancelled);
      expect(endingOfStatus(SessionStatus.running), isNull);
      expect(endingOfStatus(SessionStatus.idle), isNull);
      expect(endingOfStatus(SessionStatus.created), isNull);
    });

    test('an observed transition into failure is a crash', () {
      expect(
        endingOfTransition(
          from: AgentActivityStatus.working,
          to: AgentActivityStatus.failed,
        ),
        SessionEnding.failed,
      );
    });

    test('a first observation is no evidence anything just changed', () {
      // The same rule `AgentStatusTransition` states: `from == null` happens
      // for every live session on app start, and reading it as a crash would
      // mint a follow-up for every session that was already broken yesterday.
      expect(
        endingOfTransition(from: null, to: AgentActivityStatus.failed),
        isNull,
      );
    });

    test('a turn ending is not a session ending', () {
      // working -> idle is what the inbox already calls "finished". Treating it
      // as an ending would raise a follow-up on every turn of every session.
      expect(
        endingOfTransition(
          from: AgentActivityStatus.working,
          to: AgentActivityStatus.idle,
        ),
        isNull,
      );
    });

    test('losing sight of a session is its own answer, not a failure', () {
      expect(
        endingOfTransition(
          from: AgentActivityStatus.working,
          to: AgentActivityStatus.unknown,
        ),
        SessionEnding.lostTrack,
      );
    });

    test('a status repeating itself is not a transition', () {
      expect(
        endingOfTransition(
          from: AgentActivityStatus.failed,
          to: AgentActivityStatus.failed,
        ),
        isNull,
      );
    });
  });

  group('what a session left behind', () {
    test('no runs at all is no residue — an empty record is not evidence', () {
      expect(verificationResidueIn(const []), VerificationResidue.none);
    });

    test('a pass leaves nothing to come back to', () {
      expect(
        verificationResidueIn([run(verdict: VerificationVerdict.pass)]),
        VerificationResidue.none,
      );
    });

    test('a fail and an inconclusive both leave a verdict to answer', () {
      expect(
        verificationResidueIn([run(verdict: VerificationVerdict.fail)]),
        VerificationResidue.notPassed,
      );
      expect(
        verificationResidueIn([run(verdict: VerificationVerdict.inconclusive)]),
        VerificationResidue.notPassed,
      );
    });

    test('a run nothing ever finished was abandoned', () {
      expect(verificationResidueIn([run()]), VerificationResidue.abandoned);
    });

    test('a stated failure outranks an unfinished check', () {
      expect(
        verificationResidueIn([
          run(id: 'v1'),
          run(id: 'v2', verdict: VerificationVerdict.fail),
        ]),
        VerificationResidue.notPassed,
      );
    });
  });

  group('the four endings get four answers', () {
    test('a crash always leaves a follow-up', () {
      expect(
        followUpFor(ending: SessionEnding.failed),
        FollowUpReason.endedInFailure,
      );
    });

    test('a crash is a crash whatever it verified', () {
      expect(
        followUpFor(
          ending: SessionEnding.failed,
          verification: VerificationResidue.notPassed,
        ),
        FollowUpReason.endedInFailure,
      );
    });

    test('a handoff is already the follow-up, so nothing is raised', () {
      for (final residue in VerificationResidue.values) {
        expect(
          followUpFor(ending: SessionEnding.handedOff, verification: residue),
          isNull,
          reason: residue.name,
        );
      }
    });

    test('the user ending it on purpose is answered with silence', () {
      for (final residue in VerificationResidue.values) {
        expect(
          followUpFor(ending: SessionEnding.cancelled, verification: residue),
          isNull,
          reason: residue.name,
        );
      }
    });

    test('losing track raises nothing — it is not an ending', () {
      for (final residue in VerificationResidue.values) {
        expect(
          followUpFor(ending: SessionEnding.lostTrack, verification: residue),
          isNull,
          reason: residue.name,
        );
      }
    });

    test('a clean finish that left nothing open is a finish', () {
      expect(followUpFor(ending: SessionEnding.completed), isNull);
    });

    test('a clean finish over an unanswered verdict is not', () {
      expect(
        followUpFor(
          ending: SessionEnding.completed,
          verification: VerificationResidue.notPassed,
        ),
        FollowUpReason.verificationNotPassed,
      );
      expect(
        followUpFor(
          ending: SessionEnding.completed,
          verification: VerificationResidue.abandoned,
        ),
        FollowUpReason.verificationAbandoned,
      );
    });
  });
}
