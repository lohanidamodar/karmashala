import 'agent_session_key.dart';
import 'attention_json.dart';
import 'evidence_line.dart';
import 'notification_policy.dart';
import 'session_attention.dart';
import 'watched_session.dart';

/// Who may take an item off the attention inbox — exactly one per
/// [InboxItemKind], and the wrong one is silent in both directions.
enum InboxRetirement {
  /// The agent status watcher, when it can see the session and the condition
  /// has cleared. Only for things the watcher actually observes.
  agentWatcher,

  /// Looking at the source. For things that already happened, where looking is
  /// the whole of dealing with them.
  viewing,

  /// The store that raised it, and nothing else. For things that outlive both
  /// a poll and a glance.
  source,
}

/// Why something is in the attention inbox. The same events a toast reports,
/// but a queue rather than an interruption: toasts off must not empty the list.
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
  readyToMerge,

  /// A session ended and left something behind — see `FollowUp`.
  followUp,

  /// An agent's turn ended on its account's usage limit.
  usageLimit,

  /// A turn the session host's stop cut off: continued at its next start, or
  /// left for a person with the reason.
  turnCutOff;

  /// Who is entitled to take an item of this kind off the list.
  InboxRetirement get retirement => switch (this) {
    // State the watcher can see stop: it is looking at exactly this every poll.
    InboxItemKind.needsApproval ||
    InboxItemKind.failed => InboxRetirement.agentWatcher,
    // Events. A turn that ended stays ended and a build that went red went red,
    // so looking at the source is what finishes them.
    InboxItemKind.finished ||
    InboxItemKind.checksFailed ||
    InboxItemKind.changesRequested ||
    InboxItemKind.readyToMerge ||
    InboxItemKind.usageLimit ||
    InboxItemKind.turnCutOff => InboxRetirement.viewing,
    // Neither: the watcher would sweep this away on its next poll, and glancing
    // at a crashed session does not deal with what it left.
    InboxItemKind.followUp => InboxRetirement.source,
  };

  /// Whether this kind is a condition still true right now. Load-bearing: a
  /// delivery item marked one would be swept away by a poll that knows no PRs.
  bool get isCondition => retirement == InboxRetirement.agentWatcher;

  String get label => switch (this) {
    InboxItemKind.needsApproval => 'Needs approval',
    InboxItemKind.failed => 'Failed',
    InboxItemKind.finished => 'Finished',
    InboxItemKind.checksFailed => 'Checks failed',
    InboxItemKind.changesRequested => 'Changes requested',
    InboxItemKind.readyToMerge => 'Ready to merge',
    InboxItemKind.followUp => 'Needs a follow-up',
    InboxItemKind.usageLimit => 'Usage limit reached',
    InboxItemKind.turnCutOff => 'Turn cut off',
  };

  /// The kind written on the wire. A kind added after 1.31 travels as
  /// [followUp] with its own name beside it: a released client throws on a
  /// kind it does not know, and that loses the whole batch it came in.
  String get wireName => switch (this) {
    InboxItemKind.turnCutOff => InboxItemKind.followUp.name,
    _ => name,
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
    this.detail,
    String? id,
  }) : id = id ?? idFor(kind, session.key);

  final WatchedSession session;
  final InboxItemKind kind;

  /// When this entered the inbox, not when it happened at the agent — ordering
  /// only. A follow-up is the exception: it carries the moment it was raised.
  final DateTime at;

  /// The source's own words about this item, or null when it gave none. Never
  /// synthesised — an empty line reads as "not recorded", which is honest.
  final String? detail;

  /// Whether the user has looked at the source since this arrived.
  final bool seen;

  AgentSessionKey get key => session.key;

  /// Stable across polls, so an item keeps its place and [seen] flag. Stored,
  /// not computed: a getter interpolating a new string per read was the cost.
  final String id;

  /// The id an item for [kind] and [key] would have. A follow-up passes its own
  /// instead: two workspace sessions can share one CLI conversation id.
  static String idFor(InboxItemKind kind, AgentSessionKey key) =>
      '${kind.name}:$key';

  String get label => session.label;

  InboxItem copyWith({bool? seen}) => InboxItem(
    session: session,
    kind: kind,
    at: at,
    seen: seen ?? this.seen,
    detail: detail,
    id: id,
  );

  /// The one-line form used in the tray menu — the list's own wording, so the
  /// tray and the inbox cannot come to describe the same item differently.
  String get menuLabel => '${session.label} — ${kind.label.toLowerCase()}';

  @override
  bool operator ==(Object other) =>
      other is InboxItem &&
      other.id == id &&
      other.session == session &&
      other.kind == kind &&
      other.at == at &&
      other.seen == seen &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(id, session, kind, at, seen, detail);

  @override
  String toString() => 'InboxItem($id, seen: $seen)';

  Map<String, Object?> toJson() => {
    'id': id,
    'session': session.toJson(),
    'kind': kind.wireName,
    if (kind.wireName != kind.name) 'kindName': kind.name,
    'at': at.toUtc().toIso8601String(),
    if (seen) 'seen': true,
    'detail': ?detail,
  };

  static InboxItem fromJson(Object? json) {
    final map = attentionObject(json, 'inbox item');
    final named = map['kindName'];
    return InboxItem(
      id: attentionString(map, 'id'),
      session: WatchedSession.fromJson(map['session']),
      kind: InboxItemKind.values.firstWhere(
        (kind) => kind.name == named,
        orElse: () => attentionEnum(InboxItemKind.values, map, 'kind'),
      ),
      at: attentionTime(map, 'at'),
      seen: map['seen'] == true,
      detail: map['detail'] as String?,
    );
  }
}

