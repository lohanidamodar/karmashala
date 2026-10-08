import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// Lines a diff draws before the rest wait behind a count.
const int kDiffTextLines = 3000;

enum DiffTextKind { meta, hunk, added, removed, context }

/// One line of a unified diff, with the old and new line numbers it has.
class DiffTextLine {
  const DiffTextLine(this.kind, this.text, {this.oldNumber, this.newNumber});

  final DiffTextKind kind;
  final String text;
  final int? oldNumber;
  final int? newNumber;
}

final _hunkHeader = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@');

/// [source] read line by line, numbered from each hunk header. A hunk ends
/// when its counts are spent, so a `---` after it is the next file's header;
/// lines outside a hunk carry no numbers.
List<DiffTextLine> parseDiffText(String source) {
  var oldLine = 0;
  var newLine = 0;
  var oldLeft = 0;
  var newLeft = 0;
  final out = <DiffTextLine>[];
  for (final line in source.split('\n')) {
    final inHunk = oldLeft > 0 || newLeft > 0;
    final hunk = _hunkHeader.firstMatch(line);
    if (hunk != null) {
      oldLine = int.parse(hunk[1]!);
      oldLeft = int.parse(hunk[2] ?? '1');
      newLine = int.parse(hunk[3]!);
      newLeft = int.parse(hunk[4] ?? '1');
      out.add(DiffTextLine(DiffTextKind.hunk, line));
    } else if (!inHunk &&
        (line.startsWith('+++') ||
            line.startsWith('---') ||
            line.startsWith('diff ') ||
            line.startsWith('index '))) {
      out.add(DiffTextLine(DiffTextKind.meta, line));
    } else if (line.startsWith('+')) {
      out.add(
        DiffTextLine(
          DiffTextKind.added,
          line,
          newNumber: inHunk ? newLine++ : null,
        ),
      );
      if (inHunk) newLeft--;
    } else if (line.startsWith('-')) {
      out.add(
        DiffTextLine(
          DiffTextKind.removed,
          line,
          oldNumber: inHunk ? oldLine++ : null,
        ),
      );
      if (inHunk) oldLeft--;
    } else if (inHunk && !line.startsWith(r'\')) {
      out.add(
        DiffTextLine(
          DiffTextKind.context,
          line,
          oldNumber: oldLine++,
          newNumber: newLine++,
        ),
      );
      oldLeft--;
      newLeft--;
    } else {
      out.add(DiffTextLine(DiffTextKind.context, line));
    }
  }
  return out;
}

/// A unified diff: each line tinted across the whole width by what it does,
/// old and new line numbers in a gutter, scrolled sideways or [wrap]ped.
class DiffText extends StatelessWidget {
  const DiffText(this.source, {this.wrap = false, super.key});

  final String source;
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    final all = parseDiffText(source);
    final lines = all.length > kDiffTextLines
        ? all.sublist(0, kDiffTextLines)
        : all;
    final scheme = Theme.of(context).colorScheme;
    final semantic = SemanticColors.of(context);
    final mono = MonoStyles.label.copyWith(color: scheme.onSurface);
    final widest = lines.fold<int>(
      0,
      (w, l) => math.max(w, math.max(l.oldNumber ?? 0, l.newNumber ?? 0)),
    );
    final numbered = widest > 0;
    final gutter = MonoStyles.label.copyWith(color: scheme.onSurfaceVariant);
    final digits = '$widest'.length;
    final scaler = MediaQuery.textScalerOf(context);
    final numberWidth = numbered
        ? (TextPainter(
                text: TextSpan(text: '8' * digits, style: gutter),
                textDirection: TextDirection.ltr,
                textScaler: scaler,
              )..layout()).width +
              Insets.sm
        : 0.0;

    Widget row(DiffTextLine line) {
      final (Color? wash, Color? accent, TextStyle style) = switch (line.kind) {
        DiffTextKind.added => (
          semantic.diffAdded.withValues(alpha: SemanticColors.diffLineAlpha),
          semantic.diffAdded,
          mono.copyWith(color: semantic.diffAdded),
        ),
        DiffTextKind.removed => (
          semantic.diffRemoved.withValues(alpha: SemanticColors.diffLineAlpha),
          semantic.diffRemoved,
          mono.copyWith(color: semantic.diffRemoved),
        ),
        DiffTextKind.hunk => (
          StateLayers.subtle(scheme),
          scheme.primary,
          mono.copyWith(color: scheme.primary),
        ),
        DiffTextKind.meta => (
          null,
          null,
          mono.copyWith(fontWeight: FontWeight.w700),
        ),
        DiffTextKind.context => (
          null,
          null,
          mono.copyWith(color: scheme.onSurfaceVariant),
        ),
      };
      Widget number(int? n) => SizedBox(
        width: numberWidth,
        child: Text(
          n == null ? '' : '$n',
          textAlign: TextAlign.right,
          style: gutter,
        ),
      );
      final text = Text(
        line.text.isEmpty ? ' ' : line.text,
        softWrap: wrap,
        style: style,
      );
      return DecoratedBox(
        decoration: BoxDecoration(
          color: wash,
          border: Border(
            left: BorderSide(
              color: accent ?? Colors.transparent,
              width: Insets.xxs,
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: wrap ? MainAxisSize.max : MainAxisSize.min,
          children: [
            if (numbered)
              SelectionContainer.disabled(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    number(line.oldNumber),
                    number(line.newNumber),
                    const SizedBox(width: Insets.sm),
                  ],
                ),
              )
            else
              const SizedBox(width: Insets.xs),
            if (wrap) Expanded(child: text) else text,
          ],
        ),
      );
    }

    final rows = [for (final line in lines) row(line)];
    final more = all.length - lines.length;
    final column = Column(
      key: const ValueKey('diff-lines'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (wrap)
          column
        else
          LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: constraints.hasBoundedWidth
                      ? constraints.maxWidth
                      : 0,
                ),
                // As wide as the longest line, so every tint reaches the
                // same right edge.
                child: IntrinsicWidth(child: column),
              ),
            ),
          ),
        if (more > 0)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Text(
              '$more more lines not shown',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}
