import 'package:flutter/material.dart';

import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_git/git.dart';

/// One row of a unified diff — the only place one is drawn. Colour is never the
/// only signal: the verbatim `+`/`-`, a semantics label, and the tint (§5).
class DiffLineTile extends StatelessWidget {
  const DiffLineTile({
    required this.line,
    this.trailing,
    super.key,
  });

  final DiffLine line;

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
          // On the gutter rather than the text: merged into the code a screen
          // reader reads "added line" glued to the source, and an extra node
          // is one more swipe stop on every unchanged line.
          label == null ? gutter : Semantics(label: label, child: gutter),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              // An empty row still needs a height, and ' ' is what the diff
              // format writes for an empty context line.
              line.text.isEmpty ? ' ' : line.text,
              softWrap: false,
              overflow: TextOverflow.visible,
              maxLines: 1,
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
