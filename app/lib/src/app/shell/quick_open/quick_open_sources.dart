import '../../../core/capabilities/capabilities.dart';
import '../../../features/workspaces/data/workspace_data.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../shell_shortcuts.dart' show shellCommandLabel;
import '../../../features/agents/application/agent_installations_controller.dart';
import '../../../features/agents/application/agent_providers.dart';
import '../../../features/artifacts/data/artifacts_data.dart';
import '../../../features/explorer/application/session_context.dart'
    show panelSessionIdProvider;
import '../../../features/artifacts/presentation/artifact_card.dart'
    show selectedArtifactProvider;
import '../../../features/artifacts/presentation/artifact_screen.dart';
import '../../../features/artifacts/presentation/artifact_viewer.dart'
    show artifactKindIcon, artifactKindLabel;
import 'package:karmashala_conversations/karmashala_conversations.dart';
import '../../../features/cli_detection/presentation/detected_projects_view.dart';
import '../../../features/environments/presentation/environment_health_dialog.dart';
import '../../../features/automations/application/scheduled_resume_providers.dart';
import '../../../features/automations/presentation/resume_on_reset_dialog.dart';
import '../../../features/fanout/presentation/fanout_dialog.dart';
import '../../../features/onboarding/presentation/quick_start_card.dart';
import '../../../features/git/application/changes_providers.dart';
import '../../../features/notes/application/notes_providers.dart';
import '../../../features/notifications/application/focus_mode.dart';
import '../../../features/notifications/application/notification_providers.dart';
import '../../../features/projects/application/projects_controller.dart';
import '../../../features/projects/presentation/new_project_dialog.dart';
import '../../../features/editor/application/editor_tab_actions.dart';
import '../../../features/git/application/diff_tab_actions.dart';
import '../../../features/explorer/application/checkout_picker.dart';
import '../../../features/explorer/application/explorer_actions.dart';
import '../../../features/explorer/application/worktree_choices.dart';
import '../../../features/explorer/presentation/unresumable_sessions_dialog.dart';
import '../../../features/overview/application/overview_prefs.dart';
import '../../../features/overview/application/overview_resume.dart';
import '../../../features/overview/presentation/background_launch_notice.dart';
import '../../../features/overview/presentation/overview_triage.dart'
    show showOverviewKeys;
import '../../../features/sessions/application/session_engine_provider.dart';
import '../../../features/sessions/application/session_launcher.dart';
import '../../../features/sessions/application/session_last_active_providers.dart';
import '../../../features/sessions/application/session_list_prefs.dart';
import '../../../features/sessions/application/session_providers.dart';
import '../../../features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/resume.dart';
import 'package:karmashala_session/launch.dart';
import '../../../features/sessions/presentation/new_session_dialog.dart';
import '../../../features/sessions/presentation/session_destination_picker.dart'
    show SessionDestination;
import '../../../features/environments/application/environment_providers.dart';
import '../../../features/explorer/presentation/explorer_tree_rows.dart'
    show openTerminalOn;
import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_git/repositories.dart' show Repository;
import 'package:karmashala_projects/karmashala_projects.dart' show Project;
import '../../../features/files/application/files_tab_actions.dart';
import '../../../core/logging/diagnostics_providers.dart'
    show serverLogFileProvider;
import '../../../features/server/application/server_commands.dart';
import '../../../features/server/application/server_files.dart';
import '../../../features/server/application/server_overview.dart';
import '../../../features/server/presentation/server_command_actions.dart';
import '../../../features/workflows/application/workflows_state.dart';
import '../../../features/settings/presentation/settings_catalog.dart'
    show settingsEntries;
