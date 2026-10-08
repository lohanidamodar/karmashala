import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart' show showConfirmDialog;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/hunk_review_marks.dart';
import '../application/hunk_reverts.dart';

export '../application/diff_hunks.dart' show EditHunk, diffHunks;

/// [relative], a path git names inside [checkout], on the checkout's machine,
/// spelled with its separators.
EnvironmentPath checkoutFile(EnvironmentPath checkout, String relative) {
  final root = checkout.path;
  final windows = root.contains(r'\') || RegExp(r'^[A-Za-z]:').hasMatch(root);
  final sep = windows ? r'\' : '/';
  final rel = windows ? relative.replaceAll('/', r'\') : relative;
  final trimmed = root.endsWith(sep)
      ? root.substring(0, root.length - 1)
      : root;
  return EnvironmentPath(
    environmentId: checkout.environmentId,
    path: '$trimmed$sep$rel',
  );
}

/// What a diff's hunk controls do, handed down by the view showing the diff.
/// Without one in scope a diff draws no Keep or Revert.
abstract interface class HunkReview {
  bool kept(EditHunk hunk);
  void toggleKept(EditHunk hunk);
  bool reverted(EditHunk hunk);
  Future<void> revertHunk(BuildContext context, EditHunk hunk);

  /// Every hunk of the file at [path], after a confirm.
  Future<void> revertFile(
    BuildContext context,
    String path,
    List<EditHunk> hunks,
  );
}

class HunkReviewScope extends InheritedWidget {
  const HunkReviewScope({
    required this.review,
    required this.revision,
    required super.child,
    super.key,
  });

  final HunkReview review;

  /// Moves whenever a mark or a revert does, so the diffs redraw.
  final Object revision;

  static HunkReview? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HunkReviewScope>()?.review;

  @override
  bool updateShouldNotify(HunkReviewScope oldWidget) =>
      revision != oldWidget.revision || review != oldWidget.review;
}

/// **Keep or revert an agent's change, per hunk**, for one session's diffs
/// below it. Revert goes through [hunkRevertsProvider] — a checkpoint first,
/// then the server's files ops — and Keep is a mark on this device.
class HunkReviewHost extends ConsumerStatefulWidget {
  const HunkReviewHost({
    required this.sessionId,
    required this.place,
    required this.openFile,
    required this.child,
    this.gitCheckout,
    this.onReverted,
    super.key,
  });

  final String sessionId;

  /// Where a diff's path is on the session's machine; null when unknown.
  final EnvironmentPath? Function(String path) place;

  /// Opens the file at a diff's path, offered when a hunk no longer applies.
  final void Function(String path) openFile;

  /// The checkout a git diff is of: Revert file then puts the file back to
  /// git's, rather than undoing one turn's change.
  final EnvironmentPath? gitCheckout;

  /// Told after anything was put back, for a view to read its diff again.
  final VoidCallback? onReverted;

  final Widget child;

  @override
  ConsumerState<HunkReviewHost> createState() => _HunkReviewHostState();
}

class _HunkReviewHostState extends ConsumerState<HunkReviewHost>
    implements HunkReview {
  /// Put back in this view's life: the record still shows the change.
  final _reverted = <String>{};

  @override
  bool kept(EditHunk hunk) => ref
      .read(hunkReviewMarksProvider.notifier)
      .kept(widget.sessionId, hunk.key);

  @override
  void toggleKept(EditHunk hunk) => ref
      .read(hunkReviewMarksProvider.notifier)
      .toggle(widget.sessionId, hunk.key);

  @override
  bool reverted(EditHunk hunk) => _reverted.contains(hunk.key);

  void _say(BuildContext context, String message) => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));

  Future<void> _settle(
    BuildContext context,
    RevertOutcome outcome,
    String path,
    List<EditHunk> hunks,
  ) async {
    switch (outcome) {
      case Reverted():
        setState(() => _reverted.addAll(hunks.map((h) => h.key)));
        widget.onReverted?.call();
        _say(
          context,
          'Put back. Checkpoints holds the file as it was: undo it there.',
        );
      case RevertFailed(:final reason):
        _say(context, reason);
      case RevertConflict(:final reason):
        final open = await showConfirmDialog(
          context,
          title: 'This change no longer applies',
          message: '$reason Nothing was changed.',
          confirmLabel: 'Open file',
          cancelLabel: 'Close',
        );
        if (open) widget.openFile(path);
    }
  }

  @override
  Future<void> revertHunk(BuildContext context, EditHunk hunk) async {
    final file = widget.place(hunk.path);
    if (file == null) {
      _say(context, 'Karmashala has no record of where ${hunk.path} is.');
      return;
    }
    final outcome = await ref
        .read(hunkRevertsProvider)
        .revert(sessionId: widget.sessionId, file: file, hunks: [hunk]);
    if (context.mounted) await _settle(context, outcome, hunk.path, [hunk]);
  }

  @override
  Future<void> revertFile(
    BuildContext context,
    String path,
    List<EditHunk> hunks,
  ) async {
    final name =
        path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).lastOrNull ??
        path;
    final checkout = widget.gitCheckout;
    final go = await showConfirmDialog(
      context,
      title: 'Revert $name?',
      message: checkout != null
          ? 'Every uncommitted change to $name is put back to what git has. '
                'A checkpoint is taken first, so it can be undone from '
                'Checkpoints.'
          : 'Every change in this diff is taken out of $name. A checkpoint is '
                'taken first, so it can be undone from Checkpoints.',
      confirmLabel: 'Revert file',
      destructive: true,
    );
    if (!go || !context.mounted) return;
    final reverts = ref.read(hunkRevertsProvider);
    final RevertOutcome outcome;
    if (checkout != null) {
      outcome = await reverts.revertToGit(
        sessionId: widget.sessionId,
        checkout: checkout,
        path: path,
      );
    } else {
      final file = widget.place(path);
      if (file == null) {
        _say(context, 'Karmashala has no record of where $path is.');
        return;
      }
      outcome = await reverts.revert(
        sessionId: widget.sessionId,
        file: file,
        hunks: hunks,
      );
    }
    if (context.mounted) await _settle(context, outcome, path, hunks);
  }

  @override
  Widget build(BuildContext context) {
    final marks = ref.watch(
      hunkReviewMarksProvider.select((all) => all[widget.sessionId]),
    );
    return HunkReviewScope(
      review: this,
      revision: (marks, _reverted.length),
      child: widget.child,
    );
  }
}

