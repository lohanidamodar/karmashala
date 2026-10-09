import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/code.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/adaptive_modal.dart';
import '../../git/application/diff_tab_actions.dart' show diffForTargetProvider;
import '../../sessions/presentation/hunk_review.dart';
import '../application/editor_change_review.dart';
import '../application/editor_tab_actions.dart';
import '../application/review_comments.dart';

/// What the editor draws for a review: its gutter marks and the keys and taps
/// that move between changes. Null when the file has nothing to review.
typedef EditorReviewHooks = ({
  Map<int, CodeLineChange> marks,
  ValueChanged<int> onMarkTap,
  VoidCallback onNext,
  VoidCallback onPrevious,
});

/// **An agent's uncommitted changes, reviewed in the editor.** The file's
/// hunks against git are drawn in the gutter; the change at the caret gets
/// Keep and Revert — round 55's, through [HunkReviewHost] — and Comment, a
/// note sent to the session that made it. Nothing shows for a file no
/// session's checkout holds, or one with no change.
class EditorChangeReview extends ConsumerStatefulWidget {
  const EditorChangeReview({
    required this.documentId,
    required this.controller,
    required this.isDirty,
    required this.editor,
    super.key,
  });

  final String documentId;
  final CodeLineEditingController controller;

  /// Unsaved edits: Revert writes the file on disk, so it waits for them.
  final bool isDirty;

  final Widget Function(EditorReviewHooks? review) editor;

  @override
  ConsumerState<EditorChangeReview> createState() => _EditorChangeReviewState();
}

class _EditorChangeReviewState extends ConsumerState<EditorChangeReview> {
  var _hunks = const <EditorHunk>[];

  /// The change picked — by a move, a tap or the caret entering it.
  int? _current;

  /// The change the strip shows: [_current], else the caret's, else the first.
  int? _shown;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_followCaret);
  }

  @override
  void didUpdateWidget(EditorChangeReview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_followCaret);
      widget.controller.addListener(_followCaret);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_followCaret);
    super.dispose();
  }

  int get _caretLine => widget.controller.selection.extentIndex + 1;

  void _followCaret() {
    final at = hunkAtLine(_hunks, _caretLine)?.index;
    if (at != null && at != _current) setState(() => _current = at);
  }

  void _show(EditorHunk hunk) {
    setState(() => _current = hunk.index);
    final line = (hunk.startLine - 1).clamp(0, widget.controller.lineCount - 1);
    widget.controller.selection = CodeLineSelection.collapsed(
      index: line,
      offset: 0,
    );
    widget.controller.makePositionCenterIfInvisible(
      CodeLinePosition(index: line, offset: 0),
    );
  }

  /// From the change the strip shows, wrapping at either end.
  void _step(int by) {
    if (_hunks.isEmpty) return;
    final from = _hunks.indexWhere((h) => h.index == _shown);
    final at = from < 0 ? (by > 0 ? -1 : 0) : from;
    _show(_hunks[(at + by) % _hunks.length]);
  }

  Map<int, CodeLineChange> _marks(List<EditorHunk> hunks) {
    final last = widget.controller.lineCount - 1;
    final marks = <int, CodeLineChange>{};
    for (final hunk in hunks) {
      for (final line in hunk.removedAbove) {
        marks.putIfAbsent(
          (line - 1).clamp(0, last < 0 ? 0 : last),
          () => CodeLineChange.removedAbove,
        );
      }
      for (final line in hunk.addedLines) {
        marks[line - 1] = hunk.replacedLines.contains(line)
            ? CodeLineChange.modified
            : CodeLineChange.added;
      }
    }
    return marks;
  }

  @override
  Widget build(BuildContext context) {
    final target = ref.watch(editorReviewTargetProvider(widget.documentId));
    final hunks = target == null
        ? const <EditorHunk>[]
        : ref.watch(editorHunksProvider(target.diff)).value ??
              const <EditorHunk>[];
    _hunks = hunks;
    final reviewing = target != null && hunks.isNotEmpty;
    final current = !reviewing
        ? null
        : hunks.where((h) => h.index == _current).firstOrNull ??
              hunkAtLine(hunks, _caretLine) ??
              hunks.first;
    _shown = current?.index;
    // One shape whether or not there is a change to review, so the editor
    // keeps its element — its focus, caret and scroll — when hunks arrive.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (reviewing && current != null) ...[
          HunkReviewHost(
            sessionId: target.sessionId,
            gitCheckout: target.checkout,
            place: (relative) => checkoutFile(target.checkout, relative),
            openFile: (relative) => ref
                .read(editorTabActionsProvider)
                .openAt(checkoutFile(target.checkout, relative)),
            onReverted: () =>
                ref.invalidate(diffForTargetProvider(target.diff)),
            child: EditorChangeStrip(
              target: target,
              hunk: current,
              count: hunks.length,
              isDirty: widget.isDirty,
              onPrevious: () => _step(-1),
              onNext: () => _step(1),
            ),
          ),
          EditorPendingComments(target: target),
        ],
        Expanded(
          key: const ValueKey('editor-review-body'),
          child: widget.editor(
            reviewing
                ? (
                    marks: _marks(hunks),
                    onMarkTap: (index) {
                      if (hunkAtLine(hunks, index + 1) case final hunk?) {
                        _show(hunk);
                      }
                    },
                    onNext: () => _step(1),
                    onPrevious: () => _step(-1),
                  )
                : null,
          ),
        ),
      ],
    );
  }
}

