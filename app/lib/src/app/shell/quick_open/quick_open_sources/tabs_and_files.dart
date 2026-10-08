part of '../quick_open_sources.dart';

// Presets, artifacts, open tabs, files and repository facts.

extension _TabAndFileSources on QuickOpenSources {
  // --- open terminal tabs --------------------------------------------------

  /// Saved workbench shapes, under `~`. Opening one may leave panes out when a
  /// profile has gone from this machine, and the message says which.
  List<QuickOpenItem> _presets() {
    final presets = ref.read(terminalPresetsProvider);
    final shell = ref.read(shellControllerProvider.notifier);
    final messenger = ScaffoldMessenger.maybeOf(context);
    return [
      for (final preset in presets.all())
        QuickOpenItem(
          id: 'preset/${preset.id}',
          group: QuickOpenGroup.presets,
          title: preset.name,
          subtitle: _describeShape(preset),
          icon: AppIcons.terminalWindow,
          keywords: const ['preset', 'layout', 'terminal', 'workspace'],
          weight: _presetWeight,
          onSelect: () => dismiss(
            _seen(() {
              final opening = presets.open(preset);
              shell.focusPane(ShellPane.detail);
              final said = presetOpenedMessage(preset, opening);
              if (said != null) {
                messenger?.showSnackBar(SnackBar(content: Text(said)));
              }
            }),
          ),
        ),
    ];
  }

  static String _describeShape(TerminalPreset preset) {
    final tabs = preset.tabs.length == 1
        ? '1 tab'
        : '${preset.tabs.length} tabs';
    final panes = preset.paneCount == 1
        ? '1 pane'
        : '${preset.paneCount} panes';
    return '$tabs · $panes';
  }

  /// The terminal tabs nothing else here can reach: one running a session of
  /// ours is already listed as that session, so it is skipped here.
  /// What the session on screen's agent showed, each opened where its card's
  /// Open opens it: the side panel, or full screen on a phone.
  List<QuickOpenItem> _artifacts() {
    final sessionId = ref.read(panelSessionIdProvider);
    if (sessionId == null) return const [];
    final panel = ref.read(sidePanelProvider.notifier);
    return [
      for (final artifact in ref.read(artifactsDataProvider).held(sessionId))
        QuickOpenItem(
          id: 'artifact/${artifact.id}',
          group: QuickOpenGroup.sessions,
          title: artifact.title,
          subtitle:
              'Artifact · ${artifactKindLabel(artifact.kind)} · revision '
              '${artifact.revision}',
          icon: artifactKindIcon(artifact.kind),
          keywords: const ['artifact', 'visualization', 'diagram', 'page'],
          weight: _tabWeight,
          onSelect: () => dismiss(() {
            if (_onPhone || !ref.read(sidePanelRoomProvider)) {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ArtifactScreen(
                    sessionId: sessionId,
                    artifactId: artifact.id,
                  ),
                ),
              );
              return;
            }
            ref.read(selectedArtifactProvider.notifier).select(artifact.id);
            panel.show(SidePanelSurface.artifacts);
          }),
        ),
    ];
  }

  List<QuickOpenItem> _openTabs() {
    final terminals = ref.read(terminalSessionsControllerProvider);
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    final shell = ref.read(shellControllerProvider.notifier);
    final panes = ref.read(paneSessionsProvider);
    return [
      for (final tab in terminals.tabs)
        if (panes.sessionOf(tab.focusedPaneId) == null)
          QuickOpenItem(
            id: 'tab/${tab.id}',
            group: QuickOpenGroup.tabs,
            title: sessions.titleForTab(tab.id),
            // The directory is what tells two `zsh` tabs apart, here for the
            // same reason it does in the strip's picker.
            subtitle: sessions.instanceFor(tab.focusedPaneId)?.workingDirectory,
            detail: tab.id == terminals.activeTabId ? 'current' : null,
            // Settings, a note or a file wear their own glyph, as in the strip.
            icon: documentIconFor(tab) ?? AppIcons.terminal,
            keywords: const ['terminal', 'tab'],
            weight: _tabWeight,
            opensTab: true,
            onSelect: () => dismiss(
              _seen(() {
                sessions.activateTab(tab.id);
                // The group that holds the tab, which activating it has just
                // focused — not whichever group was in front before.
                sessions.revealTab(tab.id);
                shell.focusPane(ShellPane.detail);
              }),
            ),
          ),
    ];
  }

  // --- files ---------------------------------------------------------------

  List<QuickOpenItem> _files(
    List<IndexedFile> files,
    Set<String> changedPaths,
  ) => [
    for (final file in files)
      QuickOpenItem(
        id: 'file/${file.relativePath}',
        group: QuickOpenGroup.files,
        title: file.name,
        subtitle: file.relativePath,
        detail: changedPaths.contains(file.relativePath) ? 'modified' : null,
        icon: AppIcons.article,
        weight: changedPaths.contains(file.relativePath) ? 6 : 0,
        // An editor tab, or a diff tab when it has changes.
        opensTab: true,
        onSelect: () => dismiss(
          _seen(
            () => _openFile(
              file,
              changed: changedPaths.contains(file.relativePath),
            ),
          ),
        ),
      ),
  ];

  /// A file with uncommitted changes opens as its diff; any other opens as
  /// itself. Either way it is a tab, and the panel follows.
  void _openFile(IndexedFile file, {required bool changed}) {
    final panel = ref.read(sidePanelProvider.notifier);
    if (changed &&
        ref.read(diffTabActionsProvider).open(file.relativePath) != null) {
      panel.show(SidePanelSurface.changes);
      return;
    }
    panel.show(SidePanelSurface.files);
    ref.read(editorTabActionsProvider).openAt(file.path);
  }

  // --- branches, pull requests and issues ----------------------------------

  List<QuickOpenItem> _repoFacts() {
    final repositoryId = ref.read(selectedRepositoryIdProvider);
    if (repositoryId == null) return const [];
    final facts = ref
        .read(quickOpenCacheProvider.notifier)
        .factsFor(repositoryId);
    final panel = ref.read(sidePanelProvider.notifier);
    final showRepository = _onPhone
        ? _inContextSheet(SidePanelSurface.repository)
        : () => panel.show(SidePanelSurface.repository);
    return [
      for (final branch in facts.branches)
        QuickOpenItem(
          id: 'branch/$branch',
          group: QuickOpenGroup.branches,
          title: branch,
          subtitle: facts.branches.first == branch
              ? 'Checked out here'
              : 'Worktree branch',
          icon: AppIcons.gitBranch,
          weight: _branchWeight,
          onSelect: () => dismiss(showRepository),
        ),
      for (final pr in facts.pullRequests)
        QuickOpenItem(
          id: 'pr/${pr.number}',
          group: QuickOpenGroup.github,
          title: pr.title,
          subtitle:
              'PR #${pr.number}${pr.author == null ? '' : ' · ${pr.author}'}',
          detail: pr.state.toLowerCase(),
          icon: AppIcons.gitMerge,
          keywords: ['#${pr.number}', 'pull request'],
          weight: _githubWeight,
          onSelect: () => dismiss(showRepository),
        ),
      for (final issue in facts.issues)
        QuickOpenItem(
          id: 'issue/${issue.number}',
          group: QuickOpenGroup.github,
          title: issue.title,
          subtitle: 'Issue #${issue.number}',
          detail: issue.state.toLowerCase(),
          icon: AppIcons.warningCircle,
          keywords: ['#${issue.number}', 'issue'],
          weight: _githubWeight,
          onSelect: () => dismiss(showRepository),
        ),
    ];
  }
}
