import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/agents/application/agent_installations_controller.dart';
import '../../../features/agents/application/agent_providers.dart';
import '../../../features/cli_detection/application/cli_detection_providers.dart';
import '../../../features/cli_detection/data/conversation_index_dao.dart';
import '../../../features/editor/application/code_editor_providers.dart';
import '../../../features/environments/presentation/environment_health_dialog.dart';
import '../../../features/fanout/presentation/fanout_dialog.dart';
import '../../../features/git/application/changes_providers.dart';
import '../../../features/notes/application/notes_providers.dart';
import '../../../features/notes/presentation/note_edit_dialog.dart';
import '../../../features/notifications/application/notification_providers.dart';
import '../../../features/projects/application/projects_controller.dart';
import '../../../features/projects/presentation/new_project_dialog.dart';
import '../../../features/repositories/application/repository_providers.dart';
import '../../../features/explorer/application/explorer_actions.dart';
import '../../../features/explorer/presentation/unresumable_sessions_dialog.dart';
import '../../../features/sessions/application/session_providers.dart';
import '../../../features/sessions/domain/session.dart';
import '../../../features/sessions/domain/session_launch.dart';
import '../../../features/sessions/domain/session_resume.dart' show describeAge;
import '../../../features/sessions/presentation/new_session_dialog.dart';
import '../../../features/settings/application/settings_controller.dart';
import '../../../features/settings/presentation/settings_nav.dart';
import '../../../features/settings/presentation/settings_screen.dart';
import '../../../features/snippets/application/snippet_insertion.dart';
import '../../../features/snippets/application/snippet_providers.dart';
import '../../../features/snippets/domain/command_snippet.dart';
import '../../../features/snippets/presentation/snippet_dialogs.dart';
import '../../../features/terminal/application/terminal_sessions_controller.dart';
import '../../../features/terminal/domain/pane_layout.dart';
import '../../../features/terminal/presentation/empty_pane_region.dart';
import '../../../features/terminal/presentation/pane_group_strip.dart';
import '../../../features/terminal/presentation/terminal_panel.dart';
import '../../../features/todos/application/todos_providers.dart';
import '../../../features/workspaces/application/workspaces_controller.dart';
import '../../../features/workspaces/domain/workspace_scope.dart';
import '../../theme/app_icons.dart';
import '../shell_state.dart';
import '../side_panel.dart';
import '../side_panel_state.dart';
import '../tab_picker.dart';
import '../workbench.dart';
import 'quick_open_cache.dart';
import 'quick_open_item.dart';
import 'repo_file_index.dart';

/// Per-group priors, added to every match in that group.
///
/// Small on purpose. These decide what an *empty* query lists first and break
/// near-ties between kinds; they must never let a weakly-matched session
/// outrank an exactly-matched command, which is what a large prior would do.
const _sessionWeight = 24.0;
const _workspaceWeight = 14.0;

/// Just under a project: a context is *how the projects are listed*, so on an
/// empty palette it should be visible without displacing the things you open.
const _contextWeight = 12.0;
const _githubWeight = 10.0;
const _branchWeight = 8.0;
const _agentWeight = 4.0;
const _commandWeight = 2.0;

/// A snippet is the user's own text, so it outranks an app verb by a hair on an
/// empty query — but only by a hair, for the reason above: a large prior would
/// let a weakly-matched snippet beat an exactly-matched command.
const _snippetWeight = 3.0;

/// Below every snippet, so `$` lists the library first and the two ways to
/// *manage* it last. They live in the snippets group rather than under Commands
/// precisely so that `$` on an empty library still offers somewhere to go.
const _snippetAdminWeight = 0.5;

/// Below a session, above a project: a shell tab is a place you are already
/// working, but it is not a piece of work in its own right.
const _tabWeight = 18.0;

/// Just under a session's own row.
///
/// A conversation hit and the session it is in are the same destination, so
/// when a query matches both the session's title *and* something said inside
/// it, the titled row should be the one on top — it is the thing the user
/// named.
const _conversationWeight = 22.0;

/// How much the most recent session is worth over the oldest.
const _recencySpread = 12.0;

/// Being in the repository the user is already looking at is worth something,
/// but not much: quick open's whole point is reaching what is *not* on screen.
const _selectedRepoBoost = 10.0;

/// Builds everything quick open can find.
///
/// Every [QuickOpenItem.onSelect] delegates to the code that already owns that
/// jump — `focusWatchedSession` for sessions, the side panel controller for
/// surfaces, the dialogs for the actions. Quick open is a second way in, never
/// a second implementation.
class QuickOpenSources {
  QuickOpenSources({
    required this.ref,
    required this.context,
    required this.dismiss,
  });

  final WidgetRef ref;
  final BuildContext context;

  /// Closes the surface before acting, so a dialog opened from here is not
  /// stacked underneath it.
  final void Function(VoidCallback action) dismiss;

  List<QuickOpenItem> build({
    List<IndexedFile> files = const [],
    Set<String> changedPaths = const {},
  }) => [
    ..._commands(),
    ..._contexts(),
    ..._workspace(),
    ..._sessions(),
    ..._openTabs(),
    ..._files(files, changedPaths),
    ..._repoFacts(),
    ..._agents(),
    ..._snippets(),
  ];

