import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../agents/application/agent_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../settings/application/settings_controller.dart';
import '../application/explorer_agent_filter.dart';
import '../application/explorer_sections.dart';
import '../application/explorer_tree_provider.dart';
import '../application/explorer_view_mode.dart';
import '../application/session_selection.dart';
import '../domain/agent_filter.dart';

/// The Projects header's verbs, drawn before its **+** (spec §4, board A2):
/// **Select several**, then the filter. Its own widget, so a sync starting or
/// the filter changing repaints the header and not the tree beneath it.
///
/// *Detect CLI sessions* and *New session* are not here: both are in the
/// Workspace menu and the quick panel, and *New session* is the Sessions
/// area's own **+** — a header of five glyphs was the clutter the board cut.
class ExplorerHeaderActions extends ConsumerWidget {
  const ExplorerHeaderActions({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncing = ref.watch(sessionSyncingProvider) > 0;
    final selecting = ref.watch(
      sessionSelectionProvider.select((s) => s.active),
    );
    final hasProjects = ref.watch(
      explorerFilteredProjectsProvider.select((p) => p.isNotEmpty),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (syncing)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: Insets.xs),
            child: InlineSpinner(size: InlineSpinnerSize.medium),
          ),
        IconButton(
          // A toggle rather than Ctrl-click, which is invisible until
          // somebody tells you about it. The same words and glyph as the
          // Sessions area's, so the two headers teach one gesture.
          tooltip: selecting ? 'Done selecting' : 'Select several',
          isSelected: selecting,
          icon: const Icon(AppIcons.listChecks),
          onPressed: () =>
              ref.read(sessionSelectionProvider.notifier).toggleMode(),
        ),
        // One funnel for everything the Explorer holds back: two hiding
        // controls would be two stories about why a session is off screen.
        if (hasProjects) ...[
          const SizedBox(width: 6),
          const _ConnectedFilterButton(),
        ],
      ],
    );
  }
}

/// Reads what [ExplorerFilterButton] draws and writes what it picks.
class _ConnectedFilterButton extends ConsumerWidget {
  const _ConnectedFilterButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(explorerAgentFilterProvider);
    final showingViews = ref.watch(explorerShowingViewsProvider);
    final showingActivity = ref.watch(
      explorerLensProvider.select((lens) => lens == ExplorerLens.activity),
    );
    final hidingEmptySections = ref.watch(
      settingsControllerProvider.select((s) => s.hideEmptySections),
    );
    // Watched only while sections are drawn: watching it is what pays for the
    // empty filter — see [explorerSectionLayoutProvider].
    final layout = showingViews
        ? ref.watch(explorerSectionLayoutProvider)
        : null;
    final settings = ref.read(settingsControllerProvider.notifier);
    return ExplorerFilterButton(
      registry: ref.watch(agentRegistryProvider),
      filter: filter,
      showingViews: showingViews,
      showingActivity: showingActivity,
      hidingEmptySections: hidingEmptySections,
      hiddenSections: layout?.hidden,
      sectionsOnScreen: layout != null,
      onToggleSavedViews: () =>
          ref.read(explorerShowingViewsProvider.notifier).toggle(),
      onToggleActivity: () =>
          ref.read(explorerLensProvider.notifier).toggle(ExplorerLens.activity),
      onToggleEmptySections: () =>
          settings.setHideEmptySections(!hidingEmptySections),
      onAgentFilter: (ids) => settings.setExplorerAgentFilter(ids),
    );
  }
}

/// Everything the Explorer is hiding, behind one glyph. The icon fills only
/// while the agent filter narrows — hiding empty sections is on by default.
class ExplorerFilterButton extends StatelessWidget {
  const ExplorerFilterButton({
    required this.registry,
    required this.filter,
    required this.showingViews,
    required this.hidingEmptySections,
    required this.hiddenSections,
    required this.sectionsOnScreen,
    required this.onToggleSavedViews,
    required this.onToggleEmptySections,
    required this.onAgentFilter,
    this.showingActivity = false,
    this.onToggleActivity,
    super.key,
  });

  final AgentRegistry registry;
  final AgentFilter filter;
  final bool showingViews;
  final bool hidingEmptySections;

  /// Whether the by-day lens is what the Explorer's body shows.
  final bool showingActivity;

  /// Null leaves the lens off the menu.
  final VoidCallback? onToggleActivity;

  /// How many sections the empty filter folded away, null when sections are
  /// not on screen at all.
  final int? hiddenSections;

  final bool sectionsOnScreen;
  final VoidCallback onToggleSavedViews;
  final VoidCallback onToggleEmptySections;

  /// The agent ids to narrow to; empty means every agent.
  final ValueChanged<Set<String>> onAgentFilter;

  static const String _allAgents = 'agents:all';
  static const String _emptySections = 'sections:empty';
  static const String _savedViews = 'views:saved';
  static const String _activity = 'lens:activity';
  static const String _agentPrefix = 'agent:';

  @override
  Widget build(BuildContext context) {
    final hidden = hiddenSections ?? 0;
    return PopupMenuButton<String>(
      tooltip: _tooltip(),
      padding: EdgeInsets.zero,
      iconSize: Chrome.icon,
      icon: Icon(filter.isUnfiltered ? AppIcons.funnel : AppIcons.funnelFill),
      onSelected: (value) {
        if (value == _activity) {
          onToggleActivity?.call();
        } else if (value == _savedViews) {
          onToggleSavedViews();
        } else if (value == _emptySections) {
          onToggleEmptySections();
        } else if (value == _allAgents) {
          onAgentFilter(const {});
        } else {
          onAgentFilter(
            filter.toggled(value.substring(_agentPrefix.length)).agentIds,
          );
        }
      },
      itemBuilder: (context) => [
        DesktopMenuItem(
          value: _savedViews,
          // The one item here that changes *what* is listed rather than what
          // is held back, which is why it sits above its own divider.
          label: 'Saved views',
          icon: AppIcons.listChecks,
          selected: showingViews,
        ),
        // A lens over the whole body, not a filter of the tree; picked again,
        // or Escape inside it, goes back to the tree unchanged.
        if (onToggleActivity != null)
          DesktopMenuItem(
            value: _activity,
            label: 'Activity by day',
            icon: AppIcons.clock,
            selected: showingActivity,
          ),
        const PopupMenuDivider(),
        DesktopMenuItem(
          value: _allAgents,
          label: 'All agents',
          icon: AppIcons.listChecks,
          selected: filter.isUnfiltered,
        ),
        for (final id in filterableAgentIds(registry))
          DesktopMenuItem(
            value: '$_agentPrefix$id',
            label: registry.displayNameFor(id),
            icon: AppIcons.robot,
            selected: filter.agentIds.contains(id),
          ),
        if (sectionsOnScreen) ...[
          const PopupMenuDivider(),
          DesktopMenuItem(
            value: _emptySections,
            // A section folded away for holding nothing is invisible, so this
            // row is the only place a user learns it exists.
            label: !hidingEmptySections
                ? 'Hide empty sections'
                : hidden == 0
                ? 'Showing every section'
                : 'Show $hidden empty section${hidden == 1 ? '' : 's'}',
            icon: AppIcons.funnel,
            selected: hidingEmptySections,
          ),
        ],
      ],
    );
  }

  String _tooltip() {
    final hidden = hiddenSections ?? 0;
    final agents = agentFilterTooltip(filter, registry);
    if (!hidingEmptySections || hidden == 0) return agents;
    return '$agents · $hidden empty '
        'section${hidden == 1 ? '' : 's'} hidden';
  }
}
