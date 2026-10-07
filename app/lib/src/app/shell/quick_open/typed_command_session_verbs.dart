part of 'typed_command.dart';

/// The states `all` narrows a group to.
const Map<String, SessionDot> _groupStates = {
  'working': SessionDot.working,
  'waiting': SessionDot.waiting,
  'idle': SessionDot.idle,
};

/// The verbs that act on one session — or, with `all`, on a group — named by
/// its token or by words that find only it.
extension _SessionVerbs on _Parser {
  bool get _all =>
      (committed.isNotEmpty ? committed.first : partial).toLowerCase() == 'all';

  /// What was typed after the first [n] arguments, as typed.
  String _after(int n) {
    var text = rest;
    for (var i = 0; i < n; i++) {
      final word = RegExp(r'^\S+\s*').firstMatch(text);
      if (word == null) return '';
      text = text.substring(word.end);
    }
    return text;
  }

  List<CommandSession> _ranked(String typed, List<CommandSession> pool) =>
      _rank<CommandSession>(
        typed,
        pool,
        token: (s) => s.token,
        texts: (s) => [s.title],
        waiting: (s) => s.waiting,
        recency: (s) => s.recencyRank,
      );

  /// The session the first argument names in [pool]: its exact token, or the
  /// only session its words find. Anything else is shown [instead]: the
  /// candidates to pick from, never a guess.
  ({CommandSession? session, TypedCommand? instead}) _pickSession(
    List<CommandSession> pool, {
    required String none,
    String? Function(CommandSession)? refusalOf,
    bool offersAll = false,
  }) {
    CommandSession? byToken(String word) => pool
        .where((s) => s.token.toLowerCase() == word.toLowerCase())
        .firstOrNull;
    List<CommandSuggestion> listed(
      List<CommandSession> sessions, {
      String Function(CommandSession)? completion,
    }) => [
      for (final s in sessions.take(kCommandSuggestionLimit))
        _sessionSuggestion(
          s,
          refusalOf?.call(s),
          completion: completion?.call(s),
        ),
    ];

    if (committed.isEmpty) {
      final exact = partial.isEmpty ? null : byToken(partial);
      if (exact != null) return (session: exact, instead: null);
      final suggestions = [
        if (offersAll && 'all'.startsWith(partial.toLowerCase()))
          CommandSuggestion(
            id: 'keyword/all',
            kind: CommandArgKind.keyword,
            label: 'all',
            hint: 'Every working, waiting or idle session, or all in a project',
            completion: _completion('all'),
          ),
        ...listed(_ranked(partial, pool)),
      ];
      return (
        session: null,
        instead: TypedCommand(
          verb: verb,
          pending: CommandArgKind.session,
          suggestions: suggestions,
          error: partial.isNotEmpty && suggestions.isEmpty
              ? '$none matches "$partial".'
              : null,
        ),
      );
    }
    final word = committed.first;
    final exact = byToken(word);
    if (exact != null) return (session: exact, instead: null);
    final found = _ranked(word, pool);
    if (found.length == 1) return (session: found.single, instead: null);
    if (found.isEmpty) {
      return (session: null, instead: _fail('$none called "$word".'));
    }
    final after = _after(1);
    return (
      session: null,
      instead: TypedCommand(
        verb: verb,
        pending: CommandArgKind.session,
        error: '"$word" finds ${found.length} sessions — pick one.',
        suggestions: listed(
          found,
          completion: (s) => '$verbWord ${s.token} $after',
        ),
      ),
    );
  }

  TypedCommand? _tooMany(String what) {
    final extra = _after(1).trim();
    return extra.isEmpty
        ? null
        : _fail('$what takes one session — "$extra" is one too many.');
  }

  // --- answer ----------------------------------------------------------------