  // --- commands -----------------------------------------------------------

  QuickOpenItem _command(
    String label, {
    required IconData icon,
    required VoidCallback onSelect,
    String? subtitle,
    String? shortcut,
    List<String> keywords = const [],
  }) => QuickOpenItem(
    id: 'command/$label',
    group: QuickOpenGroup.commands,
    title: label,
    subtitle: subtitle,
    detail: shortcut,
    icon: icon,
    keywords: keywords,
    weight: _commandWeight,
    onSelect: () => dismiss(onSelect),
  );

  List<QuickOpenItem> _commands() {
    final panel = ref.read(sidePanelProvider.notifier);
    final shell = ref.read(shellControllerProvider.notifier);
    return [
      _command(
        'New project…',
        icon: AppIcons.folderPlus,
        shortcut: 'Ctrl+Shift+N',
        onSelect: () => NewProjectDialog.show(context),
      ),
      // Ungated. The dialog picks its own destination now — a project and a
      // checkout inside it — so "nothing is selected" is no longer a reason to
      // hide the command, and neither is an empty workspace: with no projects
      // at all the dialog says so and offers the one thing that would help,
      // which teaches more than a command that silently is not there.
      _command(
        'New session…',
        icon: AppIcons.chatCircleDots,
        shortcut: 'Ctrl+N',
        onSelect: () => NewSessionDialog.show(context),
      ),
      if (ref.read(selectedRepositoryIdProvider) != null)
        _command(
          'Fan out prompt…',
          subtitle: 'Run multiple agents in isolated worktrees',
          icon: AppIcons.gitBranch,
          onSelect: () => FanOutDialog.show(context),
        ),
      // The two things you write for yourself, listed as **verbs**.
      //
      // Both surfaces were already here as places — "Notes  ·  Side panel" —
      // and the owner still asked *"how to add notes, where can we add
      // notes?"*, then *"it's not intuitive"*. A place only answers the
      // question if you already know its name; "New note" is what somebody
      // types when they do not. Each one opens its surface on the way, so the
      // palette teaches where the thing lives instead of only doing it once.
      if (ref.read(notesEnabledProvider))
        _command(
          'New note…',
          subtitle: 'Keep an idea without acting on it',
          icon: AppIcons.notePencil,
          keywords: const [
            'note',
            'notes',
            'write',
            'idea',
            'remember',
            'save for later',
            'scratchpad',
          ],
          onSelect: () {
            panel.select(SidePanelSurface.notes);
            showNewNoteDialog(context, ref);
          },
        ),
      _command(
        'New todo',
        subtitle: 'One line, done or not, in your own order',
        icon: AppIcons.listChecks,
        keywords: const [
          'todo',
          'todos',
          'to-do',
          'task',
          'tasks',
          'checklist',
          'remind',
        ],
        onSelect: () {
          panel.select(SidePanelSurface.todos);
          ref.read(todoComposerFocusProvider.notifier).request();
        },
      ),
      _command(
        'Terminal view',
        subtitle: 'Show the terminal in the workbench',
        icon: AppIcons.terminal,
        shortcut: 'Ctrl+`',
        // The focused group: a command that names no tab means the group the
        // keyboard is in.
        onSelect: () =>
            ref.read(terminalSessionsControllerProvider.notifier).showTerminalHere(),
      ),
      // The tabs listed below are only the ones that are *nothing but* tabs
      // (see [_openTabs]), and finding one that way means knowing its name.
      // This is the other question — "show me my tabs" — and it opens the
      // strip's own picker, which holds every tab including the ones running a
      // session.
      _command(
        'Switch terminal tab…',
        subtitle: 'Every open tab, by name, session or directory',
        icon: AppIcons.listMagnifyingGlass,
        keywords: const ['tabs', 'terminal', 'switch', 'window'],
        onSelect: () => TabPicker.show(context, terminalTabEntries),
      ),
      ..._restoredSessionCommands(),
      // Moving a tab into a split, and taking a pane back out, are drags —
      // and a feature reachable only by dragging is one some people cannot
      // reach at all. Same two verbs, no mouse. Listed only when they have
      // somewhere to act: a command that is always offered and usually inert
      // is noise in a palette this size.
      ..._splitCommands(),
      _command(
        'Toggle Explorer',
        icon: AppIcons.treeStructure,
        shortcut: 'Ctrl+B',
        onSelect: shell.toggleExplorerPane,
      ),
      _command(
        'Toggle side panel',
        icon: AppIcons.sidebarSimple,
        shortcut: 'Ctrl+3',
        onSelect: panel.toggle,
      ),
      for (final surface in SidePanelSurface.offered(
        debugMode: ref.read(settingsControllerProvider).debugMode,
        notesEnabled: ref.read(notesEnabledProvider),
      ))
        _command(
          surface.label,
          subtitle: 'Side panel',
          icon: SidePanel.iconFor(surface),
          onSelect: () => panel.select(surface),
        ),
      _command(
        'Focus mode',
        subtitle: 'Give the workbench the whole window',
        icon: AppIcons.arrowsOutSimple,
        shortcut: r'Ctrl+\',
        onSelect: () => ref.read(terminalMaximizedProvider.notifier).toggle(),
      ),
      _command(
        'Check system health',
        subtitle: Platform.isWindows
            ? 'MCP bridge, WSL interop, Android tooling, disk, environments'
            : 'MCP bridge, Android tooling, disk, environments',
        icon: AppIcons.checkCircle,
        keywords: const ['mcp', 'bridge', 'wsl', 'interop', 'disk', 'adb'],
        onSelect: () => EnvironmentHealthDialog.show(context),
      ),
      // Beside "Check system health" on purpose, and built the same way: a
      // reading taken when asked, shown with its age, acted on only where it
      // is certain. This one is about the workspace rather than the machine —
      // rows whose agent has no record of the conversation they name.
      _command(
        'Review sessions with no conversation',
        subtitle: 'Rows an agent cannot resume — remove them, or start a '
            'conversation in them',
        icon: AppIcons.warningCircle,
        keywords: const [
          'unresumable',
          'missing',
          'orphan',
          'empty',
          'cleanup',
          'tidy',
        ],
        onSelect: () => UnresumableSessionsDialog.show(context),
      ),
      _command(
        'Open Settings',
        icon: AppIcons.gearSix,
        keywords: const ['preferences', 'options'],
        onSelect: () => SettingsScreen.show(context),
      ),
    ];
  }

