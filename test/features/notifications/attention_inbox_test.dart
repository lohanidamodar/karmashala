import 'package:chitragupta/src/features/agents/domain/agent_status.dart';
import 'package:chitragupta/src/features/notifications/domain/agent_session_key.dart';
import 'package:chitragupta/src/features/notifications/domain/agent_status_transition.dart';
import 'package:chitragupta/src/features/notifications/domain/inbox_item.dart';
import 'package:chitragupta/src/features/notifications/domain/notification_policy.dart';
import 'package:chitragupta/src/features/notifications/domain/notification_settings.dart';
import 'package:chitragupta/src/features/notifications/domain/session_attention.dart';
import 'package:chitragupta/src/features/notifications/domain/watched_session.dart';
import 'package:flutter_test/flutter_test.dart';

/// The attention inbox as pure logic.
///
/// The rule worth arguing about, and the reason this is a reducer rather than a
/// view over `sessionAttentionProvider`: **an item leaves because something
/// happened, never because we stopped being able to see it.** Loop 42's tray
/// mirrored the current attention set, so a status report ageing past its
/// five-minute freshness silently un-badged a session that was still waiting.
void main() {
  final t0 = DateTime.utc(2026, 8, 30, 12);
  DateTime at(int minutes) => t0.add(Duration(minutes: minutes));

  WatchedSession session(String id, {String? label}) => WatchedSession(
    key: AgentSessionKey('claudeCode', id),
    label: label ?? 'Session $id',
    openId: 'row-$id',
    imported: false,
  );

  ({WatchedSession session, NotificationReason reason}) news(
    WatchedSession s,
    NotificationReason reason,
  ) => (session: s, reason: reason);

  SessionAttention waiting(WatchedSession s, [AttentionKind? kind]) =>
      SessionAttention(session: s, kind: kind ?? AttentionKind.needsInput);

  group('what enters the inbox', () {
    test('every kind of news, whatever the toast decided', () {
      final a = session('a');
      final b = session('b');
      final c = session('c');
      final inbox = AttentionInbox.empty.apply(
        InboxUpdate(
          watched: {a.key, b.key, c.key},
          waiting: [waiting(a), waiting(c, AttentionKind.failed)],
          news: [
            news(a, NotificationReason.needsInput),
            news(b, NotificationReason.finished),
            news(c, NotificationReason.failed),
          ],
        ),
        t0,
      );

      expect(inbox.items.length, 3);
      expect(inbox.items.map((item) => item.kind).toSet(), {
        InboxItemKind.needsApproval,
        InboxItemKind.finished,
        InboxItemKind.failed,
      });
      expect(inbox.unseen, 3);
    });

    test('an event and the state confirming it are one item', () {
      final a = session('a');
      final inbox = AttentionInbox.empty.apply(
        InboxUpdate(
          watched: {a.key},
          waiting: [waiting(a)],
          news: [news(a, NotificationReason.needsInput)],
        ),
        t0,
      );
      expect(inbox.items.length, 1);
    });

    test('a condition seen again keeps its arrival time and its seen flag', () {
      final a = session('a');
      const update = InboxUpdate();
      var inbox = AttentionInbox.empty.apply(
        InboxUpdate(watched: {a.key}, waiting: [waiting(a)]),
        t0,
      );
      inbox = inbox.viewed({'row-a'});
      expect(inbox.items.single.seen, isTrue);

      inbox = inbox.apply(
        InboxUpdate(watched: {a.key}, waiting: [waiting(a)]),
        at(30),
      );
      expect(inbox.items.single.at, t0, reason: 'still the same request');
      expect(inbox.items.single.seen, isTrue, reason: 'still read');
      expect(inbox.unseen, 0);

      // An empty poll is not a poll that saw anything.
      expect(inbox.apply(update, at(31)).items.length, 1);
    });

    test('nothing new returns the same object, so nothing rebuilds', () {
      final a = session('a');
      final inbox = AttentionInbox.empty.apply(
        InboxUpdate(watched: {a.key}, waiting: [waiting(a)]),
        t0,
      );
      final again = inbox.apply(
        InboxUpdate(watched: {a.key}, waiting: [waiting(a)]),
        at(5),
      );
      expect(identical(inbox, again), isTrue);
    });
  });

  group('what leaves, and what does not', () {
    test('a condition that clears while we are watching is retired', () {
      final a = session('a');
      var inbox = AttentionInbox.empty.apply(
        InboxUpdate(watched: {a.key}, waiting: [waiting(a)]),
        t0,
      );
      expect(inbox.items, hasLength(1));

      inbox = inbox.apply(InboxUpdate(watched: {a.key}), at(1));
      expect(inbox.items, isEmpty, reason: 'the agent stopped waiting');
    });

    test('a condition we lost sight of stays — the Loop 42 bug', () {
      final a = session('a');
      var inbox = AttentionInbox.empty.apply(
        InboxUpdate(watched: {a.key}, waiting: [waiting(a)]),
        t0,
      );

      // The session's report went stale, so the watcher no longer looks at it.
      // That is us losing track, not the agent being answered.
      inbox = inbox.apply(const InboxUpdate(), at(10));
      expect(inbox.items, hasLength(1));
      expect(inbox.unseen, 1);
    });

    test('a finished turn is never retired by a poll', () {
      final a = session('a');
      var inbox = AttentionInbox.empty.apply(
        InboxUpdate(
          watched: {a.key},
          news: [news(a, NotificationReason.finished)],
        ),
        t0,
      );
      inbox = inbox.apply(InboxUpdate(watched: {a.key}), at(1));
      expect(inbox.items.single.kind, InboxItemKind.finished);
    });
  });

  group('viewing the source', () {
    test(
      'a finished turn you looked at leaves; an approval only goes quiet',
      () {
        final a = session('a');
        final b = session('b');
        var inbox = AttentionInbox.empty.apply(
          InboxUpdate(
            watched: {a.key, b.key},
            waiting: [waiting(b)],
            news: [news(a, NotificationReason.finished)],
          ),
          t0,
        );
        expect(inbox.unseen, 2);

        inbox = inbox.viewed({'row-a', 'row-b'});
        expect(inbox.items.map((item) => item.kind), [
          InboxItemKind.needsApproval,
        ], reason: 'looking at a question does not answer it');
        expect(inbox.items.single.seen, isTrue);
        expect(inbox.unseen, 0);
      },
    );

    test('viewing something else changes nothing', () {
      final a = session('a');
      final inbox = AttentionInbox.empty.apply(
        InboxUpdate(watched: {a.key}, waiting: [waiting(a)]),
        t0,
      );
      expect(identical(inbox.viewed({'row-z'}), inbox), isTrue);
      expect(identical(inbox.viewed(const {}), inbox), isTrue);
    });
  });

  group('the user clearing it', () {
    test('mark all read drops finished turns and quietens the rest', () {
      final a = session('a');
      final b = session('b');
      var inbox = AttentionInbox.empty.apply(
        InboxUpdate(
          watched: {a.key, b.key},
          waiting: [waiting(b, AttentionKind.failed)],
          news: [news(a, NotificationReason.finished)],
        ),
        t0,
      );

      inbox = inbox.markAllSeen();
      expect(inbox.items.map((item) => item.kind), [InboxItemKind.failed]);
      expect(inbox.unseen, 0);
    });

    test('dismiss removes exactly one item', () {
      final a = session('a');
      final b = session('b');
      var inbox = AttentionInbox.empty.apply(
        InboxUpdate(watched: {a.key, b.key}, waiting: [waiting(a), waiting(b)]),
        t0,
      );
      inbox = inbox.dismiss('needsApproval:claudeCode/a');
      expect(inbox.items.single.session.key.sessionId, 'b');
    });
  });

  test('the menu label says what is waiting and why', () {
    final a = session('a', label: 'Fix login');
    final inbox = AttentionInbox.empty.apply(
      InboxUpdate(
        watched: {a.key},
        news: [news(a, NotificationReason.finished)],
      ),
      t0,
    );
    expect(inbox.items.single.menuLabel, 'Fix login — finished');
  });

  test('newsIn agrees with decide about what happened', () {
    // The two must never drift: the inbox lists what a toast would have said,
    // whether or not the toast was allowed to say it.
    const policy = AgentNotificationPolicy();
    for (final source in AgentStatusSource.values) {
      for (final from in AgentActivityStatus.values) {
        for (final to in AgentActivityStatus.values) {
          final transition = AgentStatusTransition(
            session: const AgentSessionKey('claudeCode', 'x'),
            from: from,
            to: to,
            source: source,
          );
          final news = policy.newsIn(transition).reason;
          final decision = policy
              .decide(
                NotificationContext(
                  transition: transition,
                  settings: const NotificationSettings(),
                  windowFocused: false,
                ),
              )
              .reason;
          expect(
            decision,
            news,
            reason:
                'with every gate open, a toast fires exactly when there is '
                'news: $from -> $to via ${source.name}',
          );
        }
      }
    }
  });
}