/// One hunk's line above its first change: what it changed, Keep — a mark
/// that it was reviewed — and Revert, or that it was put back.
class HunkReviewBar extends StatelessWidget {
  const HunkReviewBar({required this.hunk, required this.review, super.key});

  final EditHunk hunk;
  final HunkReview review;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final touch = UiDensity.of(context).isTouch;
    final kept = review.kept(hunk);
    final reverted = review.reverted(hunk);
    final small = theme.textTheme.labelSmall;
    final style = TextButton.styleFrom(
      visualDensity: touch ? VisualDensity.standard : VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
      minimumSize: Size(0, touch ? Touch.target : Chrome.row),
      textStyle: small,
    );
    return SelectionContainer.disabled(
      child: Container(
        key: ValueKey('hunk-bar-${hunk.index}'),
        color: kept ? StateLayers.subtle(scheme) : null,
        padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
        child: Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: 'Change ${hunk.index + 1}  '),
                    TextSpan(
                      text: '+${hunk.added}',
                      style: TextStyle(color: semantic.diffAdded),
                    ),
                    const TextSpan(text: ' '),
                    TextSpan(
                      text: '−${hunk.removed}',
                      style: TextStyle(color: semantic.diffRemoved),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: small?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            if (reverted)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Insets.xs),
                child: Text(
                  'Reverted',
                  key: const ValueKey('hunk-reverted'),
                  style: small?.copyWith(color: scheme.onSurfaceVariant),
                ),
              )
            else ...[
              Tooltip(
                message: kept
                    ? 'Marked as reviewed on this device'
                    : 'Mark as reviewed: nothing in the file changes',
                child: TextButton.icon(
                  key: const ValueKey('hunk-keep'),
                  style: style.copyWith(
                    foregroundColor: WidgetStatePropertyAll(
                      kept ? semantic.idle : scheme.onSurfaceVariant,
                    ),
                  ),
                  onPressed: () => review.toggleKept(hunk),
                  icon: Icon(
                    kept ? AppIcons.checkCircle : AppIcons.check,
                    size: Chrome.iconSmall,
                  ),
                  label: Text(kept ? 'Kept' : 'Keep'),
                ),
              ),
              Tooltip(
                message: 'Take this change out of the file',
                child: TextButton.icon(
                  key: const ValueKey('hunk-revert'),
                  style: style.copyWith(
                    foregroundColor: WidgetStatePropertyAll(
                      scheme.onSurfaceVariant,
                    ),
                  ),
                  onPressed: () => review.revertHunk(context, hunk),
                  icon: const Icon(
                    AppIcons.arrowCounterClockwise,
                    size: Chrome.iconSmall,
                  ),
                  label: const Text('Revert'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A file's Revert file, beside its name in a diff's header.
class RevertFileButton extends StatelessWidget {
  const RevertFileButton({
    required this.path,
    required this.hunks,
    required this.review,
    super.key,
  });

  final String path;
  final List<EditHunk> hunks;
  final HunkReview review;

  @override
  Widget build(BuildContext context) {
    final touch = UiDensity.of(context).isTouch;
    final floor = touch ? Touch.target : Insets.xl;
    return IconButton(
      key: const ValueKey('hunk-revert-file'),
      tooltip: 'Revert file',
      visualDensity: touch ? VisualDensity.standard : VisualDensity.compact,
      iconSize: touch ? Touch.icon : Chrome.iconSmall,
      constraints: BoxConstraints(minWidth: floor, minHeight: floor),
      padding: EdgeInsets.zero,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      icon: const Icon(AppIcons.arrowCounterClockwise),
      onPressed: () => review.revertFile(context, path, hunks),
    );
  }
}
