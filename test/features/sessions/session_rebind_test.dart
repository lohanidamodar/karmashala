import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/domain/session_rebind.dart';

final _now = DateTime.utc(2026, 9, 13, 17, 30);

void main() {
  group('sessionToRebind', () {
    test('the pane whose conversation went quiet takes the new one', () {
      // The owner's machine, 2026-09-13: three Claude panes, two of them
      // reporting hooks all the time, and `karmashala-2` silent since it was
      // cleared two and a half hours earlier.
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
      );

      expect(chosen, 'karmashala-2');
    });

    test('a pane that has never reported counts as quiet, not as fresh', () {
      final chosen = sessionToRebind(
        panes: [
          BoundPane(
            sessionId: 'busy',
            conversationId: 'a',
            lastHeardFrom: _now,
          ),
          const BoundPane(sessionId: 'unheard', conversationId: 'b'),
        ],
        now: _now,
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
  });
}
