/// Showing what an agent changed in a file, as a diff. Feed it through
/// [FileEditCollector]: Claude records one write twice, as call and as result.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_git/git.dart';
import 'diff_line_tile.dart';

/// How many diff rows a card draws inline before it gives the diff its own
/// scrolling box. A card that fits scrolls with the transcript as one thing.
const int kFileEditInlineRows = 24;

/// Row height, fixed so the long-diff list can use `itemExtent` and build only
/// what is visible. It matches [DiffLineTile]'s 18px gutter.
const double kDiffRowHeight = 18;

/// One file an agent wrote, with its diff a click away — collapsed and
/// summarised, the same shape as the Git panel's changed-file rows.
class FileEditDiffCard extends StatefulWidget {
  const FileEditDiffCard({
    required this.record,
    this.initiallyExpanded = false,
    super.key,
  });

  final FileEditRecord record;
  final bool initiallyExpanded;

  @override
  State<FileEditDiffCard> createState() => _FileEditDiffCardState();
}

class _FileEditDiffCardState extends State<FileEditDiffCard> {
  late FileEditDiff _diff;
  late bool _expanded = widget.initiallyExpanded;

  @override
  void initState() {
    super.initState();
    _diff = buildFileEditDiff(widget.record);
  }

  @override
  void didUpdateWidget(FileEditDiffCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Diffing happens here and in [initState] and nowhere else: `build` runs on
    // every frame this card is in, and this isolate also holds a synchronous
    // database.
    if (widget.record != oldWidget.record) {
      _diff = buildFileEditDiff(widget.record);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          diff: _diff,
          expanded: _expanded,
          onToggle: () => setState(() => _expanded = !_expanded),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.xs),
            child: _Body(diff: _diff),
          ),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.diff,
    required this.expanded,
    required this.onToggle,
  });

  final FileEditDiff diff;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final name = fileEditDisplayName(diff.path);

    return InkWell(
      onTap: onToggle,
      child: Semantics(
        // One label for the whole row: otherwise a screen reader reads four
        // fragments, and "+1"/"-1" do not read aloud as anything.
        label: fileEditSemanticsLabel(diff),
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.xs,
              Insets.xs,
              Insets.xs,
              Insets.xs,
            ),
            child: Row(
              children: [
                Icon(
                  expanded ? AppIcons.caretDown : AppIcons.caretRight,
                  size: Chrome.icon,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                Icon(
                  _iconFor(diff.kind),
                  size: Touch.iconSmall,
                  color: _colorFor(diff.kind, context),
                ),
                const SizedBox(width: Insets.xs),
                // The word, not only the glyph and the colour.
                Text(diff.kind.label, style: theme.textTheme.labelSmall),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Tooltip(
                    message: diff.path,
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: MonoStyles.body,
                    ),
                  ),
                ),
                if (diff.added > 0) ...[
                  const SizedBox(width: Insets.xs),
                  Text(
                    '+${diff.added}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: semantic.diffAdded,
                    ),
                  ),
                ],
                if (diff.removed > 0) ...[
                  const SizedBox(width: Insets.xs),
                  Text(
                    '-${diff.removed}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: semantic.diffRemoved,
                    ),
                  ),
                ],
                if (diff.status == FileEditDiffStatus.ok)
                  IconButton(
                    tooltip: 'Copy diff',
                    visualDensity: VisualDensity.compact,
                    iconSize: Chrome.iconSmall,
                    constraints: const BoxConstraints(
                      minWidth: 26,
                      minHeight: 26,
                    ),
                    padding: EdgeInsets.zero,
                    icon: const Icon(AppIcons.copySimple),
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: diff.unified)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.diff});

  final FileEditDiff diff;

  @override
  Widget build(BuildContext context) {
    if (diff.status != FileEditDiffStatus.ok) {
      return _Note(text: _explain(diff));
    }

    final rows = diff.lines;
    // Long lines run off the side rather than wrapping, so every row is exactly
    // [kDiffRowHeight] tall and `itemExtent` can build only what is visible.
    final content = LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(constraints.maxWidth, 1400.0);
        if (rows.length <= kFileEditInlineRows) {
          return Scrollbar(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: width,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final line in rows) DiffLineTile(line: line),
                  ],
                ),
              ),
            ),
          );
        }
        return SizedBox(
          height: kFileEditInlineRows * kDiffRowHeight,
          child: Scrollbar(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: width,
                child: ListView.builder(
                  primary: false,
                  itemExtent: kDiffRowHeight,
                  itemCount: rows.length,
                  itemBuilder: (context, index) =>
                      DiffLineTile(line: rows[index]),
                ),
              ),
            ),
          ),
        );
      },
    );

    if (!diff.truncated) return content;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        content,
        _Note(
          text:
              'Showing the first ${diff.lines.length} of ${diff.totalLines} '
              'diff lines. Copy the diff to read the rest.',
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.xs, Insets.md, 0),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The shortest name that still identifies the file — its own, with the
/// directory above it. The full path is on the tooltip and in the semantics
/// label; every row of one session shares the same leading directories.
String fileEditDisplayName(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return path;
  return parts.last;
}

/// What a screen reader says for a file-edit row.
String fileEditSemanticsLabel(FileEditDiff diff) {
  final counts = switch (diff.status) {
    FileEditDiffStatus.ok =>
      '${diff.added} added, ${diff.removed} removed',
    FileEditDiffStatus.empty => 'no lines changed',
    FileEditDiffStatus.binary => 'binary, no line diff',
    FileEditDiffStatus.tooLarge => 'too large to diff',
  };
  return '${diff.kind.label} ${diff.path}, $counts';
}

String _explain(FileEditDiff diff) => switch (diff.status) {
  FileEditDiffStatus.ok => '',
  FileEditDiffStatus.empty =>
    'The file was written, but no line changed.',
  FileEditDiffStatus.binary =>
    'No line diff: the content is binary, so there are no lines to compare.',
  FileEditDiffStatus.tooLarge =>
    'This write is too large to diff here (${_sizeOf(diff.record)}). It was '
        'applied in full; open the file to read it.',
};

/// The bigger of the two sides, in whole kilobytes — enough to say why the
/// budget refused it without pretending to a precision nobody needs.
String _sizeOf(FileEditRecord record) {
  final bytes = math.max(
    record.oldText?.length ?? 0,
    record.newText?.length ?? 0,
  );
  return '${(bytes / 1024).round()} KB';
}

IconData _iconFor(FileEditKind kind) => switch (kind) {
  FileEditKind.created => AppIcons.plusCircle,
  FileEditKind.modified => AppIcons.pencil,
  FileEditKind.deleted => AppIcons.minusCircle,
};

Color _colorFor(FileEditKind kind, BuildContext context) {
  final semantic = SemanticColors.of(context);
  return switch (kind) {
    FileEditKind.created => semantic.diffAdded,
    FileEditKind.deleted => semantic.diffRemoved,
    FileEditKind.modified => Theme.of(context).colorScheme.primary,
  };
}
