import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import 'package:karmashala_files/values.dart';

import '../../editor/application/editor_tab_actions.dart';
import '../application/file_panel_controller.dart';
import '../application/file_space_providers.dart';
import '../data/files_client.dart';
import 'file_panel_view.dart';

/// The file browser, as a tab: two machines side by side, the same panel drawn
/// for each, and a copy between them. A tab rather than a dialog because
/// moving files is work you come back to — a modal over the app cannot be left
/// open beside the session it is for.
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

  ({
    String leftEnvironmentId,
    String leftPath,
    String rightEnvironmentId,
    String rightPath,
  })?
  get sides => filesPaneSides(widget.paneId);

  @override
  void dispose() {
    _left.dispose();
    _right.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final machines = [
      for (final environment in ref.watch(browsableEnvironmentsProvider))
        (id: environment.id, label: environment.name),
    ];
    if (sides == null) {
      return const PanePlaceholder(
        message: 'This tab names a file browser Karmashala cannot read.',
        icon: AppIcons.warningCircle,
      );
    }
    _left.point(ref, machines);
    _right.point(ref, machines);

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
                  _panel(_left, _right, machines, focused: _leftFocused),
                  _panel(_right, _left, machines, focused: !_leftFocused),
                ];
                // Side by side while there is room for two listings; below
                // that the focused one has the tab, and the other is a tap
                // away — a 300px column of ellipsised names is not a browser.
                if (constraints.maxWidth < 720) {
                  return Column(
                    children: [
                      SegmentedButton<bool>(
                        showSelectedIcon: false,
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
                        selected: {_leftFocused},
                        onSelectionChanged: (choice) =>
                            setState(() => _leftFocused = choice.first),
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

  Widget _panel(
    _Side side,
    _Side other,
    List<({String id, String label})> machines, {
    required bool focused,
  }) {
    final controller = side.controller;
    if (controller == null) {
      return const Center(child: InlineSpinner(size: InlineSpinnerSize.large));
    }
    final otherLabel = other.controller == null ? null : other.label;
    return FilePanelView(
      controller: controller,
      machines: machines,
      machineId: side.environmentId,
      onMachine: (id) => setState(() => side.environmentId = id),
      focused: focused,
      onFocus: () => setState(() => _leftFocused = identical(side, _left)),
      copyLabel: otherLabel == null ? null : 'Copy to $otherLabel',
      onCopy: otherLabel == null
          ? null
          : (entries) => _copy(to: other, entries: entries),
      // Every machine the browser reaches, the editor reaches too: the server
      // reads and saves the file where it is, keyed by that place.
      onOpenFile: (entry) =>
          ref.read(editorTabActionsProvider).openAt(entry.path),
    );
  }

  /// Copies [entries] to the other side, one at a time — the server moves
  /// the bytes between the two machines — then lists the destination again.
  /// A folder is refused rather than half-copied: this moves files, and a
  /// tree is a different promise.
  Future<void> _copy({
    required _Side to,
    required List<FileEntry> entries,
  }) async {
    final into = to.controller?.value.directory;
    if (into == null) return;
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
        setState(() {
          _transferError = error is FilesException ? error.message : '$error';
        });
        break;
      }
    }
    if (!mounted) return;
    setState(() => _moving = null);
    await to.controller?.refresh();
  }
}

/// One side's machine and its panel — kept together so switching machines is
/// one assignment and the controller that goes with it.
class _Side {
  _Side(this.environmentId, this.startPath);

  String environmentId;

  /// Where this side opens the first time, from the pane id. Spent once: after
  /// that the panel is wherever the user has walked to.
  String? startPath;

  /// What the machine is called, from the environments list.
  String? label;
  FilePanelController? controller;

  /// Builds the controller for the machine this side names, when it changed.
  /// Called from `build`; it does nothing unless the machine changed.
  void point(WidgetRef ref, List<({String id, String label})> machines) {
    if (environmentId.isEmpty && machines.isNotEmpty) {
      environmentId = machines.first.id;
    }
    final machine = machines.where((m) => m.id == environmentId).firstOrNull;
    label = machine?.label;
    if (controller?.environmentId == environmentId) return;
    controller?.dispose();
    if (machine == null) {
      controller = null;
      return;
    }
    final panel = controller = FilePanelController(
      ref.read(filesClientProvider),
      environmentId,
    );
    final start = startPath;
    startPath = null;
    panel.open(
      start == null || start.isEmpty
          ? null
          : EnvironmentPath(environmentId: environmentId, path: start),
    );
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
