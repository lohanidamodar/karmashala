import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_dialog.dart';
import 'package:agent_cli/process.dart';
import '../../sessions/application/delivery_providers.dart';
import '../application/changes_providers.dart';
import '../application/review_threads.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_ui_providers.dart';
import 'package:karmashala_git/git.dart';
import 'diff_line_tile.dart';
import 'remote_link.dart';
import 'worktree_browse.dart';

/// Read-only Git change review, desktop-style: a vertical list of changed files,
/// each expandable to reveal its unified diff inline, and openable full-screen
/// for a wide, scrollable read. Git is the source of truth; there is no editor.
class ChangesView extends ConsumerStatefulWidget {
  const ChangesView({required this.repositoryName, super.key});

  final String repositoryName;

  /// Builds of the file rows, counted so a cost test can prove that a commit,
  /// a delivery, a review thread or a session selection repaints the header
  /// action that draws it and leaves the list alone.
  @visibleForTesting
  static int debugFileRowBuildCount = 0;

  @override
  ConsumerState<ChangesView> createState() => _ChangesViewState();
}

class _ChangesViewState extends ConsumerState<ChangesView> {
  final _expanded = <String>{};

  @override
  Widget build(BuildContext context) {
    // Nothing here watches a provider. Six of them used to be read in this one
    // build — the changes, the selected repository and session, the review
    // threads, the delivery and the commit log — so a commit landing or a
    // review thread arriving repainted every file row in the panel. Each
    // header action now subscribes to the one thing it draws.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneHeader(
          icon: AppIcons.gitDiff,
          title: 'Changes',
          actions: [
            // Which worktree is being read, and the only control that changes
            // it. A view state: the session's checkout is moved from the
            // Repository pane, deliberately and by another verb.
            //
            // Flexible for the same reason as the links beside it — a worktree
            // branch is as long as an agent's name, and this header is 226px.
            const Flexible(child: WorktreeBrowsePicker()),
            // Flexible, so a long branch name in a narrow panel ellipsises
            // rather than overflowing — this header sits in a side panel that
            // can be dragged down to 240px.
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

/// What this repository's work is called on the forge, so a branch, a commit or
/// a pull request in view is one click from the page that owns it.
///
/// Its own widget because it is the only thing in the header that cares about
/// the delivery or the commit log, and both of those move on a git poll.
class _DeliveryLinks extends ConsumerWidget {
  const _DeliveryLinks();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final repositoryId = ref.watch(selectedRepositoryIdProvider);
    // The branch and the pull request are the *selected checkout's*, and while
    // another worktree is being read they would label it with somebody else's
    // work. The picker beside this names the worktree instead; the head commit
    // stays, because the commit log follows the tree being read.
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

/// `git merge --abort` on the working tree being read, behind a confirm.
///
/// **The only lever in the strip that is ours and undoes rather than does.**
/// `ChangesService.abortMerge` had exactly one caller — the delivery
/// pipeline's failure path — so a merge an agent left half-done could be
/// undone only by asking a model to type the command. Merge and push stay
/// prompts, because what a merge should say is a decision; aborting one has
/// nothing in it to decide, which is the test `DeliveryAction` sets for an
/// action the app owns.
///
/// **It appears only when there is something to abort**, which is now a
/// reading the panel already holds rather than a process. It used to sit in the
/// header unconditionally, on the argument that asking would cost a
/// `CreateProcessW` on every poll — true of `git rev-parse MERGE_HEAD`, and not
/// true of [mergeInProgressProvider], which is the listing plus at most one
/// `stat` of `.git`. A permanent undo button beside a clean tree is an offer to
/// discard work that is not there.
///
/// The outcome still states which of the two happened rather than predicting
/// it: [ChangesService.abortMerge] reports whether a tree came back, and a
/// reading taken a moment ago is not a promise about what git will find.
class _AbortMergeButton extends ConsumerWidget {
  const _AbortMergeButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final checkout = ref.watch(viewedCheckoutProvider);
    if (checkout == null) return const SizedBox.shrink();
    // Hidden while the reading is pending or errored, for the same reason it is
    // hidden when there is no merge: this button destroys work, so it appears
    // on evidence and never on a guess.
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
    // Only on the half that rewrote files. An abort that found nothing to undo
    // changed no file, so re-reading would be a git process spent on a listing
    // that cannot have moved.
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

/// Sends the should-fix review threads to the session on screen.
///
/// The review index and the selected session are read here rather than in the
/// panel: a reply arriving over MCP bumps the index, and that must cost one
/// badge rather than the whole file list.
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
              // Nothing is cleared, marked or resolved by sending. The thread
              // stays should-fix until somebody looks at the code and decides
              // it is done — which is the whole reason these are rows now. See
              // `buildReviewThreadPrompt`.
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

  /// The same list, in the order it is read in. **Tiered, never filtered** —
  /// see `review_order.dart`; git's own order is alphabetical, which opens
  /// every review on `pubspec.lock`.
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
            child: _InlineDiff(path: file.path, wrap: true),
          ),
        const Divider(height: 1),
      ],
    );
  }
}

