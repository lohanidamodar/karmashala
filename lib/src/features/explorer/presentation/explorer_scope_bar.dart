import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../projects/application/projects_controller.dart';
import '../../settings/application/settings_controller.dart';
import '../../workspaces/application/workspaces_controller.dart';
import '../../workspaces/domain/workspace.dart';
import '../../workspaces/domain/workspace_scope.dart';
import '../application/explorer_tree_nodes.dart';
import '../application/explorer_tree_provider.dart';
import 'environment_rows.dart';
import 'explorer_context_actions.dart';
import 'explorer_tree_rows.dart';

/// **Which machine the Explorer lists.** The machine used to be the tree's top
/// level; it is a choice above the list now, so a project stands at depth zero.
/// Not drawn with one machine: there is nothing to choose between.
class ExplorerEnvironmentSwitcher extends ConsumerWidget {
  const ExplorerEnvironmentSwitcher({super.key});

  static const _all = '';
  static const _terminal = 'terminal:';

  /// Under this the button is its glyph and caret, and the name its tooltip.
  static const nameFloor = 260.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(explorerEnvironmentScopeProvider);
    final environments = scope.environments;
    if (environments.length < 2) return const SizedBox.shrink();
    final current = environments
        .where((choice) => choice.environmentId == scope.environmentId)
        .firstOrNull;
    // Short on the button, which shares its row with the search field; the
    // menu and the tooltip say it in full.
    final label = current?.label ?? 'Everywhere';
    final total = environments.fold(0, (sum, e) => sum + e.projectCount);

    return PopupMenuButton<String>(
      tooltip: current == null
          ? 'Showing every environment'
          : 'Showing $label only',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      onSelected: (value) {
        if (value.startsWith(_terminal)) {
          final environment = current?.environment;
          if (environment != null) openTerminalOn(ref, environment);
          return;
        }
        ref
            .read(settingsControllerProvider.notifier)
            .setExplorerEnvironmentScope(value);
      },
      itemBuilder: (context) => [
        DesktopMenuDetailItem(
          value: _all,
          label: 'All environments',
          detail: projectCountWords(total),
          icon: AppIcons.stack,
          selected: current == null,
        ),
        const DesktopMenuDivider(),
        for (final choice in environments)
          DesktopMenuDetailItem(
            value: choice.environmentId,
            label: choice.label,
            // A machine whose row has gone is named, never folded into this
            // one — and the menu is where it says so.
            detail: choice.environment == null
                ? '${projectCountWords(choice.projectCount)} · no longer in '
                      'the workspace'
                : choice.projectCount == 0
                ? 'No projects yet'
                : projectCountWords(choice.projectCount),
            icon: environmentGlyph(choice.kind),
            selected: choice.environmentId == current?.environmentId,
          ),
        if (current?.environment != null) ...[
          const DesktopMenuDivider(),
          DesktopMenuItem(
            value: '$_terminal${current!.environmentId}',
            label: 'Open a terminal on ${current.label}',
            icon: AppIcons.terminal,
          ),
        ],
      ],
      child: _SwitcherFace(
        icon: current == null ? AppIcons.stack : environmentGlyph(current.kind),
        label: label,
      ),
    );
  }
}

class _SwitcherFace extends StatelessWidget {
  const _SwitcherFace({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final named =
        (ExplorerScopeBar.widthOf(context) ?? double.infinity) >=
        ExplorerEnvironmentSwitcher.nameFloor;
    return Semantics(
      button: true,
      label: 'Environment: $label',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Chrome.control),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: Chrome.icon, color: scheme.onSurfaceVariant),
              if (named) ...[
                SizedBox(width: density.glyphGap),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: density.rowTitle(theme, strong: true),
                  ),
                ),
              ],
              SizedBox(width: density.glyphGap / 2),
              Icon(
                AppIcons.caretDown,
                size: Chrome.iconSmall,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The row above the list: the machine on the left when there is more than
/// one, and [search] in what is left.
class ExplorerScopeBar extends ConsumerWidget {
  const ExplorerScopeBar({required this.search, super.key});

  final Widget search;

  /// The most of the row the machine's name may take.
  static const switcherShare = 0.42;

  /// The bar's width, for the switcher to decide whether its name fits.
  static double? widthOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ScopeBarWidth>()?.width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final several = ref.watch(
      explorerEnvironmentScopeProvider.select(
        (scope) => scope.environments.length > 1,
      ),
    );
    if (!several) return search;
    return LayoutBuilder(
      builder: (context, constraints) => _ScopeBarWidth(
        width: constraints.maxWidth,
        child: Row(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.maxWidth * switcherShare,
              ),
              child: const Padding(
                padding: EdgeInsets.only(left: Insets.xs, top: Insets.xs),
                child: ExplorerEnvironmentSwitcher(),
              ),
            ),
            Expanded(child: search),
          ],
        ),
      ),
    );
  }
}

