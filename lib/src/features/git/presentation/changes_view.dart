import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:agent_cli/process.dart';
import '../../sessions/application/delivery_providers.dart';
import '../application/changes_providers.dart';
import '../application/review_threads.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_ui_providers.dart';
import 'package:karmashala_git/git.dart';
import 'diff_view.dart';
import 'remote_link.dart';
import 'worktree_browse.dart';

/// Read-only Git change review: changed files, each expandable to its unified
/// diff inline and openable full-screen. There is no editor.
class ChangesView extends ConsumerStatefulWidget {
  const ChangesView({required this.repositoryName, super.key});

  final String repositoryName;

  /// Builds of the file rows, counted so a cost test can prove a header action
  /// repaints without the list.
  @visibleForTesting
  static int debugFileRowBuildCount = 0;

  @override
  ConsumerState<ChangesView> createState() => _ChangesViewState();
}

class _ChangesViewState extends ConsumerState<ChangesView> {
  final _expanded = <String>{};

  @override
  Widget build(BuildContext context) {
    // Nothing here watches a provider: each header action subscribes to the one
    // thing it draws, so a commit does not repaint every file row.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneHeader(
          icon: AppIcons.gitDiff,
          title: 'Changes',
          actions: [
            // Which worktree is being *read*; the session's checkout is moved
            // from the Repository pane, by another verb.
            const Flexible(child: WorktreeBrowsePicker()),
            // Flexible so a long branch ellipsises: this side panel can be
            // dragged down to 240px.
            const Flexible(child: _DeliveryLinks()),
            const _ChangedFileCount(),
            const _AbortMergeButton(),
            IconButton(
              tooltip: 'Refresh',
              visualDensity: VisualDensity.compact,
              icon: const Icon(AppIcons.arrowsClockwise, size: Chrome.icon),
              // The probe as well, or a folder that has just had `git init` run
              // in it would keep answering from the cached verdict.
              onPressed: () {
                ref.invalidate(checkoutGitPresenceProvider);
                ref.invalidate(repositoryChangesProvider);
              },
            ),
            const _SendReviewThreadsButton(),
          ],
        ),
        const WorktreeBrowseNotice(),
        Expanded(
          child: _ChangedFiles(
            expanded: _expanded,
            onToggle: (path) => setState(() {
              if (!_expanded.remove(path)) _expanded.add(path);
            }),
            onFullscreen: (file) => _openFullscreen(context, file),
          ),
        ),
      ],
    );
  }

  void _openFullscreen(BuildContext context, FileChange file) {
    ref.read(selectedChangeFileProvider.notifier).select(file.path);
    showDialog<void>(
      context: context,
      builder: (_) => _DiffFullscreenDialog(file: file),
    );
  }
}

/// Forge links for the branch, head commit and pull request in view. Its own
/// widget because only it watches the delivery and commit log, which poll.
class _DeliveryLinks extends ConsumerWidget {
  const _DeliveryLinks();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final repositoryId = ref.watch(selectedRepositoryIdProvider);
    // The branch and pull request are the *selected checkout's*, so they would
    // mislabel a browsed worktree; the head commit follows the tree being read.
    final browsing = ref.watch(
      browsedWorktreeProvider.select((browse) => browse != null),
    );
    final delivery = repositoryId == null
        ? null
        : ref.watch(repositoryDeliveryProvider(repositoryId)).asData?.value;
    // Only the tip is drawn, so only the tip is subscribed to: the other seven
    // commits the provider returns move without touching this row.
    final head = ref.watch(
      recentCommitsProvider.select((v) => v.asData?.value.firstOrNull),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (delivery?.branch case final branch? when !browsing) ...[
          const SizedBox(width: Insets.sm),
          Flexible(
            child: RemoteLink(
              text: branch,
              url: delivery!.remote?.branchUrl(branch),
              style: theme.textTheme.labelSmall,
            ),
          ),
        ],
        if (head != null) ...[
          const SizedBox(width: Insets.sm),
          Flexible(
            child: RemoteLink(
              text: shortSha(head.sha),
              // Drawn plainly when there is no remote — a commit without one
              // is still a commit.
              url: delivery?.remote?.commitUrl(head.sha),
              style: theme.textTheme.labelSmall,
              tooltip: head.subject,
            ),
          ),
        ],
        if (delivery?.pullRequest case final pr? when !browsing) ...[
          const SizedBox(width: Insets.sm),
          Flexible(
            child: RemoteLink(
              text: '#${pr.number}',
              url: pr.url,
              style: theme.textTheme.labelSmall,
              tooltip: pr.title.isEmpty ? pr.url : pr.title,
              icon: true,
            ),
          ),
        ],
      ],
    );
  }
}

