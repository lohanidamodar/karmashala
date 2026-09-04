import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/shell/reveal_in_file_manager.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../../app/widgets/row_menu.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/local_environment.dart';
import '../application/file_explorer_providers.dart';
import '../data/file_listing_service.dart';

/// How far in a row at [depth] starts. One expression, used by the rows and by
/// the "Empty"/"Loading…" placeholders alike, because the two drifting apart is
/// exactly what a reader sees as a ragged tree.
double _indentFor(int depth) => Insets.md + depth * Chrome.treeIndent;

/// A tree row is tighter than [Insets.xs]: at [Chrome.row] density the padding
/// is what stops two file names touching, not what separates sections.
const double _rowPadY = 3;

/// How many rows have been drawn. Test-only, and the only way to pin the claim
/// that a reveal target rebuilds the rows *on the way to it* and no others: the
/// panel routinely holds hundreds of rows, and rebuilding all of them because
/// one is selected is the cost this feature must not add.
@visibleForTesting
int debugFileRowBuilds = 0;

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
    final root = ref.watch(selectedRepoWindowsRootProvider);
    // The header stays in the empty state. This surface tells the side panel it
    // draws its own (`drawsOwnHeader`), so returning a bare placeholder left the
    // panel with no title and no way out of it but the rail glyph.
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

  /// The row's path as the rest of the app spells one.
  ///
  /// `DirEntry.windowsPath` is already a host path — the listing runs on the
  /// Windows host through `dart:io` — so this only puts the owning environment
  /// back on it, which is what [RevealInFileManager] needs to answer
  /// "can this be shown?" without guessing.
  EnvironmentPath get _path => EnvironmentPath(
    environmentId: localHostEnvironmentId,
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

  /// Opens on the way down, and puts the target on screen once it exists.
  ///
  /// After the frame rather than during it, and deliberately without any
  /// sequencing of its own: expanding mounts a `_DirChildren` whose listing is
  /// async, and the rows that listing produces ask this same question in turn.
  /// The tree therefore walks itself down one listing at a time, whether the
  /// target arrived while the panel was open, closed, or halfway expanded.
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
      onTap: isDir
          ? () => setState(() => _expanded = !_expanded)
          : _openInEditor,
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
    // [RowContextMenu] rather than a bare right-click: this row had the
    // gesture and nothing else, so a keyboard could reach every file in the
    // tree and none of their actions. It now answers `Shift+F10`, the Menu key
    // and a screen reader's named action too — the row's own `InkWell` is the
    // focus stop that makes those work. No `⋮`: nothing here is hidden behind
    // one, and a glyph on every line of a file tree is the clutter this pane
    // has always done without.
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
