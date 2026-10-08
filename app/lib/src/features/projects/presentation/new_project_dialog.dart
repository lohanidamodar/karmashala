import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import '../../../app/widgets/full_screen_form.dart';
import '../../../core/capabilities/capabilities.dart'
    show capabilitiesProvider, kAddProjectNotGranted;
import '../../sessions/presentation/new_dialog_section.dart';
import '../../sessions/presentation/new_session_dialog.dart';

import 'package:agent_cli/process.dart';
import 'package:karmashala_ui/picking.dart';
import '../../environments/application/environments_controller.dart';
import '../../files/data/files_client.dart';
import '../../settings/presentation/path_field_row.dart';
import 'package:karmashala_git/repositories.dart';
import '../../workspaces/application/workspace_suggestion.dart';
import '../../workspaces/application/workspaces_controller.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../agents/data/agents_data.dart';
import '../../git/data/git_data.dart';
import 'package:karmashala_git/git.dart';
import '../application/project_service.dart';
import '../application/project_source_preview.dart';
import '../application/projects_controller.dart';

part 'new_project_dialog/source_section.dart';

/// Creates a project from a folder or Git repository URL. Supports local,
/// WSL, and SSH environments.
class NewProjectDialog extends ConsumerStatefulWidget {
  const NewProjectDialog({this.initialEnvironmentId, super.key});

  final String? initialEnvironmentId;

