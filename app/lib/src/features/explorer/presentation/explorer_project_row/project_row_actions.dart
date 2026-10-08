// What a project row's taps and menu do, and the remove dialog.

part of '../explorer_project_row.dart';

/// What a project row's taps and menu do. Holds no state of its own: the
/// expansion lives in [explorerExpandedProjectsProvider].
class ProjectRowActions {
  ProjectRowActions(this.ref, this.context, this.project);

  final WidgetRef ref;
  final BuildContext context;
  final Project project;

  void _say(String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void toggle() {
    ref.read(explorerExpandedProjectsProvider.notifier).toggle(project.id);
    // A deliberate pick outranks wherever the pane on screen has wandered to,
    // until you move panes yourself.
    ref.read(explorerFollowHoldProvider.notifier).hold();
    ref.read(selectedProjectIdProvider.notifier).select(project.id);
    // Single-repository projects select that repository so "New session" and
    // the detail view have a working context immediately.
    final repos = ref.read(workspaceDataProvider).repositoriesOf(project.id);
    if (repos.length == 1) {
      ref.read(selectedRepositoryIdProvider.notifier).select(repos.first.id);
    }
    // Nothing is scanned here: `explorer_expand_scan_cost_test.dart` pins it.
  }

  void togglePin() => ref
      .read(settingsControllerProvider.notifier)
      .togglePinnedProject(project.id);

  /// " · checked 3m ago", or " · never checked" when nothing has read the
  /// stores for this project yet.
  String checkedSuffix() {
    final at = ref.read(cliSessionsCheckedProvider).forProject(project.id);
    if (at == null) return ' · never checked';
    final now = ref.read(clockProvider).nowUtc();
    return ' · checked ${describeAge(now.difference(at))}';
  }

  /// Where a session started *at the project* runs — the checkout the project
  /// chose, else the first one the picker would offer, so the `+` and the
  /// dialog cannot pick different clones.
  Repository? _defaultCheckout() => projectDefaultCheckout(
    defaultRepositoryId: project.defaultRepositoryId,
    offered: ref.read(checkoutsInProjectProvider(project.id)),
    all: ref.read(workspaceDataProvider).repositoriesOf(project.id),
  );

  /// [_defaultCheckout], falling back to the project's own folder for a project
  /// that has no checkout recorded at all — a folder is enough to run in. Null
  /// only once the real reason has been said.
  Future<Repository?> _runLocation() async {
    final chosen = _defaultCheckout();
    if (chosen != null) return chosen;
    try {
      return await ref
          .read(projectsControllerProvider.notifier)
          .ensureRunLocation(project.id);
    } on StateError catch (error) {
      _say(error.message);
      return null;
    }
  }

  Future<void> _startSession({
    required Repository repository,
    AgentInstallation? installation,
  }) async {
    final result = await ref
        .read(explorerActionsProvider)
        .startSession(repository: repository, installation: installation);
    final message = result.message;
    if (message != null) _say(message);
  }

  /// The `+`: starts a session with [SessionDefaults] and no dialog — unless a
  /// piece is missing, when the dialog opens to name it.
  Future<void> startWithDefaults() async {
    final repository = await _runLocation();
    // Null only once `_runLocation` has said why; opening the dialog would ask
    // the same question again and answer it with the same sentence.
    if (repository == null) return;
    final defaults = ref.read(sessionDefaultsProvider).forCheckout(repository);
    if (!defaults.isComplete) {
      await newSessionDialog(repository: repository);
      return;
    }
    // The card the session appears on has to be on screen: a start nobody can
    // see is indistinguishable from a dead click.
    if (ref.read(selectedProjectIdProvider) != project.id) {
      ref.read(selectedProjectIdProvider.notifier).select(project.id);
    }
    ref.read(explorerExpandedProjectsProvider.notifier).open(project.id);
    await _startSession(
      repository: repository,
      installation: defaults.installation,
    );
  }

  Future<void> newSessionDialog({Repository? repository}) async {
    ref.read(selectedProjectIdProvider.notifier).select(project.id);
    ref.read(explorerExpandedProjectsProvider.notifier).open(project.id);
    final repo = repository ?? await _runLocation();
    // The dialog opens on the current selection, so opening it with nowhere to
    // run would point it at whichever other project was last selected.
    // `_runLocation` has already said why there is nowhere.
    if (repo == null || !context.mounted) return;
    ref.read(selectedRepositoryIdProvider.notifier).select(repo.id);
    unawaited(NewSessionDialog.show(context));
  }

  void openTerminal() {
    final env = ref
        .read(environmentsDataProvider)
        .getById(project.environmentId);
    final controller = ref.read(terminalSessionsControllerProvider.notifier);
    final sshHostId = env?.sshHostId;
    final TerminalProfile profile;
    if (sshHostId != null) {
      profile = TerminalProfile.ssh(sshHostId, hostName: env?.name);
    } else if (env?.kind == EnvironmentKind.wsl) {
      final distro = env?.wslDistribution ?? env?.name ?? '';
      profile = TerminalProfile(
        id: TerminalProfile.wslId(distro),
        label: '$distro (WSL)',
        shell: TerminalShell.wsl,
        wslDistribution: distro,
      );
    } else {
      profile = TerminalProfile.powerShell;
    }
    controller.openTab(profile, workingDirectory: project.root.path);
    controller.showTerminalHere();
  }

  Future<void> _syncSessions() async {
    try {
      final result = await ref
          .read(projectsControllerProvider.notifier)
          .syncSessions(project.id);
      _say(
        result.sessions == 0
            ? 'Sessions are up to date.'
            : 'Added ${result.sessions} CLI session${result.sessions == 1 ? '' : 's'}.',
      );
    } catch (error) {
      _say('Could not refresh sessions: $error');
    }
  }

  /// Re-runs discovery over the project's folder, which is what turns a "not
  /// scanned yet" row into a real repository row.
  Future<void> _rescan() async {
    try {
      final added = await ref
          .read(projectsControllerProvider.notifier)
          .rediscover(project.id);
      _say(
        added.isEmpty
            ? 'No new repositories found in ${project.name}.'
            : 'Found ${added.length} '
                  'repositor${added.length == 1 ? 'y' : 'ies'}.',
      );
    } catch (error) {
      _say(error is StateError ? error.message : 'Could not rescan: $error');
    }
  }

  /// [RevealInFileManager.reveal] reports failure as a [RevealOutcome].
  Future<void> _reveal() async {
    final outcome = await ref
        .read(revealInFileManagerProvider)
        .reveal(project.root);
    if (!outcome.ok) _say(outcome.error!);
  }

  Future<void> _copyPath() async {
    await Clipboard.setData(ClipboardData(text: project.root.path));
    _say('Path copied to clipboard');
  }

  /// With [chooseSubfolder], a picker rooted at the project chooses a
  /// sub-folder to open instead of the project root.
  Future<void> _openInEditor({bool chooseSubfolder = false}) async {
    final actions = ref.read(editorActionsProvider);
    String? subPath;
    if (chooseSubfolder) {
      final picked = await pickOneDirectory(
        context: context,
        what: 'a folder of ${project.name} to open',
        startNear: project.root.path,
        confirmButtonText: 'Open in editor',
      );
      if (picked == null) return;
      subPath = picked;
    }
    try {
      await actions.openProject(project.id, subPath: subPath);
      _say('Opening in editor…');
    } catch (e) {
      _say(e is StateError ? e.message : '$e');
    }
  }

  Future<void> _confirmDelete() async {
    final deleteCliSessions = await showDialog<bool>(
      context: context,
      builder: (context) => _RemoveProjectDialog(name: project.name),
    );
    if (deleteCliSessions == null) return;
    try {
      await ref
          .read(projectsControllerProvider.notifier)
          .deleteProject(project.id, deleteCliSessions: deleteCliSessions);
    } on DataRefused catch (refusal) {
      // The server's words, where the person is looking — not an uncaught
      // error in the log.
      _say(refusal.message);
    }
  }

  /// Files the project where the menu said, and says what happened.
  Future<void> _applyContextAction(String action) async {
    final target = action.substring(_contextAction.length);
    final controller = ref.read(workspacesControllerProvider.notifier);
    if (target == _noContext) {
      await controller.assign(project.id, null);
      // Named in full, because the menu's other leaving verb deletes the
      // project and this one must not be mistaken for it.
      _say('"${project.name}" is no longer in a context. It is still here.');
      return;
    }
    if (target == _newContext) {
      final created = await NewContextDialog.show(
        context,
        forProjectNamed: project.name,
      );
      if (created == null) return;
      await controller.assign(project.id, created.id);
      _say('Moved "${project.name}" to ${created.name}.');
      return;
    }
    if (project.workspaceId == target) return;
    await controller.assign(project.id, target);
    final name = ref
        .read(workspacesControllerProvider)
        .where((w) => w.id == target)
        .map((w) => w.name)
        .firstOrNull;
    if (name != null) _say('Moved "${project.name}" to $name.');
  }

  void onMenu(String action) {
    if (action.startsWith('new-with:')) {
      final id = action.substring('new-with:'.length);
      final installation = ref
          .read(agentInstallationsDataProvider)
          .getByEnvironment(project.root.environmentId)
          .where((installation) => installation.id == id)
          .firstOrNull;
      if (installation == null) return;
      unawaited(
        _runLocation().then((repo) {
          if (repo != null) {
            _startSession(repository: repo, installation: installation);
          }
        }),
      );
      return;
    }
    if (action.startsWith(_contextAction)) {
      _applyContextAction(action);
      return;
    }
    switch (action) {
      case 'new-session':
        newSessionDialog();
      case 'terminal':
        openTerminal();
      case 'copy-cmd':
        copyCommandToClipboard(
          context,
          () => ref
              .read(sessionActionsProvider)
              .newSessionShellCommand(project.id),
        );
      case 'open-editor':
        _openInEditor();
      case 'open-editor-subfolder':
        _openInEditor(chooseSubfolder: true);
      case 'reveal':
        _reveal();
      case 'copy-path':
        _copyPath();
      case 'edit':
        EditProjectDialog.show(context, project);
      case 'pin':
        togglePin();
      case 'refresh':
        _syncSessions();
      case 'rescan':
        _rescan();
      case 'delete':
        _confirmDelete();
    }
  }
}

/// Asks before removing a project. Pops null for cancel, otherwise whether to
/// delete the CLI's session files too.
class _RemoveProjectDialog extends StatefulWidget {
  const _RemoveProjectDialog({required this.name});

  final String name;

  @override
  State<_RemoveProjectDialog> createState() => _RemoveProjectDialogState();
}

class _RemoveProjectDialogState extends State<_RemoveProjectDialog> {
  bool _deleteCliSessions = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const DesktopDialogTitle(
      icon: AppIcons.trash,
      title: 'Remove project?',
      subtitle: 'This only changes the Karmashala workspace.',
    ),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Removes "${widget.name}" and all its sessions from the workspace.',
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _deleteCliSessions,
          onChanged: (v) => setState(() => _deleteCliSessions = v ?? false),
          title: const Text('Also delete session files on disk'),
          subtitle: const Text(
            "Permanently removes this project's Claude/Codex session "
            'history from the CLI store. Otherwise, files on disk are '
            'left untouched.',
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      DestructiveButton(
        onPressed: () => Navigator.of(context).pop(_deleteCliSessions),
        child: const Text('Delete'),
      ),
    ],
  );
}
