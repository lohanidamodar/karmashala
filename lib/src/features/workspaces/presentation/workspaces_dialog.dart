import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_dialog.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../projects/application/projects_controller.dart';
import '../../projects/domain/project.dart';
import '../application/workspaces_controller.dart';
import '../domain/workspace.dart';

/// Create, rename, describe, delete and assign — the verbs a context has.
/// The project list is a `const` child: a new context rebuilt all 31 rows.
class WorkspacesDialog extends ConsumerStatefulWidget {
  const WorkspacesDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const WorkspacesDialog(),
  );

  @override
  ConsumerState<WorkspacesDialog> createState() => _WorkspacesDialogState();
}

class _WorkspacesDialogState extends ConsumerState<WorkspacesDialog> {
  final _newController = TextEditingController();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();

  String? _editingId;
  String? _confirmingDeleteId;
  String? _error;

  @override
  void dispose() {
    _newController.dispose();
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _run(VoidCallback action) {
    try {
      action();
      setState(() => _error = null);
    } on DuplicateWorkspaceName catch (e) {
      setState(() => _error = e.toString());
    } on ArgumentError catch (e) {
      setState(() => _error = '${e.message}');
    }
  }

  void _create() {
    final name = _newController.text.trim();
    if (name.isEmpty) return;
    _run(() {
      ref.read(workspacesControllerProvider.notifier).create(name);
      _newController.clear();
    });
  }

  void _commitEdit(String id) {
    _run(() {
      ref
          .read(workspacesControllerProvider.notifier)
          .edit(
            id,
            name: _nameController.text,
            description: _descriptionController.text,
          );
      _editingId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final workspaces = ref.watch(workspacesControllerProvider);
    final counts = ref.watch(workspaceProjectCountsProvider);

    return AlertDialog(
      title: const DesktopDialogTitle(
        icon: AppIcons.folder,
        title: 'Contexts',
        subtitle: 'Group projects by what they are for.',
      ),
      content: SizedBox(
        // **Tight**, not a max: `AlertDialog` asks its content for an intrinsic
        // width, and the scrolling list below cannot answer without building it all.
        width: _contentWidth(context),
        height: _contentHeight(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _newController,
                    decoration: const InputDecoration(
                      labelText: 'New context',
                      hintText: 'Game dev',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _create(),
                  ),
                ),
                const SizedBox(width: Insets.sm),
                OutlinedButton.icon(
                  onPressed: _create,
                  icon: const Icon(AppIcons.plus, size: Chrome.icon),
                  label: const Text('Add'),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: Insets.sm),
              DesktopErrorBanner(_error!),
            ],
            const SizedBox(height: Insets.md),
            Expanded(
              child: workspaces.isEmpty
                  ? Align(
                      alignment: Alignment.topLeft,
                      child: Text(
                        'No contexts yet. Add one above, then put projects in '
                        'it — a project can be in none, which is normal.',
                        style: theme.textTheme.bodySmall,
                      ),
                    )
                  // Every row built rather than a lazy `ListView`: a viewport that disposes
                  // rows it scrolls past breaks Tab, and the ring stops closing.
                  : SingleChildScrollView(
                      primary: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final workspace in workspaces)
                            _workspaceRow(workspace, counts),
                          const Divider(height: Insets.xl),
                          Padding(
                            padding: const EdgeInsets.only(bottom: Insets.xs),
                            child: Text(
                              'Projects',
                              style: theme.textTheme.labelLarge,
                            ),
                          ),
                          // `const`, and that is the fix for the reported lag: a new context leaves
                          // this instance identical, so the project rows are never asked to rebuild.
                          const _ProjectsSection(),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }

  /// The dialog's own insets take 80 of the width; the title and actions take
  /// about 260 of the height at 1.0x, and more as text scales.
  static double _contentWidth(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return width - 96 < 460 ? (width - 96).clamp(200.0, 460.0) : 460.0;
  }

  static double _contentHeight(BuildContext context) {
    final media = MediaQuery.of(context);
    final chrome = 200 * media.textScaler.scale(1);
    return (media.size.height - chrome).clamp(160.0, 340.0);
  }

  Widget _workspaceRow(Workspace workspace, Map<String, int> counts) {
    final theme = Theme.of(context);
    if (_editingId == workspace.id) {
      // Name and description stacked rather than side by side: at the 200px this
      // dialog squeezes to, two fields on one row are two nobody can read.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _commitEdit(workspace.id),
                  ),
                ),
                const SizedBox(width: Insets.sm),
                IconButton(
                  tooltip: 'Save context',
                  icon: const Icon(AppIcons.check, size: Chrome.icon),
                  onPressed: () => _commitEdit(workspace.id),
                ),
                IconButton(
                  tooltip: 'Cancel edit',
                  icon: const Icon(AppIcons.x, size: Chrome.icon),
                  onPressed: () => setState(() => _editingId = null),
                ),
              ],
            ),
            const SizedBox(height: Insets.xs),
            TextField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: 'Description',
                hintText: 'What this context is for. Optional.',
                isDense: true,
              ),
              onSubmitted: (_) => _commitEdit(workspace.id),
            ),
          ],
        ),
      );
    }

    if (_confirmingDeleteId == workspace.id) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.xs),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Delete "${workspace.name}"? Its projects stay, with no '
                'context.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _confirmingDeleteId = null),
              child: const Text('Cancel'),
            ),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
              onPressed: () {
                ref
                    .read(workspacesControllerProvider.notifier)
                    .delete(workspace.id);
                setState(() => _confirmingDeleteId = null);
              },
              child: const Text('Delete'),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Row(
        children: [
          Icon(
            AppIcons.folder,
            size: Chrome.icon,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  workspace.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  describeWorkspace(
                    workspace,
                    projectCount: counts[workspace.id] ?? 0,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Edit ${workspace.name}',
            icon: const Icon(AppIcons.pencilSimple, size: Chrome.icon),
            onPressed: () => setState(() {
              _editingId = workspace.id;
              _confirmingDeleteId = null;
              _nameController.text = workspace.name;
              _descriptionController.text = workspace.description ?? '';
            }),
          ),
          IconButton(
            tooltip: 'Delete ${workspace.name}',
            icon: const Icon(AppIcons.trash, size: Chrome.icon),
            onPressed: () => setState(() {
              _confirmingDeleteId = workspace.id;
              _editingId = null;
            }),
          ),
        ],
      ),
    );
  }
}

