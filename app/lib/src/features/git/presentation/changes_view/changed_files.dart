// The changed-file list, its section headers and its empty state.

part of '../changes_view.dart';

/// The list of changed files — the only part of the panel that watches the
/// changes themselves.
class _ChangedFiles extends ConsumerStatefulWidget {
  const _ChangedFiles();

  @override
  ConsumerState<_ChangedFiles> createState() => _ChangedFilesState();
}

class _ChangedFilesState extends ConsumerState<_ChangedFiles> {
  /// New folders folded shut, keyed by section and folder.
  final _collapsed = <String>{};

  @override
  Widget build(BuildContext context) {
    return ref
        .watch(repositoryChangesProvider)
        .when(
          loading: () =>
              const Center(child: InlineSpinner(size: InlineSpinnerSize.large)),
          error: (e, _) => _NoChangesToRead(error: e),
          data: (files) => files.isEmpty
              ? const PanePlaceholder(
                  message: 'No working-tree changes.',
                  icon: AppIcons.gitDiff,
                )
              : _ordered(files),
        );
  }

  /// The same list, in review order — tiered, never filtered; git's own
  /// alphabetical order opens every review on `pubspec.lock`.
  ///
  /// Grouped the way a source-control pane groups: what is going into the next
  /// commit, then what is not. A file can be in both when part of it is
  /// staged, and it is listed in both — that is what git means by it, and one
  /// row saying "staged" would be a lie about the other half.
  Widget _ordered(List<FileChange> files) {
    final conflicts = [
      for (final file in files)
        if (file.type == FileChangeType.conflicted) file,
    ];
    final staged = [
      for (final file in files)
        if (file.staged && file.type != FileChangeType.conflicted) file,
    ];
    final unstaged = [
      for (final file in files)
        if (file.unstaged && file.type != FileChangeType.conflicted) file,
    ];
    final sections = [
      if (conflicts.isNotEmpty)
        (
          title: 'Conflicts',
          files: orderedForReview(conflicts, (f) => f.path),
          staged: false,
          conflicted: true,
        ),
      if (staged.isNotEmpty)
        (
          title: 'Staged changes',
          files: orderedForReview(staged, (f) => f.path),
          staged: true,
          conflicted: false,
        ),
      if (unstaged.isNotEmpty)
        (
          title: 'Unstaged changes',
          files: orderedForReview(unstaged, (f) => f.path),
          staged: false,
          conflicted: false,
        ),
    ];
    // One flat list of rows and headers rather than nested scrollers: a
    // sticky-per-section ListView inside a 240px panel scrolls two ways.
    final rows = <Widget>[];
    for (final section in sections) {
      rows.add(
        _SectionHeader(
          title: section.title,
          count: changedFileCount(section.files),
          files: section.files,
          staged: section.staged,
          conflicted: section.conflicted,
        ),
      );
      // A new folder sits where its first file would, its files under it.
      final folders = <String, List<FileChange>>{};
      for (final file in section.files) {
        if (file.newFolder case final folder?) {
          (folders[folder] ??= []).add(file);
        }
      }
      for (final file in section.files) {
        final folder = file.newFolder;
        if (folder == null) {
          rows.add(
            _ChangedFileRow(file: file, inStagedSection: section.staged),
          );
          continue;
        }
        final inFolder = folders.remove(folder);
        if (inFolder == null) continue;
        inFolder.sort((a, b) => a.path.compareTo(b.path));
        final key = '${section.title}|$folder';
        final open = !_collapsed.contains(key);
        rows.add(
          _NewFolderRow(
            folder: folder,
            files: inFolder,
            open: open,
            inStagedSection: section.staged,
            onToggle: () => setState(
              () => open ? _collapsed.add(key) : _collapsed.remove(key),
            ),
          ),
        );
        if (!open) continue;
        for (final child in inFolder) {
          rows.add(
            child.moreFiles > 0
                ? _MoreFilesRow(file: child)
                : _ChangedFileRow(
                    file: child,
                    inStagedSection: section.staged,
                    nestedIn: folder,
                  ),
          );
        }
      }
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      itemCount: rows.length,
      itemBuilder: (context, index) => rows[index],
    );
  }
}

/// A group's name, how many files are in it, and the two verbs that act on all
/// of them. Its own widget so the buttons repaint without the rows.
class _SectionHeader extends ConsumerWidget {
  const _SectionHeader({
    required this.title,
    required this.count,
    required this.files,
    required this.staged,
    required this.conflicted,
  });

  final String title;
  final int count;
  final List<FileChange> files;
  final bool staged;
  final bool conflicted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final busy = ref.watch(
      workingCopyControllerProvider.select((state) => state.isBusy),
    );
    final copy = ref.read(workingCopyControllerProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.sm,
        Insets.xs,
        Insets.xs,
        Insets.xxs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${title.toUpperCase()}  $count',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 0.6,
              ),
            ),
          ),
          if (!conflicted)
            IconButton(
              tooltip: staged ? 'Unstage all' : 'Stage all',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                staged ? AppIcons.minusCircle : AppIcons.plus,
                size: Chrome.iconSmall,
              ),
              onPressed: busy
                  ? null
                  : () => staged
                        ? copy.unstage([for (final f in files) f.path])
                        : copy.stage([for (final f in files) f.path]),
            ),
          if (!staged && !conflicted)
            IconButton(
              tooltip: 'Discard all changes',
              visualDensity: VisualDensity.compact,
              icon: const Icon(
                AppIcons.arrowCounterClockwise,
                size: Chrome.iconSmall,
              ),
              onPressed: busy
                  ? null
                  : () => confirmDiscard(context, ref, files),
            ),
        ],
      ),
    );
  }
}

/// What this pane says when there is no diff to draw — three things, not one.
/// [gitTroubleOf] is the single place they are told apart, so this pane and the
/// Repository pane cannot word the same failure two ways.
class _NoChangesToRead extends StatelessWidget {
  const _NoChangesToRead({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => switch (gitTroubleOf(error)) {
    // The same muted surface as "No working-tree changes." beside it, because
    // it is the same kind of statement: nothing is wrong here.
    GitTrouble.notARepository => const PanePlaceholder(
      message: notARepositoryMessage,
      icon: AppIcons.folder,
    ),
    GitTrouble.unreachable => const PanePlaceholder(
      message: gitUnreachableMessage,
      icon: AppIcons.linkBreak,
    ),
    GitTrouble.failed => DiffErrorBox(message: '$error'),
  };
}
