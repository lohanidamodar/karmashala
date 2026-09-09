import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/notifications/domain/agent_session_key.dart';
import 'package:karmashala/src/features/notifications/domain/agent_status_transition.dart';
import 'package:karmashala/src/features/notifications/domain/inbox_item.dart';
import 'package:karmashala/src/features/notifications/domain/notification_policy.dart';
import 'package:karmashala/src/features/notifications/domain/notification_settings.dart';
import 'package:karmashala/src/features/notifications/domain/session_attention.dart';
import 'package:karmashala/src/features/notifications/domain/watched_session.dart';
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

  group('where an item leads', () {
    /// The same conversation, watched as read-only history rather than as the
    /// row running it — which is how a Codex session looks for as long as its
    /// row has no conversation id.
    WatchedSession asHistory(WatchedSession live) => WatchedSession(
      key: live.key,
      label: live.label,
      openId: 'imported-${live.key.sessionId}',
      imported: true,
      stateFilePath: '/store/rollout.jsonl',
    );

    test('an item follows the session to the row that is running it', () {
      // The owner's third symptom, after the id lands. A Codex session filed
      // its notification while the only record of the conversation was the
      // imported transcript; attribution then gave the native row the same
      // conversation id, so the *same* key is now reported by the row with the
      // pane. The item is the same thing waiting — it keeps its place and its
      // seen flag — but where to go for it is not identity, and an item still
      // pointing at history opens a read-only view of a live session.
      final live = session('a');
      final inbox = AttentionInbox.empty.apply(
        InboxUpdate(
          watched: {live.key},
          news: [news(asHistory(live), NotificationReason.finished)],
        ),
        t0,
      );
      expect(inbox.items.single.session.imported, isTrue);

      final after = inbox.apply(
        InboxUpdate(
          watched: {live.key},
          news: [news(live, NotificationReason.finished)],
        ),
        at(5),
      );

      expect(after.items.single.session, live);
      expect(after.items.single.session.openId, 'row-a');
      expect(after.items.single.at, t0, reason: 'not a new thing to tell');
      expect(after.unseen, 1);
    });

    test('a rebound item keeps the seen flag it had', () {
      final live = session('a');
      final inbox = AttentionInbox.empty
          .apply(
            InboxUpdate(
              watched: {live.key},
              waiting: [waiting(asHistory(live))],
            ),
            t0,
          )
          .viewed({'imported-a'});
      expect(inbox.unseen, 0);

      final after = inbox.apply(
        InboxUpdate(watched: {live.key}, waiting: [waiting(live)]),
        at(5),
      );

      expect(after.items.single.session.openId, 'row-a');
      expect(after.items.single.seen, isTrue);
      expect(after.unseen, 0);
    });

    test('an unchanged session still costs nothing', () {
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

  group('the cap', () {
    /// One poll's worth of finished turns for [count] fresh sessions.
    AttentionInbox fill(
      AttentionInbox inbox,
      int count,
      int minute, {
      String prefix = 'f',
    }) {
      final sessions = [
        for (var i = 0; i < count; i++) session('$prefix$minute-$i'),
      ];
      return inbox.apply(
        InboxUpdate(
          watched: {for (final s in sessions) s.key},
          news: [
            for (final s in sessions) news(s, NotificationReason.finished),
          ],
        ),
        at(minute),
      );
    }

    test('it never holds more than the cap, however hard it is pushed', () {
      var inbox = AttentionInbox.empty;
      for (var minute = 1; minute <= 10; minute++) {
        inbox = fill(inbox, kAttentionInboxCap, minute);
        expect(inbox.items.length, kAttentionInboxCap);
      }
    });

    test('the oldest event is what goes', () {
      // A full inbox of finished turns, then one more arrives. The newest
      // survives and the oldest pays, which is the order a work queue wants.
      var inbox = fill(AttentionInbox.empty, kAttentionInboxCap, 1);
      final oldest = inbox.items.last;
      final newest = inbox.items.first;
      inbox = fill(inbox, 1, 2, prefix: 'new');

      expect(inbox.items.length, kAttentionInboxCap);
      expect(inbox.items.first.id, isNot(oldest.id));
      expect(
        inbox.items.map((item) => item.id),
        isNot(contains(oldest.id)),
        reason: 'the oldest event is the least useful thing in the list',
      );
      expect(inbox.items.map((item) => item.id), contains(newest.id));
    });

    test('an unresolved request survives a flood of finished turns', () {
      final blocked = session('blocked');
      var inbox = AttentionInbox.empty.apply(
        InboxUpdate(watched: {blocked.key}, waiting: [waiting(blocked)]),
        t0,
      );

      // Ten times the cap in ordinary news, arriving after it.
      for (var minute = 1; minute <= 10; minute++) {
        inbox = fill(inbox, kAttentionInboxCap, minute);
      }

      expect(
        inbox.items.length,
        kAttentionInboxCap + 1,
        reason: 'the cap counts events; the one live condition is exempt',
      );
      final approval = inbox.items.where(
        (item) => item.session.key == blocked.key,
      );
      expect(
        approval.single.kind,
        InboxItemKind.needsApproval,
        reason: 'the one thing the user actually has to answer is not evicted',
      );
      expect(approval.single.seen, isFalse);
    });

    test('read is evicted before unread, and events before conditions', () {
      // Four items, one of each rank, then the cap is pushed down to them by
      // filling the rest with news that is newer than all four.
      final seenEvent = session('seen-event');
      final unseenEvent = session('unseen-event');
      final seenCondition = session('seen-condition');
      final unseenCondition = session('unseen-condition');

      var inbox = AttentionInbox.empty.apply(
        InboxUpdate(
          watched: {
            seenEvent.key,
            unseenEvent.key,
            seenCondition.key,
            unseenCondition.key,
          },
          waiting: [waiting(seenCondition), waiting(unseenCondition)],
          news: [
            news(seenEvent, NotificationReason.finished),
            news(unseenEvent, NotificationReason.finished),
          ],
        ),
        t0,
      );
      inbox = inbox.viewed({'row-seen-event', 'row-seen-condition'});
      // The viewed event left; re-file it as a read one the poll cannot retire.
      expect(inbox.items.length, 3);

      List<String> survivorsAfter(int newer) {
        var pushed = inbox;
        for (var i = 0; i < newer; i++) {
          pushed = fill(pushed, kAttentionInboxCap ~/ 2, i + 1, prefix: 'p$i');
        }
        return [
          for (final item in pushed.items)
            if (item.session.openId.startsWith('row-unseen') ||
                item.session.openId.startsWith('row-seen'))
              item.session.openId,
        ];
      }

      // Enough newer news to evict everything evictable.
      expect(survivorsAfter(4), [
        'row-unseen-condition',
        'row-seen-condition',
      ], reason: 'conditions outlast events; unread outlasts read');
    });

    test('five hundred sessions all blocked are all listed, and stably', () {
      // The cap counts events. Making conditions evictable would also make the
      // list churn: an evicted condition is re-filed by the next poll with a
      // fresh arrival time, so it would displace a survivor, forever.
      final sessions = [for (var i = 0; i < 500; i++) session('w$i')];
      final poll = InboxUpdate(
        watched: {for (final s in sessions) s.key},
        waiting: [for (final s in sessions) waiting(s)],
      );
      final inbox = AttentionInbox.empty.apply(poll, t0);
      expect(inbox.items, hasLength(500));
      expect(inbox.unseen, 500);
      expect(
        identical(inbox.apply(poll, at(5)), inbox),
        isTrue,
        reason: 'saying the same thing again rebuilds nothing',
      );
    });

    test('the cap does not lose an item the inbox still needs to retire', () {
      // Eviction must not leave a condition listed-but-forgotten: what is
      // dropped is dropped from the index too, so a later poll retiring it is
      // a no-op rather than a rebuild.
      final blocked = session('blocked');
      var inbox = AttentionInbox.empty.apply(
        InboxUpdate(watched: {blocked.key}, waiting: [waiting(blocked)]),
        t0,
      );
      for (var minute = 1; minute <= 3; minute++) {
        inbox = fill(inbox, kAttentionInboxCap, minute);
      }
      inbox = inbox.apply(InboxUpdate(watched: {blocked.key}), at(20));
      expect(
        inbox.items.where((item) => item.session.key == blocked.key),
        isEmpty,
        reason: 'the agent stopped waiting, so the condition retires',
      );
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

  group('walking to the next agent that needs you', () {
    InboxItem itemFor(String id) => InboxItem(
      session: WatchedSession(
        key: AgentSessionKey('claudeCode', id),
        label: id,
        openId: id,
        imported: false,
      ),
      kind: InboxItemKind.needsApproval,
      at: DateTime.utc(2026, 9, 8),
    );

    test('an empty inbox has nowhere to go, and says so with null', () {
      expect(AttentionInbox().nextAfter(null), isNull);
      expect(AttentionInbox().nextAfter('s1'), isNull);
    });

    test('from nowhere in particular, the first one', () {
      final inbox = AttentionInbox(items: [itemFor('a'), itemFor('b')]);

      expect(inbox.nextAfter(null)?.session.openId, 'a');
    });

    test('a pane that is not waiting on anybody starts at the first — which '
        'is the ordinary case', () {
      final inbox = AttentionInbox(items: [itemFor('a'), itemFor('b')]);

      expect(inbox.nextAfter('unrelated')?.session.openId, 'a');
    });

    test('from one, the next', () {
      final inbox = AttentionInbox(
        items: [itemFor('a'), itemFor('b'), itemFor('c')],
      );

      expect(inbox.nextAfter('a')?.session.openId, 'b');
      expect(inbox.nextAfter('b')?.session.openId, 'c');
    });

    test('from the last, round to the first', () {
      final inbox = AttentionInbox(items: [itemFor('a'), itemFor('b')]);

      expect(
        inbox.nextAfter('b')?.session.openId,
        'a',
        reason: 'a list you can walk off the end of is not a cycle',
      );
    });

    test('one waiting agent answers itself rather than nothing', () {
      final inbox = AttentionInbox(items: [itemFor('a')]);

      expect(
        inbox.nextAfter('a')?.session.openId,
        'a',
        reason: 'revealing it again confirms where you are; null would read '
            'as the chord being broken',
      );
    });
  });
}
