import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../git/application/changes_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'checkout.dart';
import 'picked_checkouts.dart';

/// The session running in the pane the terminal is showing, or null.
///
/// Keyed off the *pane on screen*, not off the Explorer's selection: switching
/// terminal tabs changes which agent you are looking at, and anything that
/// followed the tree instead would describe a session the user is not in. A
/// plain shell tab has no session row pointing at it and answers null, which is
/// what leaves the Explorer's own selection in charge.
final activePaneSessionIdProvider = Provider<String?>((ref) {
  final terminals = ref.watch(terminalSessionsControllerProvider);
  // Adopting a pane, or launching into one, rewrites `pane_id` on the row.
  ref.watch(sessionsRevisionProvider);
  final paneId = terminals.activeTab?.focusedPaneId;
  if (paneId == null) return null;
  for (final record in ref.read(sessionDaoProvider).getAll()) {
    if (record.paneId == paneId) return record.id;
  }
  return null;
});

/// The repository whose checkout contains [sessionId]'s work.
///
/// **The deepest registered repository that contains the session's working
/// directory**, which is the rule `placeSessions` already uses to decide which
/// Explorer row a session is drawn on — a session in `hub/projects/app` belongs
/// to `app`, not to the `hub` that contains it, even though both are ancestors.
/// The directory is the one the tree reads too (`Session.worktree` when it has a
/// worktree, otherwise its repository's checkout), so the row a session is drawn
/// on and the repository the side panel describes cannot disagree.
///
/// Falls back to the session's own `repositoryId` when nothing contains it — a
/// different environment, or a directory outside every registered checkout.
Repository? repositoryForSession(Ref ref, String sessionId) {
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  if (session == null) return null;
  final repositories = ref.read(repositoryDaoProvider);
  final own = repositories.getById(session.repositoryId);
  final directory = session.worktree ?? own?.path;
  if (directory == null) return own;

  Repository? best;
  for (final repository in repositories.getAll()) {
    if (!isUnder(repository.path, directory)) continue;
    if (best == null || pathDepth(repository.path) > pathDepth(best.path)) {
      best = repository;
    }
  }
  return best ?? own;
}

/// Moves the workspace's context to the session the user is working in.
///
/// The side panel's whole family — changes and diffs, repository info and
/// worktrees, GitHub and its remote links — reads one provider,
/// [selectedRepositoryIdProvider], and until now only the Explorer ever wrote
/// it. So the panel described whatever row was last clicked, which for a hub
/// project is the hub, while the user was typing into an agent three folders
/// down. This is the missing writer.
///
/// **Who wins.** The active session writes the context whenever it *changes* —
/// activating another terminal tab, or the workbench revealing a session. An
/// explicit Explorer click writes it too and then holds, because nothing
/// overwrites it until the active session changes again. A tab with no session
/// writes nothing at all, so the Explorer's selection stays in charge.
class SessionContext {
  const SessionContext(this._ref);

  final Ref _ref;

  /// Points the Explorer and the side panel at [sessionId]'s repository, and at
  /// the project above it — selecting a repository whose project is not the
  /// selected one leaves the tree pointing elsewhere, which is the same walk
  /// `focusWatchedSession` does for the attention inbox.
  ///
  /// Returns the repository it landed on, or null when the session names none.
  Repository? follow(String sessionId) {
    // A checkout picked while working in this session outranks the one its
    // launch directory computes to: the user has already said where the work
    // is, and recomputing it on every tab switch is how a pick stopped meaning
    // anything. See [PickedCheckouts].
    final picked = _ref.read(pickedCheckoutsProvider.notifier).forSession(
      sessionId,
    );
    final remembered = picked == null
        ? null
        : _ref.read(repositoryDaoProvider).getById(picked);
    final repository = remembered ?? repositoryForSession(_ref, sessionId);
    if (repository == null) return null;
    // What a pick made from here on will be filed against.
    _ref.read(followedSessionProvider.notifier).set(sessionId);
    _ref.read(selectedProjectIdProvider.notifier).select(repository.projectId);
    _ref.read(selectedRepositoryIdProvider.notifier).select(repository.id);
    return repository;
  }
}

final sessionContextProvider = Provider(SessionContext.new);
