import 'package:flutter/material.dart';

import 'package:agent_cli/stream.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../git/presentation/diff_line_tile.dart';

/// How many rows an edit's diff draws before the reader asks for the rest.
const int kDiffCardCollapsedRows = 8;

/// Unchanged lines kept beside a change when the stretch around it is folded.
const int kDiffFoldContext = 3;

/// The most rows one edit draws even when opened; the chat is not the diff
/// viewer, and every row is a widget.
const int kDiffCardMaxRows = 400;

/// One row of a diff card: a line of the diff, or a stretch of unchanged lines
/// folded into one.
sealed class DiffCardRow {
  const DiffCardRow();
}

final class DiffShownRow extends DiffCardRow {
  const DiffShownRow(this.line);

  final DiffLine line;
}

final class DiffFoldRow extends DiffCardRow {
  const DiffFoldRow(this.lines);

  final List<DiffLine> lines;
}

/// [lines] with every unchanged stretch longer than its context folded, keeping
/// [kDiffFoldContext] lines next to each change. A stretch at the start or end
/// of a hunk has a change on one side only, so it keeps context on that side.
List<DiffCardRow> foldUnchangedLines(List<DiffLine> lines) {
  bool edge(int index) =>
      index < 0 ||
      index >= lines.length ||
      lines[index].kind == DiffLineKind.hunk ||
      lines[index].kind == DiffLineKind.meta;

  final rows = <DiffCardRow>[];
  var i = 0;
  while (i < lines.length) {
    if (lines[i].kind != DiffLineKind.context) {
      rows.add(DiffShownRow(lines[i++]));
      continue;
    }
    var end = i;
    while (end < lines.length && lines[end].kind == DiffLineKind.context) {
      end++;
    }
    final keepHead = edge(i - 1) ? 0 : kDiffFoldContext;
    final keepTail = edge(end) ? 0 : kDiffFoldContext;
    // Folding a single line costs the row it saves.
    if (end - i - keepHead - keepTail < 2) {
      for (var k = i; k < end; k++) {
        rows.add(DiffShownRow(lines[k]));
      }
    } else {
      for (var k = i; k < i + keepHead; k++) {
        rows.add(DiffShownRow(lines[k]));
      }
      rows.add(DiffFoldRow(lines.sublist(i + keepHead, end - keepTail)));
      for (var k = end - keepTail; k < end; k++) {
        rows.add(DiffShownRow(lines[k]));
      }
    }
    i = end;
  }
  return rows;
}

/// The diffs of the files one tool call wrote, drawn under its row in the
/// chat.
class ToolEditDiffCard extends StatelessWidget {
  const ToolEditDiffCard({required this.activity, super.key});

  final ToolActivity activity;

  @override
  Widget build(BuildContext context) =>
      FileEditDiffs(edits: activity.edits, truncated: activity.editsTruncated);
}

/// One section per edit in [edits], each its own collapsed diff, and a line
/// saying so when [truncated] content was cut before it got here.
class FileEditDiffs extends StatelessWidget {
  const FileEditDiffs({required this.edits, this.truncated = false, super.key});

