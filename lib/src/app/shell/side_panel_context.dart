import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';

import '../../features/explorer/application/checkout.dart';
import '../../features/explorer/application/checkout_picker.dart';
import '../../features/projects/application/project_providers.dart';
import '../../features/projects/application/projects_controller.dart';
import '../../features/repositories/domain/repository.dart';

/// Asks for a rescan of the project's folder from the picker.
class _RescanChoice {
  const _RescanChoice();
}

/// Which checkout the panel is describing, and the picker that moves it.
///
/// The selection moves on its own — it follows the terminal tab — so the
/// surfaces have to name it; making that same line open the list of checkouts
/// costs no extra chrome.
///
/// **The menu is offered even when the project has one checkout**, and that is
/// the fix for the complaint made three times from the shipped app: "github
/// panel only shows popupbits/popupbits even though this session is also
/// working on the sub folder". The project had exactly one recorded checkout —
/// its own root, written the day it was added — so this line drew no caret and
/// no menu, and there was nothing to click and nothing to say why. A list of
/// one is still worth opening when the thing you actually need is the
/// **Rescan** under it.
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
      // The last result belongs to the last rescan. Kept until the menu is
      // opened again — without this the item is permanently labelled "No new
      // checkouts found" and the word Rescan is never seen twice.
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
          PopupMenuItem<Object>(
            value: checkout,
            height: 44,
            child: _CheckoutMenuRow(
              repository: checkout,
              within: project == null
                  ? null
                  : relativeSubPath(project.root, checkout.path),
              selected: checkout.id == repository.id,
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          value: const _RescanChoice(),
          enabled: !_rescanning,
          height: 36,
          child: Row(
            children: [
              const Icon(AppIcons.arrowsClockwise, size: Chrome.iconSmall),
              const SizedBox(width: Insets.sm),
              // Says what it is for, because the reason to reach for it is a
              // checkout that is missing rather than one that is wrong.
              Expanded(
                child: Text(
                  _rescanResult ?? 'Rescan for checkouts',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ],
      child: line,
    );
  }
}

/// The 22px strip. Identical whether or not it is a button.
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
      height: 22,
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
            const SizedBox(width: 2),
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
/// and the clone it was cut from reading as two folder names; its worktree and
/// branch halves arrive after the menu is drawn, so the row height is fixed.
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = ref
        .watch(checkoutLabelsProvider(repository.projectId))
        .asData
        ?.value[repository.id];
    final branch = label?.branch;
    final detail = [
      if (label?.isWorktree ?? false) 'worktree',
      ?branch,
      within ?? 'project root',
    ].join('  ·  ');

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 380),
      child: Row(
        children: [
          Icon(
            selected ? AppIcons.check : AppIcons.bookBookmark,
            size: Chrome.iconSmall,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  repository.name,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: selected ? FontWeight.w600 : null,
                    color: selected ? scheme.primary : null,
                  ),
                ),
                Text(
                  detail,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