  TypedCommand _answerSession() {
    final picked = _pickSession([
      for (final s in catalog.sessions)
        if (s.waiting || s.question != null) s,
    ], none: 'No session waiting on you');
    final session = picked.session;
    if (session == null) return picked.instead!;
    final question = session.question;
    final preview = 'Answer ${session.named}';
    if (question == null) {
      return TypedCommand(
        verb: verb,
        plan: session.approval != null
            ? CommandPlan(
                preview: preview,
                canonical: '',
                refusal: 'It asks to run a command — use allow or deny.',
              )
            : CommandPlan(
                preview: 'Open ${session.named} to answer it',
                canonical: 'open ${session.token}',
                note: session.questionUnread
                    ? 'Its question is still being read'
                    : 'Only its own view can answer what it asks',
                action: PeekCommand(session.id),
              ),
      );
    }
    if (question.refusal case final refusal?) {
      return TypedCommand(
        verb: verb,
        plan: CommandPlan(preview: preview, canonical: '', refusal: refusal),
      );
    }
    final options = question.options;
    _written.add(session.token);
    List<CommandSuggestion> optionRows(Iterable<int> indexes) => [
      for (final i in indexes)
        CommandSuggestion(
          id: 'option/$i',
          kind: CommandArgKind.option,
          label: '${i + 1} · ${options[i]}',
          completion: _completion('${i + 1}'),
        ),
    ];
    final said = _after(1).trim();
    if (said.isEmpty) {
      return TypedCommand(
        verb: verb,
        pending: CommandArgKind.option,
        suggestions: optionRows(Iterable.generate(options.length)),
      );
    }
    int? index;
    final number = int.tryParse(said);
    if (number != null) {
      if (number < 1 || number > options.length) {
        return _fail('It offers options 1 to ${options.length}.');
      }
      index = number - 1;
    } else {
      final exact = options.indexWhere(
        (o) => o.toLowerCase() == said.toLowerCase(),
      );
      final found = exact >= 0
          ? [exact]
          : [
              for (final (i, option) in options.indexed)
                if (matchesSearch(said, option)) i,
            ];
      if (found.length != 1) {
        return TypedCommand(
          verb: verb,
          pending: CommandArgKind.option,
          error: found.isEmpty
              ? 'No option "$said" — pick one of its ${options.length}.'
              : '"$said" finds ${found.length} options — pick one.',
          suggestions: optionRows(
            found.isEmpty ? Iterable.generate(options.length) : found,
          ),
        );
      }
      index = found.single;
    }
    return TypedCommand(
      verb: verb,
      plan: CommandPlan(
        preview: '$preview — ${index + 1} · ${options[index]}',
        // Never re-run from history: a later question has other options.
        canonical: '',
        action: AnswerQuestionCommand(
          sessionId: session.id,
          toolUseId: question.toolUseId,
          option: index,
        ),
      ),
    );
  }

  // --- allow / deny ----------------------------------------------------------

  TypedCommand _approval() {
    final allow = verb == CommandVerb.allow;
    String? refusalOf(CommandSession s) => switch (s.approval) {
      null => 'Not waiting on a command approval',
      final approval => allow ? approval.allowRefusal : approval.denyRefusal,
    };
    final picked = _pickSession(
      [
        for (final s in catalog.sessions)
          if (s.approval != null) s,
        for (final s in catalog.sessions)
          if (s.approval == null && s.waiting) s,
      ],
      none: 'No session waiting on a command',
      refusalOf: refusalOf,
    );
    final session = picked.session;
    if (session == null) return picked.instead!;
    if (_tooMany(verb.spelling) case final fail?) return fail;
    final approval = session.approval;
    return TypedCommand(
      verb: verb,
      plan: CommandPlan(
        preview: [
          '${allow ? 'Allow' : 'Deny'} ${session.named}',
          if (approval != null && approval.subject.isNotEmpty) approval.subject,
        ].join(' — '),
        note: approval == null || approval.folder.isEmpty
            ? null
            : 'in ${approval.folder}',
        // Never re-run from history: a later approval asks something else.
        canonical: '',
        refusal: refusalOf(session),
        action: refusalOf(session) == null
            ? ApprovalCommand(session.id, allow: allow)
            : null,
      ),
    );
  }

