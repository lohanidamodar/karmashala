import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/panes.dart';
import '../../../app/shell/reveal_in_file_manager.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../editor/application/editor_tab_actions.dart';
import 'package:agent_cli/process.dart';
import '../application/file_explorer_providers.dart';
import '../application/file_tree_rows.dart';
import '../data/file_listing_service.dart';

/// How far in a row at [depth] starts. One expression for the rows and the
/// placeholders alike, because the two drifting apart reads as a ragged tree.
double _indentFor(int depth) => Insets.md + depth * Chrome.treeIndent;

/// A tree row is tighter than [Insets.xs]: at [Chrome.row] density the padding
/// is what stops two file names touching, not what separates sections.
const double _rowPadY = 3;

/// How many rows have been drawn. Test-only: the only way to pin that a reveal
/// target rebuilds the rows on the way to it and no others.
@visibleForTesting
int debugFileRowBuilds = 0;

/// A lazy file/folder tree for the selected repository, listed on the Windows
/// host. Every row right-clicks to reveal or copy; nothing starts a process.
class FileExplorerView extends ConsumerWidget {
  const FileExplorerView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final root = ref.watch(selectedRepoWindowsRootProvider);
    // The header stays in the empty state: this surface draws its own, so a bare
    // placeholder left the panel with no title and no way out but the rail glyph.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneHeader(
          icon: AppIcons.folder,
          title: 'Files',
          actions: [
            if (root != null)
              IconButton(
                tooltip: 'Refresh',
                visualDensity: VisualDensity.compact,
                icon: const Icon(AppIcons.arrowsClockwise),
                onPressed: () =>
                    ref.read(fileListingRefreshProvider.notifier).refresh(),
              ),
          ],
        ),
        Expanded(
          child: root == null
              ? const PanePlaceholder(
                  message: 'Select a repository to browse its files.',
                  icon: AppIcons.folder,
                )
              : FileTreeList(root: root),
        ),
      ],
    );
  }
}

/// The tree under [root] as one lazy list: a row is built only while it is on
/// screen, and a folder is listed only once it is opened.
class FileTreeList extends ConsumerStatefulWidget {
  const FileTreeList({required this.root, super.key});

  final String root;

  @override
  ConsumerState<FileTreeList> createState() => _FileTreeListState();
}

class _FileTreeListState extends ConsumerState<FileTreeList> {
  final _scroll = ScrollController();

  /// Held by the reveal target's row while it is built.
  final _targetRow = GlobalKey();

  /// The target already scrolled to. Scrolling once is a reveal; scrolling on
  /// every rebuild fights the reader.
  FileRevealTarget? _scrolledTo;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Puts the target on screen once its row exists in the list. Off screen it
  /// has no context, so jump by its share of the list first, then settle.
  void _followTarget(FileTreeRows rows) {
    final target = ref.read(fileRevealTargetProvider);
    if (target == null) {
      _scrolledTo = null;
      return;
    }
    if (target == _scrolledTo) return;
    final wanted = fileTreeKey(target.hostPath);
    final index = rows.items.indexWhere(
      (item) =>
          item is FileTreeEntryItem &&
          fileTreeKey(item.entry.windowsPath) == wanted,
    );
    if (index < 0) return;
    _scrolledTo = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      void settle() {
        final row = _targetRow.currentContext;
        if (row == null) return;
        Scrollable.ensureVisible(
          row,
          alignment: 0.5,
          duration: Motion.of(context).fast,
        );
      }

      if (_targetRow.currentContext == null && _scroll.hasClients) {
        final position = _scroll.position;
        final content = position.maxScrollExtent + position.viewportDimension;
        final guess =
            content * index / rows.items.length -
            position.viewportDimension / 2;
        _scroll.jumpTo(guess.clamp(0.0, position.maxScrollExtent));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) settle();
        });
        return;
      }
      settle();
    });
  }

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(fileTreeRowsProvider(widget.root));
    // Listened, not watched: a target arriving redraws the rows whose role
    // changed, never the list.
    ref.listen(fileRevealTargetProvider, (_, _) => _followTarget(rows));
    _followTarget(rows);
    return ListView.builder(
      controller: _scroll,
      // One fixed extent: without it a jump far down lays out every row on
      // the way to learn where it lands, which is the cost this list avoids.
      prototypeItem: const FileRowTile(name: '', depth: 0, isDirectory: true),
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      itemCount: rows.items.length,
      itemBuilder: (context, index) => switch (rows.items[index]) {
        final FileTreeEntryItem item => FileEntryRow(
          key: ValueKey(item.entry.windowsPath),
          entry: item.entry,
          depth: item.depth,
          targetKey: _targetRow,
        ),
        final FileTreeNoticeItem item => FileTreeNoticeRow(
          key: ValueKey('${item.folder}#notice'),
          notice: item.notice,
          depth: item.depth,
        ),
      },
    );
  }
}

/// "Loading…", "Empty", or a folder that could not be read.
class FileTreeNoticeRow extends StatelessWidget {
  const FileTreeNoticeRow({
    required this.notice,
    required this.depth,
    super.key,
  });

