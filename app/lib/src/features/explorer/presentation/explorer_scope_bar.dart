import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/phone_shell.dart';
import '../../projects/application/projects_controller.dart';
import '../../settings/application/settings_controller.dart';
import '../../ssh/presentation/pair_phone_entry.dart';
import '../../workspaces/application/workspaces_controller.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import '../../workspaces/domain/workspace_scope.dart';
import '../application/explorer_tree_nodes.dart';
import '../application/explorer_tree_provider.dart';
import 'environment_rows.dart';
import 'explorer_context_actions.dart';
import 'explorer_tree_rows.dart';
import 'sidebar_chrome.dart';

/// **Which machine the Explorer lists**: one small menu at the end of the
/// filter row — the secondary filter, after the groups. The machine used to be
/// the tree's top level; it is a choice above the list now, so a project
/// stands at depth zero. Not drawn with one machine: there is nothing to
/// choose between.
class ExplorerEnvironmentSwitcher extends ConsumerWidget {
  const ExplorerEnvironmentSwitcher({super.key});

  static const _all = '';
  static const _terminal = 'terminal:';
  static const _pairPhone = 'pair-phone:';

  /// Every machine at once — in the menu, on the face where it fits, and to a
  /// screen reader. Where it does not fit the face is its glyph: a second
  /// "All" beside the groups' own would read as one filter said twice.
  static const allLabel = 'All environments';

  /// What a machine's line in a menu says under its name.
  static String detailOf(EnvironmentChoice choice) => choice.environment == null
      // A machine whose row has gone is named, never folded into this one —
      // and the menu is where it says so.
      ? '${projectCountWords(choice.projectCount)} · no longer in '
            'the workspace'
      : choice.projectCount == 0
      ? 'No projects yet'
      : projectCountWords(choice.projectCount);

  /// The verbs a machine in scope offers besides being chosen.
  static List<PopupMenuEntry<String>> actionsOf(
    WidgetRef ref,
    EnvironmentChoice choice,
  ) => [
    if (choice.environment != null) ...[
      const DesktopMenuDivider(),
      DesktopMenuItem(
        value: '$_terminal${choice.environmentId}',
        label: 'Open a terminal on ${choice.label}',
        icon: AppIcons.terminal,
      ),
      // Only a box has an address of its own for a phone to pair with.
      if (sshHostOf(ref, choice.environment) != null)
        DesktopMenuItem(
          value: '$_pairPhone${choice.environmentId}',
          label: 'Pair a phone with ${choice.label}…',
          icon: AppIcons.deviceMobile,
        ),
    ],
  ];

