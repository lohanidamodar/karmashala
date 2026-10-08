part of '../quick_open_sources.dart';

// Contexts, projects and repositories, and the steps a project or repository opens.

extension QuickOpenWorkspaceSources on QuickOpenSources {
  // --- contexts -----------------------------------------------------------

  /// Switching the project list's context from the palette. "All projects" is
  /// listed first: the way out must not be harder to reach than the way in.
  List<QuickOpenItem> _contexts() {
    final workspaces = ref.read(workspacesControllerProvider);
    if (workspaces.isEmpty) return const [];
    final scope = ref.read(workspaceScopeProvider);
    final counts = ref.read(workspaceProjectCountsProvider);
    final scopes = ref.read(workspaceScopeProvider.notifier);

    QuickOpenItem item({
      required String id,
      required String title,
      required String subtitle,
      required IconData icon,
      required bool current,
      required WorkspaceScope target,
    }) => QuickOpenItem(
      id: 'context/$id',
      group: QuickOpenGroup.contexts,
      title: title,
      subtitle: subtitle,
      // Said rather than implied: the palette is the one place you can pick the
      // filter you are already looking at, and doing so must not look broken.
      detail: current ? 'Showing' : null,
      icon: icon,
      keywords: const ['context', 'filter'],
      weight: _contextWeight,
      onSelect: () => dismiss(_inProjects(() => scopes.select(target))),
    );

    return [
      item(
        id: 'all',
        title: 'All projects',
        subtitle: 'Show every project, in any context',
        icon: AppIcons.folders,
        current: scope.isAll,
        target: WorkspaceScope.all,
      ),
      for (final workspace in workspaces)
        item(
          id: workspace.id,
          title: workspace.name,
          subtitle: describeWorkspace(
            workspace,
            projectCount: counts[workspace.id] ?? 0,
          ),
          icon: AppIcons.stack,
          current: scope.workspaceId == workspace.id,
          target: WorkspaceScope.of(workspace.id),
        ),
      item(
        id: 'none',
        title: 'No context',
        subtitle: 'Only the projects filed under nothing',
        icon: AppIcons.minusCircle,
        current: scope.unassignedOnly,
        target: WorkspaceScope.unassigned,
      ),
    ];
  }

  // --- projects and repositories ------------------------------------------

  List<QuickOpenItem> _workspace() {
    final items = <QuickOpenItem>[];
    final workspace = ref.read(workspaceDataProvider);
    for (final project in ref.read(sortedProjectsProvider)) {
      items.add(
        QuickOpenItem(
          id: 'project/${project.id}',
          group: QuickOpenGroup.workspace,
          title: project.name,
          subtitle: 'Project',
          icon: AppIcons.folder,
          keywords: [project.root.path],
          weight: _workspaceWeight,
          onSelect: () => push(projectStep(project)),
        ),
      );
      for (final repository in workspace.repositoriesOf(project.id)) {
        items.add(
          QuickOpenItem(
            id: 'repository/${repository.id}',
            group: QuickOpenGroup.workspace,
            title: repository.name,
            subtitle: '${project.name} · repository',
            icon: AppIcons.gitBranch,
            keywords: [repository.path.path],
            weight: _workspaceWeight,
            // Through the project's step, so the breadcrumb and Backspace are
            // what drilling in from the project gives.
            onSelect: () {
              push(projectStep(project));
              push(repositoryStep(project, repository));
            },
          ),
        );
      }
    }
    return items;
  }

  // --- a project's and a repository's own steps ----------------------------

  /// What can be done with [project]: a new session first, so project → Enter
  /// → Enter starts one; its sessions; a terminal and the files there; its
  /// repositories, each a step; and the sidebar jump picking it used to make.
  QuickOpenStep projectStep(Project project) => QuickOpenStep(
    id: 'project/${project.id}',
    title: project.name,
    hintText: 'Act on ${project.name}, or find one of its sessions',
    items: () {
      final repositories = ref
          .read(workspaceDataProvider)
          .repositoriesOf(project.id);
      final id = 'project/${project.id}';
      return [
        _newSessionIn(
          id,
          subtitle: project.name,
          // Read when picked, not listed: the checkout the Explorer's `+` and
          // the typed `start` would choose.
          destination: () => SessionDestination(
            projectId: project.id,
            checkout: commandDefaultCheckout(
              ProviderScope.containerOf(context, listen: false),
              project.id,
            ),
          ),
        ),
        ..._sessions(projectId: project.id),
        // The project's folder, or each repository's when there are several:
        // a parent folder of three clones is rarely where the work is.
        if (repositories.length <= 1)
          ?_terminalIn(id, project.root)
        else
          for (final repository in repositories)
            ?_terminalIn(
              'repository/${repository.id}',
              repository.path,
              title: 'Open a terminal in ${repository.name}',
            ),
        _filesIn(id, project.root),
        _showInSidebar(
          id,
          () => ref.read(selectedProjectIdProvider.notifier).select(project.id),
        ),
        // One repository is the project again; drilling into it says nothing.
        if (repositories.length > 1)
          for (final repository in repositories)
            QuickOpenItem(
              id: '$id/repository/${repository.id}',
              group: QuickOpenGroup.repositories,
              title: repository.name,
              subtitle: repository.path.path,
              icon: AppIcons.gitBranch,
              keywords: const ['repository'],
              onSelect: () => push(repositoryStep(project, repository)),
            ),
      ];
    },
  );

