import 'package:karmashala/src/features/notifications/domain/agent_session_key.dart';
import 'package:karmashala/src/features/notifications/domain/inbox_item.dart';
import 'package:karmashala/src/features/notifications/domain/notification_policy.dart';
import 'package:karmashala/src/features/notifications/domain/session_attention.dart';
import 'package:karmashala/src/features/notifications/domain/watched_session.dart';
import 'package:flutter_test/flutter_test.dart';

/// What one poll costs the attention inbox, measured against the algorithm it
/// replaced.
///
/// The audit's finding (the 2026-08-31 performance audit, §P1, "the
/// inbox is unbounded and poll application can become quadratic"): every upsert
/// was an `indexWhere` over the whole item list, and the id it compared was a
/// *getter* that interpolated a fresh string for each item it looked at. A poll
/// over N waiting sessions against N listed items therefore built N² strings.
///
/// [_legacyApply] below is that algorithm transcribed — including the id
/// getter, which is the expensive half — so the two can be run over identical
/// input. It doubles as an equivalence oracle: the fast version must produce
/// the same items, or the measurement is comparing two different features.
void main() {
  final t0 = DateTime.utc(2026, 8, 31, 12);

  WatchedSession session(int i) => WatchedSession(
    key: _CountingKey('claudeCode', 'cli-$i'),
    label: 'Session $i',
    openId: 'row-$i',
    imported: false,
  );

  /// A poll in which every one of [count] sessions is waiting on the user —
  /// the worst case, because every session both upserts and has to be checked
  /// for retirement.
  InboxUpdate waitingPoll(int count) {
    final sessions = [for (var i = 0; i < count; i++) session(i)];
    return InboxUpdate(
      watched: {for (final s in sessions) s.key},
      waiting: [
        for (final s in sessions)
          SessionAttention(session: s, kind: AttentionKind.needsInput),
      ],
    );
  }

  /// A poll of [count] finished turns, all of them new — every event inserts.
  InboxUpdate newsPoll(int count, int generation) {
    final sessions = [
      for (var i = 0; i < count; i++) session(generation * 100000 + i),
    ];
    return InboxUpdate(
      watched: {for (final s in sessions) s.key},
      news: [
        for (final s in sessions)
          (session: s, reason: NotificationReason.finished),
      ],
    );
  }

  group('applying a poll', () {
    // Filled by the two cases below, so the *shape* can be asserted across
    // them rather than inside either one.
    final builds = <int, int>{};

    for (final count in [100, 500]) {
      test('at $count sessions it is linear, not quadratic', () {
        final poll = waitingPoll(count);

        // Both start from an inbox already holding one item per session, which
        // is the steady state the audit describes: everything is listed and the
        // poll says the same thing again.
        final seeded = AttentionInbox.empty.apply(poll, t0);
        expect(seeded.items, hasLength(count));

        final legacySeeded = _legacyApply(const [], poll, t0);
        expect(
          legacySeeded.map((item) => item.id).toSet(),
          seeded.items.map((item) => item.id).toSet(),
          reason: 'the two algorithms must be applying the same rules',
        );

        // **Counted, not timed.** This assertion used to compare two
        // stopwatches over a few microseconds of work, and it failed whenever
        // the machine was busy — three separate agents hit it on a loaded
        // run and each one re-ran rather than read it, which is what a flaky
        // perf test costs. The audit's own unit is countable directly: the old
        // algorithm's expense *was* building N² id strings, and an id is built
        // by interpolating the key.
        const reps = 5;
        _CountingKey.builds = 0;
        for (var i = 0; i < reps; i++) {
          _legacyApply(legacySeeded, poll, t0);
        }
        final legacyBuilds = _CountingKey.builds;

        _CountingKey.builds = 0;
        for (var i = 0; i < reps; i++) {
          seeded.apply(poll, t0);
        }
        final fastBuilds = _CountingKey.builds;

        // ignore: avoid_print
        print(
          'inbox apply · $count sessions · before $legacyBuilds id-builds'
          ' · after $fastBuilds',
        );
        builds[count] = fastBuilds;

        // A steady-state poll now allocates nothing at all: no list copy, no id
        // strings, and the same object back, so no surface rebuilds.
        expect(identical(seeded.apply(poll, t0), seeded), isTrue);

        // Linear in the session count, with a constant nobody has to trust: a
        // handful of ids per session per rep, however loaded the runner is.
        expect(fastBuilds, lessThanOrEqualTo(4 * count * reps));
        expect(
          legacyBuilds,
          greaterThan(fastBuilds * 4),
          reason: 'the algorithm this replaced built one id per comparison',
        );
      });
    }

    test('and the curve is linear across the two sizes', () {
      // Five times the sessions, five times the work — the claim the timing
      // version was reaching for, now stated in a unit a busy machine cannot
      // move.
      expect(builds[100], isNotNull, reason: 'the two cases ran first');
      expect(builds[500]! / builds[100]!, closeTo(5, 0.5));
    });

    test('a poll of pure news agrees with the old algorithm', () {
      // The insert-only case is where the old algorithm was least bad, so it is
      // the one worth checking for equivalence rather than for speed. Kept
      // under the cap so the two are comparable at all.
      var fast = AttentionInbox.empty;
      var legacy = const <InboxItem>[];
      for (var generation = 0; generation < 3; generation++) {
        final poll = newsPoll(50, generation);
        final now = t0.add(Duration(minutes: generation));
        fast = fast.apply(poll, now);
        legacy = _legacyApply(legacy, poll, now);
      }
      expect(
        fast.items.map((item) => item.id),
        legacy.map((item) => item.id),
        reason: 'same items, same order',
      );
      expect(fast.unseen, legacy.where((item) => !item.seen).length);
    });
  });

  group('reading the inbox', () {
    /// An inbox in the shape a busy workspace leaves behind: every session
    /// blocked and already acknowledged, plus a cap's worth of finished turns
    /// nobody has looked at. The filter behind `pending` therefore has real
    /// work to do — it has to walk the conditions to reject them.
    AttentionInbox busy(int count) {
      final seen = AttentionInbox.empty.apply(waitingPoll(count), t0).markAllSeen();
      return seen.apply(newsPoll(count, 1), t0.add(const Duration(minutes: 1)));
    }

    for (final count in [100, 500]) {
      test('at $count sessions pending is read, not rebuilt', () {
        final inbox = busy(count);
        expect(inbox.unseen, greaterThan(0));
        expect(
          inbox.pending,
          hasLength(inbox.unseen),
          reason: 'the list and the count are the same fact',
        );

        // Warmed first: at 200 reps the JIT's first pass over the filter is
        // most of the smaller case's time, and it is not what is being claimed.
        const reps = 200;
        for (var i = 0; i < reps; i++) {
          _legacyPending(inbox.items);
          inbox.pending;
        }

        final legacy = Stopwatch()..start();
        for (var i = 0; i < reps; i++) {
          _legacyPending(inbox.items);
        }
        legacy.stop();

        final fast = Stopwatch()..start();
        for (var i = 0; i < reps; i++) {
          inbox.pending;
        }
        fast.stop();

        // ignore: avoid_print
        print(
          'inbox pending · $count sessions · ${inbox.items.length} items'
          ' · before ${(legacy.elapsedMicroseconds / reps).toStringAsFixed(2)}'
          ' us/read · after'
          ' ${(fast.elapsedMicroseconds / reps).toStringAsFixed(2)} us/read',
        );

        // The shape, not the number: the tray reads this on every inbox change
        // and `projectSummaryProvider` reads it once per project on every
        // rebuild, so it must not be O(items) per reader.
        expect(
          identical(inbox.pending, inbox.pending),
          isTrue,
          reason: 'two reads must be the same list, not two filters',
        );
      });
    }
  });

  group('what the inbox holds', () {
    for (final count in [100, 500]) {
      test('at $count sessions it stays within the cap', () {
        var fast = AttentionInbox.empty;
        var legacy = const <InboxItem>[];
        // Ten polls' worth of distinct finished turns — 10 × count events, none
        // of which any user ever looked at.
        for (var generation = 0; generation < 10; generation++) {
          final poll = newsPoll(count, generation);
          final now = t0.add(Duration(minutes: generation));
          fast = fast.apply(poll, now);
          legacy = _legacyApply(legacy, poll, now);
        }
        // ignore: avoid_print
        print(
          'inbox size · $count sessions × 10 polls · ${count * 10} events'
          ' · before ${legacy.length} items · after ${fast.items.length}',
        );
        expect(legacy, hasLength(count * 10), reason: 'nothing bounded it');
        expect(fast.items.length, kAttentionInboxCap);
      });
    }
  });
}

