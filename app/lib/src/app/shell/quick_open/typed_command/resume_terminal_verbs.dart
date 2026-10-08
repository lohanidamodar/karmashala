part of '../typed_command.dart';

// The resume and open terminal verbs.

extension _ResumeTerminalVerbs on _Parser {
  TypedCommand _resume() {
    CommandProject? project;
    CommandSession? session;
    var used = 0;
    for (final word in committed) {
      // What follows the session is said to it as it comes back.
      if (session != null) break;
      used++;
      if (project == null) {
        project = _projectByToken(word);
        if (project != null) {
          _written.add(project.token);
          continue;
        }
      }
      session = _sessionByToken(word);
      if (session == null ||
          (project != null && session.projectId != project.id)) {
        return _fail(
          project == null
              ? 'No session or project called "$word".'
              : 'No session called "$word" in ${project.name}.',
        );
      }
      _written.add(session.token);
    }
    var typed = partial;
    if (session == null && project == null && typed.isNotEmpty) {
      final exact = _projectByToken(typed);
      if (exact != null) {
        project = exact;
        _written.add(exact.token);
        typed = '';
      }
    }
    if (session == null && typed.isNotEmpty) {
      final exact = _sessionByToken(typed);
      if (exact != null && (project == null || exact.projectId == project.id)) {
        session = exact;
        typed = '';
      }
    }
    if (session != null) {
      final said = used < committed.length || typed.isNotEmpty
          ? _after(used).trim()
          : '';
      return TypedCommand(verb: verb, plan: _resumePlan(session, said));
    }
    if (project != null) {
      // A project expands to its sessions, waiting first.
      return TypedCommand(
        verb: verb,
        pending: CommandArgKind.session,
        suggestions: _sessionSuggestions(
          typed,
          projectId: project.id,
          searchSaid: true,
        ),
      );
    }
    return TypedCommand(
      verb: verb,
      pending: CommandArgKind.session,
      suggestions: [
        ..._sessionSuggestions(typed, searchSaid: true),
        ..._projectSuggestions(typed).take(kCommandSuggestionLimit ~/ 2),
      ],
    );
  }

  TypedCommand _openTerminal() {
    final words = [...committed];
    var typed = partial;
    if (verbWord == 'open') {
      // `open t…` is on its way to `terminal`, which is the only thing to open.
      if (words.isEmpty) {
        return TypedCommand(
          verb: verb,
          pending: CommandArgKind.keyword,
          suggestions: [
            CommandSuggestion(
              id: 'keyword/terminal',
              kind: CommandArgKind.keyword,
              label: 'terminal',
              hint: 'Open a terminal in a project',
              completion: _completion('terminal'),
            ),
          ],
        );
      }
      if (words.first.toLowerCase() != 'terminal') {
        return _fail('open takes "terminal".');
      }
      words.removeAt(0);
      _written.add('terminal');
    }
    CommandProject? project;
    CommandEnvironment? environment;
    for (final word in words) {
      if (project == null) {
        project = _projectByToken(word);
        if (project == null) return _fail('No project called "$word".');
        _written.add(project.token);
      } else if (environment == null) {
        environment = _environmentByToken(word);
        if (environment == null) {
          return _fail('No environment called "$word".');
        }
        _written.add(environment.token);
      } else {
        return _fail(
          'open terminal takes a project and an environment — '
          '"$word" is one too many.',
        );
      }
    }
    if (typed.isNotEmpty) {
      if (project == null && _projectByToken(typed) != null) {
        project = _projectByToken(typed);
        _written.add(project!.token);
        typed = '';
      } else if (project != null &&
          environment == null &&
          _environmentByToken(typed) != null) {
        environment = _environmentByToken(typed);
        _written.add(environment!.token);
        typed = '';
      }
    }
    if (project == null) {
      return TypedCommand(
        verb: verb,
        pending: CommandArgKind.project,
        suggestions: _projectSuggestions(typed),
      );
    }
    final suggestions = environment != null
        ? const <CommandSuggestion>[]
        : _environmentSuggestions(typed, project);
    return TypedCommand(
      verb: verb,
      pending: environment == null ? CommandArgKind.environment : null,
      suggestions: suggestions,
      plan: typed.isEmpty ? _terminalPlan(project, environment) : null,
    );
  }

  List<CommandSuggestion> _environmentSuggestions(
    String typed,
    CommandProject project,
  ) {
    // The project's own first; the rest in the order they were discovered.
    final ordered = [
      ...catalog.environments.where((e) => e.id == project.environmentId),
      ...catalog.environments.where((e) => e.id != project.environmentId),
    ];
    String? refusal(CommandEnvironment e) =>
        project.terminals[e.id]?.refusal ??
        (project.terminals.containsKey(e.id)
            ? null
            : 'No terminal for ${e.label} on this machine');
    return [
      for (final e in _rank(
        typed,
        ordered,
        token: (e) => e.token,
        texts: (e) => [e.label],
        usable: (e) => refusal(e) == null,
      ))
        CommandSuggestion(
          id: 'environment/${e.id}',
          kind: CommandArgKind.environment,
          label: e.token,
          hint: e.label,
          detail: e.id == project.environmentId ? 'where it lives' : null,
          completion: _completion(e.token),
          disabledReason: refusal(e),
        ),
    ];
  }

  CommandPlan _terminalPlan(CommandProject project, CommandEnvironment? named) {
    final environmentId = named?.id ?? project.environmentId;
    final label = catalog.environmentLabel(environmentId);
    final target = project.terminals[environmentId];
    final token = named?.token ?? catalog.environment(environmentId)?.token;
    final refusal =
        target?.refusal ??
        (target?.profileId == null || target?.workingDirectory == null
            ? 'No terminal for $label on this machine.'
            : null);
    return CommandPlan(
      preview: [
        'Open a terminal in ${project.name}',
        label,
        ?target?.workingDirectory,
      ].join(' · '),
      canonical: ['open terminal', project.token, ?token].join(' '),
      refusal: refusal,
      action: refusal == null
          ? OpenTerminalCommand(
              projectId: project.id,
              environmentId: environmentId,
              profileId: target!.profileId!,
              workingDirectory: target.workingDirectory!,
            )
          : null,
    );
  }
}
