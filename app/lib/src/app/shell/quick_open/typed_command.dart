/// Typed verb commands for quick open — `start appwrite codex`, `resume fix`,
/// `open terminal api archlinux`. Pure: the query text and a [CommandCatalog]
/// in, suggestions and a runnable [CommandPlan] out. Nothing here reads a
/// provider, so every rule is unit-testable without a widget.
library;

import 'package:karmashala_core/util.dart';

import 'quick_open_item.dart';

part 'typed_command_session_verbs.dart';

part 'typed_command/catalog.dart';
part 'typed_command/plan.dart';
part 'typed_command/start_verb.dart';
part 'typed_command/resume_terminal_verbs.dart';

/// The verbs. Matched only when typed in full and followed by a space, so a
/// query that merely starts like one is ordinary search.
enum CommandVerb {
  start('start'),
  resume('resume'),
  openTerminal('open terminal'),
  answer('answer'),
  stop('stop'),
  fork('fork'),
  end('end'),
  allow('allow'),
  deny('deny'),
  message('message'),
  archive('archive'),

  /// `open <session>`: its peek on the Agent dashboard.
  peek('open');

  const CommandVerb(this.spelling);

  /// How the verb is written back into the box and into history.
  final String spelling;

  static const Map<String, CommandVerb> _words = {
    'start': CommandVerb.start,
    'new': CommandVerb.start,
    's': CommandVerb.start,
    'resume': CommandVerb.resume,
    'open': CommandVerb.openTerminal,
    'term': CommandVerb.openTerminal,
    'answer': CommandVerb.answer,
    'stop': CommandVerb.stop,
    'fork': CommandVerb.fork,
    'end': CommandVerb.end,
    'allow': CommandVerb.allow,
    'deny': CommandVerb.deny,
    'message': CommandVerb.message,
    'msg': CommandVerb.message,
    'archive': CommandVerb.archive,
    'peek': CommandVerb.peek,
  };
}

// --- scoring ----------------------------------------------------------------

/// The argument scorer: the shared search rule with scattered initials, so
/// `appwrite_ai` and `aaw` both find `appwrite-ai-workdir`. Null when [label]
/// does not match.
int? commandMatchScore(String query, String label) =>
    searchMatch(query, label, initials: true)?.score.round();

class _Ranked<T> {
  _Ranked(this.item, this.score, this.index, {required this.exact});

  final T item;
  final int score;
  final int index;
  final bool exact;
}

/// Filters [items] by [partial] and orders them: an exact token first, then
/// usable before refused, waiting on the user, most recent, best score; ties
/// keep the original order.
List<T> _rank<T>(
  String partial,
  List<T> items, {
  required String Function(T) token,
  required List<String> Function(T) texts,
  bool Function(T)? waiting,
  int? Function(T)? recency,
  bool Function(T)? usable,
}) {
  final wanted = partial.toLowerCase();
  final ranked = <_Ranked<T>>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    int? best;
    for (final text in [token(item), ...texts(item)]) {
      final score = commandMatchScore(partial, text);
      if (score != null && (best == null || score > best)) best = score;
    }
    if (best == null) continue;
    ranked.add(
      _Ranked(
        item,
        best,
        i,
        exact: wanted.isNotEmpty && token(item).toLowerCase() == wanted,
      ),
    );
  }
  int flag(bool value) => value ? 0 : 1;
  ranked.sort((a, b) {
    var c = flag(a.exact).compareTo(flag(b.exact));
    if (c != 0) return c;
    if (usable != null) {
      c = flag(usable(a.item)).compareTo(flag(usable(b.item)));
      if (c != 0) return c;
    }
    if (waiting != null) {
      c = flag(waiting(a.item)).compareTo(flag(waiting(b.item)));
      if (c != 0) return c;
    }
    if (recency != null) {
      final ra = recency(a.item);
      final rb = recency(b.item);
      if (ra != rb) {
        if (ra == null) return 1;
        if (rb == null) return -1;
        return ra.compareTo(rb);
      }
    }
    c = b.score.compareTo(a.score);
    return c != 0 ? c : a.index.compareTo(b.index);
  });
  return [for (final r in ranked) r.item];
}

// --- tokens -----------------------------------------------------------------

/// Lower-case words joined by `-`, for a title typed as one argument.
String commandSlug(String text, {int maxLength = 48}) {
  final slug = text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final cut = slug.length > maxLength ? slug.substring(0, maxLength) : slug;
  return cut.replaceAll(RegExp(r'-+$'), '');
}