  /// A phone not granted `add_project` is told so instead: every way in
  /// comes through here.
  static Future<bool?> show(
    BuildContext context, {
    String? initialEnvironmentId,
  }) {
    final container = ProviderScope.containerOf(context, listen: false);
    if (!container.read(capabilitiesProvider).mayAddProject) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text(kAddProjectNotGranted)));
      return Future.value(false);
    }
    return showFormDialog<bool>(
      context: context,
      builder: (_) =>
          NewProjectDialog(initialEnvironmentId: initialEnvironmentId),
    );
  }

  @override
  ConsumerState<NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends ConsumerState<NewProjectDialog> {
  final _gitUrlController = TextEditingController();
  final _nameController = TextEditingController();
  final _folderController = TextEditingController();
  final _newWorkspaceController = TextEditingController();
  late String _targetId;

  /// Whether the name is still the dialog's own guess. It follows the Git URL
  /// or the folder until the person types a name, and again once they clear
  /// it; a name they typed is never replaced.
  var _nameIsSuggested = true;

  /// The context the project will be filed under — a guess until the user
  /// touches it, and never applied to anything that already exists.
  String? _workspaceId;

  /// Once the user has answered the question themselves, the folder stops
  /// answering it for them. A guess that keeps overwriting a decision is worse
  /// than no guess.
  bool _workspaceChosen = false;
  bool _namingWorkspace = false;
  bool _busy = false;

  /// Which button is working: the spinner goes on that one.
  bool _busyScanning = false;
  String? _error;

  /// Whether the folder is there on the target; null until the server said.
  bool? _folderExists;
  bool _createFolder = true;
  bool _initGit = true;

  /// What the chosen folder holds (spec §5), read after typing pauses.
  late final ProjectSourcePreviewReader _reader;
  Timer? _previewPause;
  ProjectSourcePreview? _preview;
  EnvironmentPath? _previewedRoot;
  bool _previewing = false;

  static const _translator = PathTranslator();

  @override
  void initState() {
    super.initState();
    _targetId = widget.initialEnvironmentId ?? localHostEnvironmentId;
    _reader = ProjectSourcePreviewReader(
      ref.read(gitDataProvider),
      ref.read(commandRunnerFactoryProvider),
      ref.read(agentWorkProvider),
    );
  }

  /// Reads the folder once typing pauses. Cancelled on close, so no read
  /// outlives the dialog.
  void _schedulePreview() {
    _previewPause?.cancel();
    _previewPause = Timer(const Duration(milliseconds: 400), _readPreview);
  }

  Future<void> _readPreview() async {
    if (!mounted) return;
    final environments = ref.read(environmentsControllerProvider);
    final root = _storedRoot(environments);
    final environment = _envById(environments, _targetId);
    // A clone's folder does not exist yet: there is nothing in it to read.
    if (root == null ||
        environment == null ||
        _gitUrlController.text.trim().isNotEmpty) {
      setState(() {
        _preview = null;
        _previewedRoot = null;
        _previewing = false;
        _folderExists = null;
      });
      return;
    }
    if (root == _previewedRoot &&
        (_preview != null || _folderExists == false)) {
      return;
    }
    setState(() {
      _previewedRoot = root;
      _previewing = true;
      _folderExists = null;
    });
    final exists = await _folderThere(root);
    // A later folder has been asked about since: this answer is for no one.
    if (!mounted || _previewedRoot != root) return;
    if (exists == false) {
      setState(() {
        _folderExists = false;
        _preview = null;
        _previewing = false;
      });
      return;
    }
    final read = await _reader.read(root, environment);
    if (!mounted || _previewedRoot != root) return;
    setState(() {
      _folderExists = exists;
      _preview = read;
      _previewing = false;
    });
  }

  /// Whether [root] is on its machine, asked of the server; null when it
  /// could not say, which shows nothing rather than a guess.
  Future<bool?> _folderThere(EnvironmentPath root) async {
    try {
      final files = ref.read(filesClientProvider);
      var path = root;
      if (root.path == '~' || root.path.startsWith('~/')) {
        final home = await files.home(root.environmentId);
        path = EnvironmentPath(
          environmentId: root.environmentId,
          path: '${home.path}${root.path.substring(1)}',
        );
      }
      return (await files.stat(path)).exists;
    } on Object {
      return null;
    }
  }

  @override
  void dispose() {
    _previewPause?.cancel();
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
      _suggestName();
      _suggestWorkspace();
    });
    _schedulePreview();
  }

  /// Names the project after its repository, else its folder, while the name
  /// is still the dialog's guess.
  void _suggestName() {
    if (!_nameIsSuggested) return;
    final url = _gitUrlController.text.trim();
    final folder = _folderController.text.trim();
    _nameController.text = url.isNotEmpty
        ? repoNameFromUrl(url)
        : folder.isEmpty
        ? ''
        : _leafOf(folder);
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

  /// Records the project: the folder alone, or with [scan] every repository
  /// beneath it. A clone always scans what it cloned.
  Future<void> _create({required bool scan}) async {
    var name = _nameController.text.trim();
    final folder = _folderController.text.trim();
    final gitUrl = _gitUrlController.text.trim();

    if (name.isEmpty && (gitUrl.isNotEmpty || folder.isNotEmpty)) {
      name = gitUrl.isNotEmpty ? repoNameFromUrl(gitUrl) : _leafOf(folder);
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

    final cloning = gitUrl.isNotEmpty;
    final scanning = scan || cloning;
    final makeFolder =
        !cloning &&
        _folderExists == false &&
        _createFolder &&
        ref.read(capabilitiesProvider).createsProjectFolders;
    setState(() {
      _busy = true;
      _busyScanning = scanning && !cloning;
      _error = null;
    });

    try {
      final workspaceId = await _resolveWorkspace();
      final ProjectCheckouts result;
      // `createInEnvironment` scans a **Windows** folder and translates; a path
      // already spelled for its own machine must not go through it.
      final nativeToTarget = isSsh || _isPosixAbsolute(folder);
      if (cloning || nativeToTarget) {
        result = await ref
            .read(projectsControllerProvider.notifier)
            .createProject(
              name: name,
              targetEnvironmentId: _targetId,
              folderPath: folder,
              gitRepoUrl: cloning ? gitUrl : null,
              workspaceId: workspaceId,
              createFolder: makeFolder,
              initGit: makeFolder && _initGit,
              scan: scanning,
            );
      } else {
        result = await ref
            .read(projectsControllerProvider.notifier)
            .createInEnvironment(
              name: name,
              windowsPath: folder,
              targetEnvironmentId: _targetId,
              workspaceId: workspaceId,
              createFolder: makeFolder,
              initGit: makeFolder && _initGit,
              scan: scanning,
            );
      }
      if (!mounted) return;
      final found = result.repositories.length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            scanning
                ? 'Created "${result.project.name}": $found '
                      '${found == 1 ? 'repository' : 'repositories'} found'
                : 'Created "${result.project.name}"',
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
      if (mounted) {
        setState(() {
          _busy = false;
          _busyScanning = false;
        });
      }
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
    final createsFolders = ref
        .watch(capabilitiesProvider)
        .createsProjectFolders;
    final missing = !hasGit && _folderExists == false;

    final body = Column(
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
        // Three labelled parts in the order the choice is made (spec §5):
        // the machine, what to add from it, and what to call it.
        NewDialogSection(
          label: 'Machine',
          first: true,
          child: DropdownButtonFormField<String>(
            initialValue: _targetId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Machine'),
            items: [
              for (final env in environments)
                DropdownMenuItem(
                  value: env.id,
                  child: _Choice(_environmentLabel(env)),
                ),
            ],
            onChanged: (v) {
              setState(() {
                _targetId = v ?? localHostEnvironmentId;
                _suggestWorkspace();
              });
              _schedulePreview();
            },
          ),
        ),
        NewDialogSection(
          label: 'Folder or clone',
          child: _source(
            isSsh: isSsh,
            hasGit: hasGit,
            preview: preview,
            missing: missing,
            createsFolders: createsFolders,
          ),
        ),
        if (hasGit || (!missing && _folderController.text.trim().isNotEmpty))
          NewDialogSection(
            label: 'What was found',
            child: _ProjectSourceFacts(
              cloneUrl: hasGit ? _gitUrlController.text.trim() : null,
              preview: _preview,
              reading: _previewing,
            ),
          ),
        NewDialogSection(
          label: 'Name & context',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Project name',
                  hintText: 'Named after the folder if left empty',
                ),
                onChanged: (name) => _nameIsSuggested = name.trim().isEmpty,
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
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: Insets.md),
          DesktopErrorBanner(_error!),
        ],
      ],
    );
    final VoidCallback? cancel = _busy
        ? null
        : () => Navigator.of(context).pop(false);
    // Plain Create records the folder alone; scanning is the second choice,
    // and pointless for a folder about to be made. A server without the
    // feature always scans, so it gets today's one button.
    final plain = createsFolders && !hasGit;
    final create = FilledButton(
      key: const ValueKey('new-project-create'),
      onPressed: _busy ? null : () => _create(scan: !plain),
      child: _busy && !_busyScanning
          ? const InlineSpinner(size: InlineSpinnerSize.medium)
          : Text(
              hasGit
                  ? 'Clone & create'
                  : plain
                  ? 'Create'
                  : 'Create & scan',
            ),
    );
    final scan = plain && !missing
        ? OutlinedButton(
            key: const ValueKey('new-project-create-scan'),
            onPressed: _busy ? null : () => _create(scan: true),
            child: _busyScanning
                ? const InlineSpinner(size: InlineSpinnerSize.medium)
                : const Text('Create & scan'),
          )
        : null;
    if (opensFullScreen(context)) {
      return FullScreenForm(
        title: 'New project',
        body: scan == null
            ? body
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  body,
                  const SizedBox(height: Insets.lg),
                  Align(alignment: Alignment.centerRight, child: scan),
                ],
              ),
        onClose: cancel,
        primary: create,
      );
    }
    return AlertDialog(
      title: const DesktopDialogTitle(
        icon: AppIcons.folderPlus,
        title: 'New project',
        subtitle: 'Add a folder or clone a repository.',
      ),
      content: BoundedDialogContent(width: DialogWidth.regular, child: body),
      actions: [
        TextButton(onPressed: cancel, child: const Text('Cancel')),
        ?scan,
        create,
      ],
    );
  }
}
