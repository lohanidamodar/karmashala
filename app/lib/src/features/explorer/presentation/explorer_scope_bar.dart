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

/// **Which machine the Explorer lists.** The machine used to be the tree's top
/// level; it is a choice above the list now, so a project stands at depth zero.
/// Not drawn with one machine: there is nothing to choose between. Up to
/// [ExplorerEnvironmentStrip.most] machines are a strip of segments, one click
/// each; more than that are this menu.
class ExplorerEnvironmentSwitcher extends ConsumerWidget {
  const ExplorerEnvironmentSwitcher({super.key});

  static const _all = '';
  static const _terminal = 'terminal:';
  static const _pairPhone = 'pair-phone:';

  /// Under this a machine's button is its glyph and caret, and the name its
  /// tooltip.
  static const nameFloor = 260.0;

  /// Every machine at once, and what the button says of it where that does not
  /// fit — a whole word either way, never an ellipsised one.
  static const allLabel = 'All environments';
  static const allShortLabel = 'All';

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

    return PopupMenuButton<String>(
      tooltip: current == null
          ? 'Showing every environment'
          : 'Showing $label only',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      onSelected: (value) => run(context, ref, value, current),
      itemBuilder: (context) => [
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
      ],
      child: _SwitcherFace(
        icon: current == null ? AppIcons.stack : environmentGlyph(current.kind),
        label: label,
        shortLabel: current == null ? allShortLabel : null,
      ),
    );
  }
}

/// **The machines as pills** (spec §4, board A2) — `All · Windows · do-box` —
/// for a workspace with two or three, so a switch is one click and the choice
/// in force is always in view. A row of its own under the search field, each
/// pill as wide as its name, wrapping onto a second line rather than cutting a
/// name. Each pill's right-click carries what the menu's entry for that
/// machine did: its count, a terminal on it, pairing.
class ExplorerEnvironmentStrip extends ConsumerWidget {
  const ExplorerEnvironmentStrip({super.key});

  /// The most machines the pills hold; above it the switcher is a menu.
  static const most = 3;

  /// Between two pills (the mockup's `gap: 4px`).
  static const gap = Insets.xs;

  // The equal-share segment geometry the strip used before it was pills.
  // Nothing draws with it now; it is kept only so `explorer_scope_test.dart`
  // compiles until that test is rewritten for content-sized pills.

  /// Under this width per segment a segment was its glyph alone.
  static const labelFloor = 64.0;

  /// What a segment [share] wide left its name beside its glyph.
  static double labelRoomOf(double share) =>
      share - Insets.sm * 2 - Chrome.icon - Insets.sm;

  /// What a segment [share] wide left its name on its own.
  static double nameRoomOf(double share) => share - Insets.sm * 2;

  /// A segment's width when [count] of them shared [width].
  static double shareOf(double width, int count) =>
      (width - gap * (count - 1)) / count;

  /// The most of the row one machine's name may take before it is ellipsised.
  static const nameMax = 120.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(explorerEnvironmentScopeProvider);
    final environments = scope.environments;
    if (environments.length < 2 || environments.length > most) {
      return const SizedBox.shrink();
    }
    final total = environments.fold(0, (sum, e) => sum + e.projectCount);
    final segments = [
      _Segment(
        value: ExplorerEnvironmentSwitcher._all,
        icon: AppIcons.stack,
        label: ExplorerEnvironmentSwitcher.allShortLabel,
        name: ExplorerEnvironmentSwitcher.allLabel,
        detail: projectCountWords(total),
        selected: scope.environmentId == null,
        choice: null,
      ),
      for (final choice in environments)
        _Segment(
          value: choice.environmentId,
          icon: environmentGlyph(choice.kind),
          label: choice.label,
          name: choice.label,
          detail: ExplorerEnvironmentSwitcher.detailOf(choice),
          selected: choice.environmentId == scope.environmentId,
          choice: choice,
        ),
    ];
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [
        for (final segment in segments) _SegmentButton(segment: segment),
      ],
    );
  }
}

class _Segment {
  const _Segment({
    required this.value,
    required this.icon,
    required this.label,
    required this.name,
    required this.detail,
    required this.selected,
    required this.choice,
  });

  final String value;

  /// The machine's glyph, for its menu entry. The pill itself is words only.
  final IconData icon;

  /// On the pill.
  final String label;

  /// In full, for the tooltip, the menu and a screen reader.
  final String name;
  final String detail;
  final bool selected;

  /// Null for *All*.
  final EnvironmentChoice? choice;
}

class _SegmentButton extends ConsumerWidget {
  const _SegmentButton({required this.segment});

  final _Segment segment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final choice = segment.choice;
    final button = SidebarPill(
      label: segment.label,
      selected: segment.selected,
      // The label names the pill in full; its short word would only be read
      // out twice.
      semanticLabel: 'Environment: ${segment.name}',
      tooltip: '${segment.name} · ${segment.detail}',
      maxLabelWidth: MediaQuery.textScalerOf(
        context,
      ).scale(ExplorerEnvironmentStrip.nameMax),
      onTap: () =>
          ExplorerEnvironmentSwitcher.run(context, ref, segment.value, choice),
    );
    return ContextMenuRegion(
      itemBuilder: () => [
        DesktopMenuDetailItem(
          value: segment.value,
          label: segment.name,
          detail: segment.detail,
          icon: segment.icon,
          selected: segment.selected,
        ),
        if (choice != null)
          ...ExplorerEnvironmentSwitcher.actionsOf(ref, choice),
      ],
      onSelected: (value) =>
          ExplorerEnvironmentSwitcher.run(context, ref, value, choice),
      child: button,
    );
  }
}