  // --- message ---------------------------------------------------------------

  TypedCommand _message() {
    final picked = _pickSession(
      [
        for (final s in catalog.sessions)
          if (!s.imported) s,
      ],
      none: 'No session',
      offersAll: true,
    );
    final session = picked.session;
    if (session == null) return picked.instead!;
    final text = _after(1).trim();
    final preview = 'Message ${session.named}';
    return TypedCommand(
      verb: verb,
      plan: text.isEmpty
          ? CommandPlan(
              preview: preview,
              canonical: '',
              refusal: 'Type the message after its name.',
            )
          : CommandPlan(
              preview: '$preview: "$text"',
              note: session.live
                  ? null
                  : 'Not running — it is resumed to take it',
              canonical: 'message ${session.token}',
              action: MessageCommand([session.id], text),
            ),
    );
  }

  // --- groups ----------------------------------------------------------------

  /// `message all working <text>`, `stop all in <project>`: only running
  /// sessions, always named in a confirm before anything is done.
  TypedCommand _group() {
    _written.add('all');
    final words = [...committed.skip(1)];
    var typed = committed.isEmpty ? '' : partial;
    SessionDot? state;
    CommandProject? project;
    var wantsProject = false;
    var used = 1;
    for (final word in words) {
      final lower = word.toLowerCase();
      if (wantsProject) {
        project = _projectByToken(word);
        if (project == null) return _fail('No project called "$word".');
        _written.add(project.token);
        wantsProject = false;
      } else if (state == null &&
          project == null &&
          _groupStates.containsKey(lower)) {
        state = _groupStates[lower];
        _written.add(lower);
      } else if (project == null && lower == 'in') {
        wantsProject = true;
        _written.add('in');
      } else {
        break;
      }
      used++;
    }
    final choosing = used == committed.length;
    final suggestions = <CommandSuggestion>[];
    if (choosing && wantsProject) {
      final exact = _projectByToken(typed);
      if (exact == null) {
        return TypedCommand(
          verb: verb,
          pending: CommandArgKind.project,
          suggestions: _projectSuggestions(typed),
        );
      }
      project = exact;
      _written.add(exact.token);
      wantsProject = false;
      typed = '';
      used++;
    } else if (choosing) {
      final lower = typed.toLowerCase();
      final keywords = [
        if (state == null && project == null) ..._groupStates.keys,
        if (project == null) 'in',
      ];
      for (final keyword in keywords) {
        if (keyword.startsWith(lower) && keyword != lower) {
          suggestions.add(
            CommandSuggestion(
              id: 'keyword/$keyword',
              kind: CommandArgKind.keyword,
              label: keyword,
              hint: keyword == 'in'
                  ? 'Only the sessions of one project'
                  : 'Only the $keyword sessions',
              completion: _completion(keyword),
            ),
          );
        }
      }
      if (_groupStates.containsKey(lower) && state == null && project == null) {
        state = _groupStates[lower];
        typed = '';
        used++;
      } else if (suggestions.isNotEmpty) {
        typed = '';
      }
    }
    // A word on its way to a keyword is not yet the message.
    final after = suggestions.isNotEmpty ? '' : _after(used).trim();
    final text = verb == CommandVerb.message ? after : '';
    final extra = verb == CommandVerb.stop ? after : '';
    if (extra.isNotEmpty) {
      return _fail(
        'stop all takes "working" or "in <project>" — not "$extra".',
      );
    }
    final which = [
      switch (state) {
        SessionDot.working => 'working',
        SessionDot.waiting => 'waiting',
        SessionDot.idle => 'idle',
        _ => 'running',
      },
      'sessions',
      if (project != null) 'in ${project.name}',
    ].join(' ');
    final canonical = verb == CommandVerb.stop
        ? '$verbWord ${_written.join(' ')}'
        : '';
    CommandPlan plan;
    if (state == null && project == null) {
      plan = CommandPlan(
        preview: '${verb == CommandVerb.stop ? 'Interrupt' : 'Message'} all',
        canonical: '',
        refusal:
            'Say which: all working, all waiting, all idle, or all in '
            'a project.',
      );
    } else {
      final targets = [
        for (final s in catalog.sessions)
          if (!s.imported &&
              s.live &&
              (state == null || s.dot == state) &&
              (project == null || s.projectId == project.id))
            s,
      ];
      plan = verb == CommandVerb.stop
          ? _stopAllPlan(targets, which, canonical)
          : _messageAllPlan(targets, which, text);
    }
    return TypedCommand(
      verb: verb,
      pending: suggestions.isEmpty ? null : CommandArgKind.keyword,
      suggestions: suggestions,
      plan: plan,
    );
  }

