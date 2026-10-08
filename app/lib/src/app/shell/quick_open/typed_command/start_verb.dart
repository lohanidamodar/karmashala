part of '../typed_command.dart';

// The start verb: its agent and worktree suggestions, launches and plan.

extension _StartVerb on _Parser {
  List<CommandSuggestion> _agentSuggestions(
    String typed,
    CommandProject project,
  ) {
    final installed = {for (final i in project.installations) i.agentId: i};
    final defaultAgentId = project.installations
        .where((i) => i.id == project.defaultInstallationId)
        .firstOrNull
        ?.agentId;
    final envLabel = catalog.environmentLabel(project.environmentId);
    final ordered = [
      ...catalog.agents.where((a) => a.agentId == defaultAgentId),
      ...catalog.agents.where(
        (a) => a.agentId != defaultAgentId && installed.containsKey(a.agentId),
      ),
      ...catalog.agents.where((a) => !installed.containsKey(a.agentId)),
    ];
    final ranked = _rank(
      typed,
      ordered,
      token: (a) => a.token,
      texts: (a) => [a.displayName],
      usable: (a) => installed.containsKey(a.agentId),
    );
    return [
      for (final agent in ranked)
        CommandSuggestion(
          id: 'agent/${agent.agentId}',
          kind: CommandArgKind.agent,
          label: agent.token,
          hint: agent.displayName,
          detail: agent.agentId == defaultAgentId ? 'default' : null,
          completion: _completion(agent.token),
          disabledReason: installed.containsKey(agent.agentId)
              ? null
              : 'not installed in $envLabel',
        ),
    ];
  }

  CommandSuggestion _worktreeSuggestion(CommandProject project) =>
      CommandSuggestion(
        id: 'flag/worktree',
        kind: CommandArgKind.flag,
        label: '--worktree',
        hint: 'Run in a new Git worktree',
        completion: _completion('--worktree'),
        disabledReason: project.notGit ? _noWorktree(project) : null,
      );

  static String _noWorktree(CommandProject project) =>
      '${project.name} is not a Git repository, so it has no worktrees';

  // --- verbs -----------------------------------------------------------------

  TypedCommand _start() {
    CommandProject? project;
    CommandAgent? agent;
    var worktree = false;
    final words = [...committed];
    // `start session api` reads as English; `session` is a filler unless it is
    // the name of a project.
    if (words.isNotEmpty &&
        words.first.toLowerCase() == 'session' &&
        _projectByToken(words.first) == null) {
      words.removeAt(0);
      _written.add('session');
    }
    // `new appwrite ai`: words that name no project are one search for it.
    if (words.isNotEmpty &&
        !words.first.startsWith('-') &&
        _projectByToken(words.first) == null) {
      final query = [...words, if (partial.isNotEmpty) partial].join(' ');
      if (_asksForNoProject(query) ||
          catalog.projects.any((p) => matchesSearchAny(query, [p.name]))) {
        return _projectPending(query);
      }
    }
    for (final word in words) {
      if (word.startsWith('-')) {
        if (word.toLowerCase() != '--worktree') {
          return _fail('Unknown option $word — start takes --worktree.');
        }
        if (project == null) return _fail('Name a project before --worktree.');
        worktree = true;
        _written.add('--worktree');
        continue;
      }
      if (project == null) {
        project = _projectByToken(word);
        if (project == null) return _fail('No project called "$word".');
        _written.add(project.token);
        continue;
      }
      if (agent == null) {
        agent = _agentByToken(word);
        if (agent == null) return _fail('No agent called "$word".');
        _written.add(agent.token);
        continue;
      }
      return _fail(
        'start takes a project, an agent and --worktree — '
        '"$word" is one too many.',
      );
    }

    var typed = partial;
    if (typed.isNotEmpty) {
      // A finished word the cursor is still on counts as given.
      if (typed.toLowerCase() == '--worktree' && project != null) {
        worktree = true;
        _written.add('--worktree');
        typed = '';
      } else if (project == null && _projectByToken(typed) != null) {
        project = _projectByToken(typed);
        _written.add(project!.token);
        typed = '';
      } else if (project != null &&
          agent == null &&
          _agentByToken(typed) != null) {
        agent = _agentByToken(typed);
        _written.add(agent!.token);
        typed = '';
      }
    }

    if (project == null) return _projectPending(typed);

    final List<CommandSuggestion> suggestions;
    final CommandArgKind? pending;
    if (typed.startsWith('-')) {
      pending = CommandArgKind.flag;
      suggestions = worktree
          ? const []
          : [
              if (commandMatchScore(typed, '--worktree') != null)
                _worktreeSuggestion(project),
            ];
    } else if (agent == null) {
      pending = CommandArgKind.agent;
      suggestions = [
        ..._agentSuggestions(typed, project),
        if (!worktree && typed.isEmpty) _worktreeSuggestion(project),
      ];
    } else if (!worktree) {
      pending = CommandArgKind.flag;
      suggestions = [
        if (commandMatchScore(typed, '--worktree') != null)
          _worktreeSuggestion(project),
      ];
    } else {
      pending = null;
      suggestions = const [];
    }

    // A word still being typed that names nothing yet is not an argument: the
    // plan would silently ignore it.
    final plan = typed.isEmpty ? _startPlan(project, agent, worktree) : null;
    return TypedCommand(
      verb: verb,
      pending: pending,
      suggestions: suggestions,
      plan: plan,
      launches: [_dialogLaunch(project)],
    );
  }

