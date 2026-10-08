import 'package:flutter/material.dart';

import 'package:agent_cli/stream.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/transcript.dart'
    show
        PathLinkCallback,
        TranscriptPathLink,
        TranscriptTargetPress,
        pathLinkStyle;
import '../../git/presentation/diff_line_tile.dart';
import 'hunk_review.dart';

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
  const ToolEditDiffCard({required this.activity, this.onPathTap, super.key});

  final ToolActivity activity;

  /// Where a tapped file name goes; null leaves the names plain.
  final PathLinkCallback? onPathTap;

  @override
  Widget build(BuildContext context) => FileEditDiffs(
    edits: activity.edits,
    truncated: activity.editsTruncated,
    onPathTap: onPathTap,
  );
}

/// One section per edit in [edits], each its own collapsed diff, and a line
/// saying so when [truncated] content was cut before it got here.
class FileEditDiffs extends StatefulWidget {
  const FileEditDiffs({
    required this.edits,
    this.truncated = false,
    this.onPathTap,
    super.key,
  });

  final List<FileEditRecord> edits;
  final bool truncated;
  final PathLinkCallback? onPathTap;

  @override
  State<FileEditDiffs> createState() => _FileEditDiffsState();
}

/// Files a change shows before the rest fold behind "Show N more files".
const int kDiffCardShownFiles = 5;

class _FileEditDiffsState extends State<FileEditDiffs> {
  bool _allFiles = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final edits = widget.edits;
    final folds = edits.length > kDiffCardShownFiles + 1 && !_allFiles;
    final shown = folds ? edits.take(kDiffCardShownFiles) : edits;
    final truncated = widget.truncated;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final edit in shown)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: _EditDiff(edit: edit, onPathTap: widget.onPathTap),
          ),
        if (folds)
          SelectionContainer.disabled(
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('diff-more-files'),
                onPressed: () => setState(() => _allFiles = true),
                icon: const Icon(AppIcons.caretDown, size: Chrome.iconSmall),
                label: Text(
                  'Show ${edits.length - kDiffCardShownFiles} more files',
                ),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: theme.textTheme.labelSmall,
                ),
              ),
            ),
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
  const _EditDiff({required this.edit, this.onPathTap});

  final FileEditRecord edit;
  final PathLinkCallback? onPathTap;

  @override
  State<_EditDiff> createState() => _EditDiffState();
}

class _EditDiffState extends State<_EditDiff> {
  bool _expanded = false;
  final Set<int> _openFolds = {};
  FileEditDiff? _diff;
  List<DiffCardRow> _rows = const [];
  List<EditHunk> _hunks = const [];

  /// Each hunk by its first changed line, which its bar sits above.
  Map<DiffLine, EditHunk> _hunkAt = const {};

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
      // Only a whole diff of a modified file can be put back a hunk at a time.
      _hunks =
          diff.status == FileEditDiffStatus.ok &&
              !diff.truncated &&
              widget.edit.kind == FileEditKind.modified
          ? diffHunks(widget.edit.path, diff.lines)
          : const [];
      _hunkAt = Map<DiffLine, EditHunk>.identity()
        ..addAll({for (final h in _hunks) diff.lines[h.firstChange]: h});
    }
    final review = _hunks.isEmpty ? null : HunkReviewScope.maybeOf(context);

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
          _Header(
            edit: widget.edit,
            diff: diff,
            onPathTap: widget.onPathTap,
            trailing: review == null
                ? null
                : RevertFileButton(
                    path: widget.edit.path,
                    hunks: _hunks,
                    review: review,
                  ),
          ),
          for (var i = 0; i < shown.length; i++)
            switch (shown[i]) {
              DiffShownRow(:final line)
                  when review != null && _hunkAt[line] != null =>
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    HunkReviewBar(hunk: _hunkAt[line]!, review: review),
                    DiffLineTile(line: line),
                  ],
                ),
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
  const _Header({
    required this.edit,
    required this.diff,
    this.onPathTap,
    this.trailing,
  });

  final FileEditRecord edit;
  final FileEditDiff diff;
  final PathLinkCallback? onPathTap;

  /// At the row's end: Revert file, where the diff can be put back.
  final Widget? trailing;

  /// The file's name, a link to its preview where taps go anywhere.
  Widget _name(String name, String path, ColorScheme scheme) {
    final style = MonoStyles.small.copyWith(color: scheme.onSurface);
    final tap = onPathTap;
    final text = Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: tap == null ? style : style.merge(pathLinkStyle(scheme)),
    );
    if (tap == null) return text;
    return TranscriptTargetPress(
      targetAt: (_) => TranscriptPathLink(path),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: const ValueKey('diff-file-link'),
          onTap: () => tap(path),
          child: text,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final small = theme.textTheme.labelSmall;
    final path = edit.renamedTo ?? edit.path;
    // The name first and whole, the folder after it and cut: an absolute
    // path ellipsised at its end loses the one part a reader looks for.
    final cut = path.lastIndexOf(RegExp(r'[\\/]')) + 1;
    final name = path.substring(cut);
    final folder = [
      if (edit.renamedTo != null) '${edit.path} →',
      if (cut > 0) path.substring(0, cut),
    ].join(' ');
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
            child: LayoutBuilder(
              builder: (context, box) => Row(
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: box.maxWidth * 0.7),
                    child: _name(name, path, scheme),
                  ),
                  // The gap gives way with the folder in a narrow header.
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: Insets.sm),
                      child: Tooltip(
                        message: edit.path,
                        child: Text(
                          folder,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: MonoStyles.small.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (diff.added > 0 || diff.removed > 0) ...[
            const SizedBox(width: Insets.sm),
            SelectionContainer.disabled(
              child: Text.rich(
                TextSpan(
                  children: diffStatSpans(
                    semantic,
                    added: diff.added,
                    removed: diff.removed,
                  ),
                ),
                style: MonoStyles.small,
              ),
            ),
          ],
          if (trailing case final trailing?) ...[
            const SizedBox(width: Insets.xs),
            SelectionContainer.disabled(child: trailing),
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