  CommandPlan _messageAllPlan(
    List<CommandSession> targets,
    String which,
    String text,
  ) {
    final preview = 'Message ${targets.length} $which';
    if (targets.isEmpty) {
      return CommandPlan(
        preview: preview,
        canonical: '',
        refusal: 'No $which to message.',
      );
    }
    if (text.isEmpty) {
      return CommandPlan(
        preview: preview,
        canonical: '',
        refusal: 'Type the message after it.',
      );
    }
    return CommandPlan(
      preview: '$preview: "$text"',
      note: 'Asks first, naming each one',
      canonical: '',
      action: MessageCommand([for (final s in targets) s.id], text),
      confirm: CommandConfirm(
        title: 'Message ${_count(targets.length)}?',
        names: [for (final s in targets) s.named],
        confirmLabel: 'Send',
      ),
    );
  }

  CommandPlan _stopAllPlan(
    List<CommandSession> targets,
    String which,
    String canonical,
  ) {
    final stoppable = [
      for (final s in targets)
        if (s.stopRefusal == null) s,
    ];
    final skipped = targets.length - stoppable.length;
    final preview =
        'Interrupt ${stoppable.length} $which — presses Esc in each';
    if (stoppable.isEmpty) {
      return CommandPlan(
        preview: preview,
        canonical: canonical,
        refusal: targets.isEmpty
            ? 'No $which.'
            : 'None of them is mid-turn, so there is nothing to interrupt.',
      );
    }
    return CommandPlan(
      preview: preview,
      note: [
        'Asks first, naming each one',
        if (skipped > 0) '$skipped left alone: not mid-turn, or asking you',
      ].join(' · '),
      canonical: canonical,
      action: StopAllCommand([for (final s in stoppable) s.id]),
      confirm: CommandConfirm(
        title: 'Interrupt ${_count(stoppable.length)}?',
        names: [for (final s in stoppable) s.named],
        confirmLabel: 'Interrupt',
      ),
    );
  }

  static String _count(int n) => n == 1 ? '1 session' : '$n sessions';

  // --- archive / open --------------------------------------------------------

  TypedCommand _archive() {
    final picked = _pickSession(
      [
        for (final s in catalog.sessions)
          if (!s.imported) s,
      ],
      none: 'No session',
      refusalOf: (s) => s.archiveRefusal,
    );
    final session = picked.session;
    if (session == null) return picked.instead!;
    if (_tooMany('archive') case final fail?) return fail;
    final refusal = session.archiveRefusal;
    return TypedCommand(
      verb: verb,
      plan: CommandPlan(
        preview: 'Archive ${session.named}',
        note: 'Hidden from the lists; its transcript and any worktree stay',
        canonical: 'archive ${session.token}',
        refusal: refusal,
        action: refusal == null ? ArchiveCommand(session.id) : null,
      ),
    );
  }

