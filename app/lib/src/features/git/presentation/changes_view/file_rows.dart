// One changed file's row, a new folder's row and the more-files row.

part of '../changes_view.dart';

/// One changed file, listed the way VS Code lists one: the name, the folder it
/// sits in, and how many lines moved. A tap reads it in a tab — the sidebar is
/// for finding a change, not for reading one through a 300px window.
class _ChangedFileRow extends ConsumerWidget {
  const _ChangedFileRow({
    required this.file,
    this.inStagedSection = false,
    this.nestedIn,
  });

  final FileChange file;

  /// The new folder this row is listed under: it is indented, and its folder
  /// is named from there.
  final String? nestedIn;

  /// Which group this row is drawn in, which is what its verbs act on: the
  /// same path can be listed twice when half of it is staged.
  final bool inStagedSection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ChangesView.debugFileRowBuildCount++;
    final scheme = Theme.of(context).colorScheme;
    // Each row asks only about itself, so a count arriving for one file does
    // not repaint the list.
    final stat = ref.watch(
      repositoryFileDiffStatsProvider.select(
        (stats) => stats.asData?.value[file.path],
      ),
    );
    // Read off the tab on screen, so closing it unhighlights the row and a
    // click on another tab's chip moves the highlight with it.
    final selected = ref.watch(
      activeDiffFileProvider.select((path) => path == file.path),
    );
    final nestedIn = this.nestedIn;
    final folder = nestedIn == null
        ? p.posix.dirname(file.path)
        : p.posix.relative(p.posix.dirname(file.path), from: nestedIn);
    return Semantics(
      selected: selected,
      child: InkWell(
        onTap: () => ref.read(diffTabActionsProvider).open(file.path),
        child: Container(
          color: selected ? StateLayers.selected(scheme) : null,
          padding: EdgeInsets.fromLTRB(
            nestedIn == null ? Insets.sm : _nestedIndent,
            Insets.tight,
            Insets.xs,
            Insets.tight,
          ),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: Text(
                        p.posix.basename(file.path),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: MonoStyles.body,
                      ),
                    ),
                    // The folder is context, not the name — dimmed, and it
                    // gives way first when the panel is dragged narrow.
                    if (folder != '.') ...[
                      const SizedBox(width: Insets.sm),
                      Flexible(
                        child: Text(
                          folder,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: MonoStyles.small.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (stat != null && !stat.isBinary) ...[
                const SizedBox(width: Insets.xs),
                DiffCountLabel(added: stat.added!, removed: stat.removed!),
              ],
              _RowActions(file: file, inStagedSection: inStagedSection),
              const SizedBox(width: Insets.sm),
              Tooltip(
                message: changeWords(file),
                child: Text(
                  changeLetter(file.type),
                  style: MonoStyles.body.copyWith(
                    color: _colorFor(file.type, context),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const _nestedIndent = Insets.sm + 18;

/// A folder git has never seen, as one row that opens onto its files — git
/// itself reports it as a single `? dir/` entry.
class _NewFolderRow extends ConsumerWidget {
  const _NewFolderRow({
    required this.folder,
    required this.files,
    required this.open,
    required this.inStagedSection,
    required this.onToggle,
  });

  final String folder;
  final List<FileChange> files;
  final bool open;
  final bool inStagedSection;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final count = changedFileCount(files);
    final copy = ref.read(workingCopyControllerProvider.notifier);
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Insets.xs,
          Insets.tight,
          Insets.xs,
          Insets.tight,
        ),
        child: Row(
          children: [
            Icon(
              open ? AppIcons.caretDown : AppIcons.caretRight,
              size: Chrome.iconSmall,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: Insets.xxs),
            Icon(
              open ? AppIcons.folderOpen : AppIcons.folder,
              size: Chrome.iconSmall,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: Insets.xs),
            Flexible(
              child: Text(
                '$folder/',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MonoStyles.body,
              ),
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(
                '${groupedCount(count)} new file${count == 1 ? '' : 's'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MonoStyles.small.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (!inStagedSection)
              _RowButton(
                tooltip: 'Discard folder',
                icon: AppIcons.arrowCounterClockwise,
                onPressed: () => confirmDiscard(context, ref, files),
              ),
            _RowButton(
              tooltip: inStagedSection ? 'Unstage folder' : 'Stage folder',
              icon: inStagedSection ? AppIcons.minusCircle : AppIcons.plus,
              onPressed: () => inStagedSection
                  ? copy.unstage(['$folder/'])
                  : copy.stage(['$folder/']),
            ),
            const SizedBox(width: Insets.sm),
            Text(
              changeLetter(FileChangeType.untracked),
              style: MonoStyles.body.copyWith(
                color: _colorFor(FileChangeType.untracked, context),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The files of a new folder past the listing limit, counted rather than
/// listed. Their folder's own row still stages and discards them.
class _MoreFilesRow extends StatelessWidget {
  const _MoreFilesRow({required this.file});

  final FileChange file;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      _nestedIndent,
      Insets.tight,
      Insets.xs,
      Insets.tight,
    ),
    child: Text(
      '${groupedCount(file.moreFiles)} more files in ${file.newFolder}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: MonoStyles.small.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontStyle: FontStyle.italic,
      ),
    ),
  );
}

/// [n] with thousands separated: `1,500`.
@visibleForTesting
String groupedCount(int n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