  /// [projectStep] for one checkout: everything there is scoped to it.
  QuickOpenStep repositoryStep(
    Project project,
    Repository repository,
  ) => QuickOpenStep(
    id: 'repository/${repository.id}',
    title: repository.name,
    hintText: 'Act on ${repository.name}, or find one of its sessions',
    items: () {
      final id = 'repository/${repository.id}';
      return [
        _newSessionIn(
          id,
          subtitle: '${project.name} · ${repository.name}',
          destination: () =>
              SessionDestination(projectId: project.id, checkout: repository),
        ),
        ..._sessions(repositoryId: repository.id),
        ?_terminalIn(id, repository.path),
        _filesIn(id, repository.path),
        _showInSidebar(id, () {
          ref.read(selectedProjectIdProvider.notifier).select(project.id);
          ref.read(selectedRepositoryIdProvider.notifier).select(repository.id);
        }),
      ];
    },
  );

  /// The New-session dialog, opened on [destination] rather than on whatever
  /// the app is pointed at; nothing is selected until its Start.
  QuickOpenItem _newSessionIn(
    String id, {
    required String subtitle,
    required SessionDestination Function() destination,
  }) => QuickOpenItem(
    id: '$id/new-session',
    group: QuickOpenGroup.sessions,
    title: 'New session…',
    subtitle: subtitle,
    icon: AppIcons.chatCircleDots,
    keywords: const ['start', 'agent'],
    onSelect: () {
      final where = destination();
      dismiss(() => _newSessionDialog(destination: where));
    },
  );

  /// A shell on [where]'s machine, started in [where] — the Explorer's own
  /// "open a terminal on" — or nothing when that machine is no longer recorded.
  QuickOpenItem? _terminalIn(
    String id,
    EnvironmentPath where, {
    String title = 'Open a terminal',
  }) {
    final environment = ref
        .read(environmentsDataProvider)
        .getById(where.environmentId);
    if (environment == null) return null;
    return QuickOpenItem(
      id: '$id/terminal',
      group: QuickOpenGroup.actions,
      title: title,
      subtitle: where.path,
      icon: AppIcons.terminal,
      keywords: const ['shell', 'terminal', 'console'],
      opensTab: true,
      onSelect: () => dismiss(
        _seen(
          () => openTerminalOn(ref, environment, workingDirectory: where.path),
        ),
      ),
    );
  }

  /// The file browser, this machine on the left and [where] on the right.
  QuickOpenItem _filesIn(String id, EnvironmentPath where) => QuickOpenItem(
    id: '$id/files',
    group: QuickOpenGroup.actions,
    title: 'Browse files',
    subtitle: where.path,
    icon: AppIcons.folderOpen,
    keywords: const ['files', 'sftp', 'upload', 'download', 'copy'],
    opensTab: true,
    onSelect: () => dismiss(
      _seen(() => openFilesTabOn(ref, where.environmentId, path: where.path)),
    ),
  );

  /// What picking a project or repository did before it opened a step: [select]
  /// it, and bring up the Projects area that draws the selection.
  QuickOpenItem _showInSidebar(String id, VoidCallback select) => QuickOpenItem(
    id: '$id/show',
    group: QuickOpenGroup.actions,
    title: _onPhone ? 'Show in Projects' : 'Show in sidebar',
    subtitle: _onPhone ? 'The Projects tab' : 'The Projects sidebar',
    icon: AppIcons.treeStructure,
    keywords: const ['select', 'reveal', 'explorer', 'projects'],
    onSelect: () => dismiss(_inProjects(select)),
  );
}