class _SwitcherFace extends StatelessWidget {
  const _SwitcherFace({
    required this.icon,
    required this.label,
    this.shortLabel,
  });

  final IconData icon;
  final String label;

  /// Said in [label]'s place where that does not fit. With one the face is
  /// measured and says a whole word or none; without, a machine's name is
  /// ellipsised, and dropped under [ExplorerEnvironmentSwitcher.nameFloor].
  final String? shortLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final style = density.rowTitle(theme, strong: true);
    final short = shortLabel;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final roomy =
        (ExplorerScopeBar.widthOf(context) ?? double.infinity) >=
        ExplorerEnvironmentSwitcher.nameFloor;
    return Semantics(
      button: true,
      label: 'Environment: $label',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Chrome.control),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
          child: LayoutBuilder(
            builder: (context, constraints) {
              var text = roomy ? label : null;
              if (short != null) {
                final room =
                    constraints.maxWidth -
                    Chrome.icon -
                    density.glyphGap * 1.5 -
                    Chrome.iconSmall;
                final painter = TextPainter(
                  textDirection: direction,
                  textScaler: scaler,
                  maxLines: 1,
                );
                try {
                  text = [label, short]
                      .where(
                        (candidate) =>
                            (painter
                                  ..text = TextSpan(
                                    text: candidate,
                                    style: style,
                                  )
                                  ..layout())
                                .width <=
                            room,
                      )
                      .firstOrNull;
                } finally {
                  painter.dispose();
                }
              }
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: Chrome.icon, color: scheme.onSurfaceVariant),
                  if (text != null) ...[
                    SizedBox(width: density.glyphGap),
                    Flexible(
                      child: Text(
                        text,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: style,
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
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The rows above the list: [search], and the machine when there is more than
/// one. Two or three machines are a strip on a row of its own under the field
/// — never beside it, where the two crowded each other; four or more are a
/// menu on the left of the field's row, in what a menu's face needs.
class ExplorerScopeBar extends ConsumerWidget {
  const ExplorerScopeBar({required this.search, super.key});

  final Widget search;

  /// The most of the row the machine's name may take, as a menu.
  static const switcherShare = 0.42;

  /// The bar's width, for the switcher to decide whether its name fits.
  static double? widthOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ScopeBarWidth>()?.width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The machines, not which is chosen: a switch redraws the strip and the
    // list, and this row — with the search field in it — stays as it is.
    final environments = ref
        .watch(
          explorerEnvironmentScopeProvider.select(
            (scope) => ExplorerEnvironmentScope(scope.environments, null),
          ),
        )
        .environments;
    if (environments.length < 2) return search;
    if (environments.length > ExplorerEnvironmentStrip.most) {
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
                  padding: EdgeInsets.only(left: Insets.xs),
                  child: ExplorerEnvironmentSwitcher(),
                ),
              ),
              Expanded(child: search),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        search,
        const Padding(
          // On the rows' fill edge, as the field above is; the space above
          // is the only thing between the two.
          padding: EdgeInsets.fromLTRB(6, Sidebar.headerGap, 6, 0),
          child: ExplorerEnvironmentStrip(),
        ),
      ],
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
    // Measured in the pill's own hand, at the weight of the one in force, so
    // a click never changes which chips fit.
    final style = theme.textTheme.labelSmall?.copyWith(
      fontSize: 12,
      letterSpacing: 0,
      fontWeight: FontWeight.w500,
    );
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);

    return Padding(
      // On the rows' fill edge, under the machine pills: the same pills, the
      // same column.
      padding: const EdgeInsets.fromLTRB(6, Sidebar.headerGap, 6, 0),
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
                  dot: entry.hue != null,
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

  /// What a chip whose text measures [text] takes of the row, with its colour
  /// [dot] when it wears one.
  static double widthFor(double text, TextScaler scaler, {bool dot = false}) =>
      math.min(text, scaler.scale(ExplorerContextChips.chipMax)) +
      (dot ? Chrome.dot + SidebarPill.leadGap : 0) +
      SidebarPill.padX * 2 +
      // The border, and a pixel kept back: what is drawn is not what was
      // measured to the last fraction.
      3;

  /// A context is chosen with the same pill a machine is (board A2 `.pill`).
  @override
  Widget build(BuildContext context) {
    final hue = entry.hue;
    final chip = SidebarPill(
      label: entry.label,
      selected: selected,
      tooltip: entry.workspace?.description ?? projectCountWords(entry.count),
      maxLabelWidth: MediaQuery.textScalerOf(
        context,
      ).scale(ExplorerContextChips.chipMax),
      // The dot stays whether or not the chip is the one in force: the
      // colour is the context's, not the filter's.
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
    height: SidebarPill.height,
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
