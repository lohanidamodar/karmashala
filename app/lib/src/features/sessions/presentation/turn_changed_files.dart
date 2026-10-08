import 'package:flutter/material.dart';

import 'package:agent_cli/stream.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/primitives.dart';
import 'chat_transcript.dart';
import 'tool_edit_diff_card.dart';
import 'tool_run.dart';

/// One file a turn wrote, with every edit it made to it in order.
class TurnFileChange {
  const TurnFileChange({
    required this.path,
    required this.kind,
    required this.edits,
    required this.added,
    required this.removed,
    this.truncated = false,
  });

  final String path;
  final FileEditKind kind;
  final List<FileEditRecord> edits;
  final int added;
  final int removed;

  /// Whether any of [edits] lost content to the bound.
  final bool truncated;
}

/// The files written in [row]'s turn, when [row] is the turn's last run of tool
/// calls and the turn wrote any; otherwise null. A turn runs from the message
/// after the person's last one to the next of theirs.
///
/// Read off the calls' own [ToolActivity.edits], so it costs no read; a turn
/// that started before the loaded window counts only what is loaded.
List<TurnFileChange>? turnChangedFiles(
  List<ChatMessage> messages,
  TranscriptRow row,
) {
  for (var k = row.to; k < messages.length; k++) {
    if (messages[k].role == 'user') break;
    if (isToolRunMember(messages[k])) return null;
  }
  var start = row.from;
  while (start > 0 && messages[start - 1].role != 'user') {
    start--;
  }

  final byPath = <String, List<FileEditRecord>>{};
  final kinds = <String, FileEditKind>{};
  final cut = <String>{};
  for (var k = start; k < row.to; k++) {
    final tool = messages[k].tool;
    if (tool == null) continue;
    for (final edit in tool.edits) {
      (byPath[edit.path] ??= []).add(edit);
      final known = kinds[edit.path];
      // The strongest claim wins: created stays created however often it is
      // edited after, and deleted stays deleted.
      if (known == null || _rank(edit.kind) >= _rank(known)) {
        kinds[edit.path] = edit.kind;
      }
      if (tool.editsTruncated) cut.add(edit.path);
    }
  }
  if (byPath.isEmpty) return null;
  return [
    for (final MapEntry(key: path, value: edits) in byPath.entries)
      _change(path, kinds[path]!, edits, truncated: cut.contains(path)),
  ];
}

TurnFileChange _change(
  String path,
  FileEditKind kind,
  List<FileEditRecord> edits, {
  required bool truncated,
}) {
  var added = 0;
  var removed = 0;
  for (final edit in edits) {
    final diff = buildFileEditDiff(edit);
    added += diff.added;
    removed += diff.removed;
  }
  return TurnFileChange(
    path: path,
    kind: kind,
    edits: edits,
    added: added,
    removed: removed,
    truncated: truncated,
  );
}

int _rank(FileEditKind kind) => switch (kind) {
  FileEditKind.modified => 0,
  FileEditKind.created => 1,
  FileEditKind.deleted => 2,
};

/// `2 files changed  +14 −3` at the end of a turn's tool calls, opening into
/// each file's diffs. Draws nothing for a run that is not the end of a turn
/// that wrote files.
class TurnChangedFilesLine extends StatefulWidget {
  const TurnChangedFilesLine({required this.files, super.key});

  final List<TurnFileChange> files;

  @override
  State<TurnChangedFilesLine> createState() => _TurnChangedFilesLineState();
}

class _TurnChangedFilesLineState extends State<TurnChangedFilesLine> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final files = widget.files;
    var added = 0;
    var removed = 0;
    for (final file in files) {
      added += file.added;
      removed += file.removed;
    }
    final label = '${files.length} file${files.length == 1 ? '' : 's'} changed';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SelectionContainer.disabled(
          child: Semantics(
            button: true,
            expanded: _open,
            label: '$label, $added added, $removed removed',
            excludeSemantics: true,
            child: InkWell(
              onTap: () => setState(() => _open = !_open),
              hoverColor: SurfaceTones.of(context).hover,
              borderRadius: BorderRadius.circular(Radii.sm),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: UiDensity.of(context).isTouch
                      ? Touch.target
                      : Chrome.row,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
                  child: Row(
                    children: [
                      Icon(
                        _open ? AppIcons.caretDown : AppIcons.caretRight,
                        size: Chrome.iconSmall,
                        color: muted?.color,
                      ),
                      const SizedBox(width: Insets.sm),
                      Icon(
                        AppIcons.gitDiff,
                        size: Chrome.iconSmall,
                        color: muted?.color,
                      ),
                      const SizedBox(width: Insets.xs),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muted,
                        ),
                      ),
                      const SizedBox(width: Insets.sm),
                      Text.rich(
                        TextSpan(
                          children: diffStatSpans(
                            semantic,
                            added: added,
                            removed: removed,
                          ),
                        ),
                        style: MonoStyles.small,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(left: Insets.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final file in files)
                  FileEditDiffs(edits: file.edits, truncated: file.truncated),
              ],
            ),
          ),
      ],
    );
  }
}
