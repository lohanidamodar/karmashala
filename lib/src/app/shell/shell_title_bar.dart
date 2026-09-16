import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/terminal/application/terminal_sessions_controller.dart';
import '../../features/terminal/presentation/terminal_panel.dart';
import 'app_shell.dart' show ShellWidth;
import 'quick_open/quick_open.dart';
import 'shell_menus.dart';
import 'shell_shortcuts.dart';
import 'shell_state.dart';
import 'side_panel_state.dart';
import 'workbench_tabs.dart';

/// The window's one chrome row: the menus, the command field and the pane
/// toggles. Built as the tab strip's row, because it is chrome, not a heading.
class ShellTitleBar extends StatelessWidget implements PreferredSizeWidget {
  const ShellTitleBar({this.height = Chrome.titleBar, super.key});

  /// The row's height — [Chrome.titleBar] scaled by the text size at the use
  /// site (see [Chrome.titleBarOf]).
  final double height;

  @override
  Size get preferredSize => Size.fromHeight(height);

  /// The three menu titles at 1x text: the only part of the row that grows
  /// with the text scale.
  static const _menuTitlesWidth = 272.0;

  /// Everything else in the row, which does not grow: padding, gaps, the four
  /// toggles, room for both session badges, and the terminal toolbar in its
  /// compact (+ and caret) or full width.
  static const _glyphsWidth = 204.0;
  static const _compactToolbarWidth = 52.0;
  static const _fullToolbarWidth = 156.0;

  /// Whether a row [width] wide has to fold the menus behind one glyph.
  static bool foldsMenus(
    double width,
    TextScaler textScaler, {
    required bool compactToolbar,
  }) =>
      width <
      WidthClass.scaleBreakpoint(_menuTitlesWidth, textScaler) +
          _glyphsWidth +
          (compactToolbar ? _compactToolbarWidth : _fullToolbarWidth);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textScaler = MediaQuery.textScalerOf(context);
    // No app icon or name: the OS title bar already carries those.
    return Material(
      color: scheme.surfaceContainerLow,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
        ),
        // Its own width, not the window's: the row is what has to fit.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compactToolbar = ShellWidth.of(
              constraints.maxWidth,
            ).isCompact;
            final folded = foldsMenus(
              constraints.maxWidth,
              textScaler,
              compactToolbar: compactToolbar,
            );
            return Row(
              children: [
                const _ExplorerToggle(),
                const SizedBox(width: Insets.xs),
                folded ? const ShellOverflowMenu() : const ShellMenuBar(),
                const SizedBox(width: Insets.sm),
                // Expanded, not Flexible-then-Spacer: the field takes its own
                // width and the toggles are pushed to the far edge by the rest.
                const Expanded(child: _QuickOpenSlot()),
                // The terminal's own verbs, on the pane the keyboard is in. Not
                // per group: seven in every strip made a split narrower than
                // its bar.
                TerminalToolbar(compact: compactToolbar),
                const _RestoredSessionsBadge(),
                const _BackgroundSessionsBadge(),
                const _FocusModeToggle(),
                const _SidePanelToggle(),
                const _SettingsToggle(),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The command field, or nothing once the row leaves it no room.
class _QuickOpenSlot extends StatelessWidget {
  const _QuickOpenSlot();

  /// Below its own leading glyph there is nothing to draw. The field is a
  /// convenience — `Ctrl+K` is the same.
  static const _minWidth = 64.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => constraints.maxWidth < _minWidth
        ? const SizedBox.shrink()
        : const Align(
            alignment: Alignment.centerLeft,
            child: QuickOpenButton(),
          ),
  );
}

class _ExplorerToggle extends ConsumerWidget {
  const _ExplorerToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) => _ChromeToggle(
    icon: AppIcons.treeStructure,
    label: 'Show or hide the Explorer',
    chord: shellChordLabel<ToggleExplorerPaneIntent>(),
    note: 'Ctrl+B does it too, outside a terminal pane',
    selected: ref.watch(
      shellControllerProvider.select((s) => s.explorerPaneVisible),
    ),
    onPressed: () =>
        ref.read(shellControllerProvider.notifier).toggleExplorerPane(),
  );
}

class _FocusModeToggle extends ConsumerWidget {
  const _FocusModeToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) => _ChromeToggle(
    icon: AppIcons.arrowsOutSimple,
    label: 'Focus mode',
    chord: shellChordLabel<ToggleFocusModeIntent>(),
    note: 'Hides the Explorer and the side panel',
    selected: ref.watch(terminalMaximizedProvider),
    onPressed: () => ref.read(terminalMaximizedProvider.notifier).toggle(),
  );
}

class _SidePanelToggle extends ConsumerWidget {
  const _SidePanelToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) => _ChromeToggle(
    icon: AppIcons.sidebarSimple,
    label: 'Show or hide the side panel',
    chord: shellChordLabel<ToggleSidePanelIntent>(),
    selected: ref.watch(sidePanelProvider.select((panel) => panel != null)),
    onPressed: () => ref.read(sidePanelProvider.notifier).toggle(),
  );
}

class _SettingsToggle extends ConsumerWidget {
  const _SettingsToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) => _ChromeToggle(
    icon: AppIcons.gearSix,
    label: 'Settings',
    onPressed: () => openSettingsTab(ref),
  );
}

/// Sessions a restart left dormant. About the **window**, so no group's strip
/// can show it.
class _RestoredSessionsBadge extends ConsumerWidget {
  const _RestoredSessionsBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final restored = ref.watch(
      restoredAgentPanesProvider.select((panes) => panes.length),
    );
    if (restored == 0) return const SizedBox.shrink();
    return _CountBadgeButton(
      count: restored,
      tooltip:
          '$restored restored session'
          '${restored == 1 ? '' : 's'} — nothing running in '
          '${restored == 1 ? 'it' : 'them'}',
      // Not the history clock the Commands button uses: two identical icons in
      // one row are one icon as far as the eye is concerned.
      icon: AppIcons.playCircle,
      onPressed: () => TerminalActions(ref).showRestoredSessions(context),
    );
  }
}

/// Sessions kept alive with no tab.
class _BackgroundSessionsBadge extends ConsumerWidget {
  const _BackgroundSessionsBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final background = ref.watch(
      terminalSessionsControllerProvider.select((s) => s.detached.length),
    );
    if (background == 0) return const SizedBox.shrink();
    return _CountBadgeButton(
      count: background,
      tooltip:
          '$background session'
          '${background == 1 ? '' : 's'} running in the background',
      icon: AppIcons.terminalWindow,
      onPressed: () => TerminalActions(ref).showBackgroundSessions(context),
    );
  }
}

/// An icon with a count on it. The accent, not Material's error red: what it
/// counts is the app working as designed, not a fault.
class _CountBadgeButton extends StatelessWidget {
  const _CountBadgeButton({
    required this.count,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final int count;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      icon: Badge.count(
        count: count,
        backgroundColor: scheme.primary,
        textColor: scheme.onPrimary,
        child: Icon(icon, size: Chrome.icon),
      ),
      onPressed: onPressed,
    );
  }
}

/// A title-bar glyph, drawn like a rail button so the two places in the chrome
/// where an icon means "show me this" look like one control.
class _ChromeToggle extends StatelessWidget {
  const _ChromeToggle({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.chord,
    this.note,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final String? chord;
  final String? note;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: [
        [label, ?chord].join('  ·  '),
        ?note,
      ].join('\n'),
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.sm),
          onTap: onPressed,
          child: Container(
            width: Chrome.control,
            height: Chrome.control,
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Icon(
              icon,
              size: Chrome.icon,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
