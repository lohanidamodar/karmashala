import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/domain/session_rebind.dart';

final _now = DateTime.utc(2026, 9, 13, 17, 30);

void main() {
  group('sessionToRebind', () {
    test('the pane whose conversation went quiet takes the new one', () {
      // The owner's machine, 2026-09-13: three Claude panes, two of them
      // reporting hooks all the time, and `karmashala-2` silent since it was
      // cleared two and a half hours earlier. The other two have reported
      // since the unknown conversation appeared, so both are alive beside it.
      final chosen = sessionToRebind(
        panes: [
          BoundPane(
            sessionId: 'karmashala',
            conversationId: '8a817d98',
            lastHeardFrom: _now.subtract(const Duration(seconds: 4)),
          ),
          BoundPane(
            sessionId: 'karmashala-2',
            conversationId: '5f78c5f2',
            lastHeardFrom: _now.subtract(const Duration(hours: 2, minutes: 25)),
          ),
          BoundPane(
            sessionId: 'content-pipeline',
            conversationId: '707e40fb',
            lastHeardFrom: _now.subtract(const Duration(seconds: 30)),
          ),
        ],
        now: _now,
        firstHeardAt: _now.subtract(const Duration(minutes: 1)),
      );

      expect(chosen, 'karmashala-2');
    });

    test('a pane that has never reported counts as quiet, not as fresh', () {
      final chosen = sessionToRebind(
        panes: [
          BoundPane(sessionId: 'busy', conversationId: 'a', lastHeardFrom: _now),
          const BoundPane(sessionId: 'unheard', conversationId: 'b'),
        ],
        now: _now,
        firstHeardAt: _now.subtract(const Duration(seconds: 10)),
      );

      expect(chosen, 'unheard');
    });

    test('two quiet panes are a coin toss, so nothing is re-pointed', () {
      final chosen = sessionToRebind(
        panes: const [
          BoundPane(sessionId: 'one', conversationId: 'a'),
          BoundPane(sessionId: 'two', conversationId: 'b'),
        ],
        now: _now,
      );

      expect(chosen, isNull);
    });

    test('the directory breaks a tie between two quiet panes', () {
      final chosen = sessionToRebind(
        panes: const [
          BoundPane(sessionId: 'one', conversationId: 'a'),
          BoundPane(sessionId: 'two', conversationId: 'b', startedHere: true),
        ],
        now: _now,
      );

      expect(chosen, 'two');
    });

    test('a directory that matches nothing is not evidence against a pane', () {
      // An agent's live directory moves during a session — this one is two
      // folders below where it started — so no match must not refuse the pane.
      final chosen = sessionToRebind(
        panes: const [BoundPane(sessionId: 'only', conversationId: 'a')],
        now: _now,
      );

      expect(chosen, 'only');
    });

    test('every pane still reporting means the hook is somebody else', () {
      final chosen = sessionToRebind(
        panes: [
          BoundPane(
            sessionId: 'one',
            conversationId: 'a',
            lastHeardFrom: _now.subtract(const Duration(seconds: 1)),
          ),
        ],
        now: _now,
      );

      expect(chosen, isNull);
    });

    test('no panes at all is nothing to re-point', () {
      expect(sessionToRebind(panes: const [], now: _now), isNull);
    });

    test('a busy pane in the hook\'s own folder keeps a stranger from taking '
        'it', () {
      // 2026-09-20, the owner's machine: a session that had been building for
      // longer than the quiet window was handed a conversation from a project
      // it had never been in, because the pane that folder *did* have was busy
      // and so was never a candidate. Its own conversation was orphaned by the
      // move, and the next hook for that one took another row.
      final chosen = sessionToRebind(
        panes: [
          const BoundPane(sessionId: 'building', conversationId: 'a'),
          BoundPane(
            sessionId: 'in-that-folder',
            conversationId: 'b',
            startedHere: true,
            lastHeardFrom: _now.subtract(const Duration(seconds: 2)),
          ),
        ],
        now: _now,
      );

      expect(chosen, isNull);
    });

    test('and still does once that pane is plainly alive beside it', () {
      final chosen = sessionToRebind(
        panes: [
          const BoundPane(sessionId: 'building', conversationId: 'a'),
          BoundPane(
            sessionId: 'in-that-folder',
            conversationId: 'b',
            startedHere: true,
            lastHeardFrom: _now.subtract(const Duration(seconds: 2)),
          ),
        ],
        now: _now,
        firstHeardAt: _now.subtract(const Duration(seconds: 30)),
      );

      expect(chosen, isNull);
    });

    test('a quiet pane in the hook\'s own folder still takes it', () {
      final chosen = sessionToRebind(
        panes: [
          const BoundPane(sessionId: 'elsewhere', conversationId: 'a'),
          const BoundPane(
            sessionId: 'there',
            conversationId: 'b',
            startedHere: true,
          ),
        ],
        now: _now,
      );

      expect(chosen, 'there');
    });

    test('an ended conversation in another folder does not beat the hook\'s '
        'own folder', () {
      final chosen = sessionToRebind(
        panes: [
          const BoundPane(
            sessionId: 'elsewhere',
            conversationId: 'a',
            ended: true,
          ),
          const BoundPane(
            sessionId: 'there',
            conversationId: 'b',
            startedHere: true,
          ),
        ],
        now: _now,
      );

      expect(chosen, 'there');
    });

    test('two ended conversations are still a coin toss', () {
      final chosen = sessionToRebind(
        panes: const [
          BoundPane(sessionId: 'one', conversationId: 'a', ended: true),
          BoundPane(sessionId: 'two', conversationId: 'b', ended: true),
        ],
        now: _now,
      );

      expect(chosen, isNull);
    });
  });

  group('a /clear in one of two panes in the same folder (2026-09-21)', () {
    // The owner's machine: two Claude panes in `appwrite-ai-workdir`, both
    // started at the project root. "Free tier" was working until 14:31:11 and
    // then /clear'ed; a new conversation reported from 14:31:23. "analytics"
    // had been quiet since 14:16:26. The old rule excluded Free tier for
    // having been active and handed its conversation to analytics.
    final firstHeard = DateTime.utc(2026, 9, 21, 14, 31, 23);

    List<BoundPane> panes({required bool freeTierEnded}) => [
      BoundPane(
        sessionId: 'e8b49ed3',
        conversationId: 'e8b49ed3',
        startedHere: true,
        lastHeardFrom: DateTime.utc(2026, 9, 21, 14, 31, 11),
        ended: freeTierEnded,
      ),
      BoundPane(
        sessionId: 'f3976069',
        conversationId: 'f3976069',
        startedHere: true,
        lastHeardFrom: DateTime.utc(2026, 9, 21, 14, 16, 26),
      ),
    ];

    test('the pane whose conversation just ended takes the new one', () {
      final chosen = sessionToRebind(
        panes: panes(freeTierEnded: true),
        now: firstHeard,
        firstHeardAt: firstHeard,
      );

      expect(chosen, 'e8b49ed3');
    });

    test('without the ending it is unknowable, and the idle pane never takes '
        'it', () {
      final chosen = sessionToRebind(
        panes: panes(freeTierEnded: false),
        now: firstHeard,
        firstHeardAt: firstHeard,
      );

      expect(chosen, isNull);
    });

    test('and once both have been silent a while it is still a coin toss', () {
      final chosen = sessionToRebind(
        panes: panes(freeTierEnded: false),
        now: firstHeard.add(const Duration(minutes: 6)),
        firstHeardAt: firstHeard,
      );

      expect(chosen, isNull);
    });

    test('the idle pane is chosen only once the other is alive beside the new '
        'conversation', () {
      final chosen = sessionToRebind(
        panes: [
          BoundPane(
            sessionId: 'e8b49ed3',
            conversationId: 'e8b49ed3',
            startedHere: true,
            lastHeardFrom: firstHeard.add(const Duration(seconds: 8)),
          ),
          panes(freeTierEnded: false).last,
        ],
        now: firstHeard.add(const Duration(seconds: 10)),
        firstHeardAt: firstHeard,
      );

      expect(chosen, 'f3976069');
    });
  });

  group('the pane names itself', () {
    final firstHeard = DateTime.utc(2026, 9, 21, 14, 31, 23);

    test('its row takes the conversation once its own has ended, whatever '
        'the others look like', () {
      final chosen = sessionToRebind(
        panes: [
          BoundPane(
            sessionId: 'e8b49ed3',
            conversationId: 'e8b49ed3',
            lastHeardFrom: firstHeard.subtract(const Duration(seconds: 12)),
            ended: true,
          ),
          const BoundPane(
            sessionId: 'f3976069',
            conversationId: 'f3976069',
            startedHere: true,
          ),
        ],
        now: firstHeard,
        firstHeardAt: firstHeard,
        claimedBy: 'e8b49ed3',
      );

      expect(chosen, 'e8b49ed3');
    });

    test('a quiet or unheard conversation of its own moves too', () {
      expect(
        sessionToRebind(
          panes: const [BoundPane(sessionId: 'mine', conversationId: 'a')],
          now: firstHeard,
          claimedBy: 'mine',
        ),
        'mine',
      );
      expect(
        sessionToRebind(
          panes: [
            BoundPane(
              sessionId: 'mine',
              conversationId: 'a',
              lastHeardFrom: firstHeard.subtract(const Duration(minutes: 6)),
            ),
          ],
          now: firstHeard,
          claimedBy: 'mine',
        ),
        'mine',
      );
    });

    test('its own conversation still live means a child agent inherited the '
        'id, so nothing moves — and nobody else takes it', () {
      final chosen = sessionToRebind(
        panes: [
          BoundPane(
            sessionId: 'parent',
            conversationId: 'a',
            lastHeardFrom: firstHeard.subtract(const Duration(seconds: 3)),
          ),
          const BoundPane(sessionId: 'idle', conversationId: 'b'),
        ],
        now: firstHeard,
        firstHeardAt: firstHeard,
        claimedBy: 'parent',
      );

      expect(chosen, isNull);
    });

    test('a row that is not one of the candidates is nobody', () {
      final chosen = sessionToRebind(
        panes: const [BoundPane(sessionId: 'idle', conversationId: 'b')],
        now: firstHeard,
        claimedBy: 'archived-or-other-agent',
      );

      expect(chosen, isNull);
    });
  });
}
