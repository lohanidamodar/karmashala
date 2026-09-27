import '../data/git_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:agent_cli/process.dart';
import 'package:path/path.dart' as p;
import '../application/diff_tab_actions.dart';
import 'commit_box.dart';
import 'diff_counts.dart';
import '../../sessions/application/delivery_providers.dart';
import '../application/changes_providers.dart';
import '../application/review_threads.dart';
import '../application/working_copy_controller.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_ui_providers.dart';
import 'package:karmashala_git/git.dart';
import 'diff_view.dart';
import 'remote_link.dart';
import 'worktree_browse.dart';

/// Read-only Git change review: what changed, listed. Reading a change happens
/// in a workbench tab ([DiffTabView]), which has the room for it.
class ChangesView extends ConsumerWidget {
  const ChangesView({required this.repositoryName, super.key});

  final String repositoryName;

  /// Builds of the file rows, counted so a cost test can prove a header action
  /// repaints without the list.
  @visibleForTesting
  static int debugFileRowBuildCount = 0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        // Flexible, not fixed: this panel is dragged down to 240px, and the
        // file list must not be squeezed out by a commit box that will not
        // give way. It scrolls inside whatever it is left.
        const Flexible(child: CommitBox()),
        const Expanded(child: _ChangedFiles()),
      ],
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

    final restored = await ref
        .read(gitDataProvider)
        .abortMerge(checkout);
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
                  .continueSession(sessionId, buildReviewThreadPrompt(pending));
            },
    );
  }
}

/// The list of changed files — the only part of the panel that watches the
/// changes themselves.
class _ChangedFiles extends ConsumerWidget {
  const _ChangedFiles();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(repositoryChangesProvider)
        .when(
          loading: () =>
              const Center(child: InlineSpinner(size: InlineSpinnerSize.large)),
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
  ///
  /// Grouped the way a source-control pane groups: what is going into the next
  /// commit, then what is not. A file can be in both when part of it is
  /// staged, and it is listed in both — that is what git means by it, and one
  /// row saying "staged" would be a lie about the other half.
  Widget _ordered(List<FileChange> files) {
    final conflicts = [
      for (final file in files)
        if (file.type == FileChangeType.conflicted) file,
    ];
    final staged = [
      for (final file in files)
        if (file.staged && file.type != FileChangeType.conflicted) file,
    ];
    final unstaged = [
      for (final file in files)
        if (file.unstaged && file.type != FileChangeType.conflicted) file,
    ];
    final sections = [
      if (conflicts.isNotEmpty)
        (
          title: 'Conflicts',
          files: orderedForReview(conflicts, (f) => f.path),
          staged: false,
          conflicted: true,
        ),
      if (staged.isNotEmpty)
        (
          title: 'Staged changes',
          files: orderedForReview(staged, (f) => f.path),
          staged: true,
          conflicted: false,
        ),
      if (unstaged.isNotEmpty)
        (
          title: 'Changes',
          files: orderedForReview(unstaged, (f) => f.path),
          staged: false,
          conflicted: false,
        ),
    ];
    // One flat list of rows and headers rather than nested scrollers: a
    // sticky-per-section ListView inside a 240px panel scrolls two ways.
    final rows = <Widget>[];
    for (final section in sections) {
      rows.add(
        _SectionHeader(
          title: section.title,
          count: section.files.length,
          files: section.files,
          staged: section.staged,
          conflicted: section.conflicted,
        ),
      );
      for (final file in section.files) {
        rows.add(_ChangedFileRow(file: file, inStagedSection: section.staged));
      }
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      itemCount: rows.length,
      itemBuilder: (context, index) => rows[index],
    );
  }
}

/// A group's name, how many files are in it, and the two verbs that act on all
/// of them. Its own widget so the buttons repaint without the rows.
class _SectionHeader extends ConsumerWidget {
  const _SectionHeader({
    required this.title,
    required this.count,
    required this.files,
    required this.staged,
    required this.conflicted,
  });

  final String title;
  final int count;
  final List<FileChange> files;
  final bool staged;
  final bool conflicted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final busy = ref.watch(
      workingCopyControllerProvider.select((state) => state.isBusy),
    );
    final copy = ref.read(workingCopyControllerProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.sm, Insets.xs, Insets.xs, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${title.toUpperCase()}  $count',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 0.6,
              ),
            ),
          ),
          if (!conflicted)
            IconButton(
              tooltip: staged ? 'Unstage all' : 'Stage all',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                staged ? AppIcons.minusCircle : AppIcons.plus,
                size: Chrome.iconSmall,
              ),
              onPressed: busy
                  ? null
                  : () => staged
                        ? copy.unstage([for (final f in files) f.path])
                        : copy.stage([for (final f in files) f.path]),
            ),
          if (!staged && !conflicted)
            IconButton(
              tooltip: 'Discard all changes',
              visualDensity: VisualDensity.compact,
              icon: const Icon(
                AppIcons.arrowCounterClockwise,
                size: Chrome.iconSmall,
              ),
              onPressed: busy
                  ? null
                  : () => confirmDiscard(context, ref, files),
            ),
        ],
      ),
    );
  }
}

/// One changed file, listed the way VS Code lists one: the name, the folder it
/// sits in, and how many lines moved. A tap reads it in a tab — the sidebar is
/// for finding a change, not for reading one through a 300px window.
class _ChangedFileRow extends ConsumerWidget {
  const _ChangedFileRow({required this.file, this.inStagedSection = false});

