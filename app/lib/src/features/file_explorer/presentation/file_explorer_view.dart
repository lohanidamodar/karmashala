import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../editor/application/editor_tab_actions.dart';
import '../../files/application/server_file_opening.dart';
import '../../files/data/files_client.dart';
import '../../files/presentation/file_delete.dart';
import 'package:karmashala_ui/picking.dart' show FileNameDialog;
import '../../terminal/application/dropped_paths.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_files/values.dart';
import '../application/file_explorer_providers.dart';
import '../application/file_tree_rows.dart';

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

/// A lazy file/folder tree for the selected repository, listed by the server
/// wherever the repository is. Every row right-clicks to reveal or copy.
/// Nothing here reads a disk.
class FileExplorerView extends ConsumerWidget {
  const FileExplorerView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final root = ref.watch(fileTreeRootProvider);
    // The header stays in the empty state: this surface draws its own, so a bare
    // placeholder left the panel with no title and no way out.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneHeader(
          icon: AppIcons.folder,
          title: 'Files',
          actions: [
            if (root != null) ...[
              IconButton(
                tooltip: 'New file',
                visualDensity: VisualDensity.compact,
                icon: const Icon(AppIcons.filePlus),
                onPressed: () =>
                    createInFileTree(context, ref, root, folder: false),
              ),
              IconButton(
                tooltip: 'New folder',
                visualDensity: VisualDensity.compact,
                icon: const Icon(AppIcons.folderPlus),
                onPressed: () =>
                    createInFileTree(context, ref, root, folder: true),
              ),
            ],
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

  final EnvironmentPath root;

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
  void initState() {
    super.initState();
    // The tree follows the file being edited — only while it is on screen,
    // which is what this state's lifetime is, and only for a file under its
    // own folder: one elsewhere is not a statement about this tree.
    ref.listenManual<EnvironmentPath?>(activeEditorPathProvider, (_, path) {
      if (path == null || !isUnderFileTreeRoot(widget.root, path)) return;
      final target = FileRevealTarget(path: path, isDirectory: false);
      // After the build: the first call comes from initState itself, where a
      // provider may not be written.
      Future.microtask(() {
        if (!mounted || ref.read(fileRevealTargetProvider) == target) return;
        ref.read(fileRevealTargetProvider.notifier).reveal(target);
      });
    }, fireImmediately: true);
  }

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
    final wanted = fileTreeKey(target.path);
    final index = rows.items.indexWhere(
      (item) =>
          item is FileTreeEntryItem && fileTreeKey(item.entry.path) == wanted,
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
          key: ValueKey(item.entry.path),
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

  final FileEntry entry;
  final int depth;

  /// Worn while this row is the reveal target, so the list can scroll to it.
  final GlobalKey targetKey;

  EnvironmentPath get _path => entry.path;

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
          entry.path,
          isDirectory: entry.isDirectory,
        ),
      ),
    );
    final expanded =
        isDir &&
        ref.watch(
          fileTreeExpansionProvider.select(
            (open) => open.contains(fileTreeKey(entry.path)),
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
          ? () => ref.read(fileTreeExpansionProvider.notifier).toggle(_path)
          : actions.open,
    );
    // A file this machine spells the same way the server does — the server
    // runs here and the file is on its own disk — can be dropped on a pane
    // as that path. Anywhere else there is nothing of it here to paste.
    final files = ref.read(filesClientProvider);
    final dragged =
        files.canOpenHere(_path) && !_path.environmentId.startsWith('wsl:')
        ? _path.path
        : null;
    final opening = ref.read(serverFileOpeningProvider);
    // [RowContextMenu] rather than a bare right-click: with the gesture alone a
    // keyboard could reach every file and none of their actions. No `⋮` here.
    return Semantics(
      key: selected ? targetKey : null,
      selected: selected,
      child: RowContextMenu(
        menuLabel: 'Actions for ${entry.name}',
        itemBuilder: () => fileEntryMenuItems(
          isDirectory: isDir,
          name: entry.name,
          // Neither starts a process, so asking while building is free.
          canReveal: opening.canReveal(_path),
          canOpen: opening.canOpen,
          canDelete: true,
        ),
        onSelected: actions.onMenu,
        // Dropped on a session's pane, it pastes the path — what dragging the
        // same file in from the OS does.
        builder: (context) => dragged == null
            ? row
            : Draggable<HostPathDrag>(
                data: HostPathDrag([dragged]),
                dragAnchorStrategy: pointerDragAnchorStrategy,
                feedback: _DragFeedback(name: entry.name, isDirectory: isDir),
                child: row,
              ),
      ),
    );
  }
}

/// What follows the pointer while a row is dragged: its name, on a chip.
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.name, required this.isDirectory});

  final String name;
  final bool isDirectory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(Radii.sm),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.sm,
          vertical: Insets.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isDirectory ? AppIcons.folder : AppIcons.article,
              size: Chrome.iconAction,
            ),
            const SizedBox(width: Insets.xs),
            Text(name, style: theme.textTheme.bodySmall),
          ],
        ),
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
        color: selected ? StateLayers.selected(theme.colorScheme) : null,
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
            const SizedBox(width: Insets.xxs),
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