/// The change at the caret: where it is, Keep, Revert and Comment, and the
/// way to the others — in this file and in the session's other files.
class EditorChangeStrip extends StatelessWidget {
  const EditorChangeStrip({
    required this.target,
    required this.hunk,
    required this.count,
    required this.isDirty,
    required this.onPrevious,
    required this.onNext,
    super.key,
  });

  final EditorReviewTarget target;
  final EditorHunk hunk;
  final int count;
  final bool isDirty;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final review = HunkReviewScope.maybeOf(context);
    final touch = UiDensity.of(context).isTouch;
    final small = theme.textTheme.labelSmall;
    final next = CodeEditorKeys.labelFor('editor.nextChange', 'Alt+F5');
    final previous = CodeEditorKeys.labelFor(
      'editor.previousChange',
      'Shift+Alt+F5',
    );
    final label = Tooltip(
      message: 'Uncommitted, by the session "${target.sessionTitle}"',
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: 'Change ${hunk.index + 1} of $count  '),
            ...diffStatSpans(
              semantic,
              added: hunk.edit.added,
              removed: hunk.edit.removed,
            ),
            TextSpan(text: '  · ${hunk.lines}'),
          ],
        ),
        key: const ValueKey('editor-review-label'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: small?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
    IconButton nav(String key, IconData icon, String tip, VoidCallback on) =>
        IconButton(
          key: ValueKey(key),
          tooltip: tip,
          visualDensity: touch ? VisualDensity.standard : VisualDensity.compact,
          iconSize: touch ? Touch.iconSmall : Chrome.iconAction,
          icon: Icon(icon),
          onPressed: on,
        );
    final moves = [
      nav(
        'editor-review-previous',
        AppIcons.caretUp,
        previous == null ? 'Previous change' : 'Previous change ($previous)',
        onPrevious,
      ),
      nav(
        'editor-review-next',
        AppIcons.caretDown,
        next == null ? 'Next change' : 'Next change ($next)',
        onNext,
      ),
      _SessionFilesButton(target: target),
    ];
    final style = TextButton.styleFrom(
      visualDensity: touch ? VisualDensity.standard : VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
      minimumSize: Size(0, touch ? Touch.target : Chrome.row),
      textStyle: small,
      foregroundColor: scheme.onSurfaceVariant,
    );
    final kept = review?.kept(hunk.edit) ?? false;
    final acts = [
      if (review != null && review.reverted(hunk.edit))
        Text(
          'Reverted',
          key: const ValueKey('editor-review-reverted'),
          style: small?.copyWith(color: scheme.onSurfaceVariant),
        )
      else if (review != null) ...[
        Tooltip(
          message: kept
              ? 'Marked as reviewed on this device'
              : 'Mark as reviewed: nothing in the file changes',
          child: TextButton.icon(
            key: const ValueKey('editor-review-keep'),
            style: style.copyWith(
              foregroundColor: WidgetStatePropertyAll(
                kept ? semantic.idle : scheme.onSurfaceVariant,
              ),
            ),
            onPressed: () => review.toggleKept(hunk.edit),
            icon: Icon(
              kept ? AppIcons.checkCircle : AppIcons.check,
              size: Chrome.iconSmall,
            ),
            label: Text(kept ? 'Kept' : 'Keep'),
          ),
        ),
        Tooltip(
          message: isDirty
              ? 'Save or reload your edits first: Revert writes the file'
              : 'Take this change out of the file',
          child: TextButton.icon(
            key: const ValueKey('editor-review-revert'),
            style: style,
            onPressed: isDirty
                ? null
                : () => review.revertHunk(context, hunk.edit),
            icon: const Icon(
              AppIcons.arrowCounterClockwise,
              size: Chrome.iconSmall,
            ),
            label: const Text('Revert'),
          ),
        ),
      ],
      Tooltip(
        message: 'A note to "${target.sessionTitle}" about these lines',
        child: TextButton.icon(
          key: const ValueKey('editor-review-comment'),
          style: style,
          onPressed: () => showReviewCommentForm(context, target, hunk),
          icon: const Icon(AppIcons.chatCircle, size: Chrome.iconSmall),
          label: const Text('Comment'),
        ),
      ),
    ];
    return Container(
      key: const ValueKey('editor-review-strip'),
      color: scheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (WidthClass.of(constraints.maxWidth).isCompact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: label),
                    ...moves,
                  ],
                ),
                Wrap(
                  spacing: Insets.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: acts,
                ),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: label),
              ...acts,
              const SizedBox(width: Insets.sm),
              ...moves,
            ],
          );
        },
      ),
    );
  }
}

