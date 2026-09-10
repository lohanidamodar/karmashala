import 'package:riverpod/riverpod.dart';

import '../../git/application/changes_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../repositories/application/repository_providers.dart';
import 'package:karmashala_git/repositories.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'checkout_default.dart';
import 'picked_checkouts.dart';

/// The session running in the pane the terminal is showing, or null. Keyed off
/// the *tab on screen*: the focused pane first, then the rest of its tab, since
/// splitting focuses a new shell and emptied the session's whole bottom bar.
final activePaneSessionIdProvider = Provider<String?>((ref) {
  // Which tab is active and what is in it, not the whole state: this walks
  // every session row, and was re-running on any pane's liveness moving —
  // ten scans over a thousand rows for ten background processes exiting.
  final tab = ref.watch(
    terminalSessionsControllerProvider.select((s) => s.activeTab),
  );
  // Adopting a pane, or launching into one, rewrites `pane_id`, and that is the
  // only session fact this reads — a title sync must not re-answer it.
  ref.watchSessionKinds(const {
    SessionChangeKind.membership,
    SessionChangeKind.placement,
  });
  return sessionInTab(ref, tab);
});

/// The session workspace group [groupId] is showing — the per-group form of
/// [activePaneSessionIdProvider]. "The focused session" would make every group
/// describe the same one. Null for the empty room a split cleared.
final workspaceGroupSessionIdProvider = Provider.autoDispose
    .family<String?, String>((ref, groupId) {
      final tabs = ref.watch(
        terminalSessionsControllerProvider.select((s) => s.tabs),
      );
      final tabId = ref.watch(workspaceGroupActiveTabProvider(groupId));
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.placement,
      });
      for (final tab in tabs) {
        if (tab.id == tabId) return sessionInTab(ref, tab);
      }
      return null;
    });

/// The workspace group the Explorer's selection was opened into — for the rows
/// with no tab of their own, which otherwise followed the keyboard focus around
/// the window. [WorkbenchView] is the only writer; a stale id draws nothing.
class SelectionHostGroupController extends Notifier<String?> {
  @override
  String? build() => null;
  void host(String? groupId) => state = groupId;
}

final selectionHostGroupProvider =
    NotifierProvider<SelectionHostGroupController, String?>(
      SelectionHostGroupController.new,
    );

/// The session [tab] is running: the focused pane's, and failing that the
/// oldest pane in the tab that has one — a shell opened *beside* a session is
/// still beside it.
String? sessionInTab(Ref ref, TerminalTab? tab) {
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
}

/// The session the window is about: the one selected in the Explorer, or what
/// the terminal tab on screen is running. The fallback is the point — selection
/// is dropped on purpose, and anything keyed on it alone then draws nothing.
final focusedSessionIdProvider = Provider<String?>(
  (ref) =>
      ref.watch(selectedSessionIdProvider) ??
      ref.watch(activePaneSessionIdProvider),
);

/// The repository whose checkout contains [sessionId]'s work, absent a pick.
/// The rule itself is [inferredCheckoutFor], which the picker and tree share.
Repository? repositoryForSession(Ref ref, String sessionId) {
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  if (session == null) return null;
  return inferredCheckoutFor(ref, session);
}

/// Moves the workspace's context to the session the user is working in — the
/// missing writer of [selectedRepositoryIdProvider]. The active session writes
/// on *change*; an Explorer click writes and holds; a shell writes nothing.
class SessionContext {
  const SessionContext(this._ref);

  final Ref _ref;

  /// Points the Explorer and the side panel at [sessionId]'s repository *and*
  /// the project above it, or returns null when the session names none.
  Repository? follow(String sessionId) {
    // A checkout picked while working in this session outranks the one its
    // launch directory computes to — see [PickedCheckouts].
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

  /// Nothing is being followed. Without it, a pick made under a plain shell tab
  /// was filed against the session followed *last*, and stuck there.
  void stopFollowing() => _ref.read(followedSessionProvider.notifier).set(null);
}

final sessionContextProvider = Provider(SessionContext.new);
