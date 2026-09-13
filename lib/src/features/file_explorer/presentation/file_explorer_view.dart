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
              : SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: Insets.xs),
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
    padding: EdgeInsets.only(
      left: _indentFor(depth) + Chrome.treeGutter,
      top: _rowPadY,
      bottom: _rowPadY,
    ),
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

  /// Whether this row has already put itself on screen for the target it is.
  /// Scrolling once is a reveal; scrolling on every rebuild fights the reader.
  bool _scrolled = false;

  /// The row's path as the rest of the app spells one — `DirEntry.windowsPath`
  /// with its owning environment put back, which is what reveal needs.
  EnvironmentPath get _path => EnvironmentPath(
    environmentId: localHostEnvironmentId,
    path: widget.entry.windowsPath,
  );

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Opens the file in a workbench tab. The external editor is still one
  /// right-click away, for the files this one refuses.
  void _open() =>
      ref.read(editorTabActionsProvider).open(widget.entry.windowsPath);

  Future<void> _openExternally() async {
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
  /// Failure is a [RevealOutcome], not a throw, so a `catch` would never fire.
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

  /// Right-click items. Reveal is offered only where the host can reach the row;
  /// `canReveal` starts no process, so asking while building is free.
  List<PopupMenuEntry<String>> _menuItems() => [
    if (!widget.entry.isDirectory)
      DesktopMenuItem(
        value: 'open',
        label: 'Open in editor',
        icon: AppIcons.fileCode,
      ),
    DesktopMenuItem(
      value: 'external',
      label: widget.entry.isDirectory
          ? 'Open folder in external editor'
          : 'Open in external editor',
      icon: AppIcons.arrowSquareOut,
    ),
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
      case 'open':
        _open();
      case 'external':
        _openExternally();
      case 'reveal':
        _reveal();
      case 'copy-path':
        _copyPath();
    }
  }

  /// Opens on the way down, and puts the target on screen once it exists. After
  /// the frame and with no sequencing: each new listing asks the same question.
  void _followReveal(FileRevealRole role) {
    if (role == FileRevealRole.none) {
      _scrolled = false;
      return;
    }
    // A folder is opened whether it is on the way down or the target itself:
    // revealing a directory means showing what is in it.
    if (widget.entry.isDirectory && !_expanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _expanded = true);
      });
    }
    if (role == FileRevealRole.target && !_scrolled) {
      _scrolled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: const Duration(milliseconds: 150),
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    debugFileRowBuilds++;
    final theme = Theme.of(context);
    final entry = widget.entry;
    final isDir = entry.isDirectory;
    // `select` rather than a plain watch: every row re-runs this when a target
    // arrives, but only the rows whose answer *changed* are rebuilt.
    final role = ref.watch(
      fileRevealTargetProvider.select(
        (target) => fileRevealRoleFor(
          target,
          entry.windowsPath,
          isDirectory: entry.isDirectory,
        ),
      ),
    );
    _followReveal(role);
    final selected = role == FileRevealRole.target;
    final row = InkWell(
      onTap: isDir ? () => setState(() => _expanded = !_expanded) : _open,
      child: Container(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.14)
            : null,
        padding: EdgeInsets.only(
          left: _indentFor(widget.depth),
          top: _rowPadY,
          bottom: _rowPadY,
          right: Insets.sm,
        ),
        child: Row(
          children: [
            if (isDir)
              Icon(
                _expanded ? AppIcons.caretDown : AppIcons.caretRight,
                size: Chrome.iconAction,
                color: theme.colorScheme.onSurfaceVariant,
              )
            else
              const SizedBox(width: Chrome.iconAction),
            const SizedBox(width: 2),
            Icon(
              isDir
                  ? (_expanded ? AppIcons.folderOpen : AppIcons.folder)
                  : AppIcons.article,
              size: Chrome.iconAction,
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
    // [RowContextMenu] rather than a bare right-click: with the gesture alone a
    // keyboard could reach every file and none of their actions. No `⋮` here.
    final menu = Semantics(
      selected: selected,
      child: RowContextMenu(
        menuLabel: 'Actions for ${entry.name}',
        itemBuilder: _menuItems,
        onSelected: _onMenu,
        builder: (context) => row,
      ),
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
