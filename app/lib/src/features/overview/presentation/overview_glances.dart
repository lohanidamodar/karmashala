import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/dashboard_glance.dart';
import '../application/overview_glance_prefs.dart';
import '../glances/dashboard_glances.dart';

/// The narrowest a glance tile is drawn at 1x text.
const double kGlanceTileMin = WidthClass.mediumMin / 2;

/// **Glances**: other pages, in brief, under Today. A row of tiles on a wide
/// board, a strip that slides sideways on a phone. Each can be folded to its
/// title, moved or hidden, and the whole area folded; this device remembers.
class OverviewGlances extends ConsumerWidget {
  const OverviewGlances({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(dashboardGlancesProvider);
    final prefs = ref.watch(glancePrefsProvider);
    final controller = ref.read(glancePrefsProvider.notifier);
    final ids = [for (final glance in all) glance.id];
    final byId = {for (final glance in all) glance.id: glance};
    final arranged = arrangedGlanceIds(ids, prefs);
    final shown = [
      for (final id in arranged)
        if (!prefs.hidden.contains(id)) byId[id]!,
    ];
    final hidden = [
      for (final id in arranged)
        if (prefs.hidden.contains(id)) byId[id]!,
    ];
    if (all.isEmpty) return const SizedBox.shrink();
    final open = !prefs.areaCollapsed;
    final header = Row(
      children: [
        Expanded(
          child: Semantics(
            button: true,
            expanded: open,
            label: open ? 'Glances, shown. Fold them' : 'Glances, folded. Show',
            excludeSemantics: true,
            child: InkWell(
              key: const ValueKey('overview-glances-fold'),
              borderRadius: BorderRadius.circular(Radii.sm),
              onTap: () => controller.setAreaCollapsed(open),
              child: Row(
                children: [
                  const Flexible(
                    child: EyebrowLabel('Glances', padding: EdgeInsets.zero),
                  ),
                  const SizedBox(width: Insets.xs),
                  Icon(
                    open ? AppIcons.caretDown : AppIcons.caretRight,
                    size: UiDensity.of(context).iconSmall,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (hidden.isNotEmpty)
          Builder(
            builder: (button) => TextButton(
              key: const ValueKey('overview-glances-hidden'),
              style: TextButton.styleFrom(
                visualDensity: UiDensity.of(context).controlDensity,
              ),
              onPressed: () async {
                final picked = await showDesktopMenuUnder<String>(button, [
                  for (final glance in hidden)
                    DesktopMenuItem(
                      key: ValueKey('overview-glance-show:${glance.id}'),
                      value: glance.id,
                      label: 'Show ${glance.title}',
                      icon: AppIcons.eye,
                    ),
                ]);
                if (picked != null) controller.setHidden(picked, false);
              },
              child: Text('${hidden.length} hidden'),
            ),
          ),
      ],
    );
    return Padding(
      key: const ValueKey('overview-glances'),
      padding: const EdgeInsets.only(top: Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          header,
          if (open && shown.isNotEmpty) ...[
            const SizedBox(height: Insets.xs),
            LayoutBuilder(
              builder: (context, box) {
                final scaler = MediaQuery.textScalerOf(context);
                final least = WidthClass.scaleBreakpoint(
                  kGlanceTileMin,
                  scaler,
                );
                Widget tile(DashboardGlance glance, int at) => GlanceTile(
                  glance: glance,
                  collapsed: prefs.collapsed.contains(glance.id),
                  canMoveBack: at > 0,
                  canMoveOn: at < shown.length - 1,
                  onMove: (by) => controller.move(glance.id, by, ids: ids),
                );
                if (box.maxWidth < WidthClass.mediumMin) {
                  final width = math.min(least, box.maxWidth * 0.85);
                  return GlanceScope(
                    compact: true,
                    child: SingleChildScrollView(
                      key: const ValueKey('overview-glances-strip'),
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final (i, glance) in shown.indexed) ...[
                            if (i > 0) const SizedBox(width: Insets.sm),
                            SizedBox(width: width, child: tile(glance, i)),
                          ],
                        ],
                      ),
                    ),
                  );
                }
                final across = math.max(
                  1,
                  math.min(
                    shown.length,
                    ((box.maxWidth + Insets.md) / (least + Insets.md)).floor(),
                  ),
                );
                return Column(
                  key: const ValueKey('overview-glances-row'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var start = 0; start < shown.length; start += across)
                      Padding(
                        padding: EdgeInsets.only(
                          top: start == 0 ? 0 : Insets.md,
                        ),
                        child: IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var i = start; i < start + across; i++) ...[
                                if (i > start) const SizedBox(width: Insets.md),
                                Expanded(
                                  child: i < shown.length
                                      ? tile(shown[i], i)
                                      : const SizedBox.shrink(),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// One glance: its title opens the page, with fold, move and hide beside it.
class GlanceTile extends ConsumerWidget {
  const GlanceTile({
    required this.glance,
    required this.collapsed,
    required this.onMove,
    this.canMoveBack = false,
    this.canMoveOn = false,
    super.key,
  });

  final DashboardGlance glance;
  final bool collapsed;
  final bool canMoveBack;
  final bool canMoveOn;
  final ValueChanged<int> onMove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final controller = ref.read(glancePrefsProvider.notifier);
    final id = glance.id;
    // A phone's strip: one row — the title, the body's one line, the menu.
    final compact = GlanceScope.compactOf(context);
    final opener = Semantics(
      button: true,
      label: 'Open ${glance.title}',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('overview-glance-open:$id'),
        onTap: () => glance.onOpen(context, ref),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: density.minRow),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.sm,
              vertical: Insets.xs,
            ),
            child: Row(
              mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
              children: [
                Icon(
                  glance.icon,
                  size: density.icon,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Insets.sm),
                Flexible(
                  child: Text(
                    glance.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(width: Insets.xs),
                  Icon(
                    AppIcons.caretRight,
                    size: density.iconSmall,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    final menu = Builder(
      builder: (button) => IconButton(
        key: ValueKey('overview-glance-menu:$id'),
        tooltip: 'Arrange ${glance.title}',
        visualDensity: UiDensity.of(context).controlDensity,
        iconSize: density.iconSmall,
        onPressed: () =>
            unawaited(_menu(button, controller, withFold: compact)),
        icon: const Icon(AppIcons.dotsThree),
      ),
    );
    final body = Builder(
      key: ValueKey('overview-glance-body:$id'),
      builder: glance.build,
    );
    return Material(
      key: ValueKey('overview-glance:$id'),
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: compact
          ? Row(
              children: [
                Flexible(child: opener),
                Expanded(child: collapsed ? const SizedBox.shrink() : body),
                menu,
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(child: opener),
                    IconButton(
                      key: ValueKey('overview-glance-fold:$id'),
                      tooltip: collapsed
                          ? 'Show ${glance.title}'
                          : 'Fold ${glance.title}',
                      visualDensity: UiDensity.of(context).controlDensity,
                      iconSize: density.iconSmall,
                      onPressed: () => controller.toggleCollapsed(id),
                      icon: Icon(
                        collapsed ? AppIcons.caretDown : AppIcons.caretUp,
                      ),
                    ),
                    menu,
                  ],
                ),
                if (!collapsed)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Insets.sm,
                      0,
                      Insets.sm,
                      Insets.sm,
                    ),
                    child: body,
                  ),
              ],
            ),
    );
  }

  Future<void> _menu(
    BuildContext button,
    GlancePrefsController prefs, {
    bool withFold = false,
  }) async {
    final picked = await showDesktopMenuUnder<String>(button, [
      if (withFold)
        DesktopMenuItem(
          key: const ValueKey('overview-glance-fold-item'),
          value: 'fold',
          label: collapsed ? 'Show ${glance.title}' : 'Fold ${glance.title}',
          icon: collapsed ? AppIcons.caretDown : AppIcons.caretUp,
        ),
      DesktopMenuItem(
        key: const ValueKey('overview-glance-move-back'),
        value: 'back',
        label: 'Move earlier',
        icon: AppIcons.caretLeft,
        enabled: canMoveBack,
      ),
      DesktopMenuItem(
        key: const ValueKey('overview-glance-move-on'),
        value: 'on',
        label: 'Move later',
        icon: AppIcons.caretRight,
        enabled: canMoveOn,
      ),
      DesktopMenuItem(
        key: const ValueKey('overview-glance-hide'),
        value: 'hide',
        label: 'Hide ${glance.title}',
        icon: AppIcons.eyeSlash,
      ),
    ]);
    switch (picked) {
      case 'fold':
        prefs.toggleCollapsed(glance.id);
      case 'back':
        onMove(-1);
      case 'on':
        onMove(1);
      case 'hide':
        prefs.setHidden(glance.id, true);
    }
  }
}

/// The line a glance draws when there is nothing to say, or it was not read.
class GlanceNote extends StatelessWidget {
  const GlanceNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    style: UiDensity.of(context).muted(Theme.of(context)),
  );
}