  /// Runs what [actionsOf] or a machine's own entry was picked for.
  static void run(
    BuildContext context,
    WidgetRef ref,
    String value,
    EnvironmentChoice? choice,
  ) {
    if (value.startsWith(_terminal)) {
      final environment = choice?.environment;
      if (environment != null) {
        openTerminalOn(
          ref,
          environment,
          showWorkbench: phoneWorkbenchOpener(context, ref),
        );
      }
      return;
    }
    if (value.startsWith(_pairPhone)) {
      pairPhoneWith(context, ref, choice?.environment);
      return;
    }
    ref
        .read(settingsControllerProvider.notifier)
        .setExplorerEnvironmentScope(value);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(explorerEnvironmentScopeProvider);
    final environments = scope.environments;
    if (environments.length < 2) return const SizedBox.shrink();
    final current = environments
        .where((choice) => choice.environmentId == scope.environmentId)
        .firstOrNull;
    // "Environment" is the app's word for a machine (Settings › Machines),
    // so every one of them is "All environments" — here, in the menu and to a
    // screen reader.
    final label = current?.label ?? allLabel;
    final total = environments.fold(0, (sum, e) => sum + e.projectCount);
    final icon = current == null
        ? AppIcons.stack
        : environmentGlyph(current.kind);

    List<PopupMenuEntry<String>> items() => [
      DesktopMenuDetailItem(
        value: _all,
        label: allLabel,
        detail: projectCountWords(total),
        icon: AppIcons.stack,
        selected: current == null,
      ),
      const DesktopMenuDivider(),
      for (final choice in environments)
        DesktopMenuDetailItem(
          value: choice.environmentId,
          label: choice.label,
          detail: detailOf(choice),
          icon: environmentGlyph(choice.kind),
          selected: choice.environmentId == current?.environmentId,
        ),
      if (current != null) ...actionsOf(ref, current),
    ];

    final theme = Theme.of(context);
    final style = SidebarFilterTab.styleOf(theme);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // A whole name or none: under its room the face is the machine's glyph
        // and the caret, and the name is in the tooltip and to a reader.
        final painter = TextPainter(
          text: TextSpan(text: label, style: style),
          textDirection: direction,
          textScaler: scaler,
          maxLines: 1,
        );
        final double natural;
        try {
          natural = (painter..layout()).width;
        } finally {
          painter.dispose();
        }
        final fits =
            SidebarFilterTab.widthFor(
              natural,
              lead: Chrome.iconSmall,
              trail: Chrome.iconSmall,
            ) <=
            constraints.maxWidth;
        return Builder(
          builder: (anchor) => SidebarFilterTab(
            label: fits ? label : null,
            // A machine in force is a filter in force: filled, like a group's.
            selected: current != null,
            leading: Icon(icon),
            trailing: const Icon(AppIcons.caretDown),
            tooltip: current == null
                ? 'Showing every environment'
                : 'Showing $label only',
            semanticLabel: 'Environment: $label',
            onTap: () async {
              final picked = await showDesktopMenuUnder<String>(
                anchor,
                items(),
              );
              if (picked != null && context.mounted) {
                run(context, ref, picked, current);
              }
            },
          ),
        );
      },
    );
  }
}

/// **The one filter row above the list**: the groups as quiet tabs from the
/// left — the primary filter — and, with more than one machine, the machine
/// menu at the row's end. Nothing is drawn when there is neither to choose.
/// On the rows' fill edge, as the search field above it is, so the field, the
/// row and the list are one column.
class ExplorerFilterRow extends ConsumerWidget {
  const ExplorerFilterRow({super.key});

  /// The most of the row the machine menu may take; the groups have the rest.
  static const switcherShare = 0.42;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Whether there is anything to choose, never what is chosen: a switch
    // redraws the tabs or the menu, not this row.
    final contexts = ref.watch(
      workspacesControllerProvider.select((all) => all.isNotEmpty),
    );
    final machines = ref.watch(
      explorerEnvironmentScopeProvider.select(
        (scope) => scope.environments.length > 1,
      ),
    );
    if (!contexts && !machines) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Sidebar.fillEdge,
        Sidebar.headerGap,
        Sidebar.fillEdge,
        0,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            Expanded(
              child: contexts
                  ? const ExplorerContextChips()
                  : const SizedBox.shrink(),
            ),
            if (machines) ...[
              const SizedBox(width: Insets.xs),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * switcherShare,
                ),
                child: const ExplorerEnvironmentSwitcher(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The rows above the list: [search], then the [ExplorerFilterRow]. It
/// watches nothing, so a filter switch leaves the field as it is.
class ExplorerScopeBar extends StatelessWidget {
  const ExplorerScopeBar({required this.search, super.key});

  final Widget search;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [search, const ExplorerFilterRow()],
  );
}

/// **Which context the Explorer lists**: `All`, one tab per context, and the
/// projects in none — one at a time — then `…` with every one of them. It
/// draws [workspaceScopeProvider], the same scope Quick Open switches, so the
/// two cannot disagree. Nothing is drawn while there are no contexts.
class ExplorerContextChips extends ConsumerWidget {
  const ExplorerContextChips({super.key});

  static const _newContext = 'chips:new';
  static const _manage = 'chips:manage';
  static const _scopePrefix = 'scope:';

