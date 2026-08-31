import 'agent_session_key.dart';
import 'notification_policy.dart';
import 'session_attention.dart';
import 'watched_session.dart';

/// Why something is in the attention inbox.
///
/// The same three things the notification policy judges news — because they are
/// the same events. A toast is an *interruption* and is therefore rationed by
/// focus, by settings and by whether you are already looking at the session;
/// the inbox is a *queue* and is rationed by none of that. Turning toasts off
/// must not empty your work list.
enum InboxItemKind {
  /// An agent is waiting for you to approve something, or asked a question.
  needsApproval,

  /// An agent's turn ended in error.
  failed,

  /// An agent finished a turn you have not looked at yet.
  finished,

  /// A pull request's checks went red.
  checksFailed,

  /// A reviewer asked for changes on a pull request.
  changesRequested,

  /// A pull request is green and waiting for someone to press merge.
  readyToMerge;

  /// Whether this kind describes a condition that is still true right now.
  ///
  /// The two waiting kinds are *state*: the watcher can see them every poll and
  /// can therefore see them stop. Everything else is an *event* — a turn that
  /// ended stays ended, and a build that went red went red — so nothing but the
  /// user retires it.
  ///
  /// The distinction is load-bearing beyond wording: [AttentionInbox.apply]
  /// retires conditions for any session the *agent* watcher looked at, so a
  /// delivery item marked as a condition would be swept away by a poll that
  /// knows nothing about pull requests.
  bool get isCondition =>
      this == InboxItemKind.needsApproval || this == InboxItemKind.failed;

  String get label => switch (this) {
    InboxItemKind.needsApproval => 'Needs approval',
    InboxItemKind.failed => 'Failed',
    InboxItemKind.finished => 'Finished',
    InboxItemKind.checksFailed => 'Checks failed',
    InboxItemKind.changesRequested => 'Changes requested',
    InboxItemKind.readyToMerge => 'Ready to merge',
  };

  static InboxItemKind of(NotificationReason reason) => switch (reason) {
    NotificationReason.needsInput => InboxItemKind.needsApproval,
    NotificationReason.failed => InboxItemKind.failed,
    NotificationReason.finished => InboxItemKind.finished,
    NotificationReason.checksFailed => InboxItemKind.checksFailed,
    NotificationReason.changesRequested => InboxItemKind.changesRequested,
    NotificationReason.readyToMerge => InboxItemKind.readyToMerge,
  };

  static InboxItemKind ofAttention(AttentionKind kind) => switch (kind) {
    AttentionKind.needsInput => InboxItemKind.needsApproval,
    AttentionKind.failed => InboxItemKind.failed,
  };
}

/// One thing waiting for the user, and how to get to it.
class InboxItem {
  InboxItem({
    required this.session,
    required this.kind,
    required this.at,
    this.seen = false,
  }) : id = idFor(kind, session.key);

  final WatchedSession session;
  final InboxItemKind kind;

  /// When this entered the inbox. Not when it happened at the agent — we
  /// generally cannot know that — so it is only ever used to order the list.
  final DateTime at;

  /// Whether the user has looked at the source since this arrived.
  final bool seen;

  AgentSessionKey get key => session.key;

  /// Stable across polls, so an item keeps its place and its [seen] flag while
  /// the condition behind it persists.
  ///
  /// Stored rather than computed: it is the inbox's index key, so it is read
  /// once per event per poll and a getter that interpolated a new string each
  /// time was most of what made poll application expensive.
  final String id;

  /// The id an item for [kind] and [key] would have, without building one.
  static String idFor(InboxItemKind kind, AgentSessionKey key) =>
      '${kind.name}:$key';

  String get label => session.label;

  InboxItem copyWith({bool? seen}) =>
      InboxItem(session: session, kind: kind, at: at, seen: seen ?? this.seen);

  /// The one-line form used in the tray menu — the list's own wording, so the
  /// tray and the inbox cannot come to describe the same item differently.
  String get menuLabel => '${session.label} — ${kind.label.toLowerCase()}';

  @override
  bool operator ==(Object other) =>
      other is InboxItem &&
      other.session == session &&
      other.kind == kind &&
      other.at == at &&
      other.seen == seen;

  @override
  int get hashCode => Object.hash(session, kind, at, seen);

  @override
  String toString() => 'InboxItem($id, seen: $seen)';
}

/// What the watcher observed in one poll, in the terms the inbox needs.
class InboxUpdate {
  const InboxUpdate({
    this.waiting = const [],
    this.watched = const {},
    this.news = const [],
  });

  /// Sessions whose *current* status is a condition needing the user.
  final List<SessionAttention> waiting;