  /// The keyboard's way to the sessions a restart left dormant.
  ///
  /// Listed only when there are some, by the rule [_splitCommands] states: a
  /// command that is always offered and usually inert is noise in a palette
  /// this size. It is inert most of the time by design — a window whose
  /// sessions are all running has nothing to resume — and this is exactly the
  /// day it is not.
  ///
  /// It opens the dialog rather than resuming outright, because that is where
  /// the list of what is about to be started lives, and starting four agents
  /// is not something to do from a single keystroke without showing which.
  List<QuickOpenItem> _restoredSessionCommands() {
    final count = ref.read(restoredAgentPanesProvider).length;
    if (count == 0) return const [];
    return [
      _command(
        'Resume restored sessions…',
        subtitle:
            '$count session${count == 1 ? '' : 's'} came back as history with '
            'nothing running',
        icon: AppIcons.playCircle,
        keywords: const [
          'resume',
          'restored',
          'restart',
          'continue',
          'dormant',
          'sessions',
        ],
        onSelect: () => TerminalActions(ref).showRestoredSessions(context),
      ),
    ];
  }

  /// The keyboard's way to do everything the chrome can be dragged or clicked
  /// to do about layout.
  ///
  /// Every drop target and every split button has an entry, because a feature
  /// reachable only by dragging is one some people cannot reach at all — and
  /// since the split buttons moved to the title bar, where a compact window
  /// keeps only the `+`, this is the route that is always there.
  ///
  /// **Two structures, two vocabularies, and every title says which.** A
  /// *group* is a division of the whole middle workspace: its own tab strip,
  /// its own content and its own status bar, holding **tabs**. A *region* is a
  /// division inside one tab, holding **panes**. `WorkspaceLayout` states the
  /// pair once; these titles use the same two words and nothing else, because
  /// "move a tab into this split" named neither.
  List<QuickOpenItem> _splitCommands() {
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    final emptyGroup = sessions.emptyWorkspaceGroup();
    final slot = sessions.emptySlotInActiveTab();
    final pane = sessions.paneMovableToNewTab();
    final canSplitWorkspace = sessions.canSplitWorkspace();
    final canSplitPane = sessions.focusedPaneIsSplittable();
    return [
      if (canSplitWorkspace) ...[
        _command(
          'Split the workspace right',
          subtitle: 'A new group beside this one, with a strip and a bar',
          icon: AppIcons.squareSplitHorizontal,
          keywords: const ['split', 'group', 'workspace', 'right', 'column'],
          onSelect: () => sessions.splitWorkspace(SplitAxis.horizontal),
        ),
        _command(
          'Split the workspace down',
          subtitle: 'A new group under this one, with a strip and a bar',
          icon: AppIcons.squareSplitVertical,
          keywords: const ['split', 'group', 'workspace', 'down', 'row'],
          onSelect: () => sessions.splitWorkspace(SplitAxis.vertical),
        ),
      ],
      if (canSplitPane) ...[
        _command(
          'Split this pane right',
          subtitle: 'A second terminal inside this tab',
          icon: AppIcons.squareSplitHorizontal,
          keywords: const ['split', 'pane', 'region', 'terminal', 'right'],
          onSelect: () => sessions.splitPane(SplitAxis.horizontal),
        ),
        _command(
          'Split this pane down',
          subtitle: 'A second terminal inside this tab',
          icon: AppIcons.squareSplitVertical,
          keywords: const ['split', 'pane', 'region', 'terminal', 'down'],
          onSelect: () => sessions.splitPane(SplitAxis.vertical),
        ),
      ],
      if (emptyGroup != null)
        _command(
          'Move a tab into the empty group…',
          subtitle: 'Fill the group you cleared',
          icon: AppIcons.squareSplitHorizontal,
          keywords: const ['group', 'move', 'tab', 'split', 'drag'],
          onSelect: () => TabPicker.show(
            context,
            (ref) => tabsMovableToGroup(ref, emptyGroup),
          ),
        ),
      if (slot != null)
        _command(
          'Move a pane into the empty region…',
          subtitle: 'Fill the empty half of the tab you are in',
          icon: AppIcons.squareSplitVertical,
          keywords: const ['region', 'move', 'pane', 'split', 'drag'],
          onSelect: () =>
              TabPicker.show(context, (ref) => panesMovableInto(ref, slot)),
        ),
      if (pane != null) ...[
        _command(
          'Move this pane to a new tab',
          subtitle: 'Take the focused pane out of its region',
          icon: AppIcons.terminalWindow,
          keywords: const ['region', 'unsplit', 'pane', 'tab', 'move'],
          onSelect: () => sessions.movePaneToNewTab(pane),
        ),
        if (sessions.regionAnchorsBesides(pane).isNotEmpty)
          _command(
            'Move this pane into another region…',
            subtitle: 'Send the focused pane elsewhere in this tab',
            icon: AppIcons.squareSplitVertical,
            keywords: const ['region', 'pane', 'move', 'drag', 'split'],
            onSelect: () =>
                TabPicker.show(context, (ref) => regionsMovableTo(ref, pane)),
          ),
      ],
    ];
  }