/// Renders a file's unified diff. [wrap] softwraps long lines (for the narrow
/// sidebar); when false the diff scrolls horizontally (full-screen view).
class _InlineDiff extends ConsumerWidget {
  const _InlineDiff({required this.path, this.wrap = false});

  final String path;
  final bool wrap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diff = ref.watch(fileDiffByPathProvider(path));
    return diff.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(Insets.md),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (e, _) => _ErrorBox(message: '$e'),
      data: (text) {
        final lines = parseUnifiedDiff(text);
        if (lines.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(Insets.md),
            child: Text(
              'No textual diff (binary or untracked file).',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        }
        // The one translation that makes a comment anchorable: a row of this
        // rendering becomes a line of the file. The row index itself is what
        // the old `DiffAnnotation.diffIndex` stored, and it is exactly as
        // durable as the rendering — which is to say not at all.
        final numbers = newFileLineNumbers(lines);
        final threads =
            ref.watch(repositoryReviewThreadsProvider).asData?.value ??
            ReviewThreadIndex.empty;
        // Threads no line can carry, above the diff rather than lost inside it.
        final unplaced = threads.unplaced(path);
        final list = ListView.builder(
          primary: false,
          padding: const EdgeInsets.symmetric(vertical: Insets.xs),
          itemCount: unplaced.length + lines.length,
          itemBuilder: (context, index) {
            if (index < unplaced.length) {
              return _UnplacedThreadTile(entry: unplaced[index]);
            }
            final row = index - unplaced.length;
            return _DiffLineTile(
              path: path,
              lineNumber: numbers[row],
              line: lines[row],
              wrap: wrap,
            );
          },
        );
        if (wrap) return list;
        // Full-screen: let long code lines scroll horizontally.
        return Scrollbar(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: 1400, child: list),
          ),
        );
      },
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
            Expanded(child: _InlineDiff(path: file.path)),
          ],
        ),
      ),
    );
  }
}

/// One row of the diff, with whatever review threads land on it.
///
/// [lineNumber] is the row's line **in the file**, or null for a header, a hunk
/// marker or a removed line — see [newFileLineNumbers]. It is what an anchor is
/// built from, and its nullability is the reason a comment on a removed line
/// becomes a file-level thread: there is no line of the current file that
/// removed text sits on, and inventing one is the mis-anchoring this whole
/// change exists to remove.
class _DiffLineTile extends ConsumerWidget {
  const _DiffLineTile({
    required this.path,
    required this.lineNumber,
    required this.line,
    this.wrap = false,
  });

  final String path;
  final int? lineNumber;
  final DiffLine line;
  final bool wrap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final repositoryId = ref.watch(selectedRepositoryIdProvider);
    final index =
        ref.watch(repositoryReviewThreadsProvider).asData?.value ??
        ReviewThreadIndex.empty;
    // Attached threads only, by construction: `atLine` will not return one
    // whose file has moved on, because its line number no longer locates
    // anything. Those are drawn above the diff instead.
    final here = lineNumber == null
        ? const <AnchoredReviewThread>[]
        : index.atLine(path, lineNumber!);
    // The drawing lives in `DiffLineTile`, shared with the agent-edit diff in
    // the transcript; what stays here is the one thing only this panel has, the
    // review comment hung off the end of the row.
    final commentable =
        line.kind == DiffLineKind.added ||
        line.kind == DiffLineKind.removed ||
        line.kind == DiffLineKind.context;
    return DiffLineTile(
      line: line,
      wrap: wrap,
      trailing: commentable
          ? IconButton(
              tooltip: here.isEmpty
                  ? 'Add review comment'
                  : here.map((entry) => entry.thread.body).join('\n\n'),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              padding: EdgeInsets.zero,
              icon: Icon(
                here.isEmpty ? AppIcons.chatCircle : AppIcons.chatCircleDots,
                size: Chrome.iconSmall,
                color: here.isEmpty ? null : scheme.tertiary,
              ),
              onPressed: repositoryId == null
                  ? null
                  : () => showReviewThreadDialog(
                      context,
                      repositoryId: repositoryId,
                      path: path,
                      // Null for a removed line, which opens a file-level
                      // thread quoting the removed text.
                      lineNumber: lineNumber,
                      excerpt: line.text,
                      existing: here,
                    ),
            )
          : null,
    );
  }
}