/// Every project, and the context it is in. Its own `const` widget, so the
/// dialog above can rebuild with this subtree untouched.
class _ProjectsSection extends ConsumerWidget {
  const _ProjectsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final project in ref.watch(projectsControllerProvider))
        _ProjectRow(project: project),
    ],
  );
}

/// One project, and the context it is in. The picker is the assign verb — the
/// same one the Explorer's right-click menu calls.
class _ProjectRow extends ConsumerWidget {
  const _ProjectRow({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // The *name of this project's own context*, and nothing else: another
    // context changing leaves this value alone, so this row is not rebuilt.
    final current = ref.watch(
      workspacesControllerProvider.select(
        (workspaces) => workspaces
            .where((w) => w.id == project.workspaceId)
            .map((w) => w.name)
            .firstOrNull,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              project.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: Insets.sm),
          PopupMenuButton<String>(
            tooltip: 'Context for ${project.name}',
            position: PopupMenuPosition.under,
            // Read when the menu opens, not when the row is drawn: the row must not
            // subscribe to the whole context list for a picker nobody has clicked.
            itemBuilder: (context) => [
              DesktopMenuItem(
                value: '',
                label: 'None',
                icon: AppIcons.minusCircle,
                selected: project.workspaceId == null,
              ),
              for (final workspace in ref.read(workspacesControllerProvider))
                DesktopMenuItem(
                  value: workspace.id,
                  label: workspace.name,
                  icon: AppIcons.folder,
                  selected: project.workspaceId == workspace.id,
                ),
            ],
            onSelected: (value) => ref
                .read(workspacesControllerProvider.notifier)
                .assign(project.id, value.isEmpty ? null : value),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  current ?? 'None',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: current == null
                        ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.primary,
                  ),
                ),
                Icon(
                  AppIcons.caretDown,
                  size: Chrome.icon,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
