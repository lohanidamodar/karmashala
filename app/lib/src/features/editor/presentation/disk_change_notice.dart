import 'package:agent_cli/read.dart' show FileEditKind, FileEditRecord;
import 'package:flutter/material.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/code.dart';

import '../../git/presentation/diff_line_tile.dart';
import '../domain/source_document.dart';

/// What the disk check found under a buffer, said above it without stopping
/// anyone typing. Nothing for a buffer that is [DiskState.current].
class DiskChangeNotice extends StatelessWidget {
  const DiskChangeNotice({
    required this.disk,
    required this.onReload,
    required this.onKeepMine,
    required this.onCompare,
    this.onSave,
    super.key,
  });

  final DiskState disk;
  final VoidCallback onReload;
  final VoidCallback onKeepMine;
  final VoidCallback onCompare;

  /// Null for a buffer that cannot be saved here — a read-only viewer.
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    return switch (disk) {
      DiskState.current => const SizedBox.shrink(),
      DiskState.changed => PaneNoticeBar(
        icon: AppIcons.warningCircle,
        tone: NoticeTone.attention,
        message:
            'Changed on disk. Your unsaved edits are kept until you choose.',
        action: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(onPressed: onCompare, child: const Text('Compare')),
            TextButton(onPressed: onKeepMine, child: const Text('Keep mine')),
            TextButton(
              onPressed: onReload,
              child: const Text('Reload (discard mine)'),
            ),
          ],
        ),
      ),
      DiskState.deleted => PaneNoticeBar(
        icon: AppIcons.warningCircle,
        tone: NoticeTone.attention,
        message: onSave == null
            ? 'Deleted on disk. The text is kept.'
            : 'Deleted on disk. The text is kept; saving puts the file back.',
        action: onSave == null
            ? null
            : TextButton.icon(
                onPressed: onSave,
                icon: const Icon(AppIcons.floppyDisk, size: Chrome.iconAction),
                label: const Text('Save to recreate'),
              ),
      ),
    };
  }
}

/// The file's environment stopped answering — a dropped SSH connection. Said
/// without a dialog: the buffer is kept, and a save waits for the connection.
class ConnectionLostNotice extends StatelessWidget {
  const ConnectionLostNotice({
    required this.reason,
    required this.onRetry,
    super.key,
  });

  final String reason;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: reason,
      child: PaneNoticeBar(
        icon: AppIcons.warningCircle,
        tone: NoticeTone.attention,
        message:
            'Connection lost. Your edits are kept; saving waits until it '
            'reconnects.',
        action: TextButton(onPressed: onRetry, child: const Text('Retry')),
      ),
    );
  }
}

/// The disk's text against the buffer, drawn by the same rows as a Changes
/// diff: `-` is on disk, `+` is yours.
Future<void> showDiskCompareDialog(
  BuildContext context, {
  required String name,
  required String onDisk,
  required String mine,
}) {
  final diff = buildFileEditDiff(
    FileEditRecord(
      path: name,
      kind: FileEditKind.modified,
      oldText: onDisk,
      newText: mine,
    ),
  );
  return showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final Widget body = switch (diff.status) {
        FileEditDiffStatus.ok => ListView.builder(
          itemExtent: DiffLineTile.lineHeightOf(
            MediaQuery.textScalerOf(context),
          ),
          itemCount: diff.lines.length,
          itemBuilder: (context, index) =>
              DiffLineTile(line: diff.lines[index]),
        ),
        FileEditDiffStatus.empty => const Center(
          child: Text('The text on disk is the same as yours.'),
        ),
        FileEditDiffStatus.binary => const Center(
          child: Text('The file on disk is no longer text.'),
        ),
        FileEditDiffStatus.tooLarge => const Center(
          child: Text('Too large to compare here.'),
        ),
      };
      return AlertDialog(
        title: Text('$name: on disk (−) and yours (+)'),
        content: SizedBox(
          width: 760,
          height: 480,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (diff.truncated)
                Padding(
                  padding: const EdgeInsets.only(bottom: Insets.xs),
                  child: Text(
                    'Showing the first ${diff.lines.length} of '
                    '${diff.totalLines} lines.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              Expanded(
                child: ColoredBox(
                  color: theme.colorScheme.surfaceContainerLowest,
                  child: SelectionArea(child: body),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}

/// [selection] moved inside text whose lines are [lineLengths] long: each end
/// kept on its own line and column where they still exist, pulled in where
/// they do not.
CodeLineSelection clampSelection(
  CodeLineSelection selection,
  List<int> lineLengths,
) {
  if (lineLengths.isEmpty) return const CodeLineSelection.zero();
  (int, int) clamp(int index, int offset) {
    final line = index.clamp(0, lineLengths.length - 1);
    return (line, offset.clamp(0, lineLengths[line]));
  }

  final (baseIndex, baseOffset) = clamp(
    selection.baseIndex,
    selection.baseOffset,
  );
  final (extentIndex, extentOffset) = clamp(
    selection.extentIndex,
    selection.extentOffset,
  );
  return CodeLineSelection(
    baseIndex: baseIndex,
    baseOffset: baseOffset,
    extentIndex: extentIndex,
    extentOffset: extentOffset,
    baseAffinity: selection.baseAffinity,
    extentAffinity: selection.extentAffinity,
  );
}