/// A thread that no line of this diff can carry: a file-level comment, or one
/// whose file has changed since it was written.
///
/// It gets a row of its own above the diff rather than a marker on a line,
/// because the honest thing to say about a detached thread is a sentence, and
/// there is nowhere on a code line to say it.
class _UnplacedThreadTile extends ConsumerWidget {
  const _UnplacedThreadTile({required this.entry});

  final AnchoredReviewThread entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final repositoryId = ref.watch(selectedRepositoryIdProvider);
    final detached = !entry.isAttached;
    return InkWell(
      onTap: repositoryId == null
          ? null
          : () => showReviewThreadDialog(
              context,
              repositoryId: repositoryId,
              path: entry.anchor.path,
              lineNumber: null,
              excerpt: null,
              existing: [entry],
            ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Insets.sm, 4, Insets.sm, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              detached ? AppIcons.warningCircle : AppIcons.chatCircleDots,
              size: Chrome.iconSmall,
              color: detached ? scheme.error : scheme.tertiary,
            ),
            const SizedBox(width: Insets.xs),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    detachedThreadHeadline(entry),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: detached ? scheme.error : scheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    entry.thread.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The sentence a thread wears above the diff, in the panel and in the dialog.
///
/// Spelled out rather than reduced to an icon, and it names the *file*, not the
/// line, when the line is no longer meaningful. "Was at lib/a.dart:42" is the
/// truth; "lib/a.dart:42" alone would be read as where it is now.
String detachedThreadHeadline(AnchoredReviewThread entry) {
  final status = entry.thread.status.label;
  return switch (entry.attachment) {
    ReviewThreadAttachment.attached =>
      '${entry.anchor.location} · $status',
    ReviewThreadAttachment.detached =>
      'Detached — the file changed since this was written. Was at '
          '${entry.anchor.location} · $status',
    ReviewThreadAttachment.unknown =>
      'Cannot be checked — this file could not be read. Written against '
          '${entry.anchor.location} · $status',
  };
}

/// Opens the review threads on one anchor, and lets a new one be written.
Future<void> showReviewThreadDialog(
  BuildContext context, {
  required String repositoryId,
  required String path,
  required int? lineNumber,
  required String? excerpt,
  required List<AnchoredReviewThread> existing,
}) => showDialog<void>(
  context: context,
  builder: (_) => _ReviewThreadDialog(
    repositoryId: repositoryId,
    path: path,
    lineNumber: lineNumber,
    excerpt: excerpt,
    existing: existing,
  ),
);

class _ReviewThreadDialog extends ConsumerStatefulWidget {
  const _ReviewThreadDialog({
    required this.repositoryId,
    required this.path,
    required this.lineNumber,
    required this.excerpt,
    required this.existing,
  });

  final String repositoryId;
  final String path;
  final int? lineNumber;
  final String? excerpt;
  final List<AnchoredReviewThread> existing;

  @override
  ConsumerState<_ReviewThreadDialog> createState() =>
      _ReviewThreadDialogState();
}

class _ReviewThreadDialogState extends ConsumerState<_ReviewThreadDialog> {
  final _composer = TextEditingController();

  /// Which thread the composer is answering, or null when it is opening a new
  /// one. A reply and a new comment on the same line are different acts and the
  /// dialog never guesses between them.
  String? _replyingTo;

  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Re-read rather than trusting what was passed in: a reply posted in this
    // dialog, or one an agent posted over MCP while it was open, has to appear.
    final index =
        ref.watch(repositoryReviewThreadsProvider).asData?.value ??
        ReviewThreadIndex.empty;
    final ids = {for (final entry in widget.existing) entry.thread.id};
    final threads = [
      for (final entry in index.all)
        if (ids.contains(entry.thread.id)) entry,
    ];

    return AlertDialog(
      title: Text(
        widget.lineNumber == null
            ? 'Review · ${widget.path}'
            : 'Review · ${widget.path}:${widget.lineNumber}',
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in threads) ...[
                _ThreadCard(
                  entry: entry,
                  onReply: () => setState(() {
                    _replyingTo = entry.thread.id;
                    _error = null;
                  }),
                  onStatus: (status) => ref
                      .read(reviewThreadServiceProvider)
                      .setStatus(entry.thread.id, status),
                ),
                const Divider(),
              ],
              TextField(
                controller: _composer,
                autofocus: true,
                minLines: 3,
                maxLines: 8,
                decoration: InputDecoration(
                  labelText: _replyingTo == null
                      ? 'New review comment'
                      : 'Reply',
                  helperText: _composerHelp(),
                  helperMaxLines: 3,
                  errorText: _error,
                ),
              ),
              if (_replyingTo != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => setState(() => _replyingTo = null),
                    child: const Text('Write a new comment instead'),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(_replyingTo == null ? 'Comment' : 'Reply'),
        ),
      ],
    );
  }

