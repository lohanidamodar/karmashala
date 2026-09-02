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

/// Create, rename, delete and assign — the four verbs a context has, and
/// nothing else.
///
/// Deliberately *not* a management page. There is no navigation to a context,
/// no per-context screen and no ordering: a context is a filter over the
/// project list, so the only things worth doing to one are naming it and
/// saying which projects are in it.
///
/// Both destructive-ish steps confirm **in place** rather than in a second
/// dialog: a dialog over a dialog at 720x560 covers the list you were reading,
/// and the confirmation here is one sentence long.
class WorkspacesDialog extends ConsumerStatefulWidget {
  const WorkspacesDialog({super.key});

  static Future<void> show(BuildContext context) =>
      showDialog<void>(context: context, builder: (_) => const WorkspacesDialog());

  @override
  ConsumerState<WorkspacesDialog> createState() => _WorkspacesDialogState();
}

class _WorkspacesDialogState extends ConsumerState<WorkspacesDialog> {
  final _newController = TextEditingController();
  final _renameController = TextEditingController();

  String? _renamingId;
  String? _confirmingDeleteId;
  String? _error;

  @override
  void dispose() {
    _newController.dispose();
    _renameController.dispose();
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

  void _commitRename(String id) {
    final name = _renameController.text.trim();
    _run(() {
      ref.read(workspacesControllerProvider.notifier).rename(id, name);
      _renamingId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final workspaces = ref.watch(workspacesControllerProvider);
    final projects = ref.watch(projectsControllerProvider);

    return AlertDialog(
      title: const DesktopDialogTitle(
        icon: AppIcons.folder,
        title: 'Contexts',
        subtitle: 'Group projects by what they are for.',
      ),
      content: SizedBox(
        // **Tight**, not a max: `AlertDialog` asks its content for an intrinsic
        // width, and the scrolling list below cannot answer — a viewport would
        // have to build every child to do it. A tight constraint is answered by
        // the box itself and the question never reaches the list.
        //
        // Sized against the window rather than fixed, because the 720x560
        // minimum with text at 1.3x is the case where a constant would push the
        // buttons off the bottom.
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
                  // Every row built, rather than a lazy `ListView`: a few
                  // contexts and ~31 projects is nothing to lay out, and a
                  // viewport that disposes the rows it scrolls past breaks Tab
                  // — the traversal ring stops closing, which is the one thing
                  // in a dialog you cannot work around with the mouse.
                  : SingleChildScrollView(
                      primary: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final workspace in workspaces)
                            _workspaceRow(workspace),
                          const Divider(height: Insets.xl),
                          Padding(
                            padding: const EdgeInsets.only(bottom: Insets.xs),
                            child: Text(
                              'Projects',
                              style: theme.textTheme.labelLarge,
                            ),
                          ),
                          for (final project in projects)
                            _projectRow(project, workspaces),
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

  /// The dialog's own insets take 80 of the width; the title, actions and
  /// their padding take about 260 of the height at 1.0x and more as text
  /// scales, which is what the divisor allows for.
  static double _contentWidth(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return width - 96 < 460 ? (width - 96).clamp(200.0, 460.0) : 460.0;
  }

  static double _contentHeight(BuildContext context) {
    final media = MediaQuery.of(context);
    final chrome = 200 * media.textScaler.scale(1);
    return (media.size.height - chrome).clamp(160.0, 340.0);
  }

  Widget _workspaceRow(Workspace workspace) {
    final theme = Theme.of(context);
    if (_renamingId == workspace.id) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.xs),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _renameController,
                autofocus: true,
                decoration: const InputDecoration(isDense: true),
                onSubmitted: (_) => _commitRename(workspace.id),
              ),
            ),
            const SizedBox(width: Insets.sm),
            IconButton(
              tooltip: 'Save name',
              icon: const Icon(AppIcons.check, size: Chrome.icon),
              onPressed: () => _commitRename(workspace.id),
            ),
            IconButton(
              tooltip: 'Cancel rename',
              icon: const Icon(AppIcons.x, size: Chrome.icon),
              onPressed: () => setState(() => _renamingId = null),
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
            child: Text(
              workspace.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          IconButton(
            tooltip: 'Rename ${workspace.name}',
            icon: const Icon(AppIcons.pencilSimple, size: Chrome.icon),
            onPressed: () => setState(() {
              _renamingId = workspace.id;
              _confirmingDeleteId = null;
              _renameController.text = workspace.name;
            }),
          ),
          IconButton(
            tooltip: 'Delete ${workspace.name}',
            icon: const Icon(AppIcons.trash, size: Chrome.icon),
            onPressed: () => setState(() {
              _confirmingDeleteId = workspace.id;
              _renamingId = null;
            }),
          ),
        ],
      ),
    );
  }

  /// One project, and the context it is in. The picker is the assign verb:
  /// there is nowhere else in the app to move a project between contexts.
  Widget _projectRow(Project project, List<Workspace> workspaces) {
    final theme = Theme.of(context);
    final current = workspaces
        .where((w) => w.id == project.workspaceId)
        .map((w) => w.name)
        .firstOrNull;
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
            itemBuilder: (context) => [
              DesktopMenuItem(
                value: '',
                label: 'None',
                icon: AppIcons.minusCircle,
                selected: project.workspaceId == null,
              ),
              for (final workspace in workspaces)
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