  /// The most one tab's name may take before it is ellipsised.
  static const chipMax = 132.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Narrowing to a folded context would show a header and nothing else —
    // from here, or from Quick Open, which switches the same scope.
    ref.listen(workspaceScopeProvider, (_, scope) {
      if (scope.isAll) return;
      ref.read(settingsControllerProvider.notifier).revealExplorerNodes([
        contextHeaderId(scope.workspaceId),
      ]);
    });
    final contexts = [...ref.watch(workspacesControllerProvider)]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (contexts.isEmpty) return const SizedBox.shrink();
    final scope = ref.watch(workspaceScopeProvider);
    final counts = ref.watch(workspaceProjectCountsProvider);
    final projects = ref.watch(
      projectsControllerProvider.select((projects) => projects.length),
    );
    final known = {for (final context in contexts) context.id};
    final filed = counts.entries
        .where((entry) => known.contains(entry.key))
        .fold(0, (sum, entry) => sum + entry.value);
    final loose = projects - filed;

    final entries = [
      _ChipEntry(scope: WorkspaceScope.all, label: 'All', count: projects),
      for (final workspace in contexts)
        _ChipEntry(
          scope: WorkspaceScope.of(workspace.id),
          label: workspace.name,
          count: counts[workspace.id] ?? 0,
          workspace: workspace,
        ),
      // Offered while it would show something, and while it is what is shown.
      if (loose > 0 || scope.unassignedOnly)
        _ChipEntry(
          scope: WorkspaceScope.unassigned,
          label: ContextHeaderNode.noContextLabel,
          count: loose,
        ),
    ];
    void select(WorkspaceScope target) =>
        ref.read(workspaceScopeProvider.notifier).select(target);

    final style = SidebarFilterTab.styleOf(Theme.of(context));
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          textDirection: direction,
          textScaler: scaler,
          maxLines: 1,
        );
        final List<double> widths;
        try {
          widths = [
            for (final entry in entries)
              SidebarFilterTab.widthFor(
                math.min(
                  (painter
                        ..text = TextSpan(text: entry.label, style: style)
                        ..layout())
                      .width,
                  scaler.scale(chipMax),
                ),
                lead: entry.hue == null ? 0 : Chrome.dot,
              ),
          ];
        } finally {
          painter.dispose();
        }
        final visible = _fitting(
          widths,
          selected: entries.indexWhere((entry) => entry.scope == scope),
          room: constraints.maxWidth - _OverflowButton.width - Insets.xs,
        );
        // The tabs and `…` hug the left, from the field's edge; the room
        // after them is the row's, not a gap inside it.
        return Row(
          children: [
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final index in visible) ...[
                    Flexible(
                      // The tab in force is drawn whether or not it fits, so
                      // it is the one that gives — under the narrowest panes
                      // at the largest text. Alone in flexing, it has all the
                      // spare room.
                      flex: entries[index].scope == scope ? 1 : 0,
                      child: _ScopeChip(
                        entry: entries[index],
                        selected: entries[index].scope == scope,
                        onTap: () => select(entries[index].scope),
                        menuItems: index == 0
                            ? null
                            : () => contextMenuItems(
                                workspace: entries[index].workspace,
                                scope: ref.read(workspaceScopeProvider),
                              ),
                        onMenu: (action) => runContextAction(
                          ref,
                          context,
                          action,
                          entries[index].workspace,
                        ),
                      ),
                    ),
                    const SizedBox(width: Insets.xs),
                  ],
                ],
              ),
            ),
            _OverflowButton(
              hidden: entries.length - visible.length,
              itemBuilder: () => [
                for (final entry in entries)
                  DesktopMenuDetailItem(
                    value: '$_scopePrefix${entry.scope.stored}',
                    label: entry.label,
                    detail:
                        entry.workspace?.description ??
                        projectCountWords(entry.count),
                    detailMaxLines: 1,
                    icon: entry.workspace == null
                        ? (entry.scope.isAll
                              ? AppIcons.folders
                              : AppIcons.minusCircle)
                        : AppIcons.stack,
                    selected: entry.scope == scope,
                  ),
                const DesktopMenuDivider(),
                DesktopMenuItem(
                  value: _newContext,
                  label: 'New context…',
                  icon: AppIcons.folderPlus,
                ),
                DesktopMenuItem(
                  value: _manage,
                  label: 'Manage contexts…',
                  icon: AppIcons.stack,
                ),
              ],
              onSelected: (value) {
                if (value.startsWith(_scopePrefix)) {
                  select(
                    WorkspaceScope.parse(value.substring(_scopePrefix.length)),
                  );
                } else {
                  runContextAction(
                    ref,
                    context,
                    value == _newContext
                        ? contextActionNew
                        : contextActionManage,
                    null,
                  );
                }
              },
            ),
          ],
        );
      },
    );
  }

  /// Which tabs fit [room], by index and in order. `All` and the [selected]
  /// tab always do — a filter in force is never folded into a menu.
  static List<int> _fitting(
    List<double> widths, {
    required int selected,
    required double room,
  }) {
    final forced = {0, if (selected > 0) selected};
    var left = room;
    for (final index in forced) {
      left -= widths[index] + Insets.xs;
    }
    final visible = {...forced};
    for (var index = 1; index < widths.length; index++) {
      if (forced.contains(index)) continue;
      final need = widths[index] + Insets.xs;
      if (need > left) break;
      visible.add(index);
      left -= need;
    }
    return visible.toList()..sort();
  }
}

