import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';
import 'package:agent_cli/process.dart';
import '../../explorer/application/checkout.dart';
import '../application/changes_providers.dart';
import '../domain/git_worktree.dart';

/// Points the change-reading surfaces at [worktree], or back at the checkout
/// itself when that is the row picked.
///
/// The one writer of a browse, so both panes make the same promise: nothing is
/// selected, nothing is remembered against a session, and no agent moves.
void browseWorktree(
  WidgetRef ref, {
  required String repositoryId,
  required EnvironmentPath home,
  required GitWorktree worktree,
}) {
  final browsing = ref.read(worktreeBrowsingProvider.notifier);
  if (Checkout(worktree.path) == Checkout(home)) {
    browsing.stop();
    return;
  }
  browsing.browse(
    WorktreeBrowse(
      repositoryId: repositoryId,
      path: worktree.path,
      branch: worktree.branch,
    ),
  );
}

/// "Which worktree's changes am I reading" — the Changes pane's own picker.
///
/// Absent until there is a choice to make, so a clone with no worktrees keeps
/// the header it has. Costs one `git worktree list` for the selected checkout
/// while the pane is open; the panel chrome above it already asks the same
/// question, and the answer is what tells this pane a worktree has gone.
class WorktreeBrowsePicker extends ConsumerWidget {
  const WorktreeBrowsePicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repositoryId = ref.watch(selectedRepositoryIdProvider);
    final home = ref.watch(selectedCheckoutPathProvider);
    if (repositoryId == null || home == null) return const SizedBox.shrink();

    final worktrees =
        ref.watch(repoWorktreesProvider).asData?.value ?? const <GitWorktree>[];
    final browsed = ref.watch(browsedWorktreeProvider);
    if (worktrees.length < 2 && browsed == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final viewed = ref.watch(viewedCheckoutProvider);

    return PopupMenuButton<GitWorktree>(
      tooltip: browsed == null
          ? "Choose which worktree's changes to read. "
                "The session's checkout does not move."
          : "Reading ${browsed.label}. The session's checkout has not moved.",
      position: PopupMenuPosition.under,
      padding: EdgeInsets.zero,
      onSelected: (worktree) => browseWorktree(
        ref,
        repositoryId: repositoryId,
        home: home,
        worktree: worktree,
      ),
      itemBuilder: (context) => [
        for (final worktree in worktrees)
          DesktopMenuDetailItem<GitWorktree>(
            value: worktree,
            label: worktree.label,
            detail: Checkout(worktree.path) == Checkout(home)
                ? 'the selected checkout'
                : worktree.path.path,
            detailMaxLines: 1,
            icon: AppIcons.gitBranch,
            selected:
                viewed != null && Checkout(worktree.path) == Checkout(viewed),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.gitBranch,
              size: Chrome.icon,
              color: browsed == null ? scheme.onSurfaceVariant : scheme.primary,
            ),
            if (browsed != null) ...[
              const SizedBox(width: Insets.xs),
              Flexible(
                child: Text(
                  browsed.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The one line that has to be said out loud: the worktree being read has been
/// removed, and the pane has fallen back to the checkout.
///
/// Nothing at all in every other state — including while the listing is still
/// loading, because "not asked yet" is not "gone".
class WorktreeBrowseNotice extends ConsumerWidget {
  const WorktreeBrowseNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final browsed = ref.watch(browsedWorktreeProvider);
    if (browsed == null) return const SizedBox.shrink();
    if (!ref.watch(browsedWorktreeMissingProvider)) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final attention = SemanticColors.of(context).attention;
    final home = ref.watch(selectedCheckoutPathProvider);
    final fallback = home == null
        ? 'the checkout'
        : lastPathSegment(home.path);

    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(Insets.sm, Insets.xs, 2, Insets.xs),
      child: Row(
        children: [
          Icon(AppIcons.warning, size: Chrome.iconSmall, color: attention),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Text(
              '${browsed.label} is gone. Reading $fallback instead.',
              style: theme.textTheme.labelSmall?.copyWith(color: attention),
            ),
          ),
          IconButton(
            tooltip: 'Stop reading the removed worktree',
            iconSize: Chrome.iconAction,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
            padding: EdgeInsets.zero,
            icon: const Icon(AppIcons.x),
            onPressed: () => ref.read(worktreeBrowsingProvider.notifier).stop(),
          ),
        ],
      ),
    );
  }
}
