import 'package:flutter_riverpod/flutter_riverpod.dart';

/// **What a change to the session list actually touched.**
///
/// `sessionsRevisionProvider` is one global counter with sixteen bump sites and
/// twenty-eight watchers. Every bump invalidates all twenty-eight, and several
/// of them answer with a full synchronous `SELECT * FROM sessions` — and
/// `package:sqlite3` is synchronous, so that scan runs on the UI isolate,
/// inside the frame. So one narrow fact ("a session's title changed") woke
/// everything that cares about sessions at all, including code that scans every
/// row. `session_signal_cost_test.dart` measured it: renaming one session cost
/// **9 reads at 1 session, 18 at 10 and 108 at 100**, four of them unfiltered
/// table scans, plus a `git worktree list` subprocess.
///
/// These are the concerns a watcher can subscribe to instead. A watcher names
/// what it actually reads, and a change that touched nothing on its list leaves
/// it asleep.
enum SessionChangeKind {
  /// A row appeared or went away — the shape of the list changed.
  membership,

  /// A row's title changed, and nothing else about it.
  title,

  /// A row started, stopped, failed or was archived.
  status,

  /// Where a row lives: its pane, its repository, its worktree, or the CLI
  /// conversation it is on.
  placement,

  /// A row's own policy — today, its permission mode. No global surface reads
  /// it; the chip that draws it is per-session and watches [SessionSignals.forSession].
  settings,

  /// Projects, repositories and checkouts. Not a session fact at all, but the
  /// projects controller has always published it on this same counter, and the
  /// checkout picker and the delivery providers are watching *for it* rather
  /// than for anything about sessions.
  workspace,
}

/// One published change: which concerns it touched, and which row it was about.
///
/// A null [sessionId] means "this touched rows we cannot name". Every
/// per-session watcher must then wake, because we cannot honestly say it did
/// not — see [SessionSignals.forSession].
class SessionChange {
  const SessionChange({required this.kinds, this.sessionId});

  /// A row appeared: the list grew, and the new row brought a status and a
  /// place with it.
  const SessionChange.created(String this.sessionId)
    : kinds = const {
        SessionChangeKind.membership,
        SessionChangeKind.status,
        SessionChangeKind.placement,
      };

  /// A row went away.
  const SessionChange.removed(String this.sessionId)
    : kinds = const {
        SessionChangeKind.membership,
        SessionChangeKind.status,
        SessionChangeKind.placement,
      };

  /// A row's title changed and nothing else did.
  ///
  /// The narrowest and by far the most frequent change in the app: the CLI
  /// store sweep's title sync fires on a timer, so this one runs without the
  /// user doing anything at all.
  const SessionChange.renamed(String this.sessionId)
    : kinds = const {SessionChangeKind.title};

  /// A row started, stopped, failed, or was archived.
  const SessionChange.statusChanged(String this.sessionId)
    : kinds = const {SessionChangeKind.status};

  /// A row's pane, repository, worktree or conversation id changed.
  const SessionChange.moved(String this.sessionId)
    : kinds = const {SessionChangeKind.placement};

  /// A row's own policy changed — its permission mode.
  const SessionChange.reconfigured(String this.sessionId)
    : kinds = const {SessionChangeKind.settings};

  /// Archiving: the status moves, and so does the working tree the row named.
  const SessionChange.archived(String this.sessionId)
    : kinds = const {
        SessionChangeKind.status,
        SessionChangeKind.workspace,
        SessionChangeKind.placement,
      };

  /// Projects or repositories moved. Names no session, so every per-session
  /// watcher wakes — a rescan can retire the repository a session points at.
  const SessionChange.workspaceChanged()
    : kinds = const {
        SessionChangeKind.workspace,
        SessionChangeKind.membership,
        SessionChangeKind.placement,
      },
      sessionId = null;

  /// **The coarse signal.** Says only "something about sessions changed", so
  /// every watcher wakes, narrowed or not.
  ///
  /// This is what `SessionsRevisionController.bump()` publishes, and therefore
  /// what every bump site that has not been given a narrower word still
  /// publishes. Keeping it exactly as expensive as it always was is the point:
  /// a half-migrated system where one watcher silently stops updating is far
  /// worse than a slow one.
  static const everything = SessionChange(kinds: _allKinds);

  static const _allKinds = {
    SessionChangeKind.membership,
    SessionChangeKind.title,
    SessionChangeKind.status,
    SessionChangeKind.placement,
    SessionChangeKind.settings,
    SessionChangeKind.workspace,
  };

  final Set<SessionChangeKind> kinds;

  /// The row this was about, or null when it named none.
  final String? sessionId;
}

/// A monotonic counter per concern, and one per row that has changed.
///
/// Counters rather than a change *event*: a watcher reads its own number
/// through `select`, so Riverpod compares an `int` and rebuilds nothing when
/// the number stood still. A watcher that misses a frame still sees the number
/// move, which an event stream could not promise.
class SessionSignals {
  const SessionSignals._({
    required this.revision,
    required this.broadcasts,
    required this.byKind,
    required this.bySession,
  });

