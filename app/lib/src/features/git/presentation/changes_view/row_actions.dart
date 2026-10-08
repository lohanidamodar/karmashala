// Row actions, discard confirmation and the change-type labels.

part of '../changes_view.dart';

/// Stage, unstage and discard for one row. Drawn always rather than on hover:
/// this panel is often driven by keyboard and read on a laptop trackpad, and a
/// control that appears only under the pointer cannot be found by either.
class _RowActions extends ConsumerWidget {
  const _RowActions({required this.file, required this.inStagedSection});

  final FileChange file;
  final bool inStagedSection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (file.type == FileChangeType.conflicted) {
      // A conflict is resolved in the file, then staged like anything else;
      // offering "discard" beside it invites throwing away the resolution.
      return _RowButton(
        tooltip: 'Stage the resolution',
        icon: AppIcons.plus,
        onPressed: () =>
            ref.read(workingCopyControllerProvider.notifier).stage([file.path]),
      );
    }
    final copy = ref.read(workingCopyControllerProvider.notifier);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!inStagedSection)
          _RowButton(
            tooltip: 'Discard changes',
            icon: AppIcons.arrowCounterClockwise,
            onPressed: () => confirmDiscard(context, ref, [file]),
          ),
        _RowButton(
          tooltip: inStagedSection ? 'Unstage' : 'Stage',
          icon: inStagedSection ? AppIcons.minusCircle : AppIcons.plus,
          onPressed: () => inStagedSection
              ? copy.unstage([file.path])
              : copy.stage([file.path]),
        ),
      ],
    );
  }
}

class _RowButton extends ConsumerWidget {
  const _RowButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(
      workingCopyControllerProvider.select((state) => state.isBusy),
    );
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      iconSize: Chrome.iconSmall,
      icon: Icon(icon, size: Chrome.iconSmall),
      onPressed: busy ? null : onPressed,
    );
  }
}

/// Asks before throwing work away, and says which of the two acts it is: a
/// tracked file is rewound, an untracked one is deleted and nothing brings it
/// back. Karmashala's own checkpoints do not cover an untracked file either.
Future<void> confirmDiscard(
  BuildContext context,
  WidgetRef ref,
  List<FileChange> files,
) async {
  final untracked = [
    for (final file in files)
      if (file.type == FileChangeType.untracked) file,
  ];
  final count = changedFileCount(files);
  final what = count == 1
      ? '"${p.posix.basename(files.single.path)}"'
      : '${groupedCount(count)} files';
  final confirmed = await showConfirmDialog(
    context,
    destructive: true,
    title: 'Discard changes to $what?',
    message: untracked.isEmpty
        ? 'The working-tree changes go back to the last commit. Anything not '
              'committed is lost.'
        : untracked.length == files.length
        ? 'These files are untracked, so discarding deletes them. Nothing '
              'brings them back — git has never seen them.'
        : '${groupedCount(changedFileCount(untracked))} of them are untracked '
              'and will be deleted; the '
              'rest go back to the last commit.',
    confirmLabel: 'Discard',
  );
  if (!confirmed) return;
  await ref.read(workingCopyControllerProvider.notifier).discard(files);
}

Color _colorFor(FileChangeType type, BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  final semantic = SemanticColors.of(context);
  return switch (type) {
    FileChangeType.added => semantic.diffAdded,
    FileChangeType.deleted => semantic.diffRemoved,
    // `attention`, not `failure`: an unmerged path is the user being asked for
    // something, not a merge that broke.
    FileChangeType.conflicted => semantic.attention,
    _ => scheme.primary,
  };
}

/// git's own one-letter status, which is what a reviewer's eye scans for. The
/// colour repeats it rather than carrying it (§5).
String changeLetter(FileChangeType type) => switch (type) {
  FileChangeType.added => 'A',
  FileChangeType.modified => 'M',
  FileChangeType.deleted => 'D',
  FileChangeType.renamed => 'R',
  FileChangeType.copied => 'C',
  FileChangeType.untracked => 'U',
  FileChangeType.conflicted => '!',
  FileChangeType.unknown => '?',
};

/// What the type glyph means, in words, for the tooltip — a conflict names
/// which kind, since one icon cannot carry all of them.
String changeWords(FileChange change) => switch (change.type) {
  FileChangeType.added => 'added',
  FileChangeType.modified => 'modified',
  FileChangeType.deleted => 'deleted',
  FileChangeType.renamed => 'renamed',
  FileChangeType.copied => 'copied',
  FileChangeType.untracked => 'untracked',
  FileChangeType.conflicted =>
    'conflicted — ${(change.conflict ?? MergeConflict.unrecorded).words}',
  FileChangeType.unknown => 'changed (unrecognised git status)',
};
