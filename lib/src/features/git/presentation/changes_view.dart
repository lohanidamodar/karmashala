import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_dialog.dart';
import '../../sessions/application/delivery_providers.dart';
import '../application/changes_providers.dart';
import '../application/review_threads.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../data/git_diff_parsing.dart';
import 'diff_line_tile.dart';
import 'remote_link.dart';
import '../domain/diff_line.dart';
import '../domain/review_thread.dart';
import '../domain/file_change.dart';

/// Read-only Git change review, desktop-style: a vertical list of changed files,
/// each expandable to reveal its unified diff inline, and openable full-screen
/// for a wide, scrollable read. Git is the source of truth; there is no editor.
class ChangesView extends ConsumerStatefulWidget {
  const ChangesView({required this.repositoryName, super.key});

  final String repositoryName;

  @override
  ConsumerState<ChangesView> createState() => _ChangesViewState();
}

class _ChangesViewState extends ConsumerState<ChangesView> {
  final _expanded = <String>{};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final changes = ref.watch(repositoryChangesProvider);
    final repositoryId = ref.watch(selectedRepositoryIdProvider);
    final sessionId = ref.watch(selectedSessionIdProvider);
    // One read for the whole panel; every line tile below picks its threads
    // out of this index rather than asking the database for its own.
    final threads =
        ref.watch(repositoryReviewThreadsProvider).asData?.value ??
        ReviewThreadIndex.empty;
    final pending = threads.pending;

    // What this repository's work is called on the forge, so a branch, a
    // commit or a pull request in view is one click from the page that owns it.
    final delivery = repositoryId == null
        ? null
        : ref.watch(repositoryDeliveryProvider(repositoryId)).asData?.value;
    final head = ref.watch(recentCommitsProvider).asData?.value.firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneHeader(
          icon: AppIcons.gitDiff,
          title: 'Changes',
          actions: [
            // Flexible, so a long branch name in a narrow panel ellipsises
            // rather than overflowing — this header sits in a side panel that
            // can be dragged down to 240px.
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (delivery?.branch case final branch?) ...[
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
                        // Drawn plainly when there is no remote — a commit
                        // without one is still a commit.
                        url: delivery?.remote?.commitUrl(head.sha),
                        style: theme.textTheme.labelSmall,
                        tooltip: head.subject,
                      ),
                    ),
                  ],
                  if (delivery?.pullRequest case final pr?) ...[
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
              ),
            ),
            changes.maybeWhen(
              data: (files) => files.isEmpty
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(right: Insets.xs),
                      child: Text(
                        '${files.length}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
              orElse: () => const SizedBox.shrink(),
            ),
            IconButton(
              tooltip: 'Refresh',
              visualDensity: VisualDensity.compact,
              icon: const Icon(AppIcons.arrowsClockwise, size: Chrome.icon),
              onPressed: () => ref.invalidate(repositoryChangesProvider),
            ),
            if (pending.isNotEmpty)
              IconButton(
                // "Should fix", not "every comment": a thread nobody has
                // triaged is a claim, and sending it would hand an agent work
                // no human asked for.
                tooltip: sessionId == null
                    ? 'Select a session to send ${pending.length} review '
                          'comments marked should-fix'
                    : 'Send ${pending.length} should-fix review comments to '
                          'the agent',
                icon: Badge(
                  label: Text('${pending.length}'),
                  child: const Icon(AppIcons.chatCircleDots, size: Chrome.icon),
                ),
                onPressed: sessionId == null || repositoryId == null
                    ? null
                    : () async {
                        // Nothing is cleared, marked or resolved by sending.
                        // The thread stays should-fix until somebody looks at
                        // the code and decides it is done — which is the whole
                        // reason these are rows now. See
                        // `buildReviewThreadPrompt`.
                        await ref
                            .read(sessionActionsProvider)
                            .continueSession(
                              sessionId,
                              buildReviewThreadPrompt(pending),
                            );
                      },
              ),
          ],
        ),
        Expanded(
          child: changes.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => _ErrorBox(message: '$e'),
            data: (files) => files.isEmpty
                ? const PanePlaceholder(
                    message: 'No working-tree changes.',
                    icon: AppIcons.gitDiff,
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: Insets.xs),
                    itemCount: files.length,
                    itemBuilder: (context, index) {
                      final file = files[index];
                      return _ChangedFileSection(
                        file: file,
                        expanded: _expanded.contains(file.path),
                        onToggle: () => setState(() {
                          if (!_expanded.remove(file.path)) {
                            _expanded.add(file.path);
                          }
                        }),
                        onFullscreen: () => _openFullscreen(context, file),
                      );
                    },
                  ),
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
                Icon(
                  _iconFor(file.type),
                  size: Chrome.iconAction,
                  color: _colorFor(file.type, context),
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
  _ => AppIcons.pencil,
};

Color _colorFor(FileChangeType type, BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  final semantic = SemanticColors.of(context);
  return switch (type) {
    FileChangeType.added => semantic.diffAdded,
    FileChangeType.deleted => semantic.diffRemoved,
    _ => scheme.primary,
  };
}
