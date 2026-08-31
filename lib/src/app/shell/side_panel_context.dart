import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';

import '../../features/explorer/application/checkout.dart';
import '../../features/explorer/application/checkout_picker.dart';
import '../../features/projects/application/project_providers.dart';
import '../../features/repositories/domain/repository.dart';

/// Which checkout the panel is describing — and, when the project holds more
/// than one, the control that moves it to another.
///
/// The repository-scoped surfaces all read one selection, and since Loop 85 that
/// selection follows the terminal tab you are in — so the panel can change under
/// you without a click. A surface that moves silently is worse than one that
/// never moved, so the checkout is named on it: the repository, and where it
/// sits inside its project, which is the whole difference between a hub and the
/// clone three folders down that the agent is actually working in.
///
/// **And the name is the picker.** A session's working directory is fixed at
/// launch while its subagents work in a nested clone and in the `wt-*` worktrees
/// beside it, so the panel answered correctly about the wrong checkout and there
/// was no way to say otherwise. Rather than add a second row of chrome, the line
/// that already names the checkout opens the list of them: everything discovery
/// found in this project, the current one marked, and picking one moves changes,
/// commit, push and GitHub with it. A project with one checkout has nothing to
/// choose, so it draws exactly what it drew before — no caret, no tap target.
class SidePanelContextLine extends ConsumerWidget {
  const SidePanelContextLine({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      pickable: checkouts.length > 1,
    );
    if (checkouts.length < 2) {
      return Tooltip(message: repository.path.path, child: line);
    }
    return PopupMenuButton<Repository>(
      tooltip:
          '${repository.path.path}\n'
          'Switch to another checkout in this project',
      position: PopupMenuPosition.under,
      padding: EdgeInsets.zero,
      onSelected: (picked) =>
          ref.read(checkoutPickerProvider).select(picked),
      itemBuilder: (context) => [
        for (final checkout in checkouts)
          PopupMenuItem<Repository>(
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
      ],
      child: line,
    );
  }
}

/// The 22px strip itself. Identical whether or not it is a button, so a project
/// with one checkout is pixel-for-pixel what it was.
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
            // The sub-path, not just the name: two clones can share a name,
            // and "which one of these is it" is exactly the question a hub
            // project makes hard to answer.
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

/// One checkout in the open picker.
///
/// The second line is what stops `wt-relay` and the clone it was cut from
/// reading as two folder names: it says **worktree** where git says so, and the
/// branch, which is the only thing that tells fifteen sibling worktrees apart.
/// Those two facts cost a `git worktree list` per repository family and so
/// arrive after the menu is drawn; the sub-path is in the table already and is
/// there from the first frame, which is why the row never changes height.
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