  /// Every session the watcher looked at this poll. The difference between this
  /// and [waiting] is what lets the inbox retire a condition that has cleared
  /// **without** retiring one it merely stopped being able to see.
  final Set<AgentSessionKey> watched;

  /// News since the last poll, ungated by settings or focus.
  final List<({WatchedSession session, NotificationReason reason})> news;
}

/// How many **event** items the attention inbox keeps.
///
/// Events are the half that grew without limit: a finished turn stays until the
/// user views, dismisses or reads it, so an eight-hour day across a hundred
/// sessions accumulates thousands of records of things that already happened.
/// Two hundred is one per session in the audit's *live/quiet* tier
/// (`ARCHITECTURE.md` §"Scale target — 100 live terminals") — past that the
/// list has stopped being a work queue and become a log.
///
/// **Conditions are exempt, deliberately.** An agent waiting on you is not a
/// log entry: there is at most one per session and kind, it retires by itself
/// the moment the agent stops waiting, and dropping one is precisely the Loop
/// 42 bug this class exists to prevent — a user who walked away comes back to a
/// clean tray and a stuck agent. So the inbox holds at most
/// `kAttentionInboxCap` events plus one item per session actually blocked on
/// the user, and that second number is bounded by the watch set rather than by
/// time. Making conditions evictable would also make the list *unstable* at the
/// cap: an evicted condition is re-filed by the very next poll with a fresh
/// arrival time, so it would displace a survivor, forever.
const int kAttentionInboxCap = 200;

/// The attention inbox: everything pending, and what the user has looked at.
///
/// **An event log, not a mirror.** The distinction decides the one case Loop 42
/// got wrong and could not fix from the tray: when a session's status report
/// goes stale, `AgentStatusService` returns `unknown` and the session drops out
/// of the attention set — so a badge that mirrors that set silently loses the
/// approval it was showing, and a user who walked away for ten minutes comes
/// back to a clean tray and a stuck agent.
///
/// Here, an item is removed only when one of three things is true:
///
/// * the watcher **can still see the session** and its condition has cleared;
/// * the user **looked at the source** (finished turns only — viewing an
///   approval request does not answer it);
/// * the user **dismissed** it.
///
/// Losing track of a session is none of those, so the item stays.
///
/// **Bounded, and evicted from the bottom of a ranking rather than the end of
/// a list.** See [kAttentionInboxCap] and [AttentionInbox._evict].
class AttentionInbox {
  /// The inbox holding exactly [items], newest first, capped.
  factory AttentionInbox({List<InboxItem> items = const []}) => _index(items);

  AttentionInbox._(
    this.items,
    this._byId,
    this._conditions,
    this._openIds,
    this.pending,
  );

  /// Indexes one list of items — one pass, and the only place a new inbox is
  /// built, so nothing can construct an inbox over the cap.
  static AttentionInbox _index(List<InboxItem> items) {
    final kept = items.length > kAttentionInboxCap ? _evict(items) : items;
    // (Under the cap in total, nothing can be over it in events either.)
    final byId = <String, InboxItem>{};
    final conditions = <InboxItem>[];
    final openIds = <String>{};
    final pending = <InboxItem>[];
    for (final item in kept) {
      byId[item.id] = item;
      if (item.kind.isCondition) conditions.add(item);
      openIds.add(item.session.openId);
      if (!item.seen) pending.add(item);
    }
    return AttentionInbox._(
      List.unmodifiable(kept),
      byId,
      conditions,
      openIds,
      List.unmodifiable(pending),
    );
  }

  /// Newest first.
  final List<InboxItem> items;

  /// [InboxItem.id] → item. What makes applying a poll linear: an upsert is a
  /// map lookup rather than a scan of every item, which at 500 sessions was
  /// 500 scans of a 500-item list per poll.
  final Map<String, InboxItem> _byId;

  /// The condition items, in list order. Only these can be retired by a poll,
  /// so only these are walked when one arrives.
  final List<InboxItem> _conditions;

  /// The workspace rows this inbox has items for, so looking at a session that
  /// has none costs a set lookup rather than a walk.
  final Set<String> _openIds;

  /// Unseen items, newest first — what the tray menu lists.
  ///
  /// Built once with the indexes rather than filtered per read. Two readers ask
  /// for it and neither asks rarely: the tray rebuilds its menu from this on
  /// every inbox change, and `projectSummaryProvider` is a `.family`, so it
  /// walked the whole list once per project on every rebuild — and a project
  /// header rebuilds when git answers, which is far more often than the inbox
  /// changes.
  final List<InboxItem> pending;

  static final empty = AttentionInbox();

  bool get isEmpty => items.isEmpty;

  /// The number every surface agrees on: the status bar's count, the side
  /// panel's badge and the tray's badge are all this.
  ///
  /// The length of [pending] rather than a second tally, so the badge cannot
  /// come to disagree with the menu it opens.
  int get unseen => pending.length;

