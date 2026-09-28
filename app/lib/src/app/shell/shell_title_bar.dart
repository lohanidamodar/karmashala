import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/agents/presentation/toolbar_usage_strip.dart';
import '../../features/projects/presentation/new_project_dialog.dart';
import '../../features/sessions/presentation/new_session_dialog.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import '../../features/terminal/presentation/terminal_panel.dart';
import 'app_shell.dart' show ShellWidth;
import 'native_menus.dart';
import 'shell_compact_bar.dart';
import 'quick_open/quick_open.dart';
import 'shell_menus.dart';
import 'shell_shortcuts.dart';
import 'side_panel_state.dart';

/// **The title bar** (UI overhaul spec §4): the menus, the quick panel field
/// in the middle, each account's usage, then New and the window's toggles.
/// The terminal's own verbs moved to View ▸ Terminal and their chords.
/// Under 600 px (§5, Compact) the menus are one glyph, the strip another, and
/// a tab switcher stands where the field and the usage were.
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

  /// Everything else in the row, which does not grow: padding, gaps, New, the
  /// two toggles and room for both session badges.
  static const _glyphsWidth = 204.0;
  static const _compactToolbarWidth = 52.0;
  static const _fullToolbarWidth = 52.0;

  /// Whether a row [width] wide has to fold the menus behind one glyph.
  static bool foldsMenus(
    double width,
    TextScaler textScaler, {
    required bool compactToolbar,
  }) =>
      width <
      (useNativeMenus
              ? 0
              : WidthClass.scaleBreakpoint(_menuTitlesWidth, textScaler)) +
          _glyphsWidth +
          (compactToolbar ? _compactToolbarWidth : _fullToolbarWidth);

  @override
  Widget build(BuildContext context) {
    final tones = SurfaceTones.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    // No app icon or name: the OS title bar already carries those.
    return Material(
      color: tones.strip,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tones.line)),
        ),
        // Its own width, not the window's: the row is what has to fit.
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The window's class, not the row's: the row is a few pixels
            // narrower, and the bar must agree with the body below it about
            // whether the strip is still there.
            final compactToolbar = ShellWidth.of(
              MediaQuery.sizeOf(context).width,
            ).isCompact;
            final folded = foldsMenus(
              constraints.maxWidth,
              textScaler,
              compactToolbar: compactToolbar,
            );
            // One column under 600 (spec §5): the strip is gone, so its
            // glyphs fold in beside the menu glyph, and the tab switcher
            // takes the quick panel's place — usage too, which has no room.
            if (compactToolbar) {
              return Row(
                children: [
                  if (!useNativeMenus) const ShellOverflowMenu(),
                  const ShellAreasMenuButton(),
                  const SizedBox(width: Insets.xs),
                  const Expanded(child: ShellTabSwitcher()),
                  const _BarDivider(),
                  const _NewButton(key: ValueKey('title-bar-new')),
                  const _RestoredSessionsBadge(),
                  const _BackgroundSessionsBadge(),
                  const _FocusModeToggle(),
                  const _SidePanelToggle(),
                ],
              );
            }
            // The strip carries the areas and Settings now (UI overhaul spec
            // §4); the menus stay while the row has room for their titles.
            return Row(
              children: [
                // In the system menu bar on macOS (NativeShellMenus).
                if (!useNativeMenus) ...[
                  folded ? const ShellOverflowMenu() : const ShellMenuBar(),
                  const SizedBox(width: Insets.sm),
                ],
                // The field in the middle, the accounts' usage at the right.
                const Expanded(child: _QuickOpenSlot()),
                const _BarDivider(),
                const _NewButton(key: ValueKey('title-bar-new')),
                const _RestoredSessionsBadge(),
                const _BackgroundSessionsBadge(),
                const _FocusModeToggle(),
                const _SidePanelToggle(),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The command field in the middle of the row, then every agent account's
/// usage at its right — or only the field once the row leaves no room.
class _QuickOpenSlot extends StatelessWidget {
  const _QuickOpenSlot();

  /// Below its own leading glyph there is nothing to draw. The field is a
  /// convenience — `Ctrl+K` is the same.
  static const _minWidth = 64.0;

  /// The field's own cap; it keeps that much first.
  static const _fieldWidth = 440.0;

  /// The most the account chips take; the rest centres the field.
  static const _usageWidth = 4 * kToolbarUsageChipWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      if (width < _minWidth) return const SizedBox.shrink();
      final field = width < _fieldWidth ? width : _fieldWidth;
      final left = width - field - Insets.sm;
      final usage = left < _usageWidth ? left : _usageWidth;
      return Row(
        children: [
          Expanded(
            child: Align(
              child: SizedBox(width: field, child: const QuickOpenButton()),
            ),
          ),
          // Usage is per account, not per session, so it lives here rather
          // than under a pane.
          if (usage > 0) ...[
            const SizedBox(width: Insets.sm),
            SizedBox(width: usage, child: const ToolbarUsageStrip()),
          ],
        ],
      );
    },
  );
}

