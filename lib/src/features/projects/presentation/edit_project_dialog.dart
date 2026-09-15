import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:agent_cli/process.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/picking.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../environments/application/environments_controller.dart';
import '../../explorer/application/checkout_picker.dart';
import '../../repositories/data/repository_discovery_service.dart';
import '../../workspaces/application/workspaces_controller.dart';
import '../application/project_service.dart';
import '../application/projects_controller.dart';
import '../domain/project.dart';

/// Edits a project already in the workspace: its name, where its root folder
/// is, the context it is filed under, and the checkout its one-click session
/// runs in.
class EditProjectDialog extends ConsumerStatefulWidget {
  const EditProjectDialog({required this.project, super.key});

  final Project project;

  static Future<bool?> show(BuildContext context, Project project) =>
      showDialog<bool>(
        context: context,
        builder: (_) => EditProjectDialog(project: project),
      );

  @override
  ConsumerState<EditProjectDialog> createState() => _EditProjectDialogState();
}

const _noContext = '__none__';
const _firstCheckout = '__first__';

class _EditProjectDialogState extends ConsumerState<EditProjectDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.project.name,
  );
  late final TextEditingController _folder = TextEditingController(
    text: widget.project.root.path,
  );
  late String _targetId = widget.project.root.environmentId;
  late String _workspaceId = widget.project.workspaceId ?? _noContext;
  late String _defaultCheckout =
      widget.project.defaultRepositoryId ?? _firstCheckout;

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _folder.dispose();
    super.dispose();
  }

  /// Whether the root is being moved — the one change with consequences for
  /// rows other than this project's own.
  bool get _moving =>
      _folder.text.trim() != widget.project.root.path ||
      _targetId != widget.project.root.environmentId;

  Future<void> _browse() async {
    final directory = await pickOneDirectory(
      context: context,
      environmentId: _targetId,
      what: 'the project folder',
      startNear: _folder.text,
    );
    if (directory == null || !mounted) return;
    setState(() => _folder.text = directory);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a project name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(projectsControllerProvider.notifier)
          .updateProject(
            widget.project.id,
            name: name,
            folderPath: _moving ? _folder.text.trim() : null,
            targetEnvironmentId: _moving ? _targetId : null,
            defaultRepositoryId: _defaultCheckout == _firstCheckout
                ? null
                : _defaultCheckout,
            clearDefaultRepository: _defaultCheckout == _firstCheckout,
          );

      // Its own statement, the way the row's move-to-context menu does it, so
      // a failed edit cannot half-file a project.
      final workspaceId = _workspaceId == _noContext ? null : _workspaceId;
      if (workspaceId != widget.project.workspaceId) {
        ref
            .read(workspacesControllerProvider.notifier)
            .assign(widget.project.id, workspaceId);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_summaryOf(result))));
      Navigator.of(context).pop(true);
    } on RepositoryDiscoveryException catch (error) {
      setState(() => _error = error.message);
    } on Object catch (error) {
      setState(() => _error = 'Could not save this project: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// What the save did, counted rather than claimed. A checkout left behind is
  /// named, because nothing here knows where it went.
  String _summaryOf(ProjectUpdateResult result) {
    if (result.rebased.isEmpty &&
        result.leftBehind.isEmpty &&
        result.discovered.isEmpty) {
      return 'Saved "${result.project.name}".';
    }
    return [
      'Saved "${result.project.name}"',
      if (result.rebased.isNotEmpty) '${result.rebased.length} checkout(s) moved',
      if (result.discovered.isNotEmpty) '${result.discovered.length} found',
      if (result.leftBehind.isNotEmpty)
        '${result.leftBehind.length} left where they were',
    ].join(' — ');
  }

  @override
  Widget build(BuildContext context) {
    final environments = ref.watch(environmentsControllerProvider);
    final workspaces = ref.watch(workspacesControllerProvider);
    final checkouts = ref.watch(checkoutsInProjectProvider(widget.project.id));

    return AlertDialog(
      scrollable: true,
      title: const DesktopDialogTitle(
        icon: AppIcons.pencilSimple,
        title: 'Edit project',
        subtitle: 'The name, where it lives, and where a session starts.',
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              DesktopErrorBanner(_error!),
              const SizedBox(height: Insets.md),
            ],
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: Insets.md),
            DropdownButtonFormField<String>(
              initialValue: environments.any((e) => e.id == _targetId)
                  ? _targetId
                  : null,
              decoration: const InputDecoration(labelText: 'Environment'),
              items: [
                for (final environment in environments)
                  DropdownMenuItem(
                    value: environment.id,
                    child: Text(environmentLabel(environment) ?? environment.id),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _targetId = value ?? _targetId),
            ),
            const SizedBox(height: Insets.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _folder,
                    decoration: const InputDecoration(
                      labelText: 'Root folder',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: Insets.sm),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _browse,
                  icon: const Icon(AppIcons.folderOpen, size: Chrome.icon),
                  label: const Text('Browse'),
                ),
              ],
            ),
            if (_moving) ...[
              const SizedBox(height: Insets.sm),
              _MoveNotice(count: checkouts.length),
            ],
            const SizedBox(height: Insets.md),
            DropdownButtonFormField<String>(
              initialValue: _workspaceId == _noContext ||
                      workspaces.any((w) => w.id == _workspaceId)
                  ? _workspaceId
                  : _noContext,
              decoration: const InputDecoration(labelText: 'Context'),
              items: [
                const DropdownMenuItem(
                  value: _noContext,
                  child: Text('No context'),
                ),
                for (final workspace in workspaces)
                  DropdownMenuItem(
                    value: workspace.id,
                    child: Text(workspace.name),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (value) =>
                        setState(() => _workspaceId = value ?? _noContext),
            ),
            const SizedBox(height: Insets.md),
            DropdownButtonFormField<String>(
              initialValue:
                  _defaultCheckout == _firstCheckout ||
                      checkouts.any((c) => c.id == _defaultCheckout)
                  ? _defaultCheckout
                  : _firstCheckout,
              decoration: const InputDecoration(
                labelText: 'Default checkout',
                helperText: 'Where the + on this project starts a session.',
              ),
              items: [
                const DropdownMenuItem(
                  value: _firstCheckout,
                  child: Text('First checkout (automatic)'),
                ),
                for (final checkout in checkouts)
                  DropdownMenuItem(
                    value: checkout.id,
                    child: Text(checkout.name),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(
                      () => _defaultCheckout = value ?? _firstCheckout,
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

/// What moving a root will do, said before it is done rather than reported
/// after: the checkouts keep their ids and their sessions, and anything that
/// was not under the old root is left alone.
class _MoveNotice extends StatelessWidget {
  const _MoveNotice({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          AppIcons.info,
          size: Chrome.icon,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: Text(
            count == 0
                ? 'The new folder is read before anything is saved; one that '
                      'cannot be read changes nothing.'
                : '$count checkout(s) under the old root will be rewritten '
                      'under the new one, keeping their sessions. Anything '
                      'that was not under it is left where it is.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
