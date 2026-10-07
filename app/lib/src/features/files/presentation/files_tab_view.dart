import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/picking.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import 'package:karmashala_files/values.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../../core/data/data_client.dart' show DataLinkState;
import '../../../core/data/data_providers.dart';
import '../../editor/application/editor_tab_actions.dart';
import '../../environments/application/browse_sources.dart';
import '../../explorer/application/project_head.dart'
    show windowRefocusCountProvider;
import '../../settings/application/settings_controller.dart';
import '../application/file_space_providers.dart';
import '../data/files_client.dart';
import 'file_delete.dart';

/// The file browser, as a tab: two machines side by side, each drawn by the
/// app's one browser ([FileBrowserView]) — the picker's, with its pins,
/// New folder and New file — and a copy between them. A tab rather than a
/// dialog because moving files is work you come back to — a modal over the
/// app cannot be left open beside the session it is for.
class FilesTabView extends ConsumerStatefulWidget {
  const FilesTabView({required this.paneId, super.key});

  final String paneId;

  @override
  ConsumerState<FilesTabView> createState() => _FilesTabViewState();
}

class _FilesTabViewState extends ConsumerState<FilesTabView> {
  late final _left = _Side(sides?.leftEnvironmentId ?? '', sides?.leftPath);
  late final _Side _right = _Side(
    sides?.rightEnvironmentId ?? '',
    sides?.rightPath,
  );

  /// Which side a copy takes from. The other side is where it lands.
  bool _leftFocused = true;

  /// One transfer at a time, with the file it is on: two at once would race
  /// for the same destination listing. The server does the copy.
  String? _moving;
  String? _transferError;

  StreamSubscription<EnvironmentPath>? _touched;

  ({
    String leftEnvironmentId,
    String leftPath,
    String rightEnvironmentId,
    String rightPath,
  })?
  get sides => filesPaneSides(widget.paneId);

  @override
  void initState() {
    super.initState();
    // No folder is watched: a side lists again on focus, on Refresh, when the
    // link comes back, and after this app's own operations touch it.
    _touched = ref.read(filesClientProvider).listingsTouched.listen((folder) {
      for (final side in [_left, _right]) {
        side.controller?.relistIf(folder.environmentId, folder.path);
      }
    });
  }

