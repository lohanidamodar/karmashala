import 'package:flutter/material.dart';

import '../../../app/theme/design_tokens.dart';
import '../domain/diff_line.dart';

/// One row of a unified diff.
///
/// The **only** place a diff line is drawn. It was inlined in the Changes
/// panel; an agent's file edit needs the same picture, and two diffs that look
/// different in one app is a defect on its own — so the drawing moved here and
/// the panel kept the annotation button it wraps around it, via [trailing].
///
/// ## Colour is never the only signal
///
/// Three channels carry the same fact, so removing any one of them still leaves
/// the row readable (CLAUDE.md §5):
///
/// * the `+` / `-` / ` ` the diff format puts at the head of the text, kept
///   verbatim in a monospaced column where it lines up;
/// * a semantics label, so a screen reader announces the kind before the code;
/// * the tint and the gutter bar, for everyone reading at a glance.
class DiffLineTile extends StatelessWidget {
  const DiffLineTile({
    required this.line,
    this.wrap = false,
    this.trailing,
    super.key,
  });

  final DiffLine line;

  /// Soft-wrap long lines (a narrow side panel) instead of letting them run off
  /// the side for a horizontal scroller to catch (a full-screen read).
  final bool wrap;

  /// An action at the end of the row — the Changes panel's review comment.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = SemanticColors.of(context);
    final (Color? background, Color? foreground, Color? accent) =
        switch (line.kind) {
          DiffLineKind.added => (
            semantic.diffAdded.withValues(alpha: 0.14),
            null,
            semantic.diffAdded,
          ),
          DiffLineKind.removed => (
            semantic.diffRemoved.withValues(alpha: 0.14),
            null,
            semantic.diffRemoved,
          ),
          DiffLineKind.hunk => (
            scheme.primary.withValues(alpha: 0.10),
            scheme.primary,
            scheme.primary,
          ),
          DiffLineKind.meta => (null, scheme.onSurfaceVariant, null),
          DiffLineKind.context => (null, null, null),
        };

    final gutter = Container(
      width: 3,
      height: 18,
      color: accent ?? Colors.transparent,
    );
    final label = diffLineSemanticsLabel(line.kind);

    return Container(
      color: background,
      width: double.infinity,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The label rides on the gutter rather than on the text: merging it
          // into the code would have a screen reader read "added line" glued to
          // the source, and an empty extra node would be one more stop to swipe
          // past on every unchanged line.
          label == null ? gutter : Semantics(label: label, child: gutter),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              // An empty row still needs a height, and ' ' is also what the
              // diff format writes for an empty context line.
              line.text.isEmpty ? ' ' : line.text,
              softWrap: wrap,
              overflow: wrap ? TextOverflow.clip : TextOverflow.visible,
              maxLines: wrap ? null : 1,
              style: MonoStyles.body.copyWith(height: 1.4, color: foreground),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// What a screen reader says before the line's text, or null for a line whose
/// kind adds nothing (context, and the file headers that read as themselves).
String? diffLineSemanticsLabel(DiffLineKind kind) => switch (kind) {
  DiffLineKind.added => 'Added line',
  DiffLineKind.removed => 'Removed line',
  DiffLineKind.hunk => 'Diff position',
  DiffLineKind.meta || DiffLineKind.context => null,
};