  /// No project named yet: the sessions [typed] could start, then the
  /// projects to complete.
  TypedCommand _projectPending(String typed) => TypedCommand(
    verb: verb,
    pending: CommandArgKind.project,
    suggestions: _projectSuggestions(typed),
    launches: _launches(typed),
  );

  /// Projects given a ready-to-run entry each; the best one also lists its
  /// other agents.
  static const _launchProjects = 5;

  static bool _asksForNoProject(String typed) =>
      matchesSearch(typed, 'no project') || matchesSearch(typed, 'scratch');

  List<CommandPlan> _launches(String typed) {
    final projects = _rank(
      typed,
      catalog.projects,
      token: (p) => p.token,
      texts: (p) => [p.name],
      waiting: (p) => p.waiting,
      recency: (p) => p.recencyRank,
      usable: (p) => p.installations.isNotEmpty,
    ).take(_launchProjects).toList();
    final scratch = _scratchLaunch();
    final noProjectAsked = typed.isNotEmpty && _asksForNoProject(typed);
    final best = projects.firstOrNull;
    return [
      if (noProjectAsked) ?scratch,
      for (final project in projects) _launchIn(project),
      if (best != null && typed.isNotEmpty)
        for (final installation in best.installations)
          if (installation.id != _defaultOf(best)?.id)
            _launchIn(best, other: installation),
      if (!noProjectAsked && typed.isEmpty) ?scratch,
      // With nothing to fill in, the plain "New session…" command below is
      // the same row.
      if ((typed.isNotEmpty && best != null) || message != null)
        _dialogLaunch(typed.isEmpty ? null : best),
    ];
  }

  CommandInstallation? _defaultOf(CommandProject project) =>
      project.installations
          .where((i) => i.id == project.defaultInstallationId)
          .firstOrNull ??
      project.installations.firstOrNull;

  /// What the entry says under its title: what Enter does, and the message.
  String _launchNote(List<String> about) => [
    ...about,
    message == null ? 'add ": message" to say it first' : 'says "$message"',
  ].join(' · ');

  /// A session in [project] on its default agent, or on [other].
  CommandPlan _launchIn(CommandProject project, {CommandInstallation? other}) {
    final installation = other ?? _defaultOf(project);
    final envLabel = catalog.environmentLabel(project.environmentId);
    final agent = installation == null
        ? null
        : catalog.agent(installation.agentId);
    final preview = other == null || agent == null
        ? 'New session in ${project.name}'
        : 'New ${agent.family} ${agent.formLabel.toLowerCase()} in '
              '${project.name}';
    if (installation == null || agent == null) {
      return CommandPlan(
        preview: preview,
        canonical: 'start ${project.token}',
        refusal: 'No agent is installed in $envLabel.',
      );
    }
    return CommandPlan(
      preview: preview,
      canonical: 'start ${project.token} ${agent.token}',
      note: _launchNote([
        if (other == null) ...[agent.family, agent.formLabel],
        envLabel,
      ]),
      action: StartCommand(
        projectId: project.id,
        installationId: installation.id,
        firstMessage: message,
      ),
    );
  }

  /// A session with no project, in a scratch folder.
  CommandPlan? _scratchLaunch() {
    final installation = catalog.scratchInstallation;
    if (installation == null) return null;
    final agent = catalog.agent(installation.agentId);
    return CommandPlan(
      preview: 'New session (no project)',
      canonical: 'new no project',
      note: _launchNote([
        if (agent != null) ...[agent.family, agent.formLabel],
        'a scratch folder',
      ]),
      action: StartCommand(
        projectId: null,
        installationId: installation.id,
        firstMessage: message,
      ),
    );
  }

  /// The dialog, opened on [project] and the message, for what an entry
  /// cannot say: a worktree, a title, an external terminal.
  CommandPlan _dialogLaunch(CommandProject? project) => CommandPlan(
    preview: 'New session…',
    canonical: '',
    note: project == null
        ? 'Open the New session dialog'
        : 'Open the New session dialog on ${project.name}',
    action: OpenNewSessionDialogCommand(
      projectId: project?.id,
      firstMessage: message,
    ),
  );

  CommandPlan _startPlan(
    CommandProject project,
    CommandAgent? named,
    bool worktree,
  ) {
    final envLabel = catalog.environmentLabel(project.environmentId);
    CommandInstallation? installation;
    if (named != null) {
      installation = project.installations
          .where((i) => i.agentId == named.agentId)
          .firstOrNull;
    } else {
      installation =
          project.installations
              .where((i) => i.id == project.defaultInstallationId)
              .firstOrNull ??
          project.installations.firstOrNull;
    }
    final agent =
        named ??
        (installation == null ? null : catalog.agent(installation.agentId));
    final agentName = agent?.displayName ?? 'an agent';
    final preview = [
      'Start $agentName in ${project.name}',
      envLabel,
      if (project.branch != null) 'branch ${project.branch}',
      if (worktree) 'in a new worktree',
    ].join(' · ');
    final canonical = [
      'start',
      project.token,
      ?agent?.token,
      if (worktree) '--worktree',
    ].join(' ');
    String? refusal;
    if (project.installations.isEmpty) {
      refusal = 'No agent is installed in $envLabel.';
    } else if (installation == null) {
      refusal = '${named!.displayName} is not installed in $envLabel.';
    } else if (worktree && project.notGit) {
      refusal = '${_noWorktree(project)}.';
    }
    return CommandPlan(
      preview: preview,
      canonical: canonical,
      refusal: refusal,
      note: message == null ? null : 'Enter to run · says "$message"',
      action: refusal == null
          ? StartCommand(
              projectId: project.id,
              installationId: installation!.id,
              worktree: worktree,
              firstMessage: message,
            )
          : null,
    );
  }
}