/// What the watcher observed in one poll, in the terms the inbox needs.
class InboxUpdate {
  const InboxUpdate({
    this.waiting = const [],
    this.watched = const {},
    this.news = const [],
    this.details = const {},
  });

  /// Sessions whose *current* status is a condition needing the user.
  final List<SessionAttention> waiting;

  /// Every session the watcher looked at this poll. The difference from
  /// [waiting] retires a cleared condition without retiring an unseen one.
  final Set<AgentSessionKey> watched;

  /// News since the last poll, ungated by settings or focus.
  final List<({WatchedSession session, NotificationReason reason})> news;

  /// The agent's own words for a session this poll looked at. Absent for a
  /// source that quoted nothing, which is the normal case — see [evidenceLine].
  final Map<AgentSessionKey, String> details;
}

/// How many *event* items the attention inbox keeps. Conditions and follow-ups
/// are exempt: an evicted one is re-filed next poll and displaces a survivor.
const int kAttentionInboxCap = 200;

/// Everything pending, and what the user has looked at. An event log, not a
/// mirror: losing sight of a session never removes an item.
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

  /// The item to jump to next, given the session on screen. Walks [items] so
  /// there is one order; wraps, and an unknown [openId] starts at the first.
  /// [where] narrows the walk to the items it accepts.
  InboxItem? nextAfter(String? openId, {bool Function(InboxItem item)? where}) {
    final walk = where == null ? items : items.where(where).toList();
    if (walk.isEmpty) return null;
    if (openId == null) return walk.first;
    final at = walk.indexWhere((item) => item.session.openId == openId);
    if (at < 0) return walk.first;
    return walk[(at + 1) % walk.length];
  }

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

  /// [InboxItem.id] → item: an upsert is a map lookup, not a scan that at 500
  /// sessions meant 500 walks of a 500-item list per poll.
  final Map<String, InboxItem> _byId;

  /// The condition items, in list order. Only these can be retired by a poll,
  /// so only these are walked when one arrives.
  final List<InboxItem> _conditions;

  /// The workspace rows this inbox has items for, so looking at a session that
  /// has none costs a set lookup rather than a walk.
  final Set<String> _openIds;

  /// Unseen items, newest first — the tray menu. Built once with the indexes:
  /// `projectSummaryProvider` is a `.family` and rebuilds whenever git answers.
  final List<InboxItem> pending;

  static final empty = AttentionInbox();

  /// Every item, newest first: the wire shape of a whole inbox.
  List<Map<String, Object?>> toJson() => [
    for (final item in items) item.toJson(),
  ];

  static AttentionInbox fromJson(Object? json) {
    if (json is! List) {
      throw const AttentionFormatException('an inbox is not a list');
    }
    return AttentionInbox(
      items: [for (final item in json) InboxItem.fromJson(item)],
    );
  }

  bool get isEmpty => items.isEmpty;

  /// The one count every surface shows — the length of [pending], not a second
  /// tally, so a badge cannot disagree with the menu it opens.
  int get unseen => pending.length;

  /// Folds one poll into the inbox — linear in what the poll says, and returns
  /// `this` when nothing changed.
  AttentionInbox apply(InboxUpdate update, DateTime now) {
    final addedIds = <String>{};
    final added = <InboxItem>[];
    final rebound = <String, WatchedSession>{};

    // A row is keyed anew once its conversation id is recorded, and that is
    // the same item. Indexed only on a miss, so a steady poll stays linear.
    Map<String, InboxItem>? byRow;
    String rowOf(InboxItemKind kind, WatchedSession session) =>
        '${kind.name}:${session.imported}:${session.openId}';

    void upsert(WatchedSession session, InboxItemKind kind) {
      final id = InboxItem.idFor(kind, session.key);
      final listed =
          _byId[id] ??
          (byRow ??= {
            for (final item in items)
              if (item.kind != InboxItemKind.followUp)
                rowOf(item.kind, item.session): item,
          })[rowOf(kind, session)];
      if (listed != null) {
        // Already listed: keeps its arrival time and seen flag. But where to go
        // for it is not identity, so a rebound session must replace the old one.
        if (listed.session != session) rebound[listed.id] = session;
        return;
      }
      // Already added by the news half of this same update.
      if (!addedIds.add(id)) return;
      added.add(
        InboxItem(
          session: session,
          kind: kind,
          at: now,
          detail: update.details[session.key],
        ),
      );
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
    // the strip badges, the panel and the tray for saying the same thing again.
    if (added.isEmpty && retired.isEmpty && rebound.isEmpty) return this;
    return _index([
      // Reversed, because the last addition ends up first in the tray menu.
      ...added.reversed,
      for (final item in items)
        if (!retired.contains(item.id))
          if (rebound[item.id] case final session?)
            InboxItem(
              session: session,
              kind: item.kind,
              at: item.at,
              seen: item.seen,
            )
          else
            item,
    ]);
  }

  /// Records that the user is looking at [openIds]. Events leave; an approval
  /// or follow-up is only marked seen — looking at a question does not answer it.
  AttentionInbox viewed(Set<String> openIds) {
    if (openIds.isEmpty) return this;
    if (!openIds.any(_openIds.contains)) return this;
    final next = <InboxItem>[];
    for (final item in items) {
      if (!openIds.contains(item.session.openId)) {
        next.add(item);
        continue;
      }
      if (item.kind.retirement == InboxRetirement.viewing) continue;
      next.add(item.seen ? item : item.copyWith(seen: true));
    }
    return _maybe(next);
  }

  /// "I have read the inbox." Events leave; anything nobody else may retire
  /// stays, seen.
  AttentionInbox markAllSeen() => _maybe([
    for (final item in items)
      if (item.kind.retirement != InboxRetirement.viewing)
        item.copyWith(seen: true),
  ]);

  /// Replaces the follow-up half with what the store holds. A surviving item
  /// keeps its arrival time and seen flag, or every sync re-files it as news.
  AttentionInbox syncFollowUps(List<InboxItem> followUps) {
    final arriving = {for (final item in followUps) item.id: item};
    var retired = false;
    final kept = <InboxItem>[];
    for (final item in items) {
      if (item.kind != InboxItemKind.followUp) {
        kept.add(item);
        continue;
      }
      if (arriving.remove(item.id) == null) {
        retired = true;
        continue;
      }
      kept.add(item);
    }
    if (!retired && arriving.isEmpty) return this;
    return _index([...arriving.values, ...kept]);
  }

  /// Files [item], or replaces the one with its id: a second limit on one
  /// session is the same item with newer words.
  AttentionInbox raise(InboxItem item) => _index([
    item,
    for (final listed in items)
      if (listed.id != item.id) listed,
  ]);

  /// Retires the asks of native sessions [openIds] that have ended: an agent
  /// that is gone waits on nobody, and no poll watches it to see that clear.
  AttentionInbox retireAsksOf(Set<String> openIds) {
    if (openIds.isEmpty) return this;
    return _maybe([
      for (final item in items)
        if (item.kind != InboxItemKind.needsApproval ||
            item.session.imported ||
            !openIds.contains(item.session.openId))
          item,
    ]);
  }

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

  /// Drops the least useful events until [kAttentionInboxCap] remain. Only
  /// items retired by viewing are candidates; unread outranks read, newer older.
  static List<InboxItem> _evict(List<InboxItem> items) {
    final events = <int>[];
    for (var i = 0; i < items.length; i++) {
      if (items[i].kind.retirement == InboxRetirement.viewing) events.add(i);
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
