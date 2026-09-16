import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_git/git.dart';

/// How a row's text follows a sideways scroll it does not own: the shared
/// [offset] and the width every row's text is laid out at.
@immutable
class DiffLineScroll {
  const DiffLineScroll({required this.offset, required this.width});

  final ValueListenable<double> offset;
  final double width;
}

/// One row of a unified diff — the only place one is drawn. Colour is never the
/// only signal: the verbatim `+`/`-`, a semantics label, and the tint (§5).
class DiffLineTile extends StatelessWidget {
  const DiffLineTile({
    required this.line,
    this.trailing,
    this.scroll,
    super.key,
  });

  final DiffLine line;

  /// An action at the end of the row — the Changes panel's review comment.
  /// It stays put while the text scrolls sideways under [scroll].
  final Widget? trailing;

  /// Null clips the text at the row's end.
  final DiffLineScroll? scroll;

  static const _accentWidth = 3.0;

  /// The row's own chrome beside its text, for a caller sizing a scroll.
  static const leadingExtent = _accentWidth + Insets.xs;

  static final _style = MonoStyles.body.copyWith(height: 1.4);

  /// How wide [text] is drawn in a row, with a character to spare so the last
  /// one is not flush against the edge — what a sideways scroll is sized from.
  static double textWidthOf(String text, TextScaler textScaler) {
    final painter = TextPainter(
      text: TextSpan(text: '$text ', style: _style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  /// A row's height with no trailing action: one line of [_style].
  static double lineHeightOf(TextScaler textScaler) =>
      textScaler.scale(_style.fontSize!) * _style.height!;

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

    final label = diffLineSemanticsLabel(line.kind);
    final text = Text(
      // An empty row still needs a height, and ' ' is what the diff format
      // writes for an empty context line.
      line.text.isEmpty ? ' ' : line.text,
      softWrap: false,
      overflow: TextOverflow.clip,
      maxLines: 1,
      style: MonoStyles.body.copyWith(height: _style.height, color: foreground),
    );
    final scroll = this.scroll;
    // One text line tall, so the label has a place on screen to be read at.
    final gutter = SizedBox(
      width: Insets.xs,
      height: lineHeightOf(MediaQuery.textScalerOf(context)),
    );

    return Container(
      width: double.infinity,
      // A border rather than a fixed-height bar, so the accent is as tall as
      // the row at any text scale and beside a trailing action.
      decoration: BoxDecoration(
        color: background,
        border: Border(
          left: BorderSide(
            color: accent ?? Colors.transparent,
            width: _accentWidth,
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // On the gutter rather than the text: merged into the code a screen
          // reader reads "added line" glued to the source, and an extra node
          // is one more swipe stop on every unchanged line.
          label == null ? gutter : Semantics(label: label, child: gutter),
          Expanded(child: _scrolled(text, scroll)),
          ?trailing,
        ],
      ),
    );
  }

  static Widget _scrolled(Widget text, DiffLineScroll? scroll) {
    if (scroll == null) return text;
    return UnconstrainedBox(
      alignment: Alignment.centerLeft,
      constrainedAxis: Axis.vertical,
      clipBehavior: Clip.hardEdge,
      child: ValueListenableBuilder<double>(
        valueListenable: scroll.offset,
        builder: (context, dx, child) =>
            Transform.translate(offset: Offset(-dx, 0), child: child),
        child: SizedBox(width: scroll.width, child: text),
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
