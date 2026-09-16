import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';

import '../../features/explorer/application/checkout.dart';
import '../../features/explorer/application/checkout_picker.dart';
import '../../features/projects/application/project_providers.dart';
import '../../features/projects/application/projects_controller.dart';
import 'package:karmashala_git/repositories.dart';

/// Asks for a rescan of the project's folder from the picker.
class _RescanChoice {
  const _RescanChoice();
}

/// Which checkout the panel is describing, and the picker that moves it. The
/// menu is offered even for a single checkout, for the **Rescan** under it.
class SidePanelContextLine extends ConsumerStatefulWidget {
  const SidePanelContextLine({super.key});

  @override
  ConsumerState<SidePanelContextLine> createState() =>
      _SidePanelContextLineState();
}

class _SidePanelContextLineState extends ConsumerState<SidePanelContextLine> {
  /// What the last rescan said, shown until the picker is opened again.
  String? _rescanResult;
  bool _rescanning = false;

  Future<void> _rescan(String projectId) async {
    if (_rescanning) return;
    setState(() => _rescanning = true);
    try {
      final added = await ref
          .read(projectsControllerProvider.notifier)
          .rediscover(projectId);
      if (!mounted) return;
      setState(() {
        _rescanResult = added.isEmpty
            ? 'No new checkouts found'
            : 'Found ${added.length} '
                  'checkout${added.length == 1 ? '' : 's'}';
      });
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _rescanResult = error is StateError
            ? error.message
            : 'Could not rescan: $error',
      );
    } finally {
      if (mounted) setState(() => _rescanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(selectedCheckoutProvider);
    if (repository == null) return const SizedBox.shrink();
    final checkouts = ref.watch(projectCheckoutsProvider);
    final project = ref.read(projectDaoProvider).getById(repository.projectId);
    final within = project == null
        ? null
        : relativeSubPath(project.root, repository.path);

    final line = _ContextLineBody(
      repository: repository,
      within: within,
      pickable: true,
    );
    return PopupMenuButton<Object>(
      tooltip:
          '${repository.path.path}\n'
          'Switch to another checkout in this project, or rescan for new ones',
      position: PopupMenuPosition.under,
      padding: EdgeInsets.zero,
      // The last result belongs to the last rescan, and is kept until the menu
      // is opened again, or the word Rescan is never seen twice.
      onOpened: () {
        if (_rescanResult != null) setState(() => _rescanResult = null);
      },
      onSelected: (picked) => switch (picked) {
        final Repository checkout => ref
            .read(checkoutPickerProvider)
            .select(checkout),
        _ => _rescan(repository.projectId),
      },
      itemBuilder: (context) => [
        for (final checkout in checkouts)
          DesktopMenuDetailItem<Object>.live(
            value: checkout,
            child: _CheckoutMenuRow(
              repository: checkout,
              within: project == null
                  ? null
                  : relativeSubPath(project.root, checkout.path),
              selected: checkout.id == repository.id,
            ),
          ),
        const DesktopMenuDivider(),
        // Says what it is for, because the reason to reach for it is a checkout
        // that is missing rather than one that is wrong.
        DesktopMenuItem<Object>(
          value: const _RescanChoice(),
          enabled: !_rescanning,
          label: _rescanResult ?? 'Rescan for checkouts',
          icon: AppIcons.arrowsClockwise,
        ),
      ],
      child: line,
    );
  }
}

/// The status-bar-high strip. Identical whether or not it is a button.
class _ContextLineBody extends StatelessWidget {
  const _ContextLineBody({
    required this.repository,
    required this.within,
    required this.pickable,
  });

  final Repository repository;
  final String? within;
  final bool pickable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      height: Chrome.statusBarOf(context),
      padding: const EdgeInsets.symmetric(horizontal: Insets.md),
      color: scheme.surfaceContainerLowest,
      child: Row(
        children: [
          Icon(
            AppIcons.bookBookmark,
            size: Chrome.iconSmall,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: Insets.sm),
          Flexible(
            child: Text(
              repository.name,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            ),
          ),
          if (within != null) ...[
            const SizedBox(width: Insets.sm),
            // The sub-path, not just the name: two clones can share a name.
            Flexible(
              flex: 2,
              child: Text(
                within!,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          if (pickable) ...[
            const SizedBox(width: Insets.xs / 2),
            Icon(
              AppIcons.caretDown,
              size: Chrome.iconSmall,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ],
      ),
    );
  }
}

/// One checkout in the open picker. The second line is what stops `wt-relay`
/// and the clone it was cut from reading as two folder names.
class _CheckoutMenuRow extends ConsumerWidget {
  const _CheckoutMenuRow({
    required this.repository,
    required this.within,
    required this.selected,
  });

  final Repository repository;
  final String? within;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = ref
        .watch(checkoutLabelsProvider(repository.projectId))
        .asData
        ?.value[repository.id];
    final branch = label?.branch;
    return DesktopMenuDetailRow(
      label: repository.name,
      detail: [
        if (label?.isWorktree ?? false) 'worktree',
        ?branch,
        within ?? 'project root',
      ].join('  ·  '),
      detailMaxLines: 1,
      icon: AppIcons.bookBookmark,
      selected: selected,
    );
  }
}

/// Level two of the picker: the worktrees of this checkout. One the workspace
/// has never recorded is listed but is not a destination; Rescan changes that.
class SidePanelWorktrees extends ConsumerWidget {
  const SidePanelWorktrees({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final worktrees =
        ref.watch(selectedCheckoutWorktreesProvider).value ?? const [];
    if (worktrees.isEmpty) return const SizedBox.shrink();

    final selected = ref.watch(selectedCheckoutProvider);
    final rows = {
      for (final checkout in ref.watch(projectCheckoutRowsProvider))
        Checkout(checkout.path): checkout,
    };
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      color: scheme.surfaceContainerLowest,
      padding: const EdgeInsets.fromLTRB(Insets.md, 0, Insets.sm, Insets.xs),
      child: Wrap(
        spacing: Insets.xs,
        runSpacing: Insets.xs,
        children: [
          for (final worktree in worktrees)
            _WorktreeChip(
              label: worktree.branch ?? p.basename(worktree.path.path),
              path: worktree.path.path,
              selected: rows[Checkout(worktree.path)]?.id == selected?.id,
              onTap: switch (rows[Checkout(worktree.path)]) {
                final Repository row => () =>
                    ref.read(checkoutPickerProvider).select(row),
                _ => null,
              },
            ),
        ],
      ),
    );
  }
}

/// One worktree. Unselectable when the workspace has no row for it, and it says
/// so rather than looking broken.
class _WorktreeChip extends StatelessWidget {
  const _WorktreeChip({
    required this.label,
    required this.path,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String path;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colour = selected
        ? scheme.primary
        : onTap == null
        ? scheme.onSurfaceVariant.withValues(alpha: 0.6)
        : scheme.onSurfaceVariant;
    return Tooltip(
      message: onTap == null
          ? '$path\nNot in this workspace yet — rescan to add it'
          : path,
      child: Material(
        color: selected
            ? StateLayers.selected(scheme)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.sm),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.sm,
              vertical: Insets.xs / 2,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(AppIcons.gitBranch, size: Chrome.iconSmall, color: colour),
                const SizedBox(width: Insets.xs),
                // The tooltip carries the full path, so a long branch can end.
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(color: colour),
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
