import 'package:flutter_riverpod/flutter_riverpod.dart';

/// **What a change to the session list actually touched.** One global counter
/// woke all twenty-eight watchers: renaming one session cost 108 reads at 100.
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

  /// A row's own policy — today, its permission mode. Only the per-session
  /// chip that draws it watches this.
  settings,

  /// Projects, repositories and checkouts — not a session fact, but the
  /// checkout picker and the delivery providers watch this counter *for it*.
  workspace,
}

/// One published change: which concerns it touched, and which row. A null
/// [sessionId] means "rows we cannot name", so every per-session watcher wakes.
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

  /// A row's title changed and nothing else — the most frequent change in the
  /// app, since the CLI store sweep's title sync fires on a timer.
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

  /// **The coarse signal**: every watcher wakes, narrowed or not. Kept as
  /// expensive as it was — a watcher that silently stopped would be worse.
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

/// A monotonic counter per concern, and one per row that changed. Counters,
/// not events: a watcher that missed a frame still sees the number move.
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

  /// Changes that named no row — the floor under every per-session counter, so
  /// a coarse bump cannot leave one behind. Read through [forSession].
  final int broadcasts;

  final Map<SessionChangeKind, int> byKind;
  final Map<String, int> bySession;

  /// The number a watcher of [kinds] reads. A sum, because each counter only
  /// ever rises: it moves if and only if one of the kinds moved.
  int forKinds(Set<SessionChangeKind> kinds) {
    var total = 0;
    for (final kind in kinds) {
      total += byKind[kind] ?? 0;
    }
    return total;
  }

  /// The number a watcher of one row reads. Includes [broadcasts], so a change
  /// naming no row — the coarse `bump()`, a project rescan — still wakes it.
  int forSession(String sessionId) => broadcasts + (bySession[sessionId] ?? 0);

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

/// **The coarse signal: "something about sessions changed".** A counter this
/// controller *writes*: deriving it made three bare `listen`s miss every bump.
class SessionsRevisionController extends Notifier<int> {
  @override
  int build() => 0;

  /// Publishes a change that says nothing but its own existence — still the
  /// honest word for a launch, which mints a row and claims a pane.
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
