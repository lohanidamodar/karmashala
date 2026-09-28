import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/explorer/application/agent_state_providers.dart';
import '../../features/notifications/application/attention_inbox.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import 'activity_strip.dart';
import 'devices_dock.dart';
import 'shell_area.dart';
import 'shell_shortcuts.dart';
import 'shell_state.dart';
import 'tab_picker.dart';
import 'workbench.dart' show terminalTabEntries;
import 'workbench_tabs.dart';

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
            borderRadius: BorderRadius.circular(Radii.sm),
            onTap: () => _open(anchor, ref, badges, open ? area : null),
            child: SizedBox(
              width: Chrome.control,
              height: Chrome.control,
              child: Badge(
                isLabelVisible: waiting > 0,
                smallSize: Chrome.dot,
                backgroundColor: attention,
                alignment: AlignmentDirectional.topEnd,
                child: Center(
                  child: Icon(
                    open ? ActivityStrip.iconFor(area) : AppIcons.squaresFour,
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

/// **The session switcher** (spec §5, Compact): the tab in front, named, and
/// a press to pick another — the Zen bar's switcher, in the title bar's place
/// for the quick panel. `Ctrl+K` still opens the quick panel.
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
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Switch tab',
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, Chrome.control),
          padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          foregroundColor: scheme.onSurface,
          backgroundColor: SurfaceTones.of(context).raised,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
        ),
        onPressed: () => TabPicker.show(context, terminalTabEntries),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
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
    );
  }
}