  // --- contexts -----------------------------------------------------------

  /// Switching the project list's context, from the palette.
  ///
  /// A context is a filter, and a filter you have to find a menu for is a
  /// filter you leave switched on. These are the same three answers the scope
  /// bar offers — everything, one context, the ones in none — reachable by
  /// typing their names.
  ///
  /// **"All projects" is one of them, and is listed first.** Getting back to
  /// everything is the move people make most, and a way out that is harder to
  /// reach than the way in is how a project ends up looking lost.
  List<QuickOpenItem> _contexts() {
    final workspaces = ref.read(workspacesControllerProvider);
    if (workspaces.isEmpty) return const [];
    final scope = ref.read(workspaceScopeProvider);
    final counts = ref.read(workspaceProjectCountsProvider);
    final scopes = ref.read(workspaceScopeProvider.notifier);

    QuickOpenItem item({
      required String id,
      required String title,
      required String subtitle,
      required IconData icon,
      required bool current,
      required WorkspaceScope target,
    }) => QuickOpenItem(
      id: 'context/$id',
      group: QuickOpenGroup.contexts,
      title: title,
      subtitle: subtitle,
      // Said rather than implied: the palette is the one place you can pick the
      // filter you are already looking at, and doing so must not look broken.
      detail: current ? 'Showing' : null,
      icon: icon,
      keywords: const ['context', 'filter'],
      weight: _contextWeight,
      onSelect: () => dismiss(() => scopes.select(target)),
    );

    return [
      item(
        id: 'all',
        title: 'All projects',
        subtitle: 'Show every project, in any context',
        icon: AppIcons.folders,
        current: scope.isAll,
        target: WorkspaceScope.all,
      ),
      for (final workspace in workspaces)
        item(
          id: workspace.id,
          title: workspace.name,
          subtitle: describeWorkspace(
            workspace,
            projectCount: counts[workspace.id] ?? 0,
          ),
          icon: AppIcons.stack,
          current: scope.workspaceId == workspace.id,
          target: WorkspaceScope.of(workspace.id),
        ),
      item(
        id: 'none',
        title: 'No context',
        subtitle: 'Only the projects filed under nothing',
        icon: AppIcons.minusCircle,
        current: scope.unassignedOnly,
        target: WorkspaceScope.unassigned,
      ),
    ];
  }

  // --- projects and repositories ------------------------------------------

  List<QuickOpenItem> _workspace() {
    final items = <QuickOpenItem>[];
    final repositoryDao = ref.read(repositoryDaoProvider);
    for (final project in ref.read(sortedProjectsProvider)) {
      items.add(
        QuickOpenItem(
          id: 'project/${project.id}',
          group: QuickOpenGroup.workspace,
          title: project.name,
          subtitle: 'Project',
          icon: AppIcons.folder,
          keywords: [project.root.path],
          weight: _workspaceWeight,
          onSelect: () => dismiss(
            () =>
                ref.read(selectedProjectIdProvider.notifier).select(project.id),
          ),
        ),
      );
      for (final repository in repositoryDao.getByProject(project.id)) {
        items.add(
          QuickOpenItem(
            id: 'repository/${repository.id}',
            group: QuickOpenGroup.workspace,
            title: repository.name,
            subtitle: '${project.name} · repository',
            icon: AppIcons.gitBranch,
            keywords: [repository.path.path],
            weight: _workspaceWeight,
            onSelect: () => dismiss(() {
              ref.read(selectedProjectIdProvider.notifier).select(project.id);
              ref
                  .read(selectedRepositoryIdProvider.notifier)
                  .select(repository.id);
            }),
          ),
        );
      }
    }
    return items;
  }

  // --- sessions ------------------------------------------------------------

