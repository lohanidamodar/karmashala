import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:test/test.dart';

/// A follow-up in the attention inbox — the one surface the app has for
/// "something needs you", and the one this feature deliberately does not add a
/// second of.
///
/// The whole question here is **who is allowed to take it off the list**. The
/// inbox already had two answers (the agent watcher, and looking at the source)
/// and a follow-up needs a third, because neither of the first two knows
/// anything about it: the watcher polls agents, and glancing at a session does
/// not deal with what it left behind.
void main() {
  final t0 = DateTime.utc(2026, 9, 1, 10);

  WatchedSession watched(String id) => WatchedSession(
    key: AgentSessionKey('claudeCode', 'cli-$id'),
    label: 'Session $id',
    openId: id,
    imported: false,
  );

  InboxItem followUp(String id, {String? detail}) => InboxItem(
    session: watched(id),
    kind: InboxItemKind.followUp,
    at: t0,
    id: 'followUp:$id',
    detail: detail,
  );

  test('a follow-up carries the source\'s own words into the list', () {
    final inbox = AttentionInbox.empty.syncFollowUps([
      followUp('s1', detail: 'Fail — the login page still loads.'),
    ]);
    expect(inbox.items.single.kind, InboxItemKind.followUp);
    expect(inbox.items.single.detail, 'Fail — the login page still loads.');
    expect(inbox.unseen, 1);
  });

  test('looking at the session does not deal with what it left', () {
    // The point of the third retirement rule. A finished turn is *done with*
    // once you have looked at it; a session that crashed and left a decision
    // record is not, and it was the one thing the old inbox could not express.
    var inbox = AttentionInbox.empty.syncFollowUps([followUp('s1')]);
    inbox = inbox.apply(
      InboxUpdate(
        watched: {watched('s2').key},
        news: [(session: watched('s2'), reason: NotificationReason.finished)],
      ),
      t0,
    );
    expect(inbox.items, hasLength(2));

    inbox = inbox.viewed({'s1', 's2'});

    // The finished turn left; the follow-up stayed, marked seen.
    expect(inbox.items.single.kind, InboxItemKind.followUp);
    expect(inbox.items.single.seen, isTrue);
    expect(inbox.unseen, 0);
  });

  test('"mark all read" reads it, it does not resolve it', () {
    var inbox = AttentionInbox.empty.syncFollowUps([followUp('s1')]);
    inbox = inbox.markAllSeen();
    expect(inbox.items.single.kind, InboxItemKind.followUp);
    expect(inbox.items.single.seen, isTrue);
  });

  test('an agent poll cannot sweep a follow-up away', () {
    // The trap `inbox_item.dart` already warns about for delivery items: the
    // watcher's retirement pass knows only about agent status, so anything it
    // is allowed to retire must be something it can actually see stop.
    var inbox = AttentionInbox.empty.syncFollowUps([followUp('s1')]);
    inbox = inbox.apply(InboxUpdate(watched: {watched('s1').key}), t0);
    expect(inbox.items.single.kind, InboxItemKind.followUp);
  });

  test('only the store retires one', () {
    var inbox = AttentionInbox.empty.syncFollowUps([
      followUp('s1'),
      followUp('s2'),
    ]);
    expect(inbox.items, hasLength(2));

    inbox = inbox.syncFollowUps([followUp('s2')]);
    expect(inbox.items.map((i) => i.session.openId), ['s2']);
  });

  test('a follow-up that is still open is not news again', () {
    var inbox = AttentionInbox.empty.syncFollowUps([followUp('s1')]);
    inbox = inbox.viewed({'s1'});
    expect(inbox.unseen, 0);

    // Re-synced every time the store changes for any reason. An item that is
    // still there keeps its arrival time and its seen flag, or the badge would
    // light up again on every sync.
    final resynced = inbox.syncFollowUps([followUp('s1')]);
    expect(resynced.unseen, 0);
    expect(identical(resynced, inbox), isTrue);
  });

  test('a sync that changes nothing allocates nothing', () {
    final inbox = AttentionInbox.empty.syncFollowUps([followUp('s1')]);
    expect(identical(inbox.syncFollowUps([followUp('s1')]), inbox), isTrue);
    expect(
      identical(
        AttentionInbox.empty.syncFollowUps(const []),
        AttentionInbox.empty,
      ),
      isTrue,
    );
  });

  test('a full inbox evicts finished turns, never follow-ups', () {
    // Conditions are already exempt from eviction; follow-ups have to be too,
    // and for the same reason — an evicted one is re-filed by the very next
    // sync, so it would displace a survivor forever. They are bounded at the
    // source instead (`kOpenFollowUpCap`).
    var inbox = AttentionInbox.empty.syncFollowUps([followUp('kept')]);
    for (var i = 0; i < kAttentionInboxCap + 20; i++) {
      inbox = inbox.apply(
        InboxUpdate(
          watched: {watched('e$i').key},
          news: [
            (session: watched('e$i'), reason: NotificationReason.finished),
          ],
        ),
        t0.add(Duration(seconds: i)),
      );
    }
    expect(inbox.items.length, kAttentionInboxCap + 1);
    expect(
      inbox.items.where((i) => i.kind == InboxItemKind.followUp),
      hasLength(1),
    );
  });

  test('a condition still retires the way it always did', () {
    // The refactor that made room for a third rule must not have changed the
    // first two.
    var inbox = AttentionInbox.empty.apply(
      InboxUpdate(
        watched: {watched('s1').key},
        waiting: [
          SessionAttention(
            session: watched('s1'),
            kind: AttentionKind.needsInput,
          ),
        ],
      ),
      t0,
    );
    expect(inbox.items.single.kind, InboxItemKind.needsApproval);

    inbox = inbox.apply(InboxUpdate(watched: {watched('s1').key}), t0);
    expect(inbox.items, isEmpty);
  });

  test('dismissing removes it from the list', () {
    var inbox = AttentionInbox.empty.syncFollowUps([followUp('s1')]);
    inbox = inbox.dismiss('followUp:s1');
    expect(inbox.items, isEmpty);
  });
}