  /// Folds one poll into the inbox.
  ///
  /// Linear in what the poll *says*, not in what the inbox holds: an upsert is
  /// one map lookup, and only condition items can be retired, so a poll that
  /// changes nothing allocates nothing and returns `this`.
  AttentionInbox apply(InboxUpdate update, DateTime now) {
    final addedIds = <String>{};
    final added = <InboxItem>[];

    void upsert(WatchedSession session, InboxItemKind kind) {
      final id = InboxItem.idFor(kind, session.key);
      // Already listed, or already added by the news half of this same update.
      // Either way it keeps its arrival time and its seen flag: a condition
      // that is still true is not a new thing to tell the user about.
      if (_byId.containsKey(id) || !addedIds.add(id)) return;
      added.add(InboxItem(session: session, kind: kind, at: now));
    }

    // News first, so an event and the state that confirms it are one item.
    for (final event in update.news) {
      upsert(event.session, InboxItemKind.of(event.reason));
    }
    for (final waiting in update.waiting) {
      upsert(waiting.session, InboxItemKind.ofAttention(waiting.kind));
    }

    // Retire conditions that have cleared — but only for sessions we could
    // actually see this poll.
    final retired = <String>{};
    if (_conditions.isNotEmpty && update.watched.isNotEmpty) {
      final stillWaiting = {
        for (final waiting in update.waiting)
          InboxItem.idFor(
            InboxItemKind.ofAttention(waiting.kind),
            waiting.session.key,
          ),
      };
      for (final item in _conditions) {
        if (!update.watched.contains(item.key)) continue;
        if (stillWaiting.contains(item.id)) continue;
        retired.add(item.id);
      }
    }

    // Identity when nothing moved: a poll every five seconds must not rebuild
    // the status bar, the panel and the tray for saying the same thing again —
    // and must not copy the list to discover that.
    if (added.isEmpty && retired.isEmpty) return this;
    return _index([
      // Each addition used to be inserted at the front in turn, so the last one
      // ended up first. Kept, because it is what orders the tray menu.
      ...added.reversed,
      for (final item in items)
        if (!retired.contains(item.id)) item,
    ]);
  }

  /// Records that the user is looking at [openIds] right now.
  ///
  /// An event you have looked at is done with; it leaves. A pending approval
  /// you have looked at is marked seen — it stops counting against the badge —
  /// but stays listed, because looking at a question does not answer it.
  AttentionInbox viewed(Set<String> openIds) {
    if (openIds.isEmpty) return this;
    if (!openIds.any(_openIds.contains)) return this;
    final next = <InboxItem>[];
    for (final item in items) {
      if (!openIds.contains(item.session.openId)) {
        next.add(item);
        continue;
      }
      if (!item.kind.isCondition) continue;
      next.add(item.seen ? item : item.copyWith(seen: true));
    }
    return _maybe(next);
  }

  /// "I have read the inbox." Events leave; conditions stay, seen.
  AttentionInbox markAllSeen() => _maybe([
    for (final item in items)
      if (item.kind.isCondition) item.copyWith(seen: true),
  ]);

  AttentionInbox dismiss(String id) {
    if (!_byId.containsKey(id)) return this;
    return _index([
      for (final item in items)
        if (item.id != id) item,
    ]);
  }

  AttentionInbox _maybe(List<InboxItem> next) {
    if (next.length == items.length) {
      var same = true;
      for (var i = 0; i < next.length; i++) {
        if (next[i] != items[i]) {
          same = false;
          break;
        }
      }
      if (same) return this;
    }
    return _index(next);
  }

  /// Drops the least useful events until at most [kAttentionInboxCap] remain.
  ///
  /// Conditions are never candidates — see [kAttentionInboxCap]. Among events,
  /// an unread one outranks a read one, because an item you have already looked
  /// at is one the inbox has finished doing its job for; then the newer
  /// outranks the older. So the first thing evicted is the oldest finished turn
  /// you have already read, and the last is the newest one you have not.
  static List<InboxItem> _evict(List<InboxItem> items) {
    final events = <int>[];
    for (var i = 0; i < items.length; i++) {
      if (!items[i].kind.isCondition) events.add(i);
    }
    if (events.length <= kAttentionInboxCap) return items;
    events.sort((a, b) {
      final left = items[a];
      final right = items[b];
      if (left.seen != right.seen) return left.seen ? 1 : -1;
      final byAge = right.at.compareTo(left.at);
      return byAge != 0 ? byAge : a.compareTo(b);
    });
    final dropped = events.skip(kAttentionInboxCap).toSet();
    return [
      for (var i = 0; i < items.length; i++)
        if (!dropped.contains(i)) items[i],
    ];
  }
}