/// `AttentionInbox.apply` as it was before this loop, transcribed.
///
/// Including the id getter it compared against — `'${kind.name}:$key'`, built
/// per item per comparison — because that allocation is what the quadratic
/// actually cost. Returns the raw list rather than an [AttentionInbox], which
/// is now capped: being uncapped is half of what is under measurement.
List<InboxItem> _legacyApply(
  List<InboxItem> items,
  InboxUpdate update,
  DateTime now,
) {
  final next = [...items];

  String legacyId(InboxItem item) => '${item.kind.name}:${item.session.key}';

  int indexOf(String id) => next.indexWhere((item) => legacyId(item) == id);

  void upsert(WatchedSession session, InboxItemKind kind) {
    final item = InboxItem(session: session, kind: kind, at: now);
    if (indexOf(legacyId(item)) >= 0) return;
    next.insert(0, item);
  }

  for (final event in update.news) {
    upsert(event.session, InboxItemKind.of(event.reason));
  }
  for (final waiting in update.waiting) {
    upsert(waiting.session, InboxItemKind.ofAttention(waiting.kind));
  }

  final stillWaiting = {
    for (final waiting in update.waiting)
      '${InboxItemKind.ofAttention(waiting.kind).name}:${waiting.session.key}',
  };
  next.removeWhere(
    (item) =>
        item.kind.isCondition &&
        update.watched.contains(item.key) &&
        !stillWaiting.contains(legacyId(item)),
  );
  return next;
}

/// `AttentionInbox.pending` as it was: a fresh filter and a fresh list, per
/// read, per consumer.
List<InboxItem> _legacyPending(List<InboxItem> items) =>
    items.where((item) => !item.seen).toList(growable: false);

/// Counts the thing the old algorithm spent its time on.
///
/// `InboxItem.idFor` interpolates the key, so every id the poll builds passes
/// through here — which makes the audit's "N² strings" finding directly
/// countable, and deterministic on any machine.
class _CountingKey extends AgentSessionKey {
  const _CountingKey(super.agentId, super.sessionId);

  static int builds = 0;

  @override
  String toString() {
    builds++;
    return super.toString();
  }
}
