import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';

import 'package:karmashala_git/repositories.dart';
import '../../features/explorer/application/checkout_picker.dart';
import '../../features/explorer/application/worktree_choices.dart';
import '../../features/workspaces/data/workspace_data.dart';
import '../../features/projects/application/projects_controller.dart';
import 'worktree_switcher.dart';

/// Asks for a rescan of the project's folder from the picker.
class _RescanChoice {
  const _RescanChoice();
}

/// Which checkout the panel is describing, and the two pickers that move it:
/// `<checkout> ▾ / <worktree> ▾`. The checkout menu is offered even for a
/// single checkout, for the **Rescan** under it.
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

  /// The repository [selected] is a worktree of, for the left half while the
  /// right names the worktree. Borrowed from what git already said, never
  /// asked for here: drawing the line starts no git process.
  Repository? _ownerOf(Repository selected) {
    final labels = checkoutLabelsProvider(selected.projectId);
    if (ref.exists(labels)) {
      final label = ref.watch(labels).asData?.value[selected.id];
      final id = label?.ownerRepositoryId;
      if (label?.isWorktree == true && id != null && id != selected.id) {
        return ref.read(workspaceDataProvider).repository(id);
      }
    }
    if (ref.exists(worktreeChoicesProvider)) {
      return ref
          .watch(worktreeChoicesProvider)
          ?.all
          .where((c) => c.isMain && !c.current)
          .firstOrNull
          ?.repository;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(selectedCheckoutProvider);
    if (selected == null) return const SizedBox.shrink();
    final checkouts = ref.watch(projectCheckoutsProvider);
    final repository = _ownerOf(selected) ?? selected;
    final project = ref
        .read(workspaceDataProvider)
        .project(repository.projectId);
    final within = project == null
        ? null
        : relativeSubPath(project.root, repository.path);

    final picker = PopupMenuButton<Object>(
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
        final Repository checkout =>
          ref.read(checkoutPickerProvider).select(checkout),
        _ => _rescan(selected.projectId),
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
              selected: checkout.id == selected.id,
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
      child: _CheckoutPart(repository: repository, within: within),
    );
    return Container(
      height: Chrome.statusBarOf(context),
      padding: const EdgeInsets.symmetric(horizontal: Insets.md),
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: Row(
        children: [
          Flexible(child: picker),
          const Flexible(child: WorktreeSwitcherButton()),
        ],
      ),
    );
  }
}

/// The checkout half of the line: its name, where it sits in the project, and
/// the caret of the menu it opens.
class _CheckoutPart extends StatelessWidget {
  const _CheckoutPart({required this.repository, required this.within});

  final Repository repository;
  final String? within;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      height: Chrome.statusBarOf(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
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
          const SizedBox(width: Insets.xs / 2),
          Icon(
            AppIcons.caretDown,
            size: Chrome.iconSmall,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: Insets.xs),
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
