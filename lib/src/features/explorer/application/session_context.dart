import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../git/application/changes_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'checkout_default.dart';
import 'picked_checkouts.dart';

/// The session running in the pane the terminal is showing, or null.
///
/// Keyed off the *tab on screen*, not off the Explorer's selection: switching
/// terminal tabs changes which agent you are looking at, and anything that
/// followed the tree instead would describe a session the user is not in. A
/// plain shell tab has no session row pointing at any of its panes and answers
/// null, which is what leaves the Explorer's own selection in charge.
///
/// **The focused pane first, then the rest of its tab.** Splitting focuses the
/// new pane, and a new plain shell has no session — so keying this on the
/// focused pane alone meant that splitting an agent's tab made the session's
/// whole bottom bar disappear, which is what the owner reported as "once split,
/// bottom statusbar is gone". A shell opened *beside* a session is still a
/// shell opened beside that session, and the tab is still the session's
/// workspace.
final activePaneSessionIdProvider = Provider<String?>((ref) {
  // Which tab is active and what is in it — deliberately not the whole state.
  // This answers by walking every session row, and it was recomputed whenever
  // any pane's liveness moved: measured at ten scans over a thousand rows for
  // ten background processes exiting, for an answer that cannot have changed.
  // Liveness says nothing about which pane is focused.
  final tab = ref.watch(
    terminalSessionsControllerProvider.select((s) => s.activeTab),
  );
  // Adopting a pane, or launching into one, rewrites `pane_id` on the row.
  ref.watch(sessionsRevisionProvider);
  if (tab == null) return null;
  final siblings = tab.layout.panes.toSet();
  // The indexed query returns only sessions belonging to this tab. The focused
  // pane still wins; the oldest sibling is the deterministic fallback.
  String? fallback;
  for (final record in ref.read(sessionDaoProvider).getByPaneIds(siblings)) {
    final paneId = record.paneId;
    if (paneId == null) continue;
    if (paneId == tab.focusedPaneId) return record.id;
    if (fallback == null && siblings.contains(paneId)) fallback = record.id;
  }
  return fallback;
});

/// The repository whose checkout contains [sessionId]'s work, in the absence of
/// a pick.
///
/// The rule itself is [inferredCheckoutFor] — which location of a session the
/// app has the strongest record of, resolved to the deepest registered checkout
/// containing it. It lives next door because it is a statement about *sessions
/// and checkouts* that the picker and the tree both want, not about following.
Repository? repositoryForSession(Ref ref, String sessionId) {
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  if (session == null) return null;
  return inferredCheckoutFor(ref, session);
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
    final picked = _ref
        .read(pickedCheckoutsProvider.notifier)
        .forSession(sessionId);
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

  /// Nothing is being followed — the pane on screen runs no session of ours.
  ///
  /// Without this a pick made while a plain shell tab is up was filed against
  /// whichever session was followed *last*, and stuck there: the Changes and
  /// GitHub panels then described an unrelated checkout every time that session
  /// came back on screen, for the rest of the run. A pick made with nothing
  /// followed belongs to nothing.
  void stopFollowing() => _ref.read(followedSessionProvider.notifier).set(null);
}

final sessionContextProvider = Provider(SessionContext.new);