  TypedCommand? _peek() {
    final picked = _pickSession(catalog.sessions, none: 'No session');
    final session = picked.session;
    if (session == null) {
      // `open` with words that find nothing is a search, not an error.
      return verbWord == 'open' && picked.instead?.error != null
          ? null
          : picked.instead;
    }
    if (_tooMany('open') case final fail?) return fail;
    return TypedCommand(
      verb: verb,
      plan: CommandPlan(
        preview: 'Open ${session.named} on the Agent dashboard',
        canonical: 'open ${session.token}',
        action: PeekCommand(session.id),
      ),
    );
  }

  // --- resume / new ----------------------------------------------------------

  /// Resumes [session] where it is: at the server with no tab when nothing
  /// runs it, or goes to it when something does.
  CommandPlan _resumePlan(CommandSession session, String said) {
    final about = [
      if (session.agentName.isNotEmpty) session.agentName,
      session.projectName,
      ?session.ageLabel,
    ];
    if (session.live || session.imported) {
      return CommandPlan(
        preview: [
          '${session.live ? 'Go to' : 'Resume'} "${session.title}"',
          ...about,
        ].join(' · '),
        canonical: 'resume ${session.token}',
        refusal: said.isEmpty
            ? null
            : session.live
            ? 'It is running — say it with message.'
            : 'An imported session opens in its tab; say it there.',
        action: said.isEmpty
            ? ResumeCommand(sessionId: session.id, imported: session.imported)
            : null,
      );
    }
    return CommandPlan(
      preview: [
        'Resume "${session.title}" in the background',
        ...about,
      ].join(' · '),
      note: said.isEmpty ? 'No tab opens' : 'says "$said"',
      canonical: 'resume ${session.token}',
      action: BackgroundResumeCommand(
        session.id,
        message: said.isEmpty ? null : said,
      ),
    );
  }

  /// `new codex in karmashala fix the login`: started at the server with no
  /// tab and peeked on the Agent dashboard. Null when not that form.
  TypedCommand? _agentInProject() {
    if (committed.length < 2 || committed[1].toLowerCase() != 'in') {
      return null;
    }
    final agent = _agentByToken(committed.first);
    if (agent == null || _projectByToken(committed.first) != null) return null;
    _written
      ..add(agent.token)
      ..add('in');
    final fromPartial = committed.length == 2;
    final word = fromPartial ? partial : committed[2];
    var project = _projectByToken(word);
    if (project == null) {
      final found = _rank(
        word,
        catalog.projects,
        token: (p) => p.token,
        texts: (p) => [p.name],
        recency: (p) => p.recencyRank,
      );
      if (fromPartial || found.length != 1) {
        if (!fromPartial && found.isEmpty) {
          return _fail('No project called "$word".');
        }
        return TypedCommand(
          verb: verb,
          pending: CommandArgKind.project,
          error: !fromPartial
              ? '"$word" finds ${found.length} projects — pick one.'
              : null,
          suggestions: _projectSuggestions(word),
        );
      }
      project = found.single;
    }
    final prompt =
        message ?? (fromPartial ? null : _after(3).trim().nullIfEmpty);
    final installation = project.installations
        .where((i) => i.agentId == agent.agentId)
        .firstOrNull;
    final envLabel = catalog.environmentLabel(project.environmentId);
    return TypedCommand(
      verb: verb,
      plan: CommandPlan(
        preview:
            'New ${agent.displayName} session in ${project.name}, on the '
            'Agent dashboard',
        note: prompt == null
            ? 'No tab opens · type what to ask after it'
            : 'No tab opens · says "$prompt"',
        canonical: 'new ${agent.token} in ${project.token}',
        refusal: installation == null
            ? '${agent.displayName} is not installed in $envLabel.'
            : null,
        action: installation == null
            ? null
            : StartCommand(
                projectId: project.id,
                installationId: installation.id,
                firstMessage: prompt,
                keepHere: true,
              ),
      ),
    );
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
