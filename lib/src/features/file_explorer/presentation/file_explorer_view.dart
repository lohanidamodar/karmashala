import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/reveal_in_file_manager.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/local_environment.dart';
import '../application/file_explorer_providers.dart';
import '../data/file_listing_service.dart';

/// A lazy file/folder tree for the selected repository. Folders expand in place;
/// tapping a file opens it in the configured code editor. Listing runs on the
/// Windows host (WSL folders via their `\\wsl.localhost\…` form).
///
/// Every row — file and folder alike — right-clicks to a menu that reveals it in
/// the system file manager or copies its path. The reveal is
/// [RevealInFileManager]'s, the same one the Explorer, the repository info view
/// and the comparison view use; nothing here starts a process of its own.
class FileExplorerView extends ConsumerWidget {
  const FileExplorerView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final root = ref.watch(selectedRepoWindowsRootProvider);
    if (root == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            "Select a repository to browse its files.",
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              Expanded(child: Text('Files', style: theme.textTheme.titleSmall)),
              IconButton(
                tooltip: 'Refresh',
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: const Icon(AppIcons.arrowsClockwise),
                onPressed: () =>
                    ref.read(fileListingRefreshProvider.notifier).refresh(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: _DirChildren(dir: root, depth: 0),
          ),
        ),
      ],
    );
  }
}

class _DirChildren extends ConsumerWidget {
  const _DirChildren({required this.dir, required this.depth});

  final String dir;
  final int depth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(directoryListingProvider(dir));
    return async.when(
      loading: () => _leaf(depth, 'Loading…', theme),
      error: (e, _) => _leaf(depth, "Can't read this folder.", theme),
      data: (entries) {
        if (entries.isEmpty) return _leaf(depth, 'Empty', theme);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final entry in entries) _EntryRow(entry: entry, depth: depth),
          ],
        );
      },
    );
  }

  static Widget _leaf(int depth, String text, ThemeData theme) => Padding(
    padding: EdgeInsets.only(left: 12.0 + depth * 14 + 22, top: 3, bottom: 3),
    child: Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontStyle: FontStyle.italic,
      ),
    ),
  );
}

class _EntryRow extends ConsumerStatefulWidget {
  const _EntryRow({required this.entry, required this.depth});

  final DirEntry entry;
  final int depth;

  @override
  ConsumerState<_EntryRow> createState() => _EntryRowState();
}

class _EntryRowState extends ConsumerState<_EntryRow> {
  bool _expanded = false;

  /// The row's path as the rest of the app spells one.
  ///
  /// `DirEntry.windowsPath` is already a host path — the listing runs on the
  /// Windows host through `dart:io` — so this only puts the owning environment
  /// back on it, which is what [RevealInFileManager] needs to answer
  /// "can this be shown?" without guessing.
  EnvironmentPath get _path => EnvironmentPath(
    environmentId: localWindowsEnvironmentId,
    path: widget.entry.windowsPath,
  );

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openInEditor() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(editorActionsProvider).openPath(widget.entry.windowsPath);
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Opening in editor…')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(e is StateError ? e.message : '$e')),
      );
    }
  }

  /// Shows the row in the host's file manager, and says why when it cannot.
  ///
  /// A file is *selected* inside its folder and a folder is *opened* — the same
  /// distinction [RevealInFileManager.reveal] draws. Failure comes back as a
  /// [RevealOutcome] rather than a throw, so a `catch` here would never fire and
  /// the click would be silent; the menu entry is already withheld where the
  /// path has no host spelling, and this covers what fails anyway, such as a
  /// file manager that will not start.
  Future<void> _reveal() async {
    final outcome = await ref
        .read(revealInFileManagerProvider)
        .reveal(_path, select: !widget.entry.isDirectory);
    if (!outcome.ok) _say(outcome.error!);
  }

  Future<void> _copyPath() async {
    await Clipboard.setData(ClipboardData(text: widget.entry.windowsPath));
    _say('Path copied to clipboard');
  }

  /// Right-click items. Reveal is offered only where the host can actually
  /// reach the row — an entry that always fails is worse than no entry, and
  /// [RevealInFileManager.canReveal] starts no process, so asking while
  /// building the menu is free. "Copy path" always works: it is text.
  List<PopupMenuEntry<String>> _menuItems() => [
    if (ref.read(revealInFileManagerProvider).canReveal(_path))
      DesktopMenuItem(
        value: 'reveal',
        label: widget.entry.isDirectory
            ? 'Open in File Explorer'
            : 'Reveal in File Explorer',
        icon: AppIcons.folderOpen,
      ),
    DesktopMenuItem(
      value: 'copy-path',
      label: 'Copy path',
      icon: AppIcons.copySimple,
    ),
  ];

  void _onMenu(String action) {
    switch (action) {
      case 'reveal':
        _reveal();
      case 'copy-path':
        _copyPath();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = widget.entry;
    final isDir = entry.isDirectory;
    final row = InkWell(
      onTap: isDir
          ? () => setState(() => _expanded = !_expanded)
          : _openInEditor,
      child: Padding(
        padding: EdgeInsets.only(
          left: 12.0 + widget.depth * 14,
          top: 3,
          bottom: 3,
          right: 8,
        ),
        child: Row(
          children: [
            if (isDir)
              Icon(
                _expanded ? AppIcons.caretDown : AppIcons.caretRight,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              )
            else
              const SizedBox(width: 14),
            const SizedBox(width: 2),
            Icon(
              isDir
                  ? (_expanded ? AppIcons.folderOpen : AppIcons.folder)
                  : AppIcons.article,
              size: 15,
              color: isDir
                  ? theme.colorScheme.tertiary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
    final menu = ContextMenuRegion(
      menuItems: _menuItems(),
      onSelected: _onMenu,
      child: row,
    );
    if (!isDir || !_expanded) return menu;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        menu,
        _DirChildren(dir: entry.windowsPath, depth: widget.depth + 1),
      ],
    );
  }
}