import '../../../features/settings/presentation/settings_nav.dart';
import '../../../features/settings/application/settings_controller.dart';
import '../../../features/snippets/application/snippet_insertion.dart';
import '../../../features/snippets/application/snippet_providers.dart';
import '../../../features/snippets/domain/command_snippet.dart';
import '../../../features/snippets/presentation/snippet_dialogs.dart';
import '../../../features/terminal/application/terminal_presets.dart';
import '../../../features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import '../../../features/terminal/presentation/empty_pane_region.dart';
import '../../../features/terminal/presentation/pane_group_strip.dart';
import '../../../features/terminal/presentation/terminal_panel.dart';
import '../../../features/todos/application/todos_providers.dart';
import '../../../features/workspaces/application/workspaces_controller.dart';
import '../../../features/workspaces/domain/workspace_scope.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart' show Chrome, WidthClass;
import '../../../features/agents/presentation/agent_logo.dart';
import '../context_sheet.dart';
import '../karmashala_about_dialog.dart';
import '../running_tab_view.dart' show openPortInBrowserPane;
import '../../../features/running/application/running_providers.dart';
import '../../../features/running/domain/port_label.dart';
import '../../../features/running/domain/running_groups.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show RunningRole;
import '../phone_routes.dart';
import '../shell_area.dart';
import '../shell_state.dart';
import '../side_panel.dart';
import '../side_panel_state.dart';
import '../tab_picker.dart';
import '../workbench.dart';
import '../../../features/pipelines/presentation/pipeline_run_dialog.dart';
import 'quick_open_cache.dart';
import 'quick_open_item.dart';
import 'quick_open_step.dart';
import 'repo_file_index.dart';
import 'typed_command_runner.dart' show commandDefaultCheckout, peekOnDashboard;

part 'quick_open_sources/commands.dart';
part 'quick_open_sources/status_commands.dart';
part 'quick_open_sources/workspace.dart';
part 'quick_open_sources/sessions.dart';
part 'quick_open_sources/tabs_and_files.dart';
part 'quick_open_sources/agents_settings_snippets.dart';

/// Per-group priors, added to every match in that group. Small on purpose: a
/// large one would let a weak session match outrank an exact command match.
const _sessionWeight = 24.0;
const _workspaceWeight = 14.0;

/// Just under a project: a context is *how the projects are listed*, so on an
/// empty palette it should be visible without displacing the things you open.
const _contextWeight = 12.0;
const _githubWeight = 10.0;
const _branchWeight = 8.0;
const _agentWeight = 4.0;
const _commandWeight = 2.0;

/// Settings rows are listed only once something is typed, so these only order
/// them against other matches: over a command or an agent that matches as
/// well — "theme" means the setting before a verb — and under anything that is
/// work. A page over its sections over its options, so the broader place wins
/// a tie.
const _settingsPageWeight = 6.0;
const _settingsWeight = 5.0;
const _settingsEntryWeight = 4.5;

/// The user's own text, so it outranks an app verb — by a hair only.
const _snippetWeight = 3.0;

/// Below every snippet, so `$` lists the library first and the ways to manage
/// it last — in this group, so `$` on an empty library still offers a way in.
const _snippetAdminWeight = 0.5;

/// Just under an open tab: a preset is a tab you are *about* to have, so what
/// exists comes first and what could exist comes next.
const _presetWeight = 16.0;

/// Below a session, above a project: a shell tab is a place you are already
/// working, but it is not a piece of work in its own right.
const _tabWeight = 18.0;

/// Just under a session's own row: a conversation hit and the session it is in
/// are one destination, and the titled row is the thing the user named.
const _conversationWeight = 22.0;

/// How much the best-ranked conversation is worth over the last one shown, so
/// the search's own order survives the palette's re-sort — and the best still
/// sits no higher than the least recent session row.
const _conversationRankSpread = 2.0;

/// Conversations one search puts in the palette.
const int kQuickOpenConversationLimit = 20;

/// How much the most recent session is worth over the oldest.
const _recencySpread = 12.0;

/// Being in the repository the user is already looking at is worth something,
/// but not much: quick open's whole point is reaching what is *not* on screen.
const _selectedRepoBoost = 10.0;

/// Builds everything quick open can find. Every [QuickOpenItem.onSelect]
/// delegates to the code that owns that jump: a second way in, not a second one.
class QuickOpenSources {
  QuickOpenSources({
    required this.ref,
    required this.context,
    required this.dismiss,
    required this.push,
    this.phone,
  });

  final WidgetRef ref;
  final BuildContext context;