class _FocusModeToggle extends ConsumerWidget {
  const _FocusModeToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) => _ChromeToggle(
    icon: AppIcons.arrowsOutSimple,
    label: 'Zen',
    chord: shellChordLabel<ToggleFocusModeIntent>(),
    note: 'Only the pane',
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
    note: ref.watch(sidePanelRoomProvider) ? null : kSidePanelNoRoom,
    selected: ref.watch(
      visibleSidePanelProvider.select((panel) => panel != null),
    ),
    onPressed: () => ref.read(sidePanelProvider.notifier).toggle(),
  );
}

/// A hairline between the usage and the window's own controls.
class _BarDivider extends StatelessWidget {
  const _BarDivider();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: Chrome.iconAction,
    margin: const EdgeInsets.symmetric(horizontal: Insets.sm),
    color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(
      alpha: 0.3,
    ),
  );
}

/// **New**: one + for everything the window can make — a session, a terminal
/// (with any profile), a project. Each keeps its own chord.
class _NewButton extends ConsumerWidget {
  const _NewButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Builder(
    builder: (anchor) => _ChromeToggle(
      icon: AppIcons.plus,
      label: 'New session, terminal or project',
      onPressed: () async {
        final actions = TerminalActions(ref);
        final profiles = actions.profiles();
        final picked = await showDesktopMenuUnder<Object>(anchor, [
          DesktopMenuItem(
            value: #session,
            label: 'New session',
            icon: AppIcons.chatCircleDots,
            shortcut: shellChordLabel<NewSessionIntent>(),
          ),
          DesktopMenuItem(
            value: #terminal,
            label: 'New terminal',
            icon: AppIcons.terminal,
            shortcut: shellChordLabel<NewTerminalTabIntent>(),
          ),
          if (profiles.length > 1) ...[
            const DesktopMenuDivider(),
            for (final profile in profiles)
              DesktopMenuItem(
                value: profile,
                label: profile.label,
                icon: AppIcons.terminalWindow,
              ),
          ],
          const DesktopMenuDivider(),
          DesktopMenuItem(
            value: #project,
            label: 'New project',
            icon: AppIcons.folderPlus,
            shortcut: shellChordLabel<NewProjectIntent>(),
          ),
        ]);
        if (!anchor.mounted) return;
        switch (picked) {
          case #session:
            await NewSessionDialog.show(anchor);
          case #terminal:
            actions.open(actions.defaultProfile());
          case #project:
            await NewProjectDialog.show(anchor);
          case final TerminalProfile profile:
            actions.open(profile);
        }
      },
    ),
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

/// A title-bar glyph, drawn like an activity-strip button so the two places in
/// the chrome where an icon means "show me this" look like one control.
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
                  ? StateLayers.selected(scheme)
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