class _ScopeBarWidth extends InheritedWidget {
  const _ScopeBarWidth({required this.width, required super.child});

  final double width;

  @override
  bool updateShouldNotify(_ScopeBarWidth old) => old.width != width;
}

/// **Which context the Explorer lists**: `All`, one chip per context, and the
/// projects in none — one at a time. It draws [workspaceScopeProvider], the
/// same scope Quick Open switches, so the two cannot disagree. Nothing is
/// drawn while there are no contexts.
class ExplorerContextChips extends ConsumerWidget {
  const ExplorerContextChips({super.key});

  static const _newContext = 'chips:new';
  static const _manage = 'chips:manage';
  static const _scopePrefix = 'scope:';

  /// The most one chip's name may take before it is ellipsised.
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

    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.xs,
        Insets.hair,
        Insets.xs,
        Insets.xs,
      ),
      child: LayoutBuilder(
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
                _ScopeChip.widthFor(
                  (painter
                        ..text = TextSpan(text: entry.label, style: style)
                        ..layout())
                      .width,
                  scaler,
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
          final chips = Row(
            children: [
              for (final index in visible) ...[
                Flexible(
                  // The chip in force is drawn whether or not it fits, so it
                  // is the one that gives — under the narrowest panes at the
                  // largest text. Alone in flexing, it has all the spare room.
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
          );
          return Row(
            children: [
              Expanded(child: chips),
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
                      WorkspaceScope.parse(
                        value.substring(_scopePrefix.length),
                      ),
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
      ),
    );
  }

  /// Which chips fit [room], by index and in order. `All` and the [selected]
  /// chip always do — a filter in force is never folded into a menu.
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

  static const _padX = Insets.sm;

  /// What a chip whose text measures [text] takes of the row.
  static double widthFor(double text, TextScaler scaler) =>
      math.min(text, scaler.scale(ExplorerContextChips.chipMax)) +
      _padX * 2 +
      // The border, and a pixel kept back: what is drawn is not what was
      // measured to the last fraction.
      3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final scaler = MediaQuery.textScalerOf(context);
    const shape = StadiumBorder();
    final chip = Semantics(
      button: true,
      selected: selected,
      child: Tooltip(
        message: entry.workspace?.description ?? projectCountWords(entry.count),
        child: Material(
          color: selected ? StateLayers.selected(scheme) : Colors.transparent,
          shape: StadiumBorder(
            side: BorderSide(
              color: selected ? Colors.transparent : scheme.outlineVariant,
            ),
          ),
          child: InkWell(
            customBorder: shape,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: Chrome.statusBar,
                maxWidth:
                    scaler.scale(ExplorerContextChips.chipMax) + _padX * 2,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: _padX),
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    entry.label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: selected
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                      fontWeight: selected ? FontWeight.w600 : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
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

/// `…` at the row's end: every context, including the ones that did not fit,
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

  static const width = Chrome.control;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: Chrome.statusBar,
    child: PopupMenuButton<String>(
      tooltip: hidden == 0 ? 'Contexts' : 'Contexts — $hidden more',
      padding: EdgeInsets.zero,
      iconSize: Chrome.icon,
      position: PopupMenuPosition.under,
      icon: Icon(
        AppIcons.dotsThree,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onSelected: onSelected,
      itemBuilder: (_) => itemBuilder(),
    ),
  );
}
