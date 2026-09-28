import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import '../../sessions/presentation/new_session_dialog.dart';

import 'package:agent_cli/process.dart';
import 'package:karmashala_ui/picking.dart';
import '../../environments/application/environments_controller.dart';
import '../../settings/presentation/path_field_row.dart';
import 'package:karmashala_git/repositories.dart';
import '../../workspaces/application/workspace_suggestion.dart';
import '../../workspaces/application/workspaces_controller.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import '../application/project_service.dart';
import '../application/projects_controller.dart';

/// Creates a project from a folder or Git repository URL. Supports local,
/// WSL, and SSH environments.
class NewProjectDialog extends ConsumerStatefulWidget {
  const NewProjectDialog({this.initialEnvironmentId, super.key});

  final String? initialEnvironmentId;

  static Future<bool?> show(
    BuildContext context, {
    String? initialEnvironmentId,
  }) => showDialog<bool>(
    context: context,
    builder: (_) =>
        NewProjectDialog(initialEnvironmentId: initialEnvironmentId),
  );

  @override
  ConsumerState<NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends ConsumerState<NewProjectDialog> {
  final _gitUrlController = TextEditingController();
  final _nameController = TextEditingController();
  final _folderController = TextEditingController();
  final _newWorkspaceController = TextEditingController();
  late String _targetId;

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
  void initState() {
    super.initState();
    _targetId = widget.initialEnvironmentId ?? localHostEnvironmentId;
  }

  @override
  void dispose() {
    _gitUrlController.dispose();
    _nameController.dispose();
    _folderController.dispose();
    _newWorkspaceController.dispose();
    super.dispose();
  }

  /// One browser for every environment: it opens on the machine the target
  /// dropdown names and answers in **that machine's** spelling, which is what
  /// the project root is stored as.
  Future<void> _browse() async {
    final directory = await pickOneDirectory(
      context: context,
      environmentId: _targetId,
      what: 'a project folder',
      startNear: _folderController.text,
    );
    if (directory == null || !mounted) return;
    setState(() {
      _folderController.text = directory;
      if (_nameController.text.trim().isEmpty) {
        _nameController.text = _leafOf(directory);
      }
      _suggestWorkspace();
    });
  }

  static String _leafOf(String path) {
    final cleaned = path.replaceAll(RegExp(r'[\\/]+$'), '');
    final cut = cleaned.lastIndexOf(RegExp(r'[\\/]'));
    return cut == -1 ? cleaned : cleaned.substring(cut + 1);
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
    final target = _envById(environments, _targetId);
    if (target?.kind == EnvironmentKind.ssh) {
      return EnvironmentPath(environmentId: _targetId, path: folder);
    }
    if (_targetId == localHostEnvironmentId) {
      return EnvironmentPath(environmentId: _targetId, path: folder);
    }
    // Already spelled for the distribution — the browser answers in its
    // namespace now, and translating a POSIX path as if it were Windows
    // would refuse a folder the user just pointed at.
    if (_isPosixAbsolute(folder)) {
      return EnvironmentPath(environmentId: _targetId, path: folder);
    }
    final windows = _envById(environments, localHostEnvironmentId);
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
    final gitUrl = _gitUrlController.text.trim();
    final target = _envById(environments, _targetId);
    if (target == null) return null;

    if (target.kind == EnvironmentKind.ssh) {
      if (folder.isNotEmpty) {
        return 'Remote path: $folder';
      } else if (gitUrl.isNotEmpty) {
        final repo = repoNameFromUrl(gitUrl);
        return 'Clone target: ~/karmashala/$repo';
      }
      return null;
    }

    if (folder.isEmpty || _targetId == localHostEnvironmentId) {
      if (gitUrl.isNotEmpty && folder.isNotEmpty) {
        return 'Clone target: $folder';
      }
      return null;
    }

    final windows = _envById(environments, localHostEnvironmentId);
    if (windows == null) return null;
    try {
      final translated = _translator
          .translate(
            EnvironmentPath(environmentId: windows.id, path: folder),
            from: windows,
            to: target,
          )
          .path;
      return gitUrl.isNotEmpty ? 'Clone target: $translated' : translated;
    } on PathTranslationException catch (e) {
      return '⚠ ${e.message}';
    }
  }

  /// How an environment is named in the dropdown — the app's one vocabulary
  /// for that, shared with what the phone is told each checkout lives in.
  static String _environmentLabel(ExecutionEnvironment env) =>
      environmentLabel(env) ?? env.id;

  /// Whether [path] is written the way the distribution or host writes it.
  static bool _isPosixAbsolute(String path) =>
      path.startsWith('/') || path.startsWith('~');

  ExecutionEnvironment? _envById(List<ExecutionEnvironment> envs, String id) {
    for (final e in envs) {
      if (e.id == id) return e;
    }
    return null;
  }

  Future<void> _create() async {
    var name = _nameController.text.trim();
    final folder = _folderController.text.trim();
    final gitUrl = _gitUrlController.text.trim();

    if (name.isEmpty && gitUrl.isNotEmpty) {
      name = repoNameFromUrl(gitUrl);
      _nameController.text = name;
    }

    final environments = ref.read(environmentsControllerProvider);
    final target = _envById(environments, _targetId);
    final isSsh = target?.kind == EnvironmentKind.ssh;

    if (name.isEmpty) {
      setState(() => _error = 'Enter a project name.');
      return;
    }

    if (folder.isEmpty && gitUrl.isEmpty) {
      setState(() => _error = 'Provide a folder path or a Git repository URL.');
      return;
    }

    if (folder.isEmpty &&
        gitUrl.isNotEmpty &&
        !isSsh &&
        target?.kind != EnvironmentKind.wsl) {
      setState(
        () => _error = 'Choose a local destination folder to clone into.',
      );
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final workspaceId = await _resolveWorkspace();
      final ProjectCheckouts result;
      // `createInEnvironment` scans a **Windows** folder and translates; a path
      // already spelled for its own machine must not go through it.
      final nativeToTarget = isSsh || _isPosixAbsolute(folder);
      if (gitUrl.isNotEmpty || nativeToTarget) {
        result = await ref
            .read(projectsControllerProvider.notifier)
            .createProject(
              name: name,
              targetEnvironmentId: _targetId,
              folderPath: folder,
              gitRepoUrl: gitUrl.isEmpty ? null : gitUrl,
              workspaceId: workspaceId,
            );
      } else {
        result = await ref
            .read(projectsControllerProvider.notifier)
            .createInEnvironment(
              name: name,
              windowsPath: folder,
              targetEnvironmentId: _targetId,
              workspaceId: workspaceId,
            );
      }
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
    } on DataRefused catch (e) {
      setState(() => _error = e.message);
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
  Future<String?> _resolveWorkspace() async {
    if (!_namingWorkspace) return _workspaceId;
    final name = _newWorkspaceController.text.trim();
    if (name.isEmpty) return null;
    return (await ref.read(workspacesControllerProvider.notifier).create(name))
        .id;
  }

  @override
  Widget build(BuildContext context) {
    final environments = ref.watch(environmentsControllerProvider);
    final preview = _targetPreview(environments);
    final workspaces = ref.watch(workspacesControllerProvider);
    final target = _envById(environments, _targetId);
    final isSsh = target?.kind == EnvironmentKind.ssh;
    final hasGit = _gitUrlController.text.trim().isNotEmpty;

    return AlertDialog(
      title: const DesktopDialogTitle(
        icon: AppIcons.folderPlus,
        title: 'New project',
        subtitle: 'Add a folder or clone a repository.',
      ),
      content: BoundedDialogContent(
        width: DialogWidth.regular,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // One dialog, two tabs (spec §5): Session swaps this dialog for
            // the new-session one in the same place.
            NewKindSwitch(
              current: NewKind.project,
              onChanged: (_) {
                final navigator = Navigator.of(context);
                final host = navigator.context;
                navigator.pop();
                NewSessionDialog.show(host);
              },
            ),
            DropdownButtonFormField<String>(
              initialValue: _targetId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Environment'),
              items: [
                for (final env in environments)
                  DropdownMenuItem(
                    value: env.id,
                    child: _Choice(_environmentLabel(env)),
                  ),
              ],
              onChanged: (v) => setState(() {
                _targetId = v ?? localHostEnvironmentId;
                _suggestWorkspace();
              }),
            ),
            const SizedBox(height: Insets.md),
            TextField(
              controller: _gitUrlController,
              decoration: const InputDecoration(
                labelText: 'Git repository URL (optional)',
                hintText: 'https://github.com/owner/repo.git',
              ),
              onChanged: (url) {
                if (_nameController.text.trim().isEmpty &&
                    url.trim().isNotEmpty) {
                  setState(() {
                    _nameController.text = repoNameFromUrl(url);
                  });
                } else {
                  setState(() {});
                }
              },
            ),
            const SizedBox(height: Insets.md),
            PathFieldRow.inDialog(
              controller: _folderController,
              label: isSsh
                  ? (hasGit
                        ? 'Remote folder path (optional)'
                        : 'Remote folder path')
                  : (hasGit ? 'Destination folder path' : 'Folder path'),
              hint: isSsh
                  ? (hasGit ? '~/karmashala/<repo>' : '/home/user/project')
                  : (Platform.isWindows
                        ? r'C:\src\karmashala'
                        : '~/src/karmashala'),
              helper: isSsh && hasGit
                  ? 'Defaults to ~/karmashala/<repo> on remote host'
                  : null,
              onChanged: (_) => setState(_suggestWorkspace),
              actions: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _browse,
                  icon: const Icon(AppIcons.folderOpen, size: Chrome.icon),
                  label: const Text('Browse'),
                ),
              ],
            ),
            if (preview != null)
              Padding(
                padding: const EdgeInsets.only(top: Insets.xs),
                child: Text(
                  'Stored as: $preview',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: Insets.md),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Project name',
                hintText: 'Karmashala',
              ),
            ),
            const SizedBox(height: Insets.md),
            _ContextField(
              workspaces: workspaces,
              selectedId: _workspaceId,
              naming: _namingWorkspace,
              newName: _newWorkspaceController,
              enabled: !_busy,
              onSelected: (value) => setState(() {
                _workspaceId = value;
                _workspaceChosen = true;
              }),
              onStartNaming: () => setState(() {
                _namingWorkspace = true;
                _workspaceChosen = true;
              }),
              onStopNaming: () => setState(() {
                _namingWorkspace = false;
                _newWorkspaceController.clear();
              }),
            ),
            if (_error != null) ...[
              const SizedBox(height: Insets.md),
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
              ? const InlineSpinner(size: InlineSpinnerSize.medium)
              : Text(hasGit ? 'Clone & create' : 'Create & scan'),
        ),
      ],
    );
  }
}