  /// Native and imported sessions across every project, newest first.
  ///
  /// The whereabouts shown here are the **free** ones — where the session was
  /// started, and whether a pane of ours is running it right now. The Explorer's
  /// row also shows a "last seen" age, which costs a transcript stat per
  /// session; paying that for every session in the workspace to fill a search
  /// list would be a filesystem sweep on every keystroke.
  List<QuickOpenItem> _sessions() {
    final sessionDao = ref.read(sessionDaoProvider);
    final importedDao = ref.read(importedSessionDaoProvider);
    final repositoryDao = ref.read(repositoryDaoProvider);
    final installations = ref.read(agentInstallationDaoProvider);
    final registry = ref.read(agentRegistryProvider);
    final terminals = ref.read(terminalSessionsControllerProvider.notifier);
    final selectedRepository = ref.read(selectedRepositoryIdProvider);

    final entries = <({DateTime at, QuickOpenItem Function(double) make})>[];

    for (final project in ref.read(sortedProjectsProvider)) {
      for (final repository in repositoryDao.getByProject(project.id)) {
        final where = '${project.name} · ${repository.name}';
        final here = repository.id == selectedRepository
            ? _selectedRepoBoost
            : 0.0;

        for (final session in sessionDao.getByRepository(repository.id)) {
          final agent = registry.displayNameFor(
            installations.getById(session.agentInstallationId)?.agentId ?? '',
          );
          final note = _cheapWhereabouts(session, terminals);
          entries.add((
            at: session.createdAt,
            make: (recency) => QuickOpenItem(
              id: 'session/${session.id}',
              group: QuickOpenGroup.sessions,
              title: session.title,
              subtitle: [where, agent, ?note].join(' · '),
              detail: session.status.name,
              icon: AppIcons.chatCircle,
              keywords: [
                agent,
                session.status.name,
                if (session.useWorktree) 'worktree',
                ?session.worktree?.path,
              ],
              weight: _sessionWeight + here + recency,
              onSelect: () =>
                  dismiss(() => _focusSession(session.id, imported: false)),
            ),
          ));
        }

        for (final session in importedDao.getByRepository(repository.id)) {
          final agent = registry.displayNameFor(session.cli);
          entries.add((
            at: session.updatedAt ?? session.createdAt,
            make: (recency) => QuickOpenItem(
              id: 'imported/${session.id}',
              group: QuickOpenGroup.sessions,
              title: session.displayTitle,
              subtitle: '$where · $agent · imported',
              detail: session.isSubagent ? 'subagent' : null,
              icon: AppIcons.clockCounterClockwise,
              keywords: [agent, 'imported', session.preview],
              weight: _sessionWeight + here + recency,
              onSelect: () =>
                  dismiss(() => _focusSession(session.id, imported: true)),
            ),
          ));
        }
      }
    }

    // Recency is a rank, not a duration: the newest session is worth
    // [_recencySpread] over the oldest whether that gap is an hour or a year.
    entries.sort((a, b) => b.at.compareTo(a.at));
    final last = entries.length - 1;
    return [
      for (var i = 0; i < entries.length; i++)
        entries[i].make(
          last == 0 ? _recencySpread : _recencySpread * (1 - i / last),
        ),
    ];
  }

  String? _cheapWhereabouts(
    Session session,
    TerminalSessionsController terminals,
  ) {
    final paneId = session.paneId;
    if (paneId != null &&
        (terminals.instanceFor(paneId)?.liveness.value.isLive ?? false)) {
      return 'running here';
    }
    if (session.surface == SessionSurface.external) {
      return 'opened in an external terminal';
    }
    return null;
  }