/// How many files changed. Subscribed to the count alone, so the list growing a
/// hunk redraws nothing here.
class _ChangedFileCount extends ConsumerWidget {
  const _ChangedFileCount();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(
      repositoryChangesProvider.select((v) => v.asData?.value.length ?? 0),
    );
    if (count == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: Insets.xs),
      child: Text(
        '$count',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// `git merge --abort` on the working tree being read, behind a confirm. Shown
/// only when there is something to abort: an undo button beside a clean tree
/// offers to discard work that is not there.
class _AbortMergeButton extends ConsumerWidget {
  const _AbortMergeButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final checkout = ref.watch(viewedCheckoutProvider);
    if (checkout == null) return const SizedBox.shrink();
    // Hidden while the reading is pending or errored too: this button destroys
    // work, so it appears on evidence and never on a guess.
    if (ref.watch(mergeInProgressProvider).asData?.value != true) {
      return const SizedBox.shrink();
    }
    return IconButton(
      tooltip: 'Abort merge',
      visualDensity: VisualDensity.compact,
      icon: const Icon(AppIcons.arrowCounterClockwise, size: Chrome.icon),
      onPressed: () => _press(context, ref, checkout),
    );
  }

  Future<void> _press(
    BuildContext context,
    WidgetRef ref,
    EnvironmentPath checkout,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Abort the merge in progress?'),
        content: const Text(
          'git merge --abort puts the working tree back to the commit the '
          'merge started from. Every conflict resolution made since then is '
          'discarded.\n\n'
          'Commits are untouched, and if no merge is in progress nothing '
          'changes at all.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Abort merge'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final restored = await ref.read(changesServiceProvider).abortMerge(checkout);
    // Only on the half that rewrote files; an abort that found nothing to undo
    // changed no file.
    if (restored) ref.invalidate(repositoryChangesProvider);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          restored
              ? 'Merge aborted. The working tree is back to before it started.'
              : 'There was no merge to abort; nothing changed.',
        ),
      ),
    );
  }
}

/// Sends the should-fix review threads to the session on screen. Watches the
/// index here so a reply over MCP repaints one badge, not the file list.
class _SendReviewThreadsButton extends ConsumerWidget {
  const _SendReviewThreadsButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final threads =
        ref.watch(repositoryReviewThreadsProvider).asData?.value ??
        ReviewThreadIndex.empty;
    final pending = threads.pending;
    if (pending.isEmpty) return const SizedBox.shrink();

    final sessionId = ref.watch(selectedSessionIdProvider);
    final repositoryId = ref.watch(selectedRepositoryIdProvider);
    return IconButton(
      // "Should fix", not "every comment": a thread nobody has triaged is a
      // claim, and sending it would hand an agent work no human asked for.
      tooltip: sessionId == null
          ? 'Select a session to send ${pending.length} review comments '
                'marked should-fix'
          : 'Send ${pending.length} should-fix review comments to the agent',
      icon: Badge(
        label: Text('${pending.length}'),
        child: const Icon(AppIcons.chatCircleDots, size: Chrome.icon),
      ),
      onPressed: sessionId == null || repositoryId == null
          ? null
          : () async {
              // Sending clears nothing: the thread stays should-fix until
              // somebody looks at the code and decides it is done.
              await ref
                  .read(sessionActionsProvider)
                  .continueSession(
                    sessionId,
                    buildReviewThreadPrompt(pending),
                  );
            },
    );
  }
}

/// The list of changed files — the only part of the panel that watches the
/// changes themselves.
class _ChangedFiles extends ConsumerWidget {
  const _ChangedFiles({
    required this.expanded,
    required this.onToggle,
    required this.onFullscreen,
  });

  final Set<String> expanded;
  final void Function(String path) onToggle;
  final void Function(FileChange file) onFullscreen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(repositoryChangesProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => _NoChangesToRead(error: e),
          data: (files) => files.isEmpty
              ? const PanePlaceholder(
                  message: 'No working-tree changes.',
                  icon: AppIcons.gitDiff,
                )
              : _ordered(files),
        );
  }

  /// The same list, in review order — tiered, never filtered; git's own
  /// alphabetical order opens every review on `pubspec.lock`.
  Widget _ordered(List<FileChange> files) {
    final ordered = orderedForReview(files, (file) => file.path);
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      itemCount: ordered.length,
      itemBuilder: (context, index) {
        final file = ordered[index];
        return _ChangedFileSection(
          file: file,
          expanded: expanded.contains(file.path),
          onToggle: () => onToggle(file.path),
          onFullscreen: () => onFullscreen(file),
        );
      },
    );
  }
}