/// A file row's right-click items. Reveal only where this machine has the
/// file; open with the default app wherever a file can be brought here
/// ([canOpen], which is [canReveal] unless said). Delete last, set apart, and
/// only where [canDelete] — the dialog it opens says bin or permanent.
List<PopupMenuEntry<String>> fileEntryMenuItems({
  required bool isDirectory,
  required bool canReveal,
  bool? canOpen,
  bool canDelete = false,
  String name = '',
}) => [
  if (isDirectory) ...[
    DesktopMenuItem(
      value: 'new-file',
      label: 'New file…',
      icon: AppIcons.filePlus,
    ),
    DesktopMenuItem(
      value: 'new-folder',
      label: 'New folder…',
      icon: AppIcons.folderPlus,
    ),
    const PopupMenuDivider(),
  ],
  if (!isDirectory)
    DesktopMenuItem(
      value: 'open',
      label: 'Open in editor',
      icon: AppIcons.fileCode,
    ),
  if (!isDirectory && (canOpen ?? canReveal))
    DesktopMenuItem(
      value: 'default-app',
      label: runsAsProgram(name) ? 'Run' : 'Open with default app',
      icon: runsAsProgram(name) ? AppIcons.play : AppIcons.arrowSquareOut,
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
  if (canDelete) ...[
    const PopupMenuDivider(),
    DesktopMenuItem(
      value: 'delete',
      label: 'Delete…',
      icon: AppIcons.trash,
      destructive: true,
    ),
  ],
];

class _FileEntryActions {
  _FileEntryActions(this.ref, this.context, this.entry, this.path);

  final WidgetRef ref;
  final BuildContext context;
  final FileEntry entry;
  final EnvironmentPath path;

  void _say(String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Opens the file in a workbench tab. The external editor is still one
  /// right-click away, for the files this one refuses.
  void open() => ref.read(editorTabActionsProvider).openAt(path);

  Future<void> _openExternally() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final local = await ref.read(filesClientProvider).localPathOf(path);
      if (local == null) {
        messenger.showSnackBar(
          SnackBar(content: Text('${path.path} is not on this machine.')),
        );
        return;
      }
      await ref.read(editorActionsProvider).openPath(local);
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
        .read(serverFileOpeningProvider)
        .reveal(path, select: !entry.isDirectory);
    if (!outcome.ok) _say(outcome.error!);
  }

  /// As a double-click in the OS would: its app, or run it if it is one. A
  /// file this machine has no path to is brought here first.
  Future<void> _openWithDefaultApp() async {
    final outcome = await ref
        .read(serverFileOpeningProvider)
        .openWithDefaultApp(path);
    if (!outcome.ok) _say(outcome.error!);
  }

  Future<void> _copyPath() async {
    await Clipboard.setData(ClipboardData(text: path.path));
    _say('Path copied to clipboard');
  }

  void onMenu(String action) {
    switch (action) {
      case 'new-file':
        createInFileTree(context, ref, path, folder: false);
      case 'new-folder':
        createInFileTree(context, ref, path, folder: true);
      case 'open':
        open();
      case 'external':
        _openExternally();
      case 'reveal':
        _reveal();
      case 'default-app':
        _openWithDefaultApp();
      case 'copy-path':
        _copyPath();
      case 'delete':
        _delete();
    }
  }

  /// Asks, then has the server delete it — the one delete the Split browser
  /// uses too. Only what is inside the tree's own folder, never the folder.
  Future<void> _delete() async {
    final root = ref.read(fileTreeRootProvider);
    final messenger = ScaffoldMessenger.of(context);
    // The folder re-lists itself: FilesClient.listingsTouched.
    final outcome = await confirmAndDeleteFiles(context, [entry], within: root);
    for (final failure in outcome.failures) {
      messenger.showSnackBar(SnackBar(content: Text(failure)));
    }
  }
}

/// Asks for a name and makes a file or folder of it in [parentDir], then
/// shows it: the listing is re-read, the tree opens down to the new entry and
/// selects it, and a new file opens in the editor, since writing in it is
/// what comes next.
Future<void> createInFileTree(
  BuildContext context,
  WidgetRef ref,
  EnvironmentPath parentDir, {
  required bool folder,
}) async {
  final name = await FileNameDialog.ask(
    context,
    title: folder ? 'New folder' : 'New file',
    action: 'Create',
  );
  if (name == null) return;
  final files = ref.read(filesClientProvider);
  final EnvironmentPath created;
  try {
    created = folder
        ? await files.createDirectory(parentDir, name)
        : await files.createFile(parentDir, name);
  } on FilesException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create "$name": ${error.message}')),
      );
    }
    return;
  }
  // The listing re-lists itself (FilesClient.listingsTouched), and the held
  // reveal target waits for it.
  ref
      .read(fileRevealTargetProvider.notifier)
      .reveal(FileRevealTarget(path: created, isDirectory: folder));
  if (!folder) ref.read(editorTabActionsProvider).openAt(created);
}

/// Whether opening [name] runs it rather than showing it — worded "Run" so
/// the menu does not call starting a program "opening" it. Only what the OS
/// runs on a double-click: a `.ps1` opens in Notepad, a `.sh` in an editor.
bool runsAsProgram(String name) {
  final lower = name.toLowerCase();
  return const [
    '.exe',
    '.bat',
    '.cmd',
    '.msi',
    '.app',
    '.command',
  ].any(lower.endsWith);
}
