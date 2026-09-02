import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_dialog.dart';

import '../../../core/process/path_translator.dart';
import '../../environments/application/environments_controller.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_label.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../../environments/domain/local_environment.dart';
import '../../repositories/data/repository_discovery_service.dart';
import '../../workspaces/application/workspace_suggestion.dart';
import '../../workspaces/application/workspaces_controller.dart';
import '../../workspaces/domain/workspace.dart';
import '../application/projects_controller.dart';

/// Creates a project from a folder. The folder is chosen with the native
/// Windows picker (which can browse drives and `\\wsl.localhost\…`); choosing a
/// WSL distribution as the target binds the project to that distro's namespace
/// (e.g. `C:\src` → `/mnt/c/src`).
class NewProjectDialog extends ConsumerStatefulWidget {
  const NewProjectDialog({super.key});

  static Future<bool?> show(BuildContext context) => showDialog<bool>(
    context: context,
    builder: (_) => const NewProjectDialog(),
  );

  @override
  ConsumerState<NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends ConsumerState<NewProjectDialog> {
  final _nameController = TextEditingController();
  final _folderController = TextEditingController();
  final _newWorkspaceController = TextEditingController();
  String _targetId = localHostEnvironmentId;

  /// The context the project will be filed under — a guess until the user
  /// touches it, and never applied to anything that already exists.
  String? _workspaceId;

  /// Once the user has answered the question themselves, the folder stops
  /// answering it for them. A guess that keeps overwriting a decision is worse
  /// than no guess.
  bool _workspaceChosen = false;
  bool _namingWorkspace = false;
  bool _busy = false;
  String? _error;

  static const _translator = PathTranslator();

  @override
  void dispose() {
    _nameController.dispose();
    _folderController.dispose();
    _newWorkspaceController.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final dir = await getDirectoryPath();
    if (dir == null) return;
    setState(() {
      _folderController.text = dir;
      if (_nameController.text.trim().isEmpty) {
        _nameController.text = p.basename(
          dir.replaceAll(RegExp(r'[\\/]+$'), ''),
        );
      }
      _suggestWorkspace();
    });
  }

  /// Prefills the context from where the folder sits, by asking which context
  /// already holds the projects nearest it on disk. Suggestion only: it never
  /// runs once the user has chosen, and it never touches an existing project.
  void _suggestWorkspace() {
    if (_workspaceChosen || _namingWorkspace) return;
    final root = _storedRoot(ref.read(environmentsControllerProvider));
    _workspaceId = root == null
        ? null
        : suggestWorkspaceForRoot(
            root: root,
            projects: ref.read(projectsControllerProvider),
          );
  }

  /// The folder as it will be *stored* — in the target environment's namespace,
  /// which is the spelling the suggestion has to compare against.
  EnvironmentPath? _storedRoot(List<ExecutionEnvironment> environments) {
    final folder = _folderController.text.trim();
    if (folder.isEmpty) return null;
    if (_targetId == localHostEnvironmentId) {
      return EnvironmentPath(environmentId: _targetId, path: folder);
    }
    final windows = _envById(environments, localHostEnvironmentId);
    final target = _envById(environments, _targetId);
    if (windows == null || target == null) return null;
    try {
      return _translator.translate(
        EnvironmentPath(environmentId: windows.id, path: folder),
        from: windows,
        to: target,
      );
    } on PathTranslationException {
      return null;
    }
  }

  /// The path as it will be stored for the chosen target (for the preview).
  String? _targetPreview(List<ExecutionEnvironment> environments) {
    final folder = _folderController.text.trim();
    if (folder.isEmpty || _targetId == localHostEnvironmentId) return null;
    final windows = _envById(environments, localHostEnvironmentId);
    final target = _envById(environments, _targetId);
    if (windows == null || target == null) return null;
    try {
      return _translator
          .translate(
            EnvironmentPath(environmentId: windows.id, path: folder),
            from: windows,
            to: target,
          )
          .path;
    } on PathTranslationException catch (e) {
      return '⚠ ${e.message}';
    }
  }

  /// How an environment is named in the dropdown — the app's one vocabulary
  /// for that, shared with what the phone is told each checkout lives in.
  ///
  /// A row that carries no name worth showing falls back to its own id, which
  /// is at least a thing the user can match against the environments list; a
  /// dropdown cannot render nothing.
  static String _environmentLabel(ExecutionEnvironment env) =>
      environmentLabel(env) ?? env.id;

  ExecutionEnvironment? _envById(List<ExecutionEnvironment> envs, String id) {
    for (final e in envs) {
      if (e.id == id) return e;
    }
    return null;
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
    final folder = _folderController.text.trim();
    if (name.isEmpty || folder.isEmpty) {
      setState(() => _error = 'Choose a folder and enter a project name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final workspaceId = _resolveWorkspace();
      final result = await ref
          .read(projectsControllerProvider.notifier)
          .createInEnvironment(
            name: name,
            windowsPath: folder,
            targetEnvironmentId: _targetId,
            workspaceId: workspaceId,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Created "${result.project.name}" — '
            '${result.repositories.length} repository(ies) found.',
          ),
        ),
      );
      Navigator.of(context).pop(true);
    } on DuplicateWorkspaceName catch (e) {
      setState(() => _error = e.toString());
    } on RepositoryDiscoveryException catch (e) {
      setState(() => _error = e.message);
    } on PathTranslationException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Could not create project: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The context to file the new project under, creating it first when the
  /// user typed a new name. Nothing is written until the project is.
  String? _resolveWorkspace() {
    if (!_namingWorkspace) return _workspaceId;
    final name = _newWorkspaceController.text.trim();
    if (name.isEmpty) return null;
    return ref.read(workspacesControllerProvider.notifier).create(name).id;
  }

  @override
  Widget build(BuildContext context) {
    final environments = ref.watch(environmentsControllerProvider);
    final preview = _targetPreview(environments);
    final workspaces = ref.watch(workspacesControllerProvider);

    return AlertDialog(
      title: const DesktopDialogTitle(
        icon: AppIcons.folderPlus,
        title: 'New project',
        subtitle: 'Add a folder and discover its Git repositories.',
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _targetId,
              decoration: const InputDecoration(labelText: 'Environment'),
              items: [
                for (final env in environments)
                  if (env.kind != EnvironmentKind.ssh)
                    DropdownMenuItem(
                      value: env.id,
                      child: Text(_environmentLabel(env)),
                    ),
              ],
              onChanged: (v) => setState(() {
                _targetId = v ?? localHostEnvironmentId;
                // The stored spelling changes with the target, and so does the
                // namespace the suggestion compares in.
                _suggestWorkspace();
              }),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _folderController,
                    decoration: InputDecoration(
                      labelText: 'Folder path',
                      hintText: Platform.isWindows
                          ? r'C:\src\karmashala'
                          : '~/src/karmashala',
                    ),
                    onChanged: (_) => setState(_suggestWorkspace),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _browse,
                  icon: const Icon(AppIcons.folderOpen, size: 18),
                  label: const Text('Browse'),
                ),
              ],
            ),
            if (preview != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Stored as: $preview',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Project name',
                hintText: 'Karmashala',
              ),
            ),
            const SizedBox(height: 12),
            _workspaceField(workspaces),
            if (_error != null) ...[
              const SizedBox(height: 12),
              DesktopErrorBanner(_error!),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _create,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create & scan'),
        ),
      ],
    );
  }

  /// The context picker: which of the user's four or five contexts this project
  /// belongs to. Prefilled from the folder, and a plain "None" is a complete
  /// answer — an unassigned project is an ordinary project.
  Widget _workspaceField(List<Workspace> workspaces) {
    if (_namingWorkspace) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _newWorkspaceController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'New context',
                hintText: 'Game dev',
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Pick an existing context instead',
            icon: const Icon(AppIcons.x, size: Chrome.icon),
            onPressed: _busy
                ? null
                : () => setState(() {
                    _namingWorkspace = false;
                    _newWorkspaceController.clear();
                  }),
          ),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: DropdownButtonFormField<String?>(
            initialValue: _workspaceId,
            decoration: const InputDecoration(
              labelText: 'Context',
              helperText: 'Suggested from the folder. Change it or leave it.',
            ),
            items: [
              const DropdownMenuItem(value: null, child: Text('None')),
              for (final workspace in workspaces)
                DropdownMenuItem(
                  value: workspace.id,
                  child: Text(workspace.name),
                ),
            ],
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    _workspaceId = value;
                    _workspaceChosen = true;
                  }),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'New context',
          icon: const Icon(AppIcons.plus, size: Chrome.icon),
          onPressed: _busy
              ? null
              : () => setState(() {
                  _namingWorkspace = true;
                  _workspaceChosen = true;
                }),
        ),
      ],
    );
  }
}