/// Comments written to the session and not sent yet, with Send N comments.
class EditorPendingComments extends ConsumerStatefulWidget {
  const EditorPendingComments({required this.target, super.key});

  final EditorReviewTarget target;

  @override
  ConsumerState<EditorPendingComments> createState() =>
      _EditorPendingCommentsState();
}

class _EditorPendingCommentsState extends ConsumerState<EditorPendingComments> {
  var _sending = false;

  Future<void> _send() async {
    setState(() => _sending = true);
    await sendReviewComments(
      context,
      ref.read(reviewCommentDraftsProvider.notifier),
      widget.target,
    );
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final sessionId = widget.target.sessionId;
    final waiting = ref.watch(
      reviewCommentDraftsProvider.select((all) => all[sessionId]?.length ?? 0),
    );
    if (waiting == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final density = UiDensity.of(context).isTouch
        ? VisualDensity.standard
        : VisualDensity.compact;
    return Container(
      key: const ValueKey('editor-review-pending'),
      color: StateLayers.subtle(theme.colorScheme),
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: Insets.xs,
      ),
      child: Wrap(
        spacing: Insets.sm,
        runSpacing: Insets.xs,
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '$waiting ${waiting == 1 ? 'comment' : 'comments'} for '
            '"${widget.target.sessionTitle}", not sent yet',
            style: theme.textTheme.labelSmall,
          ),
          TextButton(
            key: const ValueKey('editor-review-discard'),
            style: TextButton.styleFrom(visualDensity: density),
            onPressed: _sending
                ? null
                : () => ref
                      .read(reviewCommentDraftsProvider.notifier)
                      .clear(sessionId),
            child: const Text('Discard'),
          ),
          FilledButton.tonal(
            key: const ValueKey('editor-review-send'),
            style: FilledButton.styleFrom(visualDensity: density),
            onPressed: _sending ? null : _send,
            child: Text(
              waiting == 1 ? 'Send 1 comment' : 'Send $waiting comments',
            ),
          ),
        ],
      ),
    );
  }
}

/// Sends [target]'s waiting comments as one message and says how it went.
Future<void> sendReviewComments(
  BuildContext context,
  ReviewCommentDrafts drafts,
  EditorReviewTarget target,
) async {
  final outcome = await drafts.send(target.sessionId);
  if (!context.mounted) return;
  final message = switch (outcome) {
    ReviewSent(count: 1) => 'Comment sent to "${target.sessionTitle}".',
    ReviewSent(:final count) =>
      '$count comments sent to "${target.sessionTitle}" as one message.',
    ReviewNotSent(:final reason) => 'Not sent: $reason',
  };
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));
}

/// Asks for a note on [hunk], to send now or keep for a batch.
Future<void> showReviewCommentForm(
  BuildContext context,
  EditorReviewTarget target,
  EditorHunk hunk,
) => showAdaptiveModal<void>(
  context: context,
  title: 'Comment on ${hunk.lines}',
  width: DialogWidth.regular,
  builder: (_) => _ReviewCommentForm(target: target, hunk: hunk),
);

class _ReviewCommentForm extends ConsumerStatefulWidget {
  const _ReviewCommentForm({required this.target, required this.hunk});

  final EditorReviewTarget target;
  final EditorHunk hunk;

  @override
  ConsumerState<_ReviewCommentForm> createState() => _ReviewCommentFormState();
}

