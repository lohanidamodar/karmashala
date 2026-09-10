import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/resume.dart';

import '../../support/fixtures.dart';

/// **Which rows may be offered for deletion, and which may never be.**
///
/// The state under test already had words before it had a feature —
/// `resumeMissingConversationMessage` describes it exactly: a session whose
/// agent takes a `--session-id` gets one of *our* ids at launch and the row
/// records it immediately, so the id is a promise about a conversation that
/// does not exist yet. A launch that failed, or a session nothing was ever said
/// in, leaves the promise unkept.
///
/// Everything here is the *free* half of finding those rows. No store is read;
/// the point of the split is that this decides, per row and in memory, whether
/// asking a store is even worth it.
void main() {
  final now = DateTime.utc(2026, 9, 4, 12);

  /// A row in exactly the shape `SessionLauncher` writes for Claude Code: the
  /// conversation id **is** the row id, because that is the id we handed the
  /// CLI.
  Session promised({
    String id = 's1',
    Duration age = const Duration(hours: 1),
    SessionSurface surface = SessionSurface.pane,
    SessionStatus status = SessionStatus.running,
    DateTime? archivedAt,
  }) => session(id: id, status: status).copyWith(
    externalSessionId: id,
    createdAt: now.subtract(age),
    surface: surface,
    archivedAt: archivedAt,
  );

  group('who ever made a promise', () {
    test('a row whose conversation id is its own id did', () {
      expect(
        promisedItsOwnConversation(promised(), agentAssignsSessionId: true),
        isTrue,
      );
    });

    test(
      'the null test the cheap version would have used cannot tell them apart',
      () {
        // The trap, pinned. Both rows below have a non-null external id, and
        // only one of them is a promise of ours — so `externalSessionId !=
        // null` is not a signal, which is why nothing in this feature uses it.
        final ours = promised(id: 's1');
        final theirs = promised(
          id: 's2',
        ).copyWith(externalSessionId: 'codex-chose-this');
        expect(ours.externalSessionId, isNotNull);
        expect(theirs.externalSessionId, isNotNull);
        expect(
          promisedItsOwnConversation(ours, agentAssignsSessionId: true),
          isTrue,
        );
        expect(
          promisedItsOwnConversation(theirs, agentAssignsSessionId: true),
          isFalse,
        );
      },
    );

    test('an agent that cannot be handed an id never promised anything', () {
      // Codex mints its own id and announces it afterwards, so an id on such a
      // row came *from* a store that had it. Not this state.
      expect(
        promisedItsOwnConversation(promised(), agentAssignsSessionId: false),
        isFalse,
      );
    });

    test('a row with no conversation id at all promised nothing', () {
      expect(
        promisedItsOwnConversation(
          session(id: 's1'),
          agentAssignsSessionId: true,
        ),
        isFalse,
      );
    });
  });

  group('screening', () {
    test('an ordinary unkept promise is a candidate', () {
      expect(
        screenSessionPromise(
          promised(),
          agentAssignsSessionId: true,
          hostedLive: false,
          now: now,
        ),
        PromiseScreening.candidate,
      );
    });

    test('a session we can see running is never offered, at any age', () {
      // Certain knowledge, and it outranks everything: we own the process.
      for (final age in const [
        Duration(seconds: 1),
        Duration(days: 30),
      ]) {
        expect(
          screenSessionPromise(
            promised(age: age),
            agentAssignsSessionId: true,
            hostedLive: true,
            now: now,
          ),
          PromiseScreening.hostedLive,
          reason: 'a live pane of ours is not a dead row at age $age',
        );
      }
    });

    test('a newly started session is never offered', () {
      // The case that would be data loss. Claude Code writes its transcript
      // when something is *said*, so a session opened seconds ago is genuinely
      // absent from the store and genuinely alive.
      expect(
        screenSessionPromise(
          promised(age: const Duration(seconds: 20)),
          agentAssignsSessionId: true,
          hostedLive: false,
          now: now,
        ),
        PromiseScreening.tooNew,
      );
    });

    test('the grace window is exclusive at its own boundary', () {
      expect(
        screenSessionPromise(
          promised(age: kUnkeptPromiseGrace),
          agentAssignsSessionId: true,
          hostedLive: false,
          now: now,
        ),
        PromiseScreening.candidate,
      );
      expect(
        screenSessionPromise(
          promised(age: kUnkeptPromiseGrace - const Duration(seconds: 1)),
          agentAssignsSessionId: true,
          hostedLive: false,
          now: now,
        ),
        PromiseScreening.tooNew,
      );
    });

    test('a session in a terminal we do not own is left alone', () {
      // We cannot see that process, so we cannot tell a dead promise from one
      // still pending in a window the user has open. Excluded, not guessed at.
      expect(
        screenSessionPromise(
          promised(surface: SessionSurface.external),
          agentAssignsSessionId: true,
          hostedLive: false,
          now: now,
        ),
        PromiseScreening.external,
      );
    });

    test('an archived session is left alone', () {
      expect(
        screenSessionPromise(
          promised(archivedAt: now),
          agentAssignsSessionId: true,
          hostedLive: false,
          now: now,
        ),
        PromiseScreening.archived,
      );
    });

    test('a row that never promised is not a candidate', () {
      expect(
        screenSessionPromise(
          session(id: 's1'),
          agentAssignsSessionId: true,
          hostedLive: false,
          now: now,
        ),
        PromiseScreening.neverPromised,
      );
    });

    test('a live pane outranks every other exclusion', () {
      // Order matters: a row that is archived *and* running must come back
      // `hostedLive`, because that is the fact that forbids touching it.
      expect(
        screenSessionPromise(
          promised(age: const Duration(seconds: 1), archivedAt: now),
          agentAssignsSessionId: true,
          hostedLive: true,
          now: now,
        ),
        PromiseScreening.hostedLive,
      );
    });
  });

  group('verdicts', () {
    test('only a store read to the end may make a row removable', () {
      expect(
        PromiseVerdict.of(ConversationPresence.absent).isRemovable,
        isTrue,
      );
      expect(
        PromiseVerdict.of(ConversationPresence.unknown).isRemovable,
        isFalse,
      );
      expect(
        PromiseVerdict.of(ConversationPresence.present).isRemovable,
        isFalse,
      );
    });

    test('unknown is a real answer and says so', () {
      expect(
        promiseVerdictNote(PromiseVerdict.unknown, 'Claude Code'),
        contains('could not check'),
      );
      expect(
        promiseVerdictNote(PromiseVerdict.unknown, 'Claude Code'),
        contains('left alone'),
      );
    });

    test('an absent verdict names whose store answered', () {
      expect(
        promiseVerdictNote(PromiseVerdict.unkept, 'Claude Code'),
        contains('Claude Code'),
      );
    });
  });

  group('the summary a user reads before acting', () {
    test('a reading that read no store claims nothing at all', () {
      final text = unkeptPromiseSummary(
        removable: 3,
        uncertain: 0,
        storesRead: 0,
      );
      expect(text, contains('has been checked'));
      expect(text, contains('Nothing will be removed'));
      expect(text, isNot(contains('3')));
    });

    test('it counts what will go', () {
      expect(
        unkeptPromiseSummary(removable: 4, uncertain: 0, storesRead: 1),
        contains('4 sessions'),
      );
      expect(
        unkeptPromiseSummary(removable: 1, uncertain: 0, storesRead: 1),
        contains('1 session '),
      );
    });

    test('it says out loud what it could not judge', () {
      final text = unkeptPromiseSummary(
        removable: 2,
        uncertain: 5,
        storesRead: 1,
      );
      expect(text, contains('2 sessions'));
      expect(text, contains('5 more could not be checked'));
    });

    test('none found is stated, not left blank', () {
      expect(
        unkeptPromiseSummary(removable: 0, uncertain: 0, storesRead: 2),
        contains('No session'),
      );
    });
  });
}
