import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';
import '../application/changes_providers.dart';
import 'package:karmashala_git/git.dart';

/// Points the change-reading surfaces at [worktree], or back at the checkout
/// itself. The one writer of a browse: nothing is selected, nothing is
/// remembered against a session, and no agent moves.
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

/// "Which worktree's changes am I reading" — the Changes pane's own picker,
/// absent until there is a choice to make. Shares the `git worktree list` the
/// panel chrome above already asks for.
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

/// The worktree being read has been removed and the pane has fallen back to the
/// checkout. Nothing in every other state, including while the listing is
/// loading: "not asked yet" is not "gone".
class WorktreeBrowseNotice extends ConsumerWidget {
  const WorktreeBrowseNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final browsed = ref.watch(browsedWorktreeProvider);
    if (browsed == null) return const SizedBox.shrink();
    if (!ref.watch(browsedWorktreeMissingProvider)) {
      return const SizedBox.shrink();
    }

    final home = ref.watch(selectedCheckoutPathProvider);
    final fallback = home == null ? 'the checkout' : lastPathSegment(home.path);

    return PaneNoticeBar(
      icon: AppIcons.warning,
      tone: NoticeTone.attention,
      message: '${browsed.label} is gone. Reading $fallback instead.',
      dismissTooltip: 'Stop reading the removed worktree',
      onDismiss: () => ref.read(worktreeBrowsingProvider.notifier).stop(),
    );
  }
}