class _ReviewCommentFormState extends ConsumerState<_ReviewCommentForm> {
  final _note = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  bool _add() {
    if (_note.text.trim().isEmpty) {
      setState(() => _error = 'Write the note first.');
      return false;
    }
    final target = widget.target;
    final hunk = widget.hunk;
    ref
        .read(reviewCommentDraftsProvider.notifier)
        .add(
          target.sessionId,
          repositoryId: target.repositoryId,
          path: target.relativePath,
          startLine: hunk.startLine,
          endLine: hunk.endLine,
          note: _note.text,
          quote: hunk.quote,
        );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final target = widget.target;
    final waiting = ref.watch(
      reviewCommentDraftsProvider.select(
        (all) => all[target.sessionId]?.length ?? 0,
      ),
    );
    final sendLabel = waiting == 0 ? 'Send' : 'Send ${waiting + 1} comments';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'In ${target.relativePath}:${widget.hunk.range}, to '
            '"${target.sessionTitle}". It goes as a message, after anything '
            'you already sent.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Insets.sm),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: Insets.xxl * 4),
            child: Container(
              padding: const EdgeInsets.all(Insets.sm),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: SingleChildScrollView(
                child: Text(
                  widget.hunk.quote,
                  key: const ValueKey('editor-review-quote'),
                  style: MonoStyles.small,
                ),
              ),
            ),
          ),
          const SizedBox(height: Insets.sm),
          TextField(
            key: const ValueKey('editor-review-note'),
            controller: _note,
            autofocus: true,
            minLines: 2,
            maxLines: 6,
            decoration: InputDecoration(
              hintText: 'This loop is wrong, use a map',
              errorText: _error,
              isDense: true,
            ),
          ),
          const SizedBox(height: Insets.sm),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: Insets.sm,
            runSpacing: Insets.xs,
            children: [
              TextButton(
                key: const ValueKey('editor-review-add'),
                onPressed: () {
                  if (_add()) Navigator.of(context).pop();
                },
                child: const Text('Add to batch'),
              ),
              FilledButton(
                key: const ValueKey('editor-review-send-now'),
                onPressed: () async {
                  if (!_add()) return;
                  final drafts = ref.read(reviewCommentDraftsProvider.notifier);
                  final navigator = Navigator.of(context);
                  final outer = navigator.context;
                  navigator.pop();
                  await sendReviewComments(outer, drafts, target);
                },
                child: Text(sendLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "Changes in this session": the session's files in this checkout, each
/// opened at its first change.
class _SessionFilesButton extends ConsumerWidget {
  const _SessionFilesButton({required this.target});

  final EditorReviewTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final touch = UiDensity.of(context).isTouch;
    return IconButton(
      key: const ValueKey('editor-review-files'),
      tooltip: 'Changes in this session',
      visualDensity: touch ? VisualDensity.standard : VisualDensity.compact,
      iconSize: touch ? Touch.iconSmall : Chrome.iconAction,
      icon: const Icon(AppIcons.listChecks),
      onPressed: () => showAdaptivePopover<void>(
        context: context,
        title: 'Changes in this session',
        builder: (_) => SessionChangesList(target: target),
      ),
    );
  }
}

/// The files [target]'s session changed, to step through.
class SessionChangesList extends ConsumerWidget {
  const SessionChangesList({required this.target, super.key});

  final EditorReviewTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final files = ref.watch(sessionReviewFilesProvider(target));
    return files.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(Insets.lg),
        child: Center(child: InlineSpinner()),
      ),
      error: (error, _) => Padding(
        padding: const EdgeInsets.all(Insets.lg),
        child: Text('$error', style: theme.textTheme.bodySmall),
      ),
      data: (files) {
        if (files.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(Insets.lg),
            child: Text(
              'No changed files in this checkout.',
              style: theme.textTheme.bodySmall,
            ),
          );
        }
        return ListView(
          key: const ValueKey('editor-review-file-list'),
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: Insets.xs),
          children: [
            for (final file in files)
              ListTile(
                key: ValueKey('editor-review-file:${file.relativePath}'),
                dense: true,
                selected: file.relativePath == target.relativePath,
                title: Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  file.relativePath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: file.added == null && file.removed == null
                    ? null
                    : Text.rich(
                        TextSpan(
                          children: diffStatSpans(
                            semantic,
                            added: file.added,
                            removed: file.removed,
                          ),
                        ),
                        style: theme.textTheme.labelSmall,
                      ),
                onTap: () {
                  Navigator.of(context).pop();
                  ref.read(editorTabActionsProvider).open(file.documentId);
                },
              ),
          ],
        );
      },
    );
  }
}
