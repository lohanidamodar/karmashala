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
  const InboxItem({
    required this.session,
    required this.kind,
    required this.at,
    this.seen = false,
  });

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
  String get id => '${kind.name}:${session.key}';

  String get label => session.label;

  InboxItem copyWith({bool? seen}) =>
      InboxItem(session: session, kind: kind, at: at, seen: seen ?? this.seen);

  /// The one-line form used in the tray menu.
  String get menuLabel => switch (kind) {
    InboxItemKind.needsApproval => '${session.label} — needs approval',
    InboxItemKind.failed => '${session.label} — failed',
    InboxItemKind.finished => '${session.label} — finished',
    InboxItemKind.checksFailed => '${session.label} — checks failed',
    InboxItemKind.changesRequested => '${session.label} — changes requested',
    InboxItemKind.readyToMerge => '${session.label} — ready to merge',
  };

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
class AttentionInbox {
  const AttentionInbox({this.items = const []});

  /// Newest first.
  final List<InboxItem> items;

  static const empty = AttentionInbox();

  /// The number every surface agrees on: the status bar's count, the side
  /// panel's badge and the tray's badge are all this.
  int get unseen => items.where((item) => !item.seen).length;

  bool get isEmpty => items.isEmpty;

  /// Unseen items, newest first — what the tray menu lists.
  List<InboxItem> get pending =>
      items.where((item) => !item.seen).toList(growable: false);

  /// Folds one poll into the inbox.
  AttentionInbox apply(InboxUpdate update, DateTime now) {
    final next = [...items];

    int indexOf(String id) => next.indexWhere((item) => item.id == id);

    void upsert(WatchedSession session, InboxItemKind kind) {
      final item = InboxItem(session: session, kind: kind, at: now);
      final existing = indexOf(item.id);
      if (existing >= 0) {
        // Already listed. Keep its arrival time and its seen flag: a condition
        // that is still true is not a new thing to tell the user about.
        return;
      }
      next.insert(0, item);
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
    final stillWaiting = {
      for (final waiting in update.waiting)
        '${InboxItemKind.ofAttention(waiting.kind).name}:${waiting.session.key}',
    };
    next.removeWhere(
      (item) =>
          item.kind.isCondition &&
          update.watched.contains(item.key) &&
          !stillWaiting.contains(item.id),
    );

    // Identity when nothing moved: a poll every five seconds must not rebuild
    // the status bar, the panel and the tray for saying the same thing again.
    return _maybe(next);
  }

  /// Records that the user is looking at [openIds] right now.
  ///
  /// An event you have looked at is done with; it leaves. A pending approval
  /// you have looked at is marked seen — it stops counting against the badge —
  /// but stays listed, because looking at a question does not answer it.
  AttentionInbox viewed(Set<String> openIds) {
    if (openIds.isEmpty) return this;
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

  AttentionInbox dismiss(String id) =>
      _maybe([...items]..removeWhere((item) => item.id == id));

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
    return AttentionInbox(items: List.unmodifiable(next));
  }
}