  /// Closes the surface before acting, so a dialog opened from here is not
  /// stacked underneath it. An [action] that returns a future — a session's
  /// resume — is still in progress until it completes, which is how an
  /// "open to the side" knows how long to wait for its tab.
  final void Function(FutureOr<void> Function() action) dismiss;

  /// Goes down a level, the palette staying open: a project lists what can be
  /// done with it rather than jumping to it (owner, 2026-10-01).
  final void Function(QuickOpenStep step) push;

  /// The phone shell, when it is the one on screen: what lands in the
  /// workbench or the side panel is then brought up where the phone shows it,
  /// and what has no place on a phone is not listed.
  final PhoneShellRoutes? phone;

  bool get _onPhone => phone != null;

  /// [action], then the phone's session page: a workbench tab is otherwise
  /// opened out of sight.
  VoidCallback _seen(VoidCallback action) {
    final phone = this.phone;
    if (phone == null) return action;
    return () {
      action();
      phone.showWorkbench();
    };
  }

  /// [action], then the Projects area that draws what it picked: the phone's
  /// Projects tab, or the desktop sidebar switched to Projects (and opened if
  /// it was hidden) — a selection made out of sight is no jump at all
  /// (owner, 2026-10-01). Resolved now, since it runs after the palette has
  /// closed.
  VoidCallback _inProjects(VoidCallback action) {
    final phone = this.phone;
    if (phone != null) {
      return () {
        action();
        phone.showProjects();
      };
    }
    if (!shellAreaShown(ref, ShellArea.projects)) return action;
    final area = ref.read(shellAreaProvider.notifier);
    final shell = ref.read(shellControllerProvider.notifier);
    final sidebarHidden = !ref
        .read(shellControllerProvider)
        .explorerPaneVisible;
    return () {
      action();
      area.select(ShellArea.projects);
      if (sidebarHidden) shell.toggleExplorerPane();
    };
  }

  /// A side-panel surface on the phone: the session page's context sheet on
  /// [surface]. Resolved now, since it runs after the palette has closed.
  VoidCallback _inContextSheet(SidePanelSurface surface) {
    final phone = this.phone!;
    final sheet = ref.read(contextSheetSurfaceProvider.notifier);
    return () {
      phone.showWorkbench();
      sheet.show(surface);
      showContextSheet(context);
    };
  }

  List<QuickOpenItem> build({
    List<IndexedFile> files = const [],
    Set<String> changedPaths = const {},
  }) => [
    ..._commands(),
    ..._contexts(),
    ..._workspace(),
    ..._sessions(),
    ..._openTabs(),
    ..._artifacts(),
    ..._files(files, changedPaths),
    ..._repoFacts(),
    ..._agents(),
    ..._settings(),
    ..._snippets(),
    ..._presets(),
  ];

  // --- commands -----------------------------------------------------------

  QuickOpenItem _command(
    String label, {
    required IconData icon,
    required VoidCallback onSelect,
    String? subtitle,
    String? shortcut,
    List<String> keywords = const [],
    bool opensTab = false,
    bool onlyWhenSearched = false,
  }) => QuickOpenItem(
    id: 'command/$label',
    group: QuickOpenGroup.commands,
    title: label,
    subtitle: subtitle,
    detail: shortcut,
    icon: icon,
    keywords: keywords,
    weight: _commandWeight,
    opensTab: opensTab,
    onlyWhenSearched: onlyWhenSearched,
    onSelect: () => dismiss(onSelect),
  );

  /// Lists the selected checkout's worktrees, once git has, as a step in the
  /// switcher's order and with its search.
  Future<void> _pushWorktrees() async {
    final listening = ref.listenManual(worktreeChoicesProvider, (_, _) {});
    try {
      await ref.read(repoWorktreesProvider.future);
      final choices = listening.read();
      if (choices != null) push(worktreesStep(choices));
    } on Object {
      // Not a repository, or git could not say: there is nothing to list.
    } finally {
      listening.close();
    }
  }

