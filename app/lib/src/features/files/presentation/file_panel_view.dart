import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/picking.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../settings/application/settings_controller.dart';
import '../application/file_panel_controller.dart';
import 'package:karmashala_files/values.dart';
import 'file_delete.dart';
import 'file_name_dialog.dart';

/// One side of the file browser: where it is looking, what is there, and the
/// operations that act on the selection. It knows nothing about the other
/// side — the tab owns the copy between them.
class FilePanelView extends ConsumerWidget {
  const FilePanelView({
    required this.controller,
    required this.machines,
    required this.machineId,
    required this.onMachine,
    required this.focused,
    required this.onFocus,
    this.copyLabel,
    this.onCopy,
    this.onOpenFile,
    super.key,
  });

  final FilePanelController controller;

  /// Every machine this browser can look at: id and what it is called.
  final List<({String id, String label})> machines;

  final String machineId;
  final ValueChanged<String> onMachine;

  /// Whether this side has the user's attention — the copy acts on it.
  final bool focused;
  final VoidCallback onFocus;

  /// "Copy to Ubuntu →" — null while there is nowhere to copy to.
  final String? copyLabel;
  final void Function(List<FileEntry> entries)? onCopy;

  /// What a double-click on a file does, when there is anything to do.
  final void Function(FileEntry entry)? onOpenFile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Watched so the Hidden chip — on either side, or in Settings — redraws
    // both panels: the chip only records the choice.
    ref.watch(settingsControllerProvider.select((s) => s.showHiddenFiles));
    return ValueListenableBuilder<FilePanelState>(
      valueListenable: controller,
      builder: (context, state, _) {
        final hidden = [
          for (final entry in state.entries)
            if (entry.name.startsWith('.')) entry,
        ];
        final visible = HiddenFilesPreference.shown
            ? state.entries
            : [
                for (final entry in state.entries)
                  if (!entry.name.startsWith('.')) entry,
              ];
        final selection = state.selectedEntries;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: onFocus,
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _MachineBar(
                  machines: machines,
                  machineId: machineId,
                  onMachine: onMachine,
                  hiddenCount: hidden.length,
                  onRefresh: state.busy ? null : controller.refresh,
                ),
                _PathBar(
                  path: state.directory?.path ?? '…',
                  onUp: state.busy ? null : controller.goUp,
                ),
                _Toolbar(
                  busy: state.busy,
                  selection: selection,
                  controller: controller,
                  copyLabel: copyLabel,
                  onCopy: onCopy,
                ),
                if (state.error case final message?)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Insets.xs),
                    child: DesktopErrorBanner(message),
                  ),
                Expanded(
                  child: state.busy && state.entries.isEmpty
                      ? const Center(
                          child: InlineSpinner(size: InlineSpinnerSize.large),
                        )
                      : visible.isEmpty
                      ? Center(
                          child: Text(
                            'Nothing here.',
                            style: theme.textTheme.bodySmall,
                          ),
                        )
                      : _Listing(
                          entries: visible,
                          selected: state.selected,
                          opensFiles: onOpenFile != null,
                          onTap: (entry) {
                            onFocus();
                            controller.select(entry);
                          },
                          onToggle: (entry) {
                            onFocus();
                            controller.select(entry, add: true);
                          },
                          onOpen: (entry) {
                            onFocus();
                            if (entry.isDirectory) {
                              controller.enter(entry);
                            } else {
                              onOpenFile?.call(entry);
                            }
                          },
                        ),
                ),
                _Footer(count: visible.length, selected: selection.length),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MachineBar extends StatelessWidget {
  const _MachineBar({
    required this.machines,
    required this.machineId,
    required this.onMachine,
    required this.hiddenCount,
    required this.onRefresh,
  });

  final List<({String id, String label})> machines;
  final String machineId;
  final ValueChanged<String> onMachine;
  final int hiddenCount;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              isExpanded: true,
              value: machines.any((m) => m.id == machineId) ? machineId : null,
              hint: const Text('Machine'),
              items: [
                for (final machine in machines)
                  DropdownMenuItem(
                    value: machine.id,
                    child: Text(machine.label, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (value) {
                if (value != null) onMachine(value);
              },
            ),
          ),
        ),
        // The chip writes the setting; FilePanelView watches it and redraws.
        HiddenFilesChip(hiddenCount: hiddenCount, onChanged: (_) {}),
        const SizedBox(width: Insets.xs),
        IconButton(
          tooltip: 'Refresh',
          visualDensity: VisualDensity.compact,
          icon: const Icon(AppIcons.arrowsClockwise),
          onPressed: onRefresh,
        ),
      ],
    );
  }
}

class _PathBar extends StatelessWidget {
  const _PathBar({required this.path, required this.onUp});

  final String path;
  final VoidCallback? onUp;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          tooltip: 'Up one level',
          visualDensity: VisualDensity.compact,
          icon: const Icon(AppIcons.arrowUp),
          onPressed: onUp,
        ),
        Expanded(
          child: Tooltip(
            message: path,
            child: Text(
              path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: MonoStyles.body,
            ),
          ),
        ),
      ],
    );
  }
}