class _ChangedFileSection extends ConsumerWidget {
  const _ChangedFileSection({
    required this.file,
    required this.expanded,
    required this.onToggle,
    required this.onFullscreen,
  });

  final FileChange file;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onFullscreen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ChangesView.debugFileRowBuildCount++;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Insets.xs, 2, Insets.xs, 2),
            child: Row(
              children: [
                Icon(
                  expanded ? AppIcons.caretDown : AppIcons.caretRight,
                  size: Chrome.icon,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                Tooltip(
                  message: changeWords(file),
                  child: Icon(
                    _iconFor(file.type),
                    size: Chrome.iconAction,
                    color: _colorFor(file.type, context),
                  ),
                ),
                const SizedBox(width: Insets.xs),
                Expanded(
                  child: Text(
                    file.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MonoStyles.body,
                  ),
                ),
                IconButton(
                  tooltip: 'Open full screen',
                  visualDensity: VisualDensity.compact,
                  iconSize: Chrome.iconAction,
                  constraints: const BoxConstraints(
                    minWidth: 26,
                    minHeight: 26,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(AppIcons.arrowsOutSimple),
                  onPressed: onFullscreen,
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: FileDiffView(path: file.path, wrap: true),
          ),
        const Divider(height: 1),
      ],
    );
  }
}

class _DiffFullscreenDialog extends StatelessWidget {
  const _DiffFullscreenDialog({required this.file});
  final FileChange file;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1200, maxHeight: 900),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.lg,
                Insets.sm,
                8,
                Insets.sm,
              ),
              child: Row(
                children: [
                  Icon(_iconFor(file.type)),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      file.path,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontFamily: kMonoFamily,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Consumer(
                    builder: (context, ref, _) => IconButton(
                      tooltip: 'Copy diff',
                      icon: const Icon(AppIcons.copySimple),
                      onPressed: () async {
                        final diff = await ref.read(
                          fileDiffByPathProvider(file.path).future,
                        );
                        await Clipboard.setData(ClipboardData(text: diff));
                      },
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(AppIcons.x),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: FileDiffView(path: file.path)),
          ],
        ),
      ),
    );
  }
}

/// What this pane says when there is no diff to draw — three things, not one.
/// [gitTroubleOf] is the single place they are told apart, so this pane and the
/// Repository pane cannot word the same failure two ways.
class _NoChangesToRead extends StatelessWidget {
  const _NoChangesToRead({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => switch (gitTroubleOf(error)) {
    // The same muted surface as "No working-tree changes." beside it, because
    // it is the same kind of statement: nothing is wrong here.
    GitTrouble.notARepository => const PanePlaceholder(
      message: notARepositoryMessage,
      icon: AppIcons.folder,
    ),
    GitTrouble.unreachable => const PanePlaceholder(
      message: gitUnreachableMessage,
      icon: AppIcons.linkBreak,
    ),
    GitTrouble.failed => DiffErrorBox(message: '$error'),
  };
}

IconData _iconFor(FileChangeType type) => switch (type) {
  FileChangeType.added => AppIcons.plusCircle,
  FileChangeType.deleted => AppIcons.minusCircle,
  FileChangeType.renamed => AppIcons.pencilSimple,
  FileChangeType.untracked => AppIcons.question,
  FileChangeType.conflicted => AppIcons.warning,
  _ => AppIcons.pencil,
};

Color _colorFor(FileChangeType type, BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  final semantic = SemanticColors.of(context);
  return switch (type) {
    FileChangeType.added => semantic.diffAdded,
    FileChangeType.deleted => semantic.diffRemoved,
    // `attention`, not `failure`: an unmerged path is the user being asked for
    // something, not a merge that broke.
    FileChangeType.conflicted => semantic.attention,
    _ => scheme.primary,
  };
}

/// What the type glyph means, in words, for the tooltip — a conflict names
/// which kind, since one icon cannot carry all of them.
String changeWords(FileChange change) => switch (change.type) {
  FileChangeType.added => 'added',
  FileChangeType.modified => 'modified',
  FileChangeType.deleted => 'deleted',
  FileChangeType.renamed => 'renamed',
  FileChangeType.copied => 'copied',
  FileChangeType.untracked => 'untracked',
  FileChangeType.conflicted =>
    'conflicted — ${(change.conflict ?? MergeConflict.unrecorded).words}',
  FileChangeType.unknown => 'changed (unrecognised git status)',
};