  /// [choices] as a step: the open ones, then the merged ones; a pick moves
  /// the one selection and closes the palette.
  QuickOpenStep worktreesStep(WorktreeChoices choices) {
    String idOf(WorktreeChoice choice) => 'worktree/${choice.path.path}';
    QuickOpenItem item(WorktreeChoice choice, QuickOpenGroup group) =>
        QuickOpenItem(
          id: idOf(choice),
          group: group,
          title: choice.label,
          subtitle: [
            choice.folder,
            if (choice.current) 'current',
            if (choice.sessions == 1) '1 session',
            if (choice.sessions > 1) '${choice.sessions} sessions',
          ].join('  ·  '),
          icon: choice.current ? AppIcons.check : AppIcons.gitBranch,
          onSelect: () => dismiss(_worktreePick(choice)),
        );
    final items = [
      for (final c in choices.open) item(c, QuickOpenGroup.worktrees),
      for (final c in choices.merged) item(c, QuickOpenGroup.mergedWorktrees),
    ];
    return QuickOpenStep(
      id: 'worktrees',
      title: 'Worktrees',
      hintText: 'Search worktrees by branch or folder',
      items: () => items,
      filter: (query, items) {
        final byId = {for (final i in items) i.id: i};
        final shown = choices.where(query);
        QuickOpenSection section(
          QuickOpenGroup group,
          List<WorktreeChoice> rows,
        ) => QuickOpenSection(
          group: group,
          results: [
            for (final c in rows)
              QuickOpenResult(
                item: byId[idOf(c)]!,
                score: 0,
                titlePositions: const [],
              ),
          ],
        );
        return [
          if (shown.open.isNotEmpty)
            section(QuickOpenGroup.worktrees, shown.open),
          if (shown.merged.isNotEmpty)
            section(QuickOpenGroup.mergedWorktrees, shown.merged),
        ];
      },
    );
  }

  /// What picking [choice] does, resolved now: it runs after the palette, and
  /// its `ref`, have gone.
  Future<void> Function() _worktreePick(WorktreeChoice choice) {
    final picker = ref.read(checkoutPickerProvider);
    final projectId = ref.read(selectedCheckoutProvider)?.projectId;
    final messenger = ScaffoldMessenger.maybeOf(context);
    return () async {
      final row = choice.repository;
      if (row != null) {
        picker.select(row);
        return;
      }
      if (projectId == null) return;
      try {
        if (await picker.selectWorktree(projectId, choice.path) == null) {
          messenger?.showSnackBar(
            SnackBar(content: Text('A rescan did not record ${choice.label}.')),
          );
        }
      } on Object catch (error) {
        messenger?.showSnackBar(
          SnackBar(content: Text('Could not rescan: $error')),
        );
      }
    };
  }

  /// The session on screen's resume, and the list of all of them — each only
  /// while it has something to act on.
  List<QuickOpenItem> _resumeCommands() {
    final sessionId = ref.read(selectedSessionIdProvider);
    final native =
        sessionId != null &&
        ref.read(sessionsDataProvider).getById(sessionId) != null;
    final waiting = native
        ? ref.read(sessionResumeBadgeProvider(sessionId))
        : null;
    final all = ref.read(liveScheduledResumesProvider).length;
    const keywords = ['usage', 'limit', 'rate limit', 'reset', 'continue'];
    return [
      if (native)
        _command(
          waiting == null
              ? 'Resume when usage resets…'
              : 'Change scheduled resume…',
          subtitle:
              waiting?.label ??
              'This session, at its limit\'s reset or a time you choose',
          icon: AppIcons.clock,
          keywords: keywords,
          onSelect: () => ResumeOnResetDialog.show(context, [sessionId]),
        ),
      if (native && waiting != null)
        _command(
          'Cancel scheduled resume',
          subtitle: waiting.label,
          icon: AppIcons.x,
          keywords: keywords,
          onSelect: () =>
              ref.read(scheduledResumeControllerProvider).cancelFor(sessionId),
        ),
      if (all > 0)
        _command(
          'Scheduled resumes',
          subtitle: all == 1 ? '1 waiting' : '$all waiting',
          icon: AppIcons.clock,
          keywords: keywords,
          opensTab: true,
          // Under the automations they follow from.
          onSelect: () =>
              openWorkflowsTab(ref, section: WorkflowsSection.automations),
        ),
    ];
  }
}