  static const initial = SessionSignals._(
    revision: 0,
    broadcasts: 0,
    byKind: {},
    bySession: {},
  );

  /// Every change, of every kind. What `sessionsRevisionProvider` publishes.
  final int revision;

  /// Changes that named no row. Floor under every per-session counter, so a
  /// coarse bump cannot leave a per-session watcher behind.
  ///
  /// Read through [forKinds] and [forSession] rather than directly: the whole
  /// value of this type is that a watcher subscribes to one number.
  final int broadcasts;

  final Map<SessionChangeKind, int> byKind;
  final Map<String, int> bySession;

  /// The number a watcher of [kinds] reads.
  ///
  /// A sum, because each counter only ever rises: the sum moves if and only if
  /// one of the kinds moved, which is exactly the question.
  int forKinds(Set<SessionChangeKind> kinds) {
    var total = 0;
    for (final kind in kinds) {
      total += byKind[kind] ?? 0;
    }
    return total;
  }

  /// The number a watcher of one row reads.
  ///
  /// Includes [broadcasts] so that a change naming no row — the coarse
  /// `bump()`, a project rescan — still wakes it.
  int forSession(String sessionId) =>
      broadcasts + (bySession[sessionId] ?? 0);

  SessionSignals after(SessionChange change) {
    final kinds = Map<SessionChangeKind, int>.of(byKind);
    for (final kind in change.kinds) {
      kinds[kind] = (kinds[kind] ?? 0) + 1;
    }
    final id = change.sessionId;
    // Only the targeted case copies the per-row map, and it holds one entry per
    // row that has *changed* this run — not one per row in the database.
    final rows = id == null
        ? bySession
        : (Map<String, int>.of(bySession)..[id] = (bySession[id] ?? 0) + 1);
    return SessionSignals._(
      revision: revision + 1,
      broadcasts: id == null ? broadcasts + 1 : broadcasts,
      byKind: kinds,
      bySession: rows,
    );
  }
}

/// Holds the counters. Written only through [SessionsRevisionController], so
/// the coarse and narrow halves can never drift apart.
class SessionSignalsController extends Notifier<SessionSignals> {
  @override
  SessionSignals build() => SessionSignals.initial;

  void record(SessionChange change) => state = state.after(change);
}

final sessionSignalsProvider =
    NotifierProvider<SessionSignalsController, SessionSignals>(
      SessionSignalsController.new,
    );

/// **The coarse signal: "something about sessions changed".**
///
/// Every change still moves this, whichever word it was published with, so a
/// watcher that has not been narrowed behaves exactly as it always did. That is
/// deliberate and load-bearing: a half-migrated system where one watcher
/// silently stops updating is far worse than a slow one, so nothing here is
/// allowed to get quieter by accident.
///
/// It is a counter this controller **writes**, rather than one derived from
/// [sessionSignalsProvider], and that is not an accident either: a derived
/// value is recomputed when Riverpod next flushes, whereas three callers
/// (`McpSessionTokenReaper`, the repo file index, the remote controller) hold a
/// bare `listen` on this and were written expecting the notification the moment
/// the write happens. Deriving it made all three miss every bump.
///
/// A watcher that knows what it reads should say so instead — see
/// [SessionChangeKind], [SessionSignalRef.watchSessionKinds] and
/// [SessionSignalRef.watchSession]. This counter is the fallback, not the
/// interface.
class SessionsRevisionController extends Notifier<int> {
  @override
  int build() => 0;

  /// Publishes a change that says nothing more specific than its own
  /// existence. Still the honest word for a caller that genuinely does not know
  /// what moved — a launch mints a row, writes a status and claims a pane.
  void bump() => changed(SessionChange.everything);

  /// **The one write path.** Narrow first, so a coarse listener woken by the
  /// line below already sees the detail.
  void changed(SessionChange change) {
    ref.read(sessionSignalsProvider.notifier).record(change);
    state++;
  }
}

final sessionsRevisionProvider =
    NotifierProvider<SessionsRevisionController, int>(
      SessionsRevisionController.new,
    );

/// Rebuilds only when one of the named concerns moves.
extension SessionSignalRef on Ref {
  /// For a provider that reads sessions: name what it reads.
  void watchSessionKinds(Set<SessionChangeKind> kinds) =>
      watch(sessionSignalsProvider.select((s) => s.forKinds(kinds)));

  /// For a provider that describes exactly one row.
  void watchSession(String sessionId) =>
      watch(sessionSignalsProvider.select((s) => s.forSession(sessionId)));

  /// Publishes [change] through the one write path.
  void publishSessionChange(SessionChange change) =>
      read(sessionsRevisionProvider.notifier).changed(change);
}

/// The same two narrowings, for a widget.
extension SessionSignalWidgetRef on WidgetRef {
  void watchSessionKinds(Set<SessionChangeKind> kinds) =>
      watch(sessionSignalsProvider.select((s) => s.forKinds(kinds)));

  void watchSession(String sessionId) =>
      watch(sessionSignalsProvider.select((s) => s.forSession(sessionId)));

  void publishSessionChange(SessionChange change) =>
      read(sessionsRevisionProvider.notifier).changed(change);
}
