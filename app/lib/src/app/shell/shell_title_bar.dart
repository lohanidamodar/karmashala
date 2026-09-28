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

/// **The title bar** (UI overhaul spec §4, board A2): the `>_` mark and the
/// app's name, one menu glyph for Workspace / View / Tools, the quick panel
/// field, each account's usage, then New and the window's toggles. The
/// terminal's own verbs moved to View ▸ Terminal and their chords.
/// Under 600 px (§5, Compact) the strip is a glyph too, and a tab switcher
/// stands where the field and the usage were.
class ShellTitleBar extends StatelessWidget implements PreferredSizeWidget {
  const ShellTitleBar({this.height = Chrome.titleBar, super.key});

  /// The row's height — [Chrome.titleBar] scaled by the text size at the use
  /// site (see [Chrome.titleBarOf]).
  final double height;

  @override
  Size get preferredSize => Size.fromHeight(height);

  /// The mark, the name and the gap after them at 1x text: the only part of
  /// the row, besides the field, that grows with the text scale.
  static const _brandWidth = 112.0;

  /// Everything else in the row, which does not grow: padding, gaps, the menu
  /// glyph, New, the two toggles and room for both session badges.
  static const _glyphsWidth = 232.0;

  /// The least the quick panel field is left before the name gives way to it:
  /// a field with room for its placeholder is worth more than the name.
  static const _fieldFloor = 160.0;

  /// Whether a row [width] wide still has room for the app's name beside the
  /// mark. The mark itself always stays; only the word folds.
  static bool showsName(double width, TextScaler textScaler) =>
      width >=
      WidthClass.scaleBreakpoint(_brandWidth, textScaler) +
          _glyphsWidth +
          _fieldFloor;

  @override
  Widget build(BuildContext context) {
    final tones = SurfaceTones.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    // The window's class, not the row's: the row is a few pixels narrower,
    // and the bar must agree with the body below it about whether the strip
    // is still there.
    final compactToolbar = ShellWidth.of(
      MediaQuery.sizeOf(context).width,
    ).isCompact;
    return Material(
      color: tones.strip,
      child: Container(
        height: height,
        // Board A2 insets the mark further than the window's controls at the
        // other end; the compact bar keeps its own, tighter, edge.
        padding: EdgeInsetsDirectional.only(
          start: compactToolbar || useNativeMenus ? Insets.xs : Insets.md,
          end: Insets.xs,
        ),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tones.line)),
        ),
        // Its own width, not the window's: the row is what has to fit. Not a
        // menu: nothing measures this row by intrinsics.
        child: LayoutBuilder(
          builder: (context, constraints) {
            // One column under 600 (spec §5): the strip is gone, so its
            // glyphs fold in beside the menu glyph, and the tab switcher
            // takes the quick panel's place — usage too, which has no room.
            // Board N4: the menu, the session switcher, the Sessions list
            // with who needs you — eight apart. The window's own menus and
            // the dormant-session badges (nothing, unless there are some)
            // follow; New, Zen and the side panel keep their chords and
            // their rows in those menus.
            if (compactToolbar) {
              return Row(
                children: [
                  const SizedBox(width: Insets.xs),
                  const ShellAreasMenuButton(),
                  const SizedBox(width: Insets.sm),
                  const Expanded(child: ShellTabSwitcher()),
                  const SizedBox(width: Insets.sm),
                  const ShellSessionsButton(),
                  const _RestoredSessionsBadge(),
                  const _BackgroundSessionsBadge(),
                  // Not a second `≡`: the areas button beside it wears that.
                  if (!useNativeMenus)
                    const ShellMenuButton(
                      icon: AppIcons.dotsThreeVertical,
                      extent: kCompactButton,
                    ),
                ],
              );
            }
            // Board A2: the mark and the name, the menus behind one glyph,
            // the field, then the accounts' usage at the right. On macOS the
            // menus live in the system menu bar (NativeShellMenus) and the
            // traffic lights keep the corner, so neither is drawn here.
            return Row(
              children: [
                if (!useNativeMenus) ...[
                  _Brand(
                    showName: showsName(constraints.maxWidth, textScaler),
                  ),
                  const SizedBox(width: Insets.xs),
                  const ShellMenuButton(),
                  const SizedBox(width: Insets.sm),
                ],
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

/// **The mark and the name** (board A2): the accent `>_` glyph and
/// "Karmashala" at 13/600. The name folds away on a row too narrow for it;
/// the mark stays, so the corner never reads as empty.
class _Brand extends StatelessWidget {
  const _Brand({required this.showName});

  final bool showName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      label: 'Karmashala',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            AppIcons.terminal,
            size: Chrome.icon,
            color: theme.colorScheme.primary,
          ),
          if (showName) ...[
            const SizedBox(width: Insets.sm),
            Text(
              'Karmashala',
              maxLines: 1,
              softWrap: false,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ],
          const SizedBox(width: Insets.xs),
        ],
      ),
    );
  }
}

/// The quick panel field after the name, then every agent account's usage
/// at the row's right end (board A2) — or only the field once the row leaves
/// no room.
class _QuickOpenSlot extends StatelessWidget {
  const _QuickOpenSlot();

  /// Below its own leading glyph there is nothing to draw. The field is a
  /// convenience — `Ctrl+K` is the same.
  static const _minWidth = 64.0;

  /// The field's cap: the board's 560px.
  static const _fieldWidth = 560.0;

  /// What the field keeps before the usage chips take their room: enough for
  /// the start of its placeholder and the chord.
  static const _fieldFloor = 240.0;

  /// The most the account chips take.
  static const _usageWidth = 4 * kToolbarUsageChipWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      if (width < _minWidth) return const SizedBox.shrink();
      // The field up to its floor first, then the chips up to theirs, then
      // the field again up to its cap; whatever is left is the gap between.
      final floor = width < _fieldFloor ? width : _fieldFloor;
      final afterFloor = width - floor - Insets.sm;
      final usage = afterFloor <= 0
          ? 0.0
          : afterFloor < _usageWidth
          ? afterFloor
          : _usageWidth;
      final spare = width - floor - (usage > 0 ? usage + Insets.sm : 0);
      final grown = floor + spare;
      final field = grown < _fieldWidth ? grown : _fieldWidth;
      return Row(
        children: [
          SizedBox(width: field, child: const QuickOpenButton()),
          const Spacer(),
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

/// A hairline between the usage and the window's own controls — the board's
/// `line2`, the tone a hairline takes when it is not a region's edge.
class _BarDivider extends StatelessWidget {
  const _BarDivider();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: Chrome.iconAction,
    margin: const EdgeInsets.symmetric(horizontal: Insets.sm),
    color: SurfaceTones.of(context).floatingLine,
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
