import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:agent_cli/process.dart';
import '../application/changes_providers.dart';
import '../application/diff_tab_actions.dart';
import '../application/parsed_diff.dart';
import '../application/review_threads.dart';
import '../../sessions/application/session_ui_providers.dart';
import 'package:karmashala_git/git.dart';
import '../../terminal/presentation/dense_icon_button.dart';
import 'diff_line_tile.dart';

/// Renders one file's unified diff, with the review threads anchored to it.
///
/// The code scrolls sideways under a pinned column: each row's comment action
/// stays inside the pane however wide the widest line is.
class FileDiffView extends ConsumerStatefulWidget {
  const FileDiffView({
    required this.path,
    required this.checkout,
    this.repositoryId,
    super.key,
  });

  final String path;

  /// The checkout to diff [path] inside. A tab names its own, so it keeps
  /// showing the file it was opened on however the sidebar moves.
  final EnvironmentPath checkout;

  /// The repository the review threads beside this diff belong to. Null falls
  /// back to the sidebar's selection, which is the sidebar's own case.
  final String? repositoryId;

  /// The width a row's comment action takes, beside its text.
  static const commentExtent = DenseIconButton.inRow;

  @override
  ConsumerState<FileDiffView> createState() => _FileDiffViewState();
}

class _FileDiffViewState extends ConsumerState<FileDiffView> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  /// [_horizontal]'s offset, for rows that are not its scroll view.
  final _offset = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    _horizontal.addListener(_followHorizontal);
  }

  @override
  void dispose() {
    _horizontal.removeListener(_followHorizontal);
    _vertical.dispose();
    _horizontal.dispose();
    _offset.dispose();
    super.dispose();
  }

  void _followHorizontal() {
    if (_horizontal.hasClients) _offset.value = _horizontal.offset;
  }

  /// A sideways wheel, or Shift with a mouse wheel, over the code. The list
  /// itself only scrolls vertically, so it leaves these alone.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_horizontal.hasClients) return;
    final shifted =
        event.kind == PointerDeviceKind.mouse &&
        HardwareKeyboard.instance.isShiftPressed;
    final delta = shifted ? event.scrollDelta.dy : event.scrollDelta.dx;
    if (delta == 0) return;
    final position = _horizontal.position;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (_) => _horizontal.jumpTo(target),
    );
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.path;
    final repositoryId = widget.repositoryId;
    final diff = ref.watch(
      parsedDiffProvider(DiffTarget(checkout: widget.checkout, path: path)),
    );
    return diff.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(Insets.md),
        child: Center(child: InlineSpinner(size: InlineSpinnerSize.large)),
      ),
      error: (e, _) => DiffErrorBox(message: '$e'),
      data: (parsed) {
        final lines = parsed.lines;
        if (lines.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(Insets.md),
            child: Text(
              // What was observed, and no guess at why: git answers this for a
              // binary file, for one it is not tracking, and for no change.
              'git reported no textual diff for this file.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        }
        // The one translation that makes a comment anchorable: a row of this
        // rendering becomes a line of the file. A row index would not survive.
        final numbers = parsed.newLineNumbers;
        final threads =
            ref.watch(reviewThreadsOf(repositoryId)).asData?.value ??
            ReviewThreadIndex.empty;
        // Threads no line can carry, above the diff rather than lost inside it.
        final unplaced = threads.unplaced(path);
        final textScaler = MediaQuery.textScalerOf(context);

        return LayoutBuilder(
          builder: (context, box) {
            final textWidth = DiffLineTile.textWidthOf(
              parsed.widestLine,
              textScaler,
            );
            final viewport =
                box.maxWidth -
                DiffLineTile.leadingExtent -
                FileDiffView.commentExtent;
            final overflows = textWidth > viewport;
            if (!overflows && _offset.value != 0) {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _offset.value = 0,
              );
            }
            final scroll = overflows
                ? DiffLineScroll(offset: _offset, width: textWidth)
                : null;

            final list = ListView.builder(
              controller: _vertical,
              padding: const EdgeInsets.symmetric(vertical: Insets.xs),
              itemCount: unplaced.length + lines.length,
              itemBuilder: (context, index) {
                if (index < unplaced.length) {
                  return UnplacedThreadTile(
                    entry: unplaced[index],
                    repositoryId: repositoryId,
                  );
                }
                final row = index - unplaced.length;
                return ReviewableDiffLine(
                  path: path,
                  repositoryId: repositoryId,
                  lineNumber: numbers[row],
                  line: lines[row],
                  scroll: scroll,
                );
              },
            );
            // Selectable so a line can be copied out of the diff. Only realised
            // rows are in the selection, which is why the header keeps a Copy
            // that takes the whole patch regardless of what is built.
            return SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (parsed.isPartial) PartialDiffBanner(parsed: parsed),
                  Expanded(
                    child: Listener(
                      onPointerSignal: _onPointerSignal,
                      child: Scrollbar(controller: _vertical, child: list),
                    ),
                  ),
                  if (overflows)
                    Scrollbar(
                      controller: _horizontal,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _horizontal,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: textWidth + box.maxWidth - viewport,
                          height: Insets.md,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// One row of the diff, with whatever review threads land on it. [lineNumber]
/// is null for a header, hunk marker or removed line — which is why a comment
/// on a removed line becomes a file-level thread rather than a guessed anchor.
class ReviewableDiffLine extends ConsumerWidget {
  const ReviewableDiffLine({
    required this.path,
    required this.lineNumber,
    required this.line,
    this.repositoryId,
    this.scroll,
    super.key,
  });

  final String path;
  final int? lineNumber;
  final DiffLine line;

  /// See [DiffLineTile.scroll].
  final DiffLineScroll? scroll;

  /// See [FileDiffView.repositoryId]; the sidebar is the only caller that
  /// leaves it null.
  final String? repositoryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final repository = repositoryId ?? ref.watch(selectedRepositoryIdProvider);
    final index =
        ref.watch(reviewThreadsOf(repositoryId)).asData?.value ??
        ReviewThreadIndex.empty;
    // Attached threads only: `atLine` will not return one whose file has moved
    // on. Those are drawn above the diff instead.
    final here = lineNumber == null
        ? const <AnchoredReviewThread>[]
        : index.atLine(path, lineNumber!);
    // The drawing lives in the shared `DiffLineTile`; only the review comment
    // hung off the row's end is this panel's.
    final commentable =
        line.kind == DiffLineKind.added ||
        line.kind == DiffLineKind.removed ||
        line.kind == DiffLineKind.context;
    return DiffLineTile(
      line: line,
      scroll: scroll,
      // A blank of the same width on a row with nothing to comment on, so every
      // row's text scrolls against the same edge.
      trailing: commentable
          ? DenseIconButton(
              tooltip: here.isEmpty
                  ? 'Add review comment'
                  : here.map((entry) => entry.thread.body).join('\n\n'),
              icon: Icon(
                here.isEmpty ? AppIcons.chatCircle : AppIcons.chatCircleDots,
                size: Chrome.iconAction,
                color: here.isEmpty ? null : scheme.tertiary,
              ),
              onPressed: repository == null
                  ? null
                  : () => showReviewThreadDialog(
                      context,
                      repositoryId: repository,
                      path: path,
                      // Null for a removed line, which opens a file-level
                      // thread quoting the removed text.
                      lineNumber: lineNumber,
                      excerpt: line.text,
                      existing: here,
                    ),
            )
          : const SizedBox(width: DenseIconButton.inRow),
    );
  }
}

/// A thread no line of this diff can carry — file-level, or detached by an
/// edit — given a row above the diff because saying so takes a sentence.
class UnplacedThreadTile extends ConsumerWidget {
  const UnplacedThreadTile({required this.entry, this.repositoryId, super.key});

  final AnchoredReviewThread entry;

  /// See [FileDiffView.repositoryId].
  final String? repositoryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final repository = repositoryId ?? ref.watch(selectedRepositoryIdProvider);
    final detached = !entry.isAttached;
    return InkWell(
      onTap: repository == null
          ? null
          : () => showReviewThreadDialog(
              context,
              repositoryId: repository,
              path: entry.anchor.path,
              lineNumber: null,
              excerpt: null,
              existing: [entry],
            ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Insets.sm,
          Insets.xs,
          Insets.sm,
          Insets.xs,
        ),
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

/// The sentence a thread wears above the diff. A detached thread says "was at
/// …": the bare location would be read as where it is now.
String detachedThreadHeadline(AnchoredReviewThread entry) {
  final status = entry.thread.status.label;
  return switch (entry.attachment) {
    ReviewThreadAttachment.attached => '${entry.anchor.location} · $status',
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

  /// Which thread the composer is answering, or null for a new one — a reply
  /// and a new comment on the same line are different acts.
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
        ref.watch(reviewThreadsOf(widget.repositoryId)).asData?.value ??
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

  /// What the composer will actually do. The removed-line case is spelled out
  /// because that click cannot get what it implied: a comment on the line.
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

/// Says, above a diff that was cut short, that it was cut short.
///
/// A view that stopped at its row limit and drew nothing about it would read
/// as the whole change — and the reader would come away believing they had
/// reviewed it. This is the same rule the repository's own guide states about
/// commands: say plainly what you could not show, in as much detail as what
/// you could. The `+N −M` in the header is still the count for the **whole**
/// patch, which the banner says, because two numbers that disagree with the
/// rows under them are worse than one explained number.
class PartialDiffBanner extends StatelessWidget {
  const PartialDiffBanner({required this.parsed, super.key});

  final ParsedDiff parsed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.sm,
      ),
      decoration: BoxDecoration(
        color: semantic.attention.withValues(alpha: 0.12),
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            AppIcons.warning,
            size: Chrome.iconSmall,
            color: semantic.attention,
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'Partial diff. ',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: semantic.attention,
                    ),
                  ),
                  TextSpan(
                    text:
                        'Showing the first ${parsed.lines.length} of '
                        '${parsed.totalLines} lines — ${parsed.omittedLines} '
                        'are not drawn. The +/− count is for the whole patch, '
                        'so what you can read here is not proof that you have '
                        'seen the complete change. Copy diff takes all of it.',
                  ),
                ],
              ),
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// The house error box, hung at the top of whatever pane it fills rather than
/// stretched down it.
class DiffErrorBox extends StatelessWidget {
  const DiffErrorBox({required this.message, super.key});
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