class _ChipEntry {
  const _ChipEntry({
    required this.scope,
    required this.label,
    required this.count,
    this.workspace,
  });

  final WorkspaceScope scope;
  final String label;
  final int count;
  final Workspace? workspace;

  ContextHue? get hue => ContextHue.tryParse(workspace?.color);
}

class _ScopeChip extends StatelessWidget {
  const _ScopeChip({
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.onMenu,
    this.menuItems,
  });

  final _ChipEntry entry;
  final bool selected;
  final VoidCallback onTap;
  final List<PopupMenuEntry<String>> Function()? menuItems;
  final ValueChanged<String> onMenu;

  @override
  Widget build(BuildContext context) {
    final hue = entry.hue;
    final chip = SidebarFilterTab(
      label: entry.label,
      selected: selected,
      tooltip: entry.workspace?.description ?? projectCountWords(entry.count),
      maxLabelWidth: MediaQuery.textScalerOf(
        context,
      ).scale(ExplorerContextChips.chipMax),
      // The dot stays whether or not the tab is the one in force: the colour
      // is the context's, not the filter's.
      leading: hue == null ? null : ContextHueDot(hue: hue, size: Chrome.dot),
      onTap: onTap,
    );
    final menuItems = this.menuItems;
    return menuItems == null
        ? chip
        : ContextMenuRegion(
            itemBuilder: menuItems,
            onSelected: onMenu,
            child: chip,
          );
  }
}

/// `…` after the tabs: every context, including the ones that did not fit,
/// and the two verbs that are about contexts rather than about one of them.
class _OverflowButton extends StatelessWidget {
  const _OverflowButton({
    required this.hidden,
    required this.itemBuilder,
    required this.onSelected,
  });

  final int hidden;
  final List<PopupMenuEntry<String>> Function() itemBuilder;
  final ValueChanged<String> onSelected;

  /// Square, a tab's height.
  static const width = SidebarFilterTab.height;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Builder(
      builder: (anchor) => SidebarFilterTab(
        selected: false,
        padding: 0,
        leading: const Icon(AppIcons.dotsThree, size: Chrome.icon),
        tooltip: hidden == 0 ? 'Contexts' : 'Contexts — $hidden more',
        onTap: () async {
          final picked = await showDesktopMenuUnder<String>(
            anchor,
            itemBuilder(),
          );
          if (picked != null) onSelected(picked);
        },
      ),
    ),
  );
}