  @override
  void dispose() {
    unawaited(_touched?.cancel());
    _left.dispose();
    _right.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final environments = ref.watch(browsableEnvironmentsProvider);
    // Watched so the Hidden chip — on either side, or in Settings — redraws
    // both panels: the chip only records the choice.
    ref.watch(settingsControllerProvider.select((s) => s.showHiddenFiles));
    if (sides == null) {
      return const PanePlaceholder(
        message: 'This tab names a file browser Karmashala cannot read.',
        icon: AppIcons.warningCircle,
      );
    }
    final files = ref.watch(filesClientProvider);
    final readsServerDisk = ref.watch(capabilitiesProvider).readsServerDisk;
    _left.point(files, environments, readsServerDisk: readsServerDisk);
    _right.point(files, environments, readsServerDisk: readsServerDisk);
    // Refreshed, never watched: on coming back to the front, and once when
    // the link to the server returns.
    ref.listen(windowRefocusCountProvider, (_, _) {
      _left.controller?.relistUnlessFresh(kListingRefocusFloor);
      _right.controller?.relistUnlessFresh(kListingRefocusFloor);
    });
    ref.listen(dataConnectionProvider, (previous, next) {
      final was = previous?.value?.state;
      if (next.value?.state != DataLinkState.connected) return;
      if (was == null || was == DataLinkState.connected) return;
      unawaited(_left.controller?.relist());
      unawaited(_right.controller?.relist());
    });

    return Column(
      children: [
        if (_moving != null || _transferError != null)
          _TransferStrip(
            progress: _moving,
            error: _transferError,
            onDismiss: () => setState(() => _transferError = null),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(Insets.xs),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final panels = [
                  _panel(_left, _right, focused: _leftFocused),
                  _panel(_right, _left, focused: !_leftFocused),
                ];
                // Side by side while there is room for two listings; below
                // that the focused one has the tab, and the other is a tap
                // away — a 300px column of ellipsised names is not a browser.
                if (constraints.maxWidth < 720) {
                  return Column(
                    children: [
                      CompactSegmented<bool>(
                        segments: [
                          ButtonSegment(
                            value: true,
                            label: Text(_left.label ?? 'Left'),
                          ),
                          ButtonSegment(
                            value: false,
                            label: Text(_right.label ?? 'Right'),
                          ),
                        ],
                        selected: _leftFocused,
                        onChanged: (left) =>
                            setState(() => _leftFocused = left),
                      ),
                      const SizedBox(height: Insets.xs),
                      Expanded(child: _leftFocused ? panels[0] : panels[1]),
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: panels[0]),
                    const SizedBox(width: Insets.xs),
                    Expanded(child: panels[1]),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _panel(_Side side, _Side other, {required bool focused}) {
    final controller = side.controller;
    if (controller == null) {
      return const Center(child: InlineSpinner(size: InlineSpinnerSize.large));
    }
    final theme = Theme.of(context);
    final otherLabel = other.controller == null ? null : other.label;
    void focus() => setState(() => _leftFocused = identical(side, _left));
    return Listener(
      // Any press inside a side gives it the copy, before the press's own
      // work: a row tapped is the side a Copy then takes from.
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (!focused) focus();
      },
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: focused
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        padding: const EdgeInsets.all(Insets.xs),
        // The view redraws on the controller, toolbar and all.
        child: FileBrowserView(
          controller: controller,
          showFooter: true,
          actions: (context) =>
              _toolbar(context, side, other, otherLabel: otherLabel),
          rowActions: (row) => [
            FileBrowserRowAction(
              label: 'Rename…',
              icon: AppIcons.pencilSimple,
              onSelected: (row) {
                final entry = side.entryOf(row.path);
                if (entry != null) unawaited(_rename(side, entry));
              },
            ),
            if (otherLabel != null && !row.isDirectory)
              FileBrowserRowAction(
                label: 'Copy to $otherLabel',
                icon: AppIcons.copySimple,
                onSelected: (row) {
                  final entry = side.entryOf(row.path);
                  if (entry != null) {
                    unawaited(_copy(to: other, entries: [entry]));
                  }
                },
              ),
            FileBrowserRowAction(
              label: 'Delete',
              icon: AppIcons.trash,
              destructive: true,
              onSelected: (row) {
                final entry = side.entryOf(row.path);
                if (entry != null) unawaited(_delete(side, [entry]));
              },
            ),
          ],
          // Every machine the browser reaches, the editor reaches too: the
          // server reads and saves the file where it is, keyed by that place.
          onOpenFile: (row) {
            final environmentId = controller.environmentId;
            if (environmentId == null) return;
            ref
                .read(editorTabActionsProvider)
                .openAt(
                  EnvironmentPath(environmentId: environmentId, path: row.path),
                );
          },
          canOpenFile: (row) =>
              side.entryOf(row.path)?.kind != FileEntryKind.other,
        ),
      ),
    );
  }

  /// What a side can do to its selection. Disabled rather than hidden: a
  /// button that comes and goes is harder to find than one that is greyed.
  Widget _toolbar(
    BuildContext context,
    _Side side,
    _Side other, {
    required String? otherLabel,
  }) {
    final controller = side.controller!;
    final busy = controller.loading || controller.working;
    final selection = side.selection;
    final one = selection.length == 1 ? selection.single : null;
    return Wrap(
      spacing: Insets.xs,
      runSpacing: Insets.xs,
      children: [
        TextButton.icon(
          icon: const Icon(AppIcons.pencilSimple, size: Chrome.iconSmall),
          label: const Text('Rename'),
          onPressed: busy || one == null
              ? null
              : () => unawaited(_rename(side, one)),
        ),
        TextButton.icon(
          icon: const Icon(AppIcons.trash, size: Chrome.iconSmall),
          label: const Text('Delete'),
          onPressed: busy || selection.isEmpty
              ? null
              : () => unawaited(_delete(side, selection)),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
        ),
        if (otherLabel != null)
          TextButton.icon(
            icon: const Icon(AppIcons.copySimple, size: Chrome.iconSmall),
            label: Text('Copy to $otherLabel'),
            onPressed: busy || selection.isEmpty
                ? null
                : () => unawaited(_copy(to: other, entries: selection)),
          ),
      ],
    );
  }

  Future<void> _rename(_Side side, FileEntry entry) async {
    final name = await FileNameDialog.ask(
      context,
      title: 'Rename',
      action: 'Rename',
      initial: entry.name,
    );
    if (name == null || name == entry.name) return;
    try {
      // The client re-lists the folder it touched (listingsTouched).
      await ref.read(filesClientProvider).rename(entry.path, name);
    } on Object catch (error) {
      side.controller?.showNotice(_sentence(error));
    }
  }

  /// The same question and the same delete as every file browser's: the
  /// recycle bin where the machine has one, permanently (and said so) where
  /// it does not.
  Future<void> _delete(_Side side, List<FileEntry> entries) async {
    final outcome = await confirmAndDeleteFiles(context, entries);
    if (outcome.failures.isEmpty) return;
    side.controller?.showNotice(outcome.failures.join('\n'));
  }

  /// Copies [entries] to the other side, one at a time — the server moves
  /// the bytes between the two machines. A folder is refused rather than
  /// half-copied: this moves files, and a tree is a different promise.
  Future<void> _copy({
    required _Side to,
    required List<FileEntry> entries,
  }) async {
    final browser = to.controller;
    final environmentId = browser?.environmentId;
    if (browser == null || environmentId == null) return;
    final into = EnvironmentPath(
      environmentId: environmentId,
      path: browser.directory,
    );
    if (_moving != null) return;
    final folders = entries.where((e) => e.isDirectory).toList();
    final files = entries.where((e) => !e.isDirectory).toList();
    setState(() {
      _transferError = folders.isEmpty
          ? null
          : 'Folders are not copied between machines yet: '
                '${folders.map((f) => f.name).join(', ')}.';
      _moving = files.isEmpty ? null : files.first.name;
    });
    final client = ref.read(filesClientProvider);
    for (final entry in files) {
      if (mounted) setState(() => _moving = entry.name);
      try {
        await client.copy(entry.path, into);
      } on Object catch (error) {
        if (!mounted) return;
        setState(() => _transferError = _sentence(error));
        break;
      }
    }
    if (!mounted) return;
    // Each copy re-lists the destination itself (FilesClient.listingsTouched).
    setState(() => _moving = null);
  }

  static String _sentence(Object error) =>
      error is FilesException ? error.message : '$error';
}

/// One side's browser, and the server's own entries behind its rows — the
/// rename, delete and copy verbs take those, not the rows.
class _Side {
  _Side(this.environmentId, this.startPath);

  /// The machine this side opens on, from the pane id.
  final String environmentId;

  /// Where this side opens the first time, from the pane id. Spent once:
  /// after that the side is wherever the user has walked to.
  String? startPath;

  FileBrowserController? controller;
  final Map<String, FileEntry> _entries = {};

  /// The machines offered when the browser was last pointed, so a rebuild
  /// that changes nothing hands it nothing.
  String _offered = '';

  /// What the open machine is called.
  String? get label => controller?.source?.label;

  FileEntry? entryOf(String path) => _entries[path];

  List<FileEntry> get selection => [
    for (final entry in controller?.selectedEntries ?? const <BrowsedEntry>[])
      ?_entries[entry.path],
  ];

  /// Builds the browser once there are machines, and hands it the machines
  /// again when the workspace found or lost one. Called from `build`.
  void point(
    FilesClient files,
    List<ExecutionEnvironment> environments, {
    required bool readsServerDisk,
  }) {
    final offered = [
      readsServerDisk,
      for (final environment in environments) environment.id,
    ].join('|');
    if (offered == _offered && controller != null) return;
    _offered = offered;
    final sources = [
      for (final environment in environments)
        browseSourceFor(
          files,
          environment,
          readsServerDisk: readsServerDisk,
          seen: (entry) => _entries[entry.path.path] = entry,
        ),
    ];
    final current = controller;
    if (current != null) {
      current.updateSources(sources);
      return;
    }
    if (sources.isEmpty) return;
    final start = startPath;
    startPath = null;
    controller = FileBrowserController(
      sources: sources,
      environmentId: environmentId.isEmpty ? null : environmentId,
      startAt: start == null || start.isEmpty ? null : start,
      multiSelect: true,
    );
    unawaited(controller!.start());
  }

  void dispose() {
    controller?.dispose();
    controller = null;
  }
}

/// What a transfer is doing, above both panels: one line, because a copy is
/// the only thing here that outlives a click.
class _TransferStrip extends StatelessWidget {
  const _TransferStrip({
    required this.progress,
    required this.error,
    required this.onDismiss,
  });

  /// The file being copied.
  final String? progress;
  final String? error;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(Insets.xs),
        child: Row(
          children: [
            Expanded(child: DesktopErrorBanner(error!)),
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(AppIcons.x, size: Chrome.iconSmall),
              onPressed: onDismiss,
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: Insets.xs,
      ),
      child: Row(
        children: [
          const SizedBox(width: 120, child: LinearProgressIndicator()),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text(
              'Copying $progress…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }
}
