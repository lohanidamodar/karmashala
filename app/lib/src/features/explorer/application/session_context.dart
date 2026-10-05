import 'package:agent_cli/process.dart';
import 'package:riverpod/riverpod.dart';

import '../../git/application/changes_providers.dart';
import '../../projects/application/projects_controller.dart';
import 'package:karmashala_git/repositories.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'checkout_default.dart';
import 'explorer_tree_nodes.dart';
import '../../workspaces/data/workspace_data.dart';
import '../../settings/application/settings_controller.dart';
import 'picked_checkouts.dart';

/// The session running in the pane the terminal is showing, or null. Keyed off
/// the *tab on screen*: the focused pane first, then the rest of its tab, since
/// splitting focuses a new shell and emptied the session's whole bottom bar.
final activePaneSessionIdProvider = Provider<String?>((ref) {
  // Which tab is active and what is in it, not the whole state: a pane's
  // liveness moving must not re-answer this.
  final tab = ref.watch(
    terminalSessionsControllerProvider.select((s) => s.activeTab),
  );
  return sessionInTab(ref.watch(paneSessionsProvider), tab);
});

/// The session **on screen**: one selected with no pane of ours is shown in
/// place of the active tab (as its chat, on a phone), and choosing a tab lets
/// that selection go; otherwise the active tab's.
final onScreenSessionIdProvider = Provider<String?>((ref) {
  final selected = ref.watch(selectedSessionIdProvider);
  if (selected != null &&
      ref.watch(paneSessionsProvider.select((p) => p.paneOf(selected))) ==
          null) {
    return selected;
  }
  return ref.watch(activePaneSessionIdProvider);
});

/// The session a context-panel surface describes: the one **on screen**, and
/// the one last clicked in the Explorer only when no pane holds one.
final panelSessionIdProvider = Provider<String?>(
  (ref) =>
      ref.watch(onScreenSessionIdProvider) ??
      ref.watch(selectedSessionIdProvider),
);

/// The session workspace group [groupId] is showing — the per-group form of
/// [activePaneSessionIdProvider]. "The focused session" would make every group
/// describe the same one. Null for the empty room a split cleared.
final workspaceGroupSessionIdProvider = Provider.autoDispose
    .family<String?, String>((ref, groupId) {
      final tabs = ref.watch(
        terminalSessionsControllerProvider.select((s) => s.tabs),
      );
      final tabId = ref.watch(workspaceGroupActiveTabProvider(groupId));
      final panes = ref.watch(paneSessionsProvider);
      for (final tab in tabs) {
        if (tab.id == tabId) return sessionInTab(panes, tab);
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
/// first pane in the tab that has one — a shell opened *beside* a session is
/// still beside it.
String? sessionInTab(PaneSessions panes, TerminalTab? tab) {
  if (tab == null) return null;
  final focused = panes.sessionOf(tab.focusedPaneId);
  if (focused != null) return focused;
  for (final paneId in tab.layout.panes) {
    final sessionId = panes.sessionOf(paneId);
    if (sessionId != null) return sessionId;
  }
  return null;
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
  final session = ref.read(sessionsDataProvider).getById(sessionId);
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
        : _ref.read(workspaceDataProvider).repository(picked);
    final repository = remembered ?? repositoryForSession(_ref, sessionId);
    if (repository == null) return null;
    // What a pick made from here on will be filed against.
    _ref.read(followedSessionProvider.notifier).set(sessionId);
    _ref.read(selectedProjectIdProvider.notifier).select(repository.projectId);
    _ref.read(selectedRepositoryIdProvider.notifier).select(repository.id);
    reveal(repository.projectId);
    return repository;
  }

  /// Points the Explorer at whatever checkout [directory] sits in, and opens
  /// the rows above it so the selection can actually be seen.
  ///
  /// **A directory in no checkout we hold changes nothing.** A `cd` to `/tmp`
  /// is not a statement about the workspace, and blanking the selection on it
  /// would empty the side panel every time you stepped outside.
  Repository? followDirectory(EnvironmentPath directory) {
    final repository = checkoutContaining(
      _ref.read(workspaceDataProvider),
      directory,
    );
    if (repository == null) return null;
    // Already there: a sweep of the repositories has happened, but nothing
    // below needs doing — no selection write, no settings read, no reveal.
    if (_ref.read(selectedRepositoryIdProvider) == repository.id) {
      return repository;
    }
    _ref.read(selectedProjectIdProvider.notifier).select(repository.projectId);
    _ref.read(selectedRepositoryIdProvider.notifier).select(repository.id);
    reveal(repository.projectId);
    return repository;
  }

  /// Opens the context header above [projectId], so a selected row is not
  /// highlighted off screen. The scope bar's filters need no opening: the
  /// tree keeps the selected project whatever they are.
  void reveal(String projectId) {
    final project = _ref.read(workspaceDataProvider).project(projectId);
    if (project == null) return;
    _ref
        .read(settingsControllerProvider.notifier)
        .revealExplorerNodes(
          explorerAncestorsOf(workspaceId: project.workspaceId),
        );
  }

  /// Nothing is being followed. Without it, a pick made under a plain shell tab
  /// was filed against the session followed *last*, and stuck there.
  void stopFollowing() => _ref.read(followedSessionProvider.notifier).set(null);
}

final sessionContextProvider = Provider(SessionContext.new);
