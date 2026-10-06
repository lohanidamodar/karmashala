import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart' show matchesSearchAny;
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:riverpod/riverpod.dart';

import '../../git/application/changes_providers.dart';
import '../../sessions/application/delivery_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../../workspaces/data/workspace_data.dart';
import 'checkout_picker.dart';
import 'picked_checkouts.dart';

/// One worktree of the selected checkout's repository, as the worktree
/// switcher and quick open list it. The counts are what is already known —
/// sessions in memory, the delivery cache — never a git call of its own.
class WorktreeChoice {
  const WorktreeChoice({
    required this.path,
    this.branch,
    this.repository,
    this.isMain = false,
    this.current = false,
    this.sessions = 0,
    this.active = false,
    this.lastActivity,
    this.dirtyFiles,
    this.ahead,
    this.behind,
    this.merged = false,
  });

  final EnvironmentPath path;

  /// Null when detached.
  final String? branch;

  /// The workspace's row for it; null until a rescan records it.
  final Repository? repository;

  /// The repository's main worktree, never stale.
  final bool isMain;

  /// The one the checkout-scoped surfaces describe now.
  final bool current;

  /// Sessions working there, archived ones left out.
  final int sessions;

  /// A live session works there, or the one on screen does.
  final bool active;

  /// When the newest session there started.
  final DateTime? lastActivity;

  final int? dirtyFiles;
  final int? ahead;
  final int? behind;

  /// Nothing on it that its base lacks, by the cached reading.
  final bool merged;

  String get folder => lastPathSegment(path.path);

  String get label => branch ?? folder;

  /// Merged, clean and unused: listed out of the way, under "Merged".
  bool get isStale =>
      merged && !isMain && !current && sessions == 0 && dirtyFiles == 0;
}

/// The switcher's two groups, each in the order it is drawn.
class WorktreeChoices {
  const WorktreeChoices({required this.open, required this.merged});

  static const empty = WorktreeChoices(open: [], merged: []);

  final List<WorktreeChoice> open;
  final List<WorktreeChoice> merged;

  List<WorktreeChoice> get all => [...open, ...merged];

  WorktreeChoice? get current => open.where((c) => c.current).firstOrNull;

  /// The rows [query] finds by branch or folder, separators and case aside.
  WorktreeChoices where(String query) => WorktreeChoices(
    open: filterWorktreeChoices(open, query),
    merged: filterWorktreeChoices(merged, query),
  );
}

/// The current worktree first, then the ones a live or on-screen session
/// works in, then the rest by last activity; stale ones go to their own group.
WorktreeChoices arrangeWorktreeChoices(Iterable<WorktreeChoice> choices) {
  int rank(WorktreeChoice c) => c.current
      ? 0
      : c.active
      ? 1
      : 2;
  final sorted = choices.toList()
    ..sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      final at = a.lastActivity;
      final bt = b.lastActivity;
      if (at != bt) {
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      }
      if (a.isMain != b.isMain) return a.isMain ? -1 : 1;
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
  return WorktreeChoices(
    open: [
      for (final c in sorted)
        if (!c.isStale) c,
    ],
    merged: [
      for (final c in sorted)
        if (c.isStale) c,
    ],
  );
}

/// [choices] that [query] finds by branch or folder name.
List<WorktreeChoice> filterWorktreeChoices(
  List<WorktreeChoice> choices,
  String query,
) => [
  for (final choice in choices)
    if (matchesSearchAny(query, [choice.branch, choice.folder])) choice,
];

/// The selected checkout's worktrees, arranged for the switcher; null while
/// git has not answered, or when the checkout is not a repository.
final worktreeChoicesProvider = Provider.autoDispose<WorktreeChoices?>((ref) {
  final selected = ref.watch(selectedCheckoutProvider);
  if (selected == null) return null;
  final listed = ref.watch(repoWorktreesProvider).asData?.value;
  if (listed == null || listed.isEmpty) return null;
  ref.watchSessionKinds(const {
    SessionChangeKind.membership,
    SessionChangeKind.status,
    SessionChangeKind.placement,
    SessionChangeKind.workspace,
  });
  // The session the panel follows, not the pane lookup it mirrors: that
  // would build the whole terminal controller.
  final onScreen = ref.watch(followedSessionProvider);
  // A reading arriving anywhere may be one of these rows'.
  ref.watch(checkoutReadingsProvider);

  final rows = ref
      .read(workspaceDataProvider)
      .repositoriesOf(selected.projectId);
  final byPlace = {for (final r in rows) Checkout(r.path): r};
  final pathById = {for (final r in rows) r.id: r.path};

  final sessionsAt = <Checkout, List<Session>>{};
  for (final session in ref.read(sessionsDataProvider).getAll()) {
    if (session.archivedAt != null) continue;
    final place = session.worktree ?? pathById[session.repositoryId];
    if (place == null) continue;
    sessionsAt.putIfAbsent(Checkout(place), () => []).add(session);
  }

  SessionDelivery? cached(EnvironmentPath path) {
    final provider = checkoutDeliveryProvider(Checkout(path));
    if (!ref.exists(provider)) return null;
    return ref.read(provider).asData?.value;
  }

  bool isActive(Session session) =>
      session.id == onScreen || session.status.claimsLive;

  final selectedPlace = Checkout(selected.path);
  return arrangeWorktreeChoices([
    for (final (index, worktree) in listed.indexed)
      if (!worktree.isBare && !worktree.isPrunable)
        () {
          final place = Checkout(worktree.path);
          final here = sessionsAt[place] ?? const <Session>[];
          final reading = cached(worktree.path);
          DateTime? last;
          for (final session in here) {
            if (last == null || session.createdAt.isAfter(last)) {
              last = session.createdAt;
            }
          }
          return WorktreeChoice(
            path: byPlace[place]?.path ?? worktree.path,
            branch: worktree.branch,
            repository: byPlace[place],
            isMain: index == 0,
            current: place == selectedPlace,
            sessions: here.length,
            active: here.any(isActive),
            lastActivity: last,
            dirtyFiles: reading?.dirtyFiles,
            ahead: reading?.aheadOfBase,
            behind: reading?.behindBase,
            merged:
                reading?.aheadOfBase == 0 &&
                reading?.dirtyFiles == 0 &&
                worktree.branch != null,
          );
        }(),
  ]);
});