  final FileChange file;

  /// Which group this row is drawn in, which is what its verbs act on: the
  /// same path can be listed twice when half of it is staged.
  final bool inStagedSection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ChangesView.debugFileRowBuildCount++;
    final scheme = Theme.of(context).colorScheme;
    // Each row asks only about itself, so a count arriving for one file does
    // not repaint the list.
    final stat = ref.watch(
      repositoryFileDiffStatsProvider.select(
        (stats) => stats.asData?.value[file.path],
      ),
    );
    // Read off the tab on screen, so closing it unhighlights the row and a
    // click on another tab's chip moves the highlight with it.
    final selected = ref.watch(
      activeDiffFileProvider.select((path) => path == file.path),
    );
    final folder = p.posix.dirname(file.path);
    return Semantics(
      selected: selected,
      child: InkWell(
        onTap: () => ref.read(diffTabActionsProvider).open(file.path),
        child: Container(
          color: selected ? StateLayers.selected(scheme) : null,
          padding: const EdgeInsets.fromLTRB(Insets.sm, 3, Insets.xs, 3),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: Text(
                        p.posix.basename(file.path),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: MonoStyles.body,
                      ),
                    ),
                    // The folder is context, not the name — dimmed, and it
                    // gives way first when the panel is dragged narrow.
                    if (folder != '.') ...[
                      const SizedBox(width: Insets.sm),
                      Flexible(
                        child: Text(
                          folder,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: MonoStyles.small.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (stat != null && !stat.isBinary) ...[
                const SizedBox(width: Insets.xs),
                DiffCountLabel(added: stat.added!, removed: stat.removed!),
              ],
              _RowActions(file: file, inStagedSection: inStagedSection),
              const SizedBox(width: Insets.sm),
              Tooltip(
                message: changeWords(file),
                child: Text(
                  changeLetter(file.type),
                  style: MonoStyles.body.copyWith(
                    color: _colorFor(file.type, context),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stage, unstage and discard for one row. Drawn always rather than on hover:
/// this panel is often driven by keyboard and read on a laptop trackpad, and a
/// control that appears only under the pointer cannot be found by either.
class _RowActions extends ConsumerWidget {
  const _RowActions({required this.file, required this.inStagedSection});

  final FileChange file;
  final bool inStagedSection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (file.type == FileChangeType.conflicted) {
      // A conflict is resolved in the file, then staged like anything else;
      // offering "discard" beside it invites throwing away the resolution.
      return _RowButton(
        tooltip: 'Stage the resolution',
        icon: AppIcons.plus,
        onPressed: () =>
            ref.read(workingCopyControllerProvider.notifier).stage([file.path]),
      );
    }
    final copy = ref.read(workingCopyControllerProvider.notifier);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!inStagedSection)
          _RowButton(
            tooltip: 'Discard changes',
            icon: AppIcons.arrowCounterClockwise,
            onPressed: () => confirmDiscard(context, ref, [file]),
          ),
        _RowButton(
          tooltip: inStagedSection ? 'Unstage' : 'Stage',
          icon: inStagedSection ? AppIcons.minusCircle : AppIcons.plus,
          onPressed: () => inStagedSection
              ? copy.unstage([file.path])
              : copy.stage([file.path]),
        ),
      ],
    );
  }
}

class _RowButton extends ConsumerWidget {
  const _RowButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(
      workingCopyControllerProvider.select((state) => state.isBusy),
    );
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      iconSize: Chrome.iconSmall,
      icon: Icon(icon, size: Chrome.iconSmall),
      onPressed: busy ? null : onPressed,
    );
  }
}

/// Asks before throwing work away, and says which of the two acts it is: a
/// tracked file is rewound, an untracked one is deleted and nothing brings it
/// back. Karmashala's own checkpoints do not cover an untracked file either.
Future<void> confirmDiscard(
  BuildContext context,
  WidgetRef ref,
  List<FileChange> files,
) async {
  final untracked = [
    for (final file in files)
      if (file.type == FileChangeType.untracked) file,
  ];
  final what = files.length == 1
      ? '"${p.posix.basename(files.single.path)}"'
      : '${files.length} files';
  final confirmed = await showConfirmDialog(
    context,
    destructive: true,
    title: 'Discard changes to $what?',
    message: untracked.isEmpty
        ? 'The working-tree changes go back to the last commit. Anything not '
              'committed is lost.'
        : untracked.length == files.length
        ? 'These files are untracked, so discarding deletes them. Nothing '
              'brings them back — git has never seen them.'
        : '${untracked.length} of them are untracked and will be deleted; the '
              'rest go back to the last commit.',
    confirmLabel: 'Discard',
  );
  if (!confirmed) return;
  await ref.read(workingCopyControllerProvider.notifier).discard(files);
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

/// git's own one-letter status, which is what a reviewer's eye scans for. The
/// colour repeats it rather than carrying it (§5).
String changeLetter(FileChangeType type) => switch (type) {
  FileChangeType.added => 'A',
  FileChangeType.modified => 'M',
  FileChangeType.deleted => 'D',
  FileChangeType.renamed => 'R',
  FileChangeType.copied => 'C',
  FileChangeType.untracked => 'U',
  FileChangeType.conflicted => '!',
  FileChangeType.unknown => '?',
};

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