/// A project's name as one argument: its spaces become `-`, its case stays.
String commandProjectToken(String name) =>
    name.trim().replaceAll(RegExp(r'\s+'), '-');

/// Makes every token in [tokens] unique by suffixing the duplicates with the
/// start of their id, so an argument can always name exactly one thing.
Map<String, String> uniqueTokens(List<({String id, String token})> tokens) {
  final counts = <String, int>{};
  for (final t in tokens) {
    final key = t.token.toLowerCase();
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return {
    for (final t in tokens)
      t.id: (counts[t.token.toLowerCase()] ?? 0) > 1
          ? '${t.token}-${t.id.length > 4 ? t.id.substring(0, 4) : t.id}'
          : t.token,
  };
}

// --- parsing ----------------------------------------------------------------

final _space = RegExp(r'\s');

/// Whether [text]'s first word is a verb followed by a space — the one test
/// that decides between a typed command and today's search, cheap enough to
/// run before any catalog is read.
CommandVerb? typedCommandVerbOf(String text) {
  final trimmed = text.trimLeft();
  if (QuickOpenQuery.parse(trimmed).only != null) return null;
  final firstSpace = trimmed.indexOf(_space);
  if (firstSpace <= 0) return null;
  final verb =
      CommandVerb._words[trimmed.substring(0, firstSpace).toLowerCase()];
  if (verb == null) return null;
  if (trimmed.substring(0, firstSpace).toLowerCase() == 'open') {
    // `open` alone is a word people search with ("Open Settings"): only
    // `open t…` — on its way to `terminal` — is the command.
    final rest = trimmed.substring(firstSpace).trimLeft();
    final word = rest.split(_space).first.toLowerCase();
    if (word.isEmpty || !'terminal'.startsWith(word)) return null;
  }
  return verb;
}

/// Parses [text] up to [cursor] as a typed command, or returns null when it is
/// not one — which leaves quick open's search exactly as it was.
TypedCommand? parseTypedCommand(
  String text,
  CommandCatalog catalog, {
  int? cursor,
}) {
  var input = cursor == null
      ? text
      : text.substring(0, cursor.clamp(0, text.length));
  final verb =
      typedCommandVerbOf(input) ??
      (_opensSession(input, catalog) ? CommandVerb.peek : null);
  if (verb == null) return null;
  // `new api: fix the login bug` — what follows the colon is said first.
  String? message;
  final uncut = input.trimLeft();
  final colon = verb == CommandVerb.start ? input.indexOf(':') : -1;
  if (colon >= 0) {
    final said = input.substring(colon + 1).trim();
    message = said.isEmpty ? null : said;
    input = input.substring(0, colon);
  }
  final trimmed = input.trimLeft();
  final words = trimmed.split(RegExp(r'\s+'));
  final trailing =
      trimmed.isNotEmpty && _space.hasMatch(trimmed[trimmed.length - 1]);
  if (trailing && words.isNotEmpty && words.last.isEmpty) words.removeLast();
  final verbWord = words.first.toLowerCase();
  final committed = trailing
      ? words.sublist(1)
      : words.sublist(1, words.length - 1);
  final partial = trailing ? '' : words.last;
  return _Parser(
    catalog: catalog,
    verb: verb,
    verbWord: verbWord,
    committed: committed,
    partial: partial,
    message: message,
    rest: trimmed.substring(words.first.length).trimLeft(),
    uncutRest: uncut.substring(words.first.length).trimLeft(),
  ).parse();
}

/// Whether [text] could be `open <session>`: quick open runs the parse for
/// it, which answers null — plain search — unless a session is named.
bool typedCommandMayOpenSession(String text) {
  final trimmed = text.trimLeft().toLowerCase();
  return trimmed.startsWith('open ') && trimmed.substring(5).trim().isNotEmpty;
}

/// `open <words>` names a session only when its words are found in one's
/// title or token, as a search would find them — never by scattered letters,
/// so "open settings" stays a search.
bool _opensSession(String text, CommandCatalog catalog) {
  if (!typedCommandMayOpenSession(text)) return false;
  final words = text.trimLeft().substring(5).trim();
  return catalog.sessions.any(
    (s) =>
        s.token.toLowerCase() == words.split(_space).first.toLowerCase() ||
        matchesSearchAny(words.split(_space).first, [s.title, s.token]),
  );
}

class _Parser {
  _Parser({
    required this.catalog,
    required this.verb,
    required this.verbWord,
    required this.committed,
    required this.partial,
    this.message,
    this.rest = '',
    this.uncutRest = '',
  });

  /// [rest] before a colon cut `start`'s message off it: a prompt typed
  /// after `new <agent> in <project>` may hold a colon of its own.
  final String uncutRest;

  final CommandCatalog catalog;
  final CommandVerb verb;

  /// Everything after the verb, as typed — what a message is cut from.
  final String rest;

  /// `start`'s opening message, typed after a colon.
  final String? message;
  final String verbWord;
  final List<String> committed;
  final String partial;

  /// The words accepted so far, as written back into the box.
  final List<String> _written = [];

  String get _base => '${[verbWord, ..._written].join(' ')} ';

  String _completion(String token) => '$_base$token ';

  TypedCommand? parse() => switch (verb) {
    CommandVerb.start => _agentInProject() ?? _start(),
    CommandVerb.resume => _resume(),
    CommandVerb.openTerminal => _openTerminal(),
    CommandVerb.answer =>
      committed.isEmpty && partial.isEmpty ? _answer() : _answerSession(),
    CommandVerb.stop when _all => _group(),
    CommandVerb.message => _all ? _group() : _message(),
    CommandVerb.stop || CommandVerb.fork || CommandVerb.end => _sessionVerb(),
    CommandVerb.allow || CommandVerb.deny => _approval(),
    CommandVerb.archive => _archive(),
    CommandVerb.peek => _peek(),
  };

  TypedCommand _fail(String error) => TypedCommand(verb: verb, error: error);

  // --- lookups ---------------------------------------------------------------

  CommandProject? _projectByToken(String word) {
    final wanted = word.toLowerCase();
    return catalog.projects
        .where((p) => p.token.toLowerCase() == wanted)
        .firstOrNull;
  }

  CommandAgent? _agentByToken(String word) {
    final wanted = word.toLowerCase();
    for (final agent in catalog.agents) {
      if (agent.token.toLowerCase() == wanted ||
          agent.agentId.toLowerCase() == wanted ||
          commandSlug(agent.displayName) == wanted) {
        return agent;
      }
    }
    return null;
  }

  CommandSession? _sessionByToken(String word, {bool nativeOnly = false}) {
    final wanted = word.toLowerCase();
    return catalog.sessions
        .where(
          (s) =>
              s.token.toLowerCase() == wanted && (!nativeOnly || !s.imported),
        )
        .firstOrNull;
  }

  CommandEnvironment? _environmentByToken(String word) {
    final wanted = word.toLowerCase();
    return catalog.environments
        .where((e) => e.token.toLowerCase() == wanted)
        .firstOrNull;
  }

  // --- suggestions -----------------------------------------------------------

  List<CommandSuggestion> _projectSuggestions(String typed) => [
    for (final project in _rank(
      typed,
      catalog.projects,
      token: (p) => p.token,
      texts: (p) => [p.name],
      waiting: (p) => p.waiting,
      recency: (p) => p.recencyRank,
    ).take(kCommandSuggestionLimit))
      CommandSuggestion(
        id: 'project/${project.id}',
        kind: CommandArgKind.project,
        label: project.token,
        hint: catalog.environmentLabel(project.environmentId),
        detail: project.waiting ? 'waiting on you' : null,
        completion: _completion(project.token),
      ),
  ];

  List<CommandSuggestion> _sessionSuggestions(
    String typed, {
    String? projectId,
    bool nativeOnly = false,
    String? Function(CommandSession)? refusalOf,
    bool searchSaid = false,
  }) {
    final pool = [
      for (final s in catalog.sessions)
        if ((projectId == null || s.projectId == projectId) &&
            (!nativeOnly || !s.imported))
          s,
    ];
    final ranked = _rank<CommandSession>(
      typed,
      pool,
      token: (s) => s.token,
      texts: (s) => [s.title],
      usable: refusalOf == null ? null : (s) => refusalOf(s) == null,
      waiting: (s) => s.waiting,
      recency: (s) => s.recencyRank,
    ).take(kCommandSuggestionLimit).toList();
    final suggestions = [
      for (final s in ranked) _sessionSuggestion(s, refusalOf?.call(s)),
    ];
    // A title that says nothing about the work: what was said in it can.
    final search = catalog.searchConversations;
    if (searchSaid && search != null && typed.trim().length >= 3) {
      final listed = {for (final s in ranked) s.id};
      for (final match in search(typed)) {
        if (suggestions.length >= kCommandSuggestionLimit) break;
        if (!listed.add(match.sessionId)) continue;
        final session = catalog.sessions
            .where((s) => s.id == match.sessionId)
            .firstOrNull;
        if (session == null) continue;
        if (projectId != null && session.projectId != projectId) continue;
        suggestions.add(_sessionSuggestion(session, null, said: match.excerpt));
      }
    }
    return suggestions;
  }

  CommandSuggestion _sessionSuggestion(
    CommandSession s,
    String? refusal, {
    String? said,
    String? completion,
  }) => CommandSuggestion(
    id: 'session/${s.id}',
    kind: CommandArgKind.session,
    label: s.title,
    hint: said == null
        ? [
            s.projectName,
            if (s.agentName.isNotEmpty) s.agentName,
            ?s.ageLabel,
          ].join(' · ')
        : 'said: $said',
    detail: _dotLabel(s.dot),
    dot: s.dot,
    completion: completion ?? _completion(s.token),
    disabledReason: refusal,
  );

  static String _dotLabel(SessionDot dot) => switch (dot) {
    SessionDot.waiting => 'waiting on you',
    SessionDot.working => 'working',
    SessionDot.idle => 'idle',
    SessionDot.stopped => 'not running',
    SessionDot.unknown => 'status unknown',
  };

  /// The installed agents, the default first; then the registry's other agents,
  /// refused with the reason rather than left out.

  TypedCommand _answer() {
    final extra = [...committed, if (partial.isNotEmpty) partial];
    if (extra.isNotEmpty) {
      return _fail(
        'answer takes nothing after it — it goes to the oldest '
        'question waiting on you.',
      );
    }
    final waiting = catalog.oldestWaiting;
    return TypedCommand(
      verb: verb,
      plan: waiting == null
          ? const CommandPlan(
              preview: 'Go to the oldest permission waiting on you',
              canonical: 'answer',
              refusal: 'Nothing is waiting on you.',
            )
          : CommandPlan(
              preview: [
                'Go to "${waiting.title}", waiting on you',
                if (waiting.detail != null && waiting.detail!.trim().isNotEmpty)
                  waiting.detail!.trim(),
              ].join(' · '),
              canonical: 'answer',
              action: AnswerCommand(itemId: waiting.itemId),
            ),
    );
  }

  String? _refusalFor(CommandSession s) => switch (verb) {
    CommandVerb.stop => s.stopRefusal,
    CommandVerb.end => s.endRefusal,
    CommandVerb.fork => s.forkRefusal,
    _ => null,
  };

  TypedCommand _sessionVerb() {
    CommandSession? session;
    for (final word in committed) {
      if (session != null) {
        return _fail(
          '${verb.spelling} takes one session — "$word" is one '
          'too many.',
        );
      }
      session = _sessionByToken(word, nativeOnly: true);
      if (session == null) return _fail('No session called "$word".');
      _written.add(session.token);
    }
    var typed = partial;
    if (session == null && typed.isNotEmpty) {
      session = _sessionByToken(typed, nativeOnly: true);
      if (session != null) typed = '';
    }
    if (session == null) {
      return TypedCommand(
        verb: verb,
        pending: CommandArgKind.session,
        suggestions: _sessionSuggestions(
          typed,
          nativeOnly: true,
          refusalOf: _refusalFor,
        ),
      );
    }
    if (typed.isNotEmpty) {
      return _fail(
        '${verb.spelling} takes one session — "$typed" is one too '
        'many.',
      );
    }
    final refusal = _refusalFor(session);
    final preview = switch (verb) {
      CommandVerb.stop =>
        'Interrupt "${session.title}" — presses Esc; the turn stops, the '
            'session stays',
      CommandVerb.fork =>
        'Fork "${session.title}" into a new session · ${session.projectName}',
      _ =>
        'End "${session.title}" — stops the agent process; its transcript '
            'stays',
    };
    return TypedCommand(
      verb: verb,
      plan: CommandPlan(
        preview: preview,
        canonical: '${verb.spelling} ${session.token}',
        refusal: refusal,
        action: refusal != null
            ? null
            : switch (verb) {
                CommandVerb.stop => StopCommand(session.id),
                CommandVerb.fork => ForkCommand(session.id),
                _ => EndCommand(session.id),
              },
      ),
    );
  }
}