  final FileTreeNotice notice;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: _indentFor(depth) + Chrome.treeGutter,
        top: _rowPadY,
        bottom: _rowPadY,
      ),
      child: Text(
        switch (notice) {
          FileTreeNotice.loading => 'Loading…',
          FileTreeNotice.unreadable => "Can't read this folder.",
          FileTreeNotice.empty => 'Empty',
        },
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

/// One file or folder. Watches only its own reveal role and whether it is open.
class FileEntryRow extends ConsumerWidget {
  const FileEntryRow({
    required this.entry,
    required this.depth,
    required this.targetKey,
    super.key,
  });

  final DirEntry entry;
  final int depth;

  /// Worn while this row is the reveal target, so the list can scroll to it.
  final GlobalKey targetKey;

  /// The row's path as the rest of the app spells one — `DirEntry.windowsPath`
  /// with its owning environment put back, which is what reveal needs.
  EnvironmentPath get _path => EnvironmentPath(
    environmentId: localHostEnvironmentId,
    path: entry.windowsPath,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    debugFileRowBuilds++;
    final isDir = entry.isDirectory;
    // `select` rather than a plain watch: only the rows whose answer *changed*
    // are rebuilt when a target arrives.
    final role = ref.watch(
      fileRevealTargetProvider.select(
        (target) => fileRevealRoleFor(
          target,
          entry.windowsPath,
          isDirectory: entry.isDirectory,
        ),
      ),
    );
    final expanded =
        isDir &&
        ref.watch(
          fileTreeExpansionProvider.select(
            (open) => open.contains(fileTreeKey(entry.windowsPath)),
          ),
        );
    final selected = role == FileRevealRole.target;
    final actions = _FileEntryActions(ref, context, entry, _path);
    final row = FileRowTile(
      name: entry.name,
      depth: depth,
      isDirectory: isDir,
      expanded: expanded,
      selected: selected,
      onTap: isDir
          ? () => ref
                .read(fileTreeExpansionProvider.notifier)
                .toggle(entry.windowsPath)
          : actions.open,
    );
    // [RowContextMenu] rather than a bare right-click: with the gesture alone a
    // keyboard could reach every file and none of their actions. No `⋮` here.
    return Semantics(
      key: selected ? targetKey : null,
      selected: selected,
      child: RowContextMenu(
        menuLabel: 'Actions for ${entry.name}',
        itemBuilder: () => fileEntryMenuItems(
          isDirectory: isDir,
          // `canReveal` starts no process, so asking while building is free.
          canReveal: ref.read(revealInFileManagerProvider).canReveal(_path),
        ),
        onSelected: actions.onMenu,
        builder: (context) => row,
      ),
    );
  }
}

/// What one file or folder row draws. Pure, so the list can also measure one
/// as its prototype.
class FileRowTile extends StatelessWidget {
  const FileRowTile({
    required this.name,
    required this.depth,
    required this.isDirectory,
    this.expanded = false,
    this.selected = false,
    this.onTap,
    super.key,
  });

  final String name;
  final int depth;
  final bool isDirectory;
  final bool expanded;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected
            ? StateLayers.selected(theme.colorScheme)
            : null,
        padding: EdgeInsets.only(
          left: _indentFor(depth),
          top: _rowPadY,
          bottom: _rowPadY,
          right: Insets.sm,
        ),
        child: Row(
          children: [
            if (isDirectory)
              Icon(
                expanded ? AppIcons.caretDown : AppIcons.caretRight,
                size: Chrome.iconAction,
                color: theme.colorScheme.onSurfaceVariant,
              )
            else
              const SizedBox(width: Chrome.iconAction),
            const SizedBox(width: 2),
            Icon(
              isDirectory
                  ? (expanded ? AppIcons.folderOpen : AppIcons.folder)
                  : AppIcons.article,
              size: Chrome.iconAction,
              color: isDirectory
                  ? theme.colorScheme.tertiary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            SizedBox(width: UiDensity.of(context).glyphGap),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A file row's right-click items. Reveal only where the host can reach it.
List<PopupMenuEntry<String>> fileEntryMenuItems({
  required bool isDirectory,
  required bool canReveal,
}) => [
  if (!isDirectory)
    DesktopMenuItem(
      value: 'open',
      label: 'Open in editor',
      icon: AppIcons.fileCode,
    ),
  DesktopMenuItem(
    value: 'external',
    label: isDirectory
        ? 'Open folder in external editor'
        : 'Open in external editor',
    icon: AppIcons.arrowSquareOut,
  ),
  if (canReveal)
    DesktopMenuItem(
      value: 'reveal',
      label: isDirectory ? 'Open in File Explorer' : 'Reveal in File Explorer',
      icon: AppIcons.folderOpen,
    ),
  DesktopMenuItem(
    value: 'copy-path',
    label: 'Copy path',
    icon: AppIcons.copySimple,
  ),
];

class _FileEntryActions {
  _FileEntryActions(this.ref, this.context, this.entry, this.path);

  final WidgetRef ref;
  final BuildContext context;
  final DirEntry entry;
  final EnvironmentPath path;

  void _say(String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Opens the file in a workbench tab. The external editor is still one
  /// right-click away, for the files this one refuses.
  void open() => ref.read(editorTabActionsProvider).open(entry.windowsPath);

  Future<void> _openExternally() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(editorActionsProvider).openPath(entry.windowsPath);
      messenger.showSnackBar(
        const SnackBar(content: Text('Opening in editor…')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e is StateError ? e.message : '$e')),
      );
    }
  }

  /// Failure is a [RevealOutcome], not a throw, so a `catch` would never fire.
  Future<void> _reveal() async {
    final outcome = await ref
        .read(revealInFileManagerProvider)
        .reveal(path, select: !entry.isDirectory);
    if (!outcome.ok) _say(outcome.error!);
  }

  Future<void> _copyPath() async {
    await Clipboard.setData(ClipboardData(text: entry.windowsPath));
    _say('Path copied to clipboard');
  }

  void onMenu(String action) {
    switch (action) {
      case 'open':
        open();
      case 'external':
        _openExternally();
      case 'reveal':
        _reveal();
      case 'copy-path':
        _copyPath();
    }
  }
}