/// Everything the panel can do to what is in it. Disabled rather than hidden:
/// a button that comes and goes is harder to find than one that is greyed.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.busy,
    required this.selection,
    required this.controller,
    required this.copyLabel,
    required this.onCopy,
  });

  final bool busy;
  final List<FileEntry> selection;
  final FilePanelController controller;
  final String? copyLabel;
  final void Function(List<FileEntry> entries)? onCopy;

  @override
  Widget build(BuildContext context) {
    final one = selection.length == 1 ? selection.single : null;
    return Wrap(
      spacing: Insets.xs,
      runSpacing: Insets.xs,
      children: [
        TextButton.icon(
          icon: const Icon(AppIcons.folderPlus, size: Chrome.iconSmall),
          label: const Text('New folder'),
          onPressed: busy ? null : () => _create(context, folder: true),
        ),
        TextButton.icon(
          icon: const Icon(AppIcons.plus, size: Chrome.iconSmall),
          label: const Text('New file'),
          onPressed: busy ? null : () => _create(context, folder: false),
        ),
        TextButton.icon(
          icon: const Icon(AppIcons.pencilSimple, size: Chrome.iconSmall),
          label: const Text('Rename'),
          onPressed: busy || one == null ? null : () => _rename(context, one),
        ),
        TextButton.icon(
          icon: const Icon(AppIcons.trash, size: Chrome.iconSmall),
          label: const Text('Delete'),
          onPressed: busy || selection.isEmpty
              ? null
              : () => _delete(context, selection),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
        ),
        if (copyLabel != null)
          TextButton.icon(
            icon: const Icon(AppIcons.copySimple, size: Chrome.iconSmall),
            label: Text(copyLabel!),
            onPressed: busy || selection.isEmpty || onCopy == null
                ? null
                : () => onCopy!(selection),
          ),
      ],
    );
  }

  Future<void> _create(BuildContext context, {required bool folder}) async {
    final name = await FileNameDialog.ask(
      context,
      title: folder ? 'New folder' : 'New file',
      action: 'Create',
    );
    if (name == null) return;
    await (folder
        ? controller.createFolder(name)
        : controller.createFile(name));
  }

  Future<void> _rename(BuildContext context, FileEntry entry) async {
    final name = await FileNameDialog.ask(
      context,
      title: 'Rename',
      action: 'Rename',
      initial: entry.name,
    );
    if (name == null || name == entry.name) return;
    await controller.rename(entry, name);
  }

  /// The same question and the same delete as the Files tab's row menu:
  /// the recycle bin where the machine has one, permanently (and said so)
  /// where it does not.
  Future<void> _delete(BuildContext context, List<FileEntry> entries) async {
    final outcome = await confirmAndDeleteFiles(context, entries);
    if (outcome.deleted.isEmpty && outcome.failures.isEmpty) return;
    await controller.showDeleted(outcome.failures);
  }
}

class _Listing extends StatelessWidget {
  const _Listing({
    required this.entries,
    required this.selected,
    required this.onTap,
    required this.onToggle,
    required this.onOpen,
    this.opensFiles = false,
  });

  final List<FileEntry> entries;
  final Set<String> selected;

  /// Whether a file row offers "Open in editor" — the tab says whether its
  /// machine's files can be opened.
  final bool opensFiles;
  final ValueChanged<FileEntry> onTap;
  final ValueChanged<FileEntry> onToggle;
  final ValueChanged<FileEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final isSelected = selected.contains(entry.path.path);
        return ListTile(
          dense: true,
          selected: isSelected,
          leading: Icon(switch (entry.kind) {
            FileEntryKind.directory => AppIcons.folder,
            FileEntryKind.symlink => AppIcons.linkSimple,
            _ => AppIcons.article,
          }, size: Chrome.icon),
          title: Text(
            entry.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: MonoStyles.body,
          ),
          subtitle: entry.isDirectory
              ? null
              : Text(
                  describeFileSize(entry.sizeBytes),
                  style: theme.textTheme.labelSmall,
                ),
          onTap: () => onTap(entry),
          // Long-press adds to the selection; the caret opens a folder, and a
          // file is opened by the tab, which is the only side that knows how.
          onLongPress: () => onToggle(entry),
          trailing: entry.isDirectory
              ? IconButton(
                  tooltip: 'Open',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(AppIcons.caretRight, size: Chrome.iconSmall),
                  onPressed: () => onOpen(entry),
                )
              : opensFiles && entry.kind != FileEntryKind.other
              ? IconButton(
                  tooltip: 'Open in editor',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(AppIcons.fileCode, size: Chrome.iconSmall),
                  onPressed: () => onOpen(entry),
                )
              : null,
        );
      },
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.count, required this.selected});

  final int count;
  final int selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.xs,
        vertical: Insets.hair,
      ),
      child: Text(
        selected == 0
            ? '$count item${count == 1 ? '' : 's'}'
            : '$count item${count == 1 ? '' : 's'} · $selected selected',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A size a person can read. Null — the filesystem did not say — is a dash,
/// never a zero.
String describeFileSize(int? bytes) {
  if (bytes == null) return '—';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