  /// Selects a session and everything above it, through the one walk that
  /// already exists for a clicked toast and a clicked tray item.
  Future<void> _focusSession(String openId, {required bool imported}) async {
    focusWatchedSession(
      ProviderScope.containerOf(context, listen: false),
      openId: openId,
      imported: imported,
    );
    ref.read(shellControllerProvider.notifier).focusPane(ShellPane.detail);

    // And actually open it. Picking a session by name is a request to be *in*
    // it, not to be shown a screen offering to put you in it — the owner asked
    // why resuming from here stopped at "No terminal of ours is running this
    // session" with a button, when they had already said which session they
    // wanted. Focusing alone left that screen as the answer.
    //
    // [ExplorerActions.openNative] is the same action the Explorer's own click
    // runs, and it decides between reattach, resume and select — so a session
    // already running in a pane is reattached rather than started twice, and
    // one that cannot be resumed still just gets selected, leaving the
    // placeholder to explain why.
    final result = await _open(openId, imported: imported);
    final message = result.message;
    if (message == null || !context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Reattach, resume or select — whichever [openId] needs.
  Future<ExplorerResult> _open(String openId, {required bool imported}) {
    final actions = ref.read(explorerActionsProvider);
    if (!imported) return actions.openNative(openId);
    final record = ref.read(importedSessionDaoProvider).getById(openId);
    return record == null
        ? Future.value(const ExplorerResult(ExplorerOutcome.selected))
        : actions.openImported(record);
  }

  // --- conversations ------------------------------------------------------

  /// One row per conversation something was *said* in.
  ///
  /// The one thing in the palette that reads a transcript's body. Fed by
  /// `ConversationIndexDao.search`, which the dialog runs as the user types;
  /// this only turns the hits into rows, so nothing here touches the disk or
  /// re-runs the query.
  ///
  /// Built **apart from [build]** because the query changes on every keystroke
  /// and the rest of the palette does not: re-running every source per
  /// character would put a `SELECT * FROM sessions` per repository behind each
  /// one.
  ///
  /// **The hits are collapsed per conversation**, because the question is
  /// "which conversation was that in", not "which of the eleven times I said
  /// it". The first hit's excerpt is the subtitle and the rest become a count.
  ///
  /// **Nothing here asks the filesystem anything.** A conversation whose
  /// worktree has been removed, whose repository has moved, or whose transcript
  /// has been deleted is still a row you can open — §20's rule, and a stated
  /// requirement: a stored path is state, whether it resolves is a
  /// measurement, and a measurement is not something a search result may be
  /// filtered on. Opening it goes through the same `_focusSession` a clicked
  /// session row uses, which *selects first* and then tries to resume, so a
  /// conversation that cannot be resumed still lands on screen read-only with
  /// the placeholder saying why.
  ///
  /// A hit whose conversation neither table knows about is dropped: the index
  /// keeps rows for a session row that has since been deleted, and there is
  /// nothing left to open. See the DEFERRED note — pruning belongs on the
  /// delete path.
  List<QuickOpenItem> conversations(
    List<ConversationHit> hits,
    String query, {
    DateTime? now,
  }) {
    if (hits.isEmpty) return const [];
    final sessionDao = ref.read(sessionDaoProvider);
    final importedDao = ref.read(importedSessionDaoProvider);
    final registry = ref.read(agentRegistryProvider);
    final at = now ?? DateTime.now().toUtc();

    final items = <QuickOpenItem>[];
    final seen = <String>{};
    for (final hit in hits) {
      if (!seen.add(hit.sessionId)) continue;
      final native = sessionDao.getByExternalSessionId(hit.sessionId);
      final imported = native == null
          ? importedDao.getByExternal(hit.cli, hit.sessionId)
          : null;
      final openId = native?.id ?? imported?.id;
      if (openId == null) continue;
      final title = native?.title ?? imported!.displayTitle;
      final agent = registry.displayNameFor(hit.cli);
      final matches = hits.where((h) => h.sessionId == hit.sessionId).length;
      items.add(
        QuickOpenItem(
          id: 'conversation/${hit.sessionId}',
          group: QuickOpenGroup.conversations,
          title: title,
          subtitle: hit.excerpt,
          // The age of the reading, not of the conversation: the index is only
          // as current as the trigger that last read that transcript, and §19
          // says a surface must be able to admit that rather than imply the
          // answer is live.
          detail: [
            if (matches > 1) '$matches matches',
            agent,
            if (hit.indexedAt != null)
              'indexed ${describeAge(at.difference(hit.indexedAt!))}',
          ].join('  ·  '),
          icon: AppIcons.chatCircleDots,
          // **FTS5 has already decided this row matches**, and the palette's
          // fuzzy scorer must not overrule it: an excerpt built around a
          // prefix match rarely contains the typed characters in order, so
          // `scoreItem` would drop half of what the index found. Carrying the
          // query itself as a keyword is what makes every hit survive ranking,
          // at the keyword weight — below a title match, which is right.
          keywords: [query, agent],
          weight: _conversationWeight,
          onSelect: () => dismiss(
            () => _focusSession(openId, imported: native == null),
          ),
        ),
      );
    }
    return items;
  }

  // --- open terminal tabs --------------------------------------------------

  /// The terminal tabs nothing else here can reach.
  ///
  /// A tab running one of our sessions is *already* in this list as that
  /// session — picking it reattaches and focuses its pane — so listing it again
  /// would only put one destination in the results twice. What is left is the
  /// tabs that are only tabs: a shell, a build, a dev server. Those had no entry
  /// in quick open at all, which meant the tab strip was the one way to reach
  /// one by name, and a strip is hopeless at a hundred.
  ///
  /// This is why the strip's own picker needed no chord of its own: `Ctrl+K`
  /// was already the way to find things by name, and it now finds these too.
  List<QuickOpenItem> _openTabs() {
    final terminals = ref.read(terminalSessionsControllerProvider);
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    final shell = ref.read(shellControllerProvider.notifier);
    final sessionPanes = {
      for (final record in ref.read(sessionDaoProvider).getAll())
        ?record.paneId,
    };
    return [
      for (final tab in terminals.tabs)
        if (!sessionPanes.contains(tab.focusedPaneId))
          QuickOpenItem(
            id: 'tab/${tab.id}',
            group: QuickOpenGroup.tabs,
            title: sessions.titleForTab(tab.id),
            // The directory is what tells two `zsh` tabs apart, here for the
            // same reason it does in the strip's picker.
            subtitle: sessions.instanceFor(tab.focusedPaneId)?.workingDirectory,
            detail: tab.id == terminals.activeTabId ? 'current' : null,
            icon: AppIcons.terminal,
            keywords: const ['terminal', 'tab'],
            weight: _tabWeight,
            onSelect: () => dismiss(() {
              sessions.activateTab(tab.id);
              // The group that holds the tab, which activating it has just
              // focused — not whichever group was in front before.
              sessions.showTerminalForTab(tab.id);
              shell.focusPane(ShellPane.detail);
            }),
          ),
    ];
  }

  // --- files ---------------------------------------------------------------

  List<QuickOpenItem> _files(
    List<IndexedFile> files,
    Set<String> changedPaths,
  ) => [
    for (final file in files)
      QuickOpenItem(
        id: 'file/${file.relativePath}',
        group: QuickOpenGroup.files,
        title: file.name,
        subtitle: file.relativePath,
        detail: changedPaths.contains(file.relativePath) ? 'modified' : null,
        icon: AppIcons.article,
        weight: changedPaths.contains(file.relativePath) ? 6 : 0,
        onSelect: () => dismiss(
          () => _openFile(
            file,
            changed: changedPaths.contains(file.relativePath),
          ),
        ),
      ),
  ];

  /// A file with uncommitted changes opens in the diff we already render; any
  /// other opens in the configured editor, which is what tapping it in the
  /// Files surface does. Either way the panel shows where you landed.
  Future<void> _openFile(IndexedFile file, {required bool changed}) async {
    final panel = ref.read(sidePanelProvider.notifier);
    if (changed) {
      ref.read(selectedChangeFileProvider.notifier).select(file.relativePath);
      panel.select(SidePanelSurface.changes);
      return;
    }
    panel.select(SidePanelSurface.files);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref.read(editorActionsProvider).openPath(file.hostPath);
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text(error is StateError ? error.message : '$error')),
      );
    }
  }

  // --- branches, pull requests and issues ----------------------------------

  List<QuickOpenItem> _repoFacts() {
    final repositoryId = ref.read(selectedRepositoryIdProvider);
    if (repositoryId == null) return const [];
    final facts = ref
        .read(quickOpenCacheProvider.notifier)
        .factsFor(repositoryId);
    final panel = ref.read(sidePanelProvider.notifier);
    return [
      for (final branch in facts.branches)
        QuickOpenItem(
          id: 'branch/$branch',
          group: QuickOpenGroup.branches,
          title: branch,
          subtitle: facts.branches.first == branch
              ? 'Checked out here'
              : 'Worktree branch',
          icon: AppIcons.gitBranch,
          weight: _branchWeight,
          onSelect: () => dismiss(() => panel.select(SidePanelSurface.changes)),
        ),
      for (final pr in facts.pullRequests)
        QuickOpenItem(
          id: 'pr/${pr.number}',
          group: QuickOpenGroup.github,
          title: pr.title,
          subtitle:
              'PR #${pr.number}${pr.author == null ? '' : ' · ${pr.author}'}',
          detail: pr.state.toLowerCase(),
          icon: AppIcons.gitMerge,
          keywords: ['#${pr.number}', 'pull request'],
          weight: _githubWeight,
          onSelect: () => dismiss(() => panel.select(SidePanelSurface.github)),
        ),
      for (final issue in facts.issues)
        QuickOpenItem(
          id: 'issue/${issue.number}',
          group: QuickOpenGroup.github,
          title: issue.title,
          subtitle: 'Issue #${issue.number}',
          detail: issue.state.toLowerCase(),
          icon: AppIcons.warningCircle,
          keywords: ['#${issue.number}', 'issue'],
          weight: _githubWeight,
          onSelect: () => dismiss(() => panel.select(SidePanelSurface.github)),
        ),
    ];
  }

  // --- agents --------------------------------------------------------------

  List<QuickOpenItem> _agents() {
    final registry = ref.read(agentRegistryProvider);
    return [
      for (final installation in ref.read(agentInstallationsControllerProvider))
        QuickOpenItem(
          id: 'agent/${installation.id}',
          group: QuickOpenGroup.agents,
          title: registry.displayNameFor(installation.agentId),
          subtitle: installation.executable.path,
          detail: installation.version,
          icon: AppIcons.robot,
          keywords: [installation.agentId, installation.environmentId],
          weight: _agentWeight,
          // Lands on the Agents section — the entry is an agent, and a jump
          // to the top of Appearance would be a jump to nowhere.
          onSelect: () => dismiss(
            () => SettingsScreen.show(
              context,
              section: SettingsSectionId.agents,
            ),
          ),
        ),
    ];
  }

  // --- command snippets ----------------------------------------------------

  /// The saved commands that fit the terminal the user is in, plus the two ways
  /// to manage the library.
  ///
  /// **The pane is resolved here, once, while the palette is being built** —
  /// see [resolveSnippetTarget]. That is the whole of "the active terminal":
  /// the palette is a dialog, so by the time a row is activated the keyboard is
  /// in a search field, but `activeTab.focusedPaneId` is controller state that a
  /// dialog never touches. Capturing it at build rather than re-reading it at
  /// select means a pane that dies under the open palette cannot silently
  /// redirect the command into whichever pane the controller refocused; the
  /// captured id is checked again by `insertSnippet` and reported if it has
  /// gone.
  ///
  /// **Filtered to the pane's own shell**, not to the host platform: a WSL
  /// one-liner is absent from a PowerShell pane on the very same machine, and
  /// an untagged snippet is everywhere. There is no SSH case because there is
  /// no SSH pane — `terminalProfilesFor` only ever produces PowerShell, Command
  /// Prompt, a WSL distribution or a POSIX shell, and `EnvironmentKind.ssh`
  /// belongs to sessions and commands rather than to a PTY. Someone who types
  /// `ssh` *inside* a pane has changed what the far end is in a way nothing here
  /// can observe, which is precisely when an untagged snippet is the honest
  /// answer.
  List<QuickOpenItem> _snippets() {
    final terminals = ref.read(terminalSessionsControllerProvider.notifier);
    final state = ref.read(terminalSessionsControllerProvider);
    final target = resolveSnippetTarget(terminals, state);
    final all = ref.read(commandSnippetsProvider);
    final fitting = target == null ? all : target.filter(all);
    return [
      for (final snippet in fitting)
        QuickOpenItem(
          id: 'snippet/${snippet.id}',
          group: QuickOpenGroup.snippets,
          title: snippet.label,
          subtitle: snippet.command,
          // The one thing worth a badge: a snippet that will press Enter has
          // to say so *before* it is picked, not afterwards.
          detail: snippet.submit ? 'runs' : null,
          icon: AppIcons.bookBookmark,
          keywords: [
            snippet.command,
            'snippet',
            ?snippet.shellId,
            if (snippet.submit) 'run',
          ],
          weight: _snippetWeight,
          onSelect: () => dismiss(() => _insert(snippet, target)),
        ),
      // **Filtering is right; silence about it is not.** The rule above is
      // deliberate, but a library of shell-tagged snippets in a pane that fits
      // none of them produced an empty palette and no reason — which reads as
      // "my snippet is gone". Two sentences, because a pane whose shell is
      // unknown is a different fact from one that runs a different shell.
      if (fitting.length < all.length)
        QuickOpenItem(
          id: 'snippet/hidden',
          group: QuickOpenGroup.snippets,
          title: switch (all.length - fitting.length) {
            1 => '1 snippet is for another shell',
            final n => '$n snippets are for another shell',
          },
          subtitle: target?.shellId == null
              ? "This pane's shell is unknown, so only untagged snippets are "
                    'offered'
              : 'This pane runs ${target!.shellId}',
          icon: AppIcons.bookBookmark,
          keywords: const ['snippet', 'hidden', 'shell', 'other'],
          weight: _snippetAdminWeight,
          onSelect: () => dismiss(
            () => SnippetLibraryDialog.show(
              context,
              suggestedShellId: target?.shellId,
            ),
          ),
        ),
      QuickOpenItem(
        id: 'snippet/new',
        group: QuickOpenGroup.snippets,
        title: 'New command snippet…',
        subtitle: 'Keep a command so you can pick it instead of retyping it',
        icon: AppIcons.plus,
        keywords: const ['snippet', 'command', 'save', 'add'],
        weight: _snippetAdminWeight,
        onSelect: () => dismiss(() => _newSnippet(target)),
      ),
      QuickOpenItem(
        id: 'snippet/manage',
        group: QuickOpenGroup.snippets,
        title: 'Manage command snippets…',
        subtitle: 'Edit or remove what you have saved',
        icon: AppIcons.bookBookmark,
        keywords: const ['snippet', 'library', 'edit', 'delete'],
        weight: _snippetAdminWeight,
        onSelect: () => dismiss(
          () => SnippetLibraryDialog.show(
            context,
            suggestedShellId: target?.shellId,
          ),
        ),
      ),
    ];
  }

  void _insert(CommandSnippet snippet, SnippetTarget? target) {
    final message = target == null
        ? 'Open a terminal to type a snippet into.'
        : insertSnippet(
            terminals: ref.read(terminalSessionsControllerProvider.notifier),
            state: ref.read(terminalSessionsControllerProvider),
            snippet: snippet,
            paneId: target.paneId,
          ).message;
    if (message == null || !context.mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// **The notifier is resolved before the `await`, and has to be.**
  ///
  /// [dismiss] pops the palette *before* running the action, so by the time the
  /// user presses Save in the editor — several frames and a whole typing
  /// session later — `_QuickOpenState` is long unmounted. Riverpod 3's
  /// `ConsumerStatefulElement._assertNotDisposed` **throws** on `ref.read` then;
  /// it is a real `throw` and not an assert, so a release build does it too.
  /// The add never ran, the snippet was never written to the dao and never
  /// entered state, and the user's snippet was *lost* rather than stale — which
  /// is why waiting for a refresh never brought it back. Through the terminal
  /// toolbar's snippet button, this is the most discoverable way to add one.
  ///
  /// Same discipline as [_openFile] above, which hoists its messenger for the
  /// same reason: after an `await`, nothing that belongs to the widget is
  /// still there to ask.
  Future<void> _newSnippet(SnippetTarget? target) async {
    final snippets = ref.read(commandSnippetsProvider.notifier);
    final draft = await SnippetEditorDialog.show(
      context,
      suggestedShellId: target?.shellId,
    );
    if (draft == null) return;
    snippets.add(
      label: draft.label,
      command: draft.command,
      shellId: draft.shellId,
      submit: draft.submit,
    );
  }
}