  /// What the composer will actually do, said before it is pressed.
  ///
  /// The removed-line case is spelled out because it is the one place the
  /// dialog cannot give the user what the click implied: they clicked a line,
  /// and what they get is a comment on the file. Saying so is the alternative
  /// to quietly anchoring onto whichever line happens to follow the deletion.
  String _composerHelp() {
    if (_replyingTo != null) return 'Added to the thread above.';
    if (widget.lineNumber != null) {
      return 'Anchored to this line and to the file\'s current contents. If '
          'the file changes, the thread detaches and says so rather than '
          'moving.';
    }
    return 'This line is not in the file as it now stands, so the comment is '
        'anchored to the file rather than to a line. The text is quoted in it.';
  }

  Future<void> _submit() async {
    final body = _composer.text.trim();
    if (body.isEmpty) {
      setState(() => _error = 'Write something first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final service = ref.read(reviewThreadServiceProvider);
    try {
      final replyingTo = _replyingTo;
      if (replyingTo != null) {
        service.reply(
          threadId: replyingTo,
          body: body,
          author: 'the user',
          authorKind: ReviewAuthorKind.user,
        );
      } else {
        await service.open(
          repositoryId: widget.repositoryId,
          path: widget.path,
          body: body,
          author: 'the user',
          authorKind: ReviewAuthorKind.user,
          startLine: widget.lineNumber,
          excerpt: widget.excerpt,
          sessionId: ref.read(selectedSessionIdProvider),
        );
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$error';
        });
      }
      return;
    }
    if (!mounted) return;
    _composer.clear();
    setState(() {
      _busy = false;
      _replyingTo = null;
    });
  }
}

/// One thread: what it is anchored to, everything said in it, and its status.
class _ThreadCard extends StatelessWidget {
  const _ThreadCard({
    required this.entry,
    required this.onReply,
    required this.onStatus,
  });

  final AnchoredReviewThread entry;
  final VoidCallback onReply;
  final ValueChanged<ReviewThreadStatus> onStatus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          detachedThreadHeadline(entry),
          style: theme.textTheme.labelSmall?.copyWith(
            color: entry.isAttached ? scheme.onSurfaceVariant : scheme.error,
          ),
        ),
        if (entry.anchor.excerpt case final excerpt?
            when excerpt.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(excerpt.trim(), style: MonoStyles.body),
          ),
        for (final comment in entry.thread.comments)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(comment.author, style: theme.textTheme.labelSmall),
                Text(comment.body, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        const SizedBox(height: Insets.xs),
        Wrap(
          spacing: Insets.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final status in const [
              ReviewThreadStatus.open,
              ReviewThreadStatus.shouldFix,
              ReviewThreadStatus.dismissed,
              ReviewThreadStatus.resolved,
            ])
              ChoiceChip(
                label: Text(status.label),
                selected: entry.thread.status == status,
                onSelected: (_) => onStatus(status),
              ),
            TextButton(onPressed: onReply, child: const Text('Reply')),
          ],
        ),
      ],
    );
  }
}

/// **What this pane says when there is no diff to draw — three things, not
/// one.**
///
/// It used to be `GitException: git status failed: fatal: not a git repository
/// …` in a red box: an internal type name standing in for an ordinary fact, and
/// the same red box for a folder that is fine as for a git that is broken.
/// [gitTroubleOf] is the single place the three are told apart, so this pane and
/// the Repository pane cannot word the same failure two ways.
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
    GitTrouble.failed => _ErrorBox(message: '$error'),
  };
}

/// The house error box, hung at the top of whatever pane it fills rather than
/// stretched down it.
class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: Padding(
      padding: const EdgeInsets.all(Insets.md),
      child: DesktopErrorBanner(message),
    ),
  );
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
    // `attention` is the token for "the user is being asked for something",
    // which is exactly what an unmerged path is; `failure` would say the merge
    // broke, and it did not — it stopped and is waiting.
    FileChangeType.conflicted => semantic.attention,
    _ => scheme.primary,
  };
}

/// What the type glyph means, in words, for the tooltip beside it.
///
/// A conflict says **which** one it is: "both modified" and "deleted by them"
/// are two different pieces of work, and the icon alone cannot carry that.
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
