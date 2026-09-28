import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/explorer/application/agent_state_providers.dart';
import '../../features/notifications/application/attention_inbox.dart';
import '../../features/sessions/application/session_status_providers.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import 'activity_strip.dart';
import 'devices_dock.dart';
import 'shell_area.dart';
import 'shell_shortcuts.dart';
import 'shell_state.dart';
import 'tab_picker.dart';
import 'workbench.dart' show terminalTabEntries;
import 'workbench_tabs.dart';

/// The compact top bar's square buttons (board N4's 34px `.act`), and the
/// corner they share with the activity strip's glyphs.
const double kCompactButton = 34;
const double kCompactButtonRadius = 9;

/// The session switcher field's height and corner (board N4).
const double _switcherHeight = 32;
const double _switcherRadius = 7;

/// **The strip as a menu** (UI overhaul spec §5, Compact): under 600 px the
/// activity strip's column is worth more as workbench, so its glyphs — the
/// areas, Usage, Settings — fold into one title-bar glyph. An area picked here
/// opens full width over the workbench, as a strip press does wider.
class ShellAreasMenuButton extends ConsumerWidget {
  const ShellAreasMenuButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final attention = SemanticColors.of(context).attention;
    final badges = {
      ShellArea.sessions: ref.watch(needsYouCountProvider),
      ShellArea.devices: ref.watch(readyDeviceCountProvider),
      ShellArea.inbox: ref.watch(attentionCountProvider),
    };
    // Only what waits on the user marks the glyph, as on the strip: a
    // connected device is not a reason to open the menu.
    final waiting =
        (badges[ShellArea.sessions] ?? 0) + (badges[ShellArea.inbox] ?? 0);
    final open = ref.watch(
      shellControllerProvider.select((s) => s.explorerPaneVisible),
    );
    final area = ref.watch(shellAreaProvider);
    return Builder(
      builder: (anchor) => Tooltip(
        message: waiting == 0 ? 'Areas' : 'Areas  ·  $waiting need you',
        child: Semantics(
          button: true,
          label: waiting == 0 ? 'Areas' : 'Areas, $waiting need you',
          excludeSemantics: true,
          child: InkWell(
            borderRadius: BorderRadius.circular(kCompactButtonRadius),
            onTap: () => _open(anchor, ref, badges, open ? area : null),
            child: SizedBox(
              width: kCompactButton,
              height: kCompactButton,
              child: Badge(
                isLabelVisible: waiting > 0,
                smallSize: Chrome.dot,
                backgroundColor: attention,
                alignment: AlignmentDirectional.topEnd,
                child: Center(
                  child: Icon(
                    open ? ActivityStrip.iconFor(area) : AppIcons.list,
                    size: Chrome.icon,
                    color: open ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open(
    BuildContext anchor,
    WidgetRef ref,
    Map<ShellArea, int> badges,
    ShellArea? showing,
  ) async {
    final picked = await showDesktopMenuUnder<Object>(anchor, [
      // With an area covering the workbench, the way back is the first row:
      // at this width there is no workbench edge left to click.
      if (showing != null) ...[
        DesktopMenuItem(
          value: #workbench,
          label: 'Back to the workbench',
          icon: AppIcons.terminal,
        ),
        const DesktopMenuDivider(),
      ],
      for (final area in ShellArea.values)
        DesktopMenuItem(
          value: area,
          label: switch (badges[area] ?? 0) {
            0 => area.label,
            final count => '${area.label}  ·  $count',
          },
          icon: ActivityStrip.iconFor(area),
          selected: area == showing,
          shortcut: shellChordLabel<ShowShellAreaIntent>(
            where: (intent) => intent.area == area,
          ),
        ),
      const DesktopMenuDivider(),
      DesktopMenuItem(
        value: #usage,
        label: 'Usage',
        icon: AppIcons.chartBar,
        shortcut: shellChordLabel<OpenUsageIntent>(),
      ),
      DesktopMenuItem(
        value: #settings,
        label: 'Settings',
        icon: AppIcons.gearSix,
        shortcut: shellChordLabel<OpenSettingsIntent>(),
      ),
    ]);
    if (!anchor.mounted) return;
    switch (picked) {
      case final ShellArea area:
        // A menu row never hides: picking the area on show leaves it up.
        showShellArea(ref, area);
      case #workbench:
        ref.read(shellControllerProvider.notifier).focusPane(ShellPane.detail);
        if (ref.read(shellControllerProvider).explorerPaneVisible) {
          ref.read(shellControllerProvider.notifier).toggleExplorerPane();
        }
      case #usage:
        openUsageTab(ref);
      case #settings:
        openSettingsTab(ref);
    }
  }
}

/// **The session switcher** (spec §5, board N4 Compact): a field on the
/// raised tone naming the tab in front with what its agent is doing, and a
/// caret — a press picks another. `Ctrl+K` still opens the quick panel.
class ShellTabSwitcher extends ConsumerWidget {
  const ShellTabSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabId = ref.watch(
      terminalSessionsControllerProvider.select((s) => s.activeTab?.id),
    );
    final title = tabId == null
        ? 'No tab'
        : ref.watch(terminalTabTitleProvider(tabId));
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      message: 'Switch tab',
      child: Material(
        color: SurfaceTones.of(context).raised,
        borderRadius: BorderRadius.circular(_switcherRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(_switcherRadius),
          onTap: () => TabPicker.show(context, terminalTabEntries),
          child: Container(
            constraints: const BoxConstraints(minHeight: _switcherHeight),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                const ShellActiveTabGlyph(),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: UiDensity.of(context).rowTitle(theme),
                  ),
                ),
                const SizedBox(width: Insets.xs),
                Icon(
                  AppIcons.caretDown,
                  size: Chrome.iconSmall,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What the agent in the tab in front is doing — the spinner, the shield —
/// ahead of the tab's name in the session switcher and the Zen bar, followed
/// by its gap. Nothing, and no width, for a tab with no agent in it.
class ShellActiveTabGlyph extends ConsumerWidget {
  const ShellActiveTabGlyph({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Joined, so the selection compares by value: the tab's pane list is a
    // new list on every change to the controller's state.
    final panes = ref.watch(
      terminalSessionsControllerProvider.select(
        (s) => s.activeTab?.layout.panes.join('\n'),
      ),
    );
    if (panes == null || panes.isEmpty) return const SizedBox.shrink();
    final status = mostUrgentAgentActivity([
      for (final paneId in panes.split('\n'))
        ref.watch(paneAgentActivityProvider(paneId)),
    ]);
    if (status == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: Insets.sm),
      child: StatusGlyph(
        status: status,
        size: Chrome.iconSmall,
        semanticLabel: 'Agent: ${agentStatusAppearance(status).label}',
        askShield: true,
      ),
    );
  }
}

/// **The Sessions button** (board N4 Compact): the Sessions list as a sheet,
/// with how many sessions need you on an amber badge — the count the strip's
/// Sessions glyph carries at wider sizes.
class ShellSessionsButton extends ConsumerWidget {
  const ShellSessionsButton({super.key});

  /// The board's badge: 14px round, 9.5px bold ink.
  static const _badge = 14.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final attention = SemanticColors.of(context).attention;
    final count = ref.watch(needsYouCountProvider);
    final showing =
        ref.watch(
          shellControllerProvider.select((s) => s.explorerPaneVisible),
        ) &&
        ref.watch(shellAreaProvider) == ShellArea.sessions;
    final label = count == 0 ? 'Sessions' : 'Sessions, $count need you';
    return Tooltip(
      message: count == 0 ? 'Sessions' : 'Sessions  ·  $count need you',
      child: Semantics(
        button: true,
        selected: showing,
        label: label,
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(kCompactButtonRadius),
          onTap: () => toggleShellArea(ref, ShellArea.sessions),
          child: SizedBox(
            width: kCompactButton,
            height: kCompactButton,
            child: Stack(
              children: [
                Center(
                  child: Icon(
                    ActivityStrip.iconFor(ShellArea.sessions),
                    size: Chrome.icon,
                    color: showing ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
                if (count > 0)
                  PositionedDirectional(
                    end: 2,
                    top: 2,
                    child: Container(
                      constraints: const BoxConstraints(
                        minWidth: _badge,
                        minHeight: _badge,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: attention,
                        borderRadius: BorderRadius.circular(Radii.pill),
                      ),
                      child: Text(
                        '$count',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: SurfaceTones.of(context).background,
                          fontWeight: FontWeight.w700,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