/// The context picker: which of the user's four or five contexts this project
/// belongs to. Prefilled from the folder, and a plain "None" is a complete
/// answer — an unassigned project is an ordinary project. [naming] swaps the
/// dropdown for a field that names a new context.
class _ContextField extends StatelessWidget {
  const _ContextField({
    required this.workspaces,
    required this.selectedId,
    required this.naming,
    required this.newName,
    required this.enabled,
    required this.onSelected,
    required this.onStartNaming,
    required this.onStopNaming,
  });

  final List<Workspace> workspaces;
  final String? selectedId;
  final bool naming;
  final TextEditingController newName;
  final bool enabled;
  final ValueChanged<String?> onSelected;
  final VoidCallback onStartNaming;
  final VoidCallback onStopNaming;

  @override
  Widget build(BuildContext context) {
    if (naming) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: newName,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'New context',
                hintText: 'Game dev',
              ),
            ),
          ),
          const SizedBox(width: Insets.sm),
          IconButton(
            tooltip: 'Pick an existing context instead',
            icon: const Icon(AppIcons.x, size: Chrome.icon),
            onPressed: enabled ? onStopNaming : null,
          ),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: DropdownButtonFormField<String?>(
            initialValue: selectedId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Context',
              helperText: 'Suggested from the folder. Change it or leave it.',
            ),
            items: [
              const DropdownMenuItem(value: null, child: _Choice('None')),
              for (final workspace in workspaces)
                DropdownMenuItem(
                  value: workspace.id,
                  child: _Choice(workspace.name),
                ),
            ],
            onChanged: enabled ? onSelected : null,
          ),
        ),
        const SizedBox(width: Insets.sm),
        IconButton(
          tooltip: 'New context',
          icon: const Icon(AppIcons.plus, size: Chrome.icon),
          onPressed: enabled ? onStartNaming : null,
        ),
      ],
    );
  }
}

/// A dropdown choice: one line, ellipsized, because environment and context
/// names are the user's own and have no length.
class _Choice extends StatelessWidget {
  const _Choice(this.label);

  final String label;

  @override
  Widget build(BuildContext context) =>
      Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
}