  final List<FileEditRecord> edits;
  final bool truncated;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final edit in edits)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: _EditDiff(edit: edit),
          ),
        if (truncated)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: SelectionContainer.disabled(
              child: Text(
                'This change was cut to fit in the chat — the file has the '
                'whole of it.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _EditDiff extends StatefulWidget {
  const _EditDiff({required this.edit});

  final FileEditRecord edit;

  @override
  State<_EditDiff> createState() => _EditDiffState();
}

class _EditDiffState extends State<_EditDiff> {
  bool _expanded = false;
  final Set<int> _openFolds = {};
  FileEditDiff? _diff;
  List<DiffCardRow> _rows = const [];

  @override
  void didUpdateWidget(_EditDiff old) {
    super.didUpdateWidget(old);
    if (old.edit.path != widget.edit.path) {
      _expanded = false;
      _openFolds.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final diff = buildFileEditDiff(widget.edit);
    if (!identical(diff, _diff)) {
      _diff = diff;
      _rows = foldUnchangedLines(diff.lines);
      _openFolds.clear();
    }

    final display = <DiffCardRow>[];
    for (var i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      if (row is DiffFoldRow && _openFolds.contains(i)) {
        display.addAll(row.lines.map(DiffShownRow.new));
      } else {
        display.add(row);
      }
    }
    final limit = _expanded ? kDiffCardMaxRows : kDiffCardCollapsedRows;
    final shown = display.length > limit ? display.sublist(0, limit) : display;
    var hiddenLines = 0;
    for (final row in display.skip(shown.length)) {
      hiddenLines += row is DiffFoldRow ? row.lines.length : 1;
    }

    final String? note = switch (diff.status) {
      FileEditDiffStatus.ok => null,
      FileEditDiffStatus.empty =>
        widget.edit.kind == FileEditKind.deleted ? null : 'No line changed.',
      FileEditDiffStatus.binary => 'Not text, so there is no line diff.',
      FileEditDiffStatus.tooLarge => 'Too large to diff in the chat.',
    };

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: dark
            ? scheme.surfaceContainerLowest
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(edit: widget.edit, diff: diff),
          for (var i = 0; i < shown.length; i++)
            switch (shown[i]) {
              DiffShownRow(:final line) => DiffLineTile(line: line),
              final DiffFoldRow fold => _FoldTile(
                count: fold.lines.length,
                onOpen: () =>
                    setState(() => _openFolds.add(_rows.indexOf(fold))),
              ),
            },
          if (note != null)
            Padding(
              padding: const EdgeInsets.all(Insets.sm),
              child: Text(note, style: muted),
            ),
          if (_expanded && hiddenLines > 0 || diff.truncated)
            Padding(
              padding: const EdgeInsets.all(Insets.sm),
              child: SelectionContainer.disabled(
                child: Text(
                  'Showing the first ${diff.truncated ? diff.lines.length : shown.length} '
                  'of ${diff.totalLines} lines.',
                  style: muted,
                ),
              ),
            ),
          if (!_expanded && hiddenLines > 0 ||
              _expanded && shown.length > kDiffCardCollapsedRows)
            Align(
              alignment: Alignment.centerLeft,
              child: SelectionContainer.disabled(
                child: TextButton.icon(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(
                    _expanded ? AppIcons.caretUp : AppIcons.caretDown,
                    size: Chrome.iconSmall,
                  ),
                  label: Text(
                    _expanded
                        ? 'Less'
                        : 'Show $hiddenLines more line${hiddenLines == 1 ? '' : 's'}',
                  ),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
                    minimumSize: const Size(0, Chrome.row),
                    textStyle: theme.textTheme.labelSmall,
                    foregroundColor: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The edit's path, what happened to it in words, and its line counts.
class _Header extends StatelessWidget {
  const _Header({required this.edit, required this.diff});

  final FileEditRecord edit;
  final FileEditDiff diff;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final small = theme.textTheme.labelSmall;
    final path = switch (edit.renamedTo) {
      null => edit.path,
      final to => '${edit.path} → $to',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: Insets.xs,
      ),
      child: Row(
        children: [
          SelectionContainer.disabled(
            child: Text(
              edit.kind.label,
              style: small?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text(
              path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: MonoStyles.small.copyWith(color: scheme.onSurface),
            ),
          ),
          if (diff.added > 0 || diff.removed > 0) ...[
            const SizedBox(width: Insets.sm),
            SelectionContainer.disabled(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '+${diff.added}',
                      style: TextStyle(color: semantic.diffAdded),
                    ),
                    const TextSpan(text: ' '),
                    TextSpan(
                      text: '−${diff.removed}',
                      style: TextStyle(color: semantic.diffRemoved),
                    ),
                  ],
                ),
                style: MonoStyles.small,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FoldTile extends StatelessWidget {
  const _FoldTile({required this.count, required this.onOpen});

  final int count;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = '$count unchanged line${count == 1 ? '' : 's'}';
    return SelectionContainer.disabled(
      child: Semantics(
        button: true,
        label: 'Show $label',
        excludeSemantics: true,
        child: InkWell(
          onTap: onOpen,
          child: Container(
            color: StateLayers.subtle(scheme),
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.sm,
              vertical: Insets.hair * 2,
            ),
            child: Row(
              children: [
                Icon(
                  AppIcons.dotsThree,
                  size: Chrome.iconSmall,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Insets.sm),
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
