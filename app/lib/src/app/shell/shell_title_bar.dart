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
import '../../features/pipelines/presentation/pipeline_run_dialog.dart';
import 'native_menus.dart';
import 'quick_open/quick_open.dart';
import 'shell_menus.dart';
import 'shell_shortcuts.dart';
import 'side_panel_state.dart';

/// **The title bar** (UI overhaul spec §4, board A2): one menu glyph for
/// Workspace / View / Tools, the quick panel field, each account's usage, then
/// New and the window's toggles. No mark or name of its own: the window's
/// title bar above it already says Karmashala on every platform (owner,
/// 2026-09-29). The terminal's own verbs moved to View ▸ Terminal and their
/// chords. Under 600 px the phone shell draws its own top bar instead.
class ShellTitleBar extends StatelessWidget implements PreferredSizeWidget {
  const ShellTitleBar({this.height = Chrome.titleBar, super.key});

  /// The row's height — [Chrome.titleBar] scaled by the text size at the use
  /// site (see [Chrome.titleBarOf]).
  final double height;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final tones = SurfaceTones.of(context);
    return Material(
      color: tones.strip,
      child: Container(
        height: height,
        // Board A2 insets the mark further than the window's controls at the
        // other end.
        padding: EdgeInsetsDirectional.only(
          start: useNativeMenus ? Insets.xs : Insets.md,
          end: Insets.xs,
        ),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tones.line)),
        ),
        // Its own width, not the window's: the row is what has to fit. Not a
        // menu: nothing measures this row by intrinsics.
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Board A2 without its mark and name: the menus behind one glyph,
            // the field, then the accounts' usage at the right. On macOS the
            // menus live in the system menu bar (NativeShellMenus) and the
            // traffic lights keep the corner, so neither is drawn here.
            return Row(
              children: [
                if (!useNativeMenus) ...[
                  const ShellMenuButton(),
                  const SizedBox(width: Insets.sm),
                ],
                const Expanded(child: _QuickOpenSlot()),
                const _BarDivider(),
                const _NewButton(key: ValueKey('title-bar-new')),
                const _RestoredSessionsBadge(),
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
          DesktopMenuItem(
            value: #pipeline,
            label: 'Run pipeline…',
            icon: AppIcons.treeStructure,
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
          case #pipeline:
            await showRunPipeline(anchor);
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
