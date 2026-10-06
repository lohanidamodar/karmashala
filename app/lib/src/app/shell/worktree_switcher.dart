import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import 'package:karmashala_git/repositories.dart';

import '../../features/explorer/application/checkout_picker.dart';
import '../../features/explorer/application/project_head.dart';
import '../../features/explorer/application/worktree_choices.dart';
import '../../features/settings/presentation/settings_catalog.dart'
    show SettingsAnchor;
import 'workbench_tabs.dart' show openSettingsTab;

/// The tallest the switcher's list grows before it scrolls.
const double kWorktreeSwitcherListMaxHeight = 320;

/// The popover's width, window permitting.
const double _panelWidth = 340;

/// The context line's `/ <branch> ▾`: which worktree the checkout-scoped
/// surfaces describe, and the one control that moves them — however many
/// worktrees there are.
class WorktreeSwitcherButton extends ConsumerStatefulWidget {
  const WorktreeSwitcherButton({super.key});

  @override
  ConsumerState<WorktreeSwitcherButton> createState() =>
      _WorktreeSwitcherButtonState();
}

class _WorktreeSwitcherButtonState
    extends ConsumerState<WorktreeSwitcherButton> {
  final _portal = OverlayPortalController();

  void _close() {
    if (_portal.isShowing) _portal.hide();
  }

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(selectedCheckoutProvider);
    if (selected == null) return const SizedBox.shrink();
    // Named from its `HEAD` file: showing the line starts no git process,
    // and only the open list asks `git worktree list`.
    final branch = ref
        .watch(checkoutHeadBranchProvider(Checkout(selected.path)))
        .value;
    if (branch == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return TapRegion(
      groupId: this,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _positioned,
        child: Tooltip(
          message: '${selected.path.path}\nSwitch worktree',
          child: InkWell(
            key: const ValueKey('worktree-switcher'),
            onTap: _portal.toggle,
            borderRadius: BorderRadius.circular(Radii.sm),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('/', style: muted),
                  const SizedBox(width: Insets.xs),
                  Icon(
                    AppIcons.gitBranch,
                    size: Chrome.iconSmall,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Insets.xs / 2),
                  Flexible(
                    child: Text(
                      branch,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                  const SizedBox(width: Insets.xs / 2),
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
      ),
    );
  }

  /// Under the button, kept inside the window at any width.
  Widget _positioned(BuildContext overlayContext) {
    final box = context.findRenderObject() as RenderBox?;
    final screen = MediaQuery.sizeOf(overlayContext);
    final width = (screen.width - 2 * Insets.sm).clamp(0.0, _panelWidth);
    var left = Insets.sm;
    var top = 0.0;
    if (box != null && box.hasSize) {
      final at = box.localToGlobal(Offset.zero);
      left = at.dx.clamp(Insets.sm, screen.width - width - Insets.sm);
      top = at.dy + box.size.height;
    }
    return Positioned(
      left: left,
      top: top,
      width: width,
      child: TapRegion(
        groupId: this,
        onTapOutside: (_) => _close(),
        child: WorktreeSwitcherPanel(onDone: _close),
      ),
    );
  }
}

/// The open switcher: a search box, the worktrees in their order, and the
/// merged ones folded away at the bottom. Arrows move, Enter picks, Esc
/// closes, and typing searches.
class WorktreeSwitcherPanel extends ConsumerStatefulWidget {
  const WorktreeSwitcherPanel({required this.onDone, super.key});

  /// Called when the panel should close: a pick, Esc, or Clean up.
  final VoidCallback onDone;

  @override
  ConsumerState<WorktreeSwitcherPanel> createState() =>
      _WorktreeSwitcherPanelState();
}

class _WorktreeSwitcherPanelState extends ConsumerState<WorktreeSwitcherPanel> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  final _rowKeys = <String, GlobalKey>{};
  bool _mergedOpen = false;
  int _highlight = 0;
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// The rows the keyboard walks: the open ones, then the merged ones when
  /// their group is showing.
  List<WorktreeChoice> _walkable(WorktreeChoices shown) => [
    ...shown.open,
    if (_showMerged(shown)) ...shown.merged,
  ];

  bool _showMerged(WorktreeChoices shown) =>
      _mergedOpen || (_query.text.trim().isNotEmpty && shown.merged.isNotEmpty);

  Future<void> _pick(WorktreeChoice choice) async {
    final picker = ref.read(checkoutPickerProvider);
    final row = choice.repository;
    if (row != null) {
      picker.select(row);
      widget.onDone();
      return;
    }
    final projectId = ref.read(selectedCheckoutProvider)?.projectId;
    if (projectId == null) return;
    try {
      final recorded = await picker.selectWorktree(projectId, choice.path);
      if (!mounted) return;
      if (recorded == null) {
        setState(() => _error = 'A rescan did not record ${choice.label}.');
        return;
      }
      widget.onDone();
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not rescan: $error');
    }
  }

  void _move(int by, int count) {
    if (count == 0) return;
    setState(() => _highlight = (_highlight + by) % count);
    final key = _rowKeys[_keyOf(_highlight)];
    final target = key?.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        alignmentPolicy: by > 0
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    }
  }

  String _keyOf(int index) => 'row $index';

  KeyEventResult _onKey(KeyEvent event, List<WorktreeChoice> walkable) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _move(1, walkable.length);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _move(-1, walkable.length);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        widget.onDone();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    final choices = ref.watch(worktreeChoicesProvider) ?? WorktreeChoices.empty;
    final shown = choices.where(_query.text);
    final walkable = _walkable(shown);
    if (_highlight >= walkable.length) _highlight = 0;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = choices.all.length;

    var index = 0;
    Widget row(WorktreeChoice choice) {
      final at = index++;
      final key = _rowKeys.putIfAbsent(_keyOf(at), GlobalKey.new);
      return _ChoiceRow(
        key: key,
        choice: choice,
        highlighted: at == _highlight,
        onTap: () => _pick(choice),
      );
    }

    final rows = <Widget>[
      for (final choice in shown.open) row(choice),
      if (_showMerged(shown) && shown.merged.isNotEmpty) ...[
        if (shown.open.isNotEmpty) const Divider(height: Insets.sm),
        for (final choice in shown.merged) row(choice),
      ],
    ];

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) => _onKey(event, walkable),
      child: Material(
        key: const ValueKey('worktree-switcher-panel'),
        color: scheme.surfaceContainerHigh,
        elevation: Elevations.popup,
        borderRadius: BorderRadius.circular(Radii.md),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(Insets.sm),
              child: SearchField(
                controller: _query,
                autofocus: true,
                clearOnEscape: false,
                style: theme.textTheme.bodySmall,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: total == 1
                      ? 'Search 1 worktree'
                      : 'Search $total worktrees',
                  prefixIcon: Icon(AppIcons.magnifyingGlass, size: 16),
                ),
                onChanged: (_) => setState(() => _highlight = 0),
                onSubmitted: (_) {
                  if (walkable.isNotEmpty) _pick(walkable[_highlight]);
                },
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(
                maxHeight: kWorktreeSwitcherListMaxHeight,
              ),
              child: rows.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(Insets.md),
                      child: Text(
                        'No worktree matches',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView(
                      key: const ValueKey('worktree-switcher-list'),
                      controller: _scroll,
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: Insets.xs),
                      children: rows,
                    ),
            ),
            // Below the scroll, so the count is seen however long the list.
            if (shown.merged.isNotEmpty)
              _MergedHeader(
                count: shown.merged.length,
                open: _showMerged(shown),
                onToggle: () => setState(() => _mergedOpen = !_mergedOpen),
                onCleanUp: () {
                  widget.onDone();
                  openSettingsTab(ref, anchor: SettingsAnchor.worktreeSetup);
                },
              ),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.md,
                  0,
                  Insets.md,
                  Insets.sm,
                ),
                child: Text(
                  error,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One worktree: its branch, and under it the folder and whatever is already
/// known about it.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.choice,
    required this.highlighted,
    required this.onTap,
    super.key,
  });

  final WorktreeChoice choice;
  final bool highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final detail = [
      choice.folder,
      if (choice.dirtyFiles case final dirty? when dirty > 0) '$dirty changed',
      if ((choice.ahead ?? 0) > 0 || (choice.behind ?? 0) > 0)
        '↑${choice.ahead ?? 0} ↓${choice.behind ?? 0}',
      if (choice.repository == null) 'not recorded yet',
    ].join('  ·  ');
    return Tooltip(
      message: choice.path.path,
      waitDuration: const Duration(milliseconds: 600),
      child: Material(
        color: highlighted
            ? StateLayers.selectedFocused(scheme)
            : choice.current
            ? StateLayers.selected(scheme)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.md,
              vertical: Insets.xs,
            ),
            child: Row(
              children: [
                Icon(
                  choice.current ? AppIcons.check : AppIcons.gitBranch,
                  size: Chrome.iconSmall,
                  color: choice.current
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        choice.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: choice.current ? FontWeight.w600 : null,
                        ),
                      ),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (choice.sessions > 0) ...[
                  const SizedBox(width: Insets.sm),
                  Text(
                    choice.sessions == 1
                        ? '1 session'
                        : '${choice.sessions} sessions',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: choice.active
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Merged (N)", folded by default, with the way to the cleanup that removes
/// them.
class _MergedHeader extends StatelessWidget {
  const _MergedHeader({
    required this.count,
    required this.open,
    required this.onToggle,
    required this.onCleanUp,
  });

  final int count;
  final bool open;
  final VoidCallback onToggle;
  final VoidCallback onCleanUp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              key: const ValueKey('worktree-switcher-merged'),
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.md,
                  vertical: Insets.xs,
                ),
                child: Row(
                  children: [
                    Icon(
                      open ? AppIcons.caretDown : AppIcons.caretRight,
                      size: Chrome.iconSmall,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: Insets.xs),
                    Flexible(
                      child: Text(
                        'Merged ($count)',
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          TextButton(onPressed: onCleanUp, child: const Text('Clean up…')),
          const SizedBox(width: Insets.xs),
        ],
      ),
    );
  }
}
