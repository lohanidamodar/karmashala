/// Typed verb commands for quick open — `start appwrite codex`, `resume fix`,
/// `open terminal api archlinux`. Pure: the query text and a [CommandCatalog]
/// in, suggestions and a runnable [CommandPlan] out. Nothing here reads a
/// provider, so every rule is unit-testable without a widget.
library;

import 'package:karmashala_core/util.dart';

import 'quick_open_item.dart';

/// The verbs. Matched only when typed in full and followed by a space, so a
/// query that merely starts like one is ordinary search.
enum CommandVerb {
  start('start'),
  resume('resume'),
  openTerminal('open terminal'),
  answer('answer'),
  stop('stop'),
  fork('fork'),
  end('end');

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
  };
}

/// What the argument being typed is.
enum CommandArgKind { keyword, project, agent, flag, session, environment }

/// The dot a session row carries.
enum SessionDot { waiting, working, idle, stopped, unknown }

/// An agent the registry knows, installed anywhere or nowhere.
class CommandAgent {
  const CommandAgent({
    required this.agentId,
    required this.token,
    required this.displayName,
    this.familyName,
    this.formLabel = 'Terminal',
  });

  final String agentId;

  /// What is typed: `claude`, `codex`, `antigravity`.
  final String token;
  final String displayName;

  /// The agent whichever form it runs in — `Codex` for Codex's chat form too;
  /// null is [displayName].
  final String? familyName;

  String get family => familyName ?? displayName;

  /// `Terminal` or `Chat`.
  final String formLabel;
}

/// One agent installed in one environment.
class CommandInstallation {
  const CommandInstallation({required this.id, required this.agentId});

  final String id;
  final String agentId;
}

/// Where `open terminal` would open for one project in one environment, or why
/// it cannot.
class CommandTerminalTarget {
  const CommandTerminalTarget({
    this.profileId,
    this.workingDirectory,
    this.refusal,
  });

  final String? profileId;
  final String? workingDirectory;
  final String? refusal;
}

class CommandProject {
  const CommandProject({
    required this.id,
    required this.name,
    required this.token,
    required this.environmentId,
    this.recencyRank,
    this.waiting = false,
    this.installations = const [],
    this.defaultInstallationId,
    this.branch,
    this.terminals = const {},
    this.notGit = false,
  });

  final String id;
  final String name;
  final String token;
  final String environmentId;

  /// 0 for the project holding the most recently active session; null when it
  /// has none with a reading.
  final int? recencyRank;

  /// Whether one of its sessions is waiting on the user.
  final bool waiting;

  /// The agents installed where this project runs.
  final List<CommandInstallation> installations;

  /// What `start` uses when no agent is named: the agent of its most recent
  /// session while still installed there, else the environment's default.
  final String? defaultInstallationId;

  /// The checked-out branch, only when something already read it.
  final String? branch;

  /// Keyed by environment id.
  final Map<String, CommandTerminalTarget> terminals;

  /// Observed not to be a Git repository — so it has no worktrees.
  final bool notGit;
}

class CommandSession {
  const CommandSession({
    required this.id,
    required this.title,
    required this.token,
    required this.projectId,
    required this.projectName,
    this.agentName = '',
    this.imported = false,
    this.dot = SessionDot.unknown,
    this.ageLabel,
    this.recencyRank,
    this.stopRefusal = 'Not running, so there is nothing to interrupt.',
    this.endRefusal = 'Not running, so there is nothing to end.',
    this.forkRefusal,
    this.live = false,
  });

  final String id;
  final String title;
  final String token;
  final String projectId;
  final String projectName;
  final String agentName;
  final bool imported;
  final SessionDot dot;
  final String? ageLabel;
  final int? recencyRank;
  final String? stopRefusal;
  final String? endRefusal;
  final String? forkRefusal;
  final bool live;

  bool get waiting => dot == SessionDot.waiting;
}

class CommandEnvironment {
  const CommandEnvironment({
    required this.id,
    required this.token,
    required this.label,
  });

  final String id;
  final String token;

  /// `Windows`, `WSL archlinux`, `do-box`.
  final String label;
}

/// The oldest permission prompt waiting on the user.
class CommandWaiting {
  const CommandWaiting({
    required this.itemId,
    required this.sessionId,
    required this.title,
    this.imported = false,
    this.detail,
  });

  final String itemId;
  final String sessionId;
  final String title;
  final bool imported;
  final String? detail;
}

/// A conversation the session search matched, by the session it opens.
typedef ConversationMatch = ({String sessionId, String excerpt});

/// Everything the completer can suggest, read once per palette.
class CommandCatalog {
  const CommandCatalog({
    this.projects = const [],
    this.sessions = const [],
    this.environments = const [],
    this.agents = const [],
    this.oldestWaiting,
    this.searchConversations,
    this.scratchInstallation,
  });

  final List<CommandProject> projects;

  /// What a session with no project runs on, as the dialog would pick it;
  /// null when no agent is installed anywhere.
  final CommandInstallation? scratchInstallation;

  /// Native and imported. `stop`, `fork` and `end` take only native ones.
  final List<CommandSession> sessions;
  final List<CommandEnvironment> environments;
  final List<CommandAgent> agents;
  final CommandWaiting? oldestWaiting;

  /// What was *said*, for `resume` when no title matches the text.
  final List<ConversationMatch> Function(String query)? searchConversations;

  CommandProject? project(String id) =>
      projects.where((p) => p.id == id).firstOrNull;

  CommandEnvironment? environment(String id) =>
      environments.where((e) => e.id == id).firstOrNull;

  CommandAgent? agent(String agentId) =>
      agents.where((a) => a.agentId == agentId).firstOrNull;

  String environmentLabel(String id) => environment(id)?.label ?? id;

  String agentName(String agentId) => agent(agentId)?.displayName ?? agentId;
}

/// What running a command does. Each maps onto an existing app action.
sealed class CommandAction {
  const CommandAction();
}

class StartCommand extends CommandAction {
  const StartCommand({
    required this.projectId,
    required this.installationId,
    this.worktree = false,
    this.firstMessage,
  });

  /// Null starts it with no project, in a scratch folder on the agent's machine.
  final String? projectId;
  final String installationId;
  final bool worktree;
  final String? firstMessage;
}

/// The New-session dialog, opened on what was typed instead of starting.
class OpenNewSessionDialogCommand extends CommandAction {
  const OpenNewSessionDialogCommand({this.projectId, this.firstMessage});

  final String? projectId;
  final String? firstMessage;
}

class ResumeCommand extends CommandAction {
  const ResumeCommand({required this.sessionId, this.imported = false});

  final String sessionId;
  final bool imported;
}

class OpenTerminalCommand extends CommandAction {
  const OpenTerminalCommand({
    required this.projectId,
    required this.environmentId,
    required this.profileId,
    required this.workingDirectory,
  });

  final String projectId;
  final String environmentId;
  final String profileId;
  final String workingDirectory;
}

class AnswerCommand extends CommandAction {
  const AnswerCommand({required this.itemId});

  final String itemId;
}

class StopCommand extends CommandAction {
  const StopCommand(this.sessionId);

  final String sessionId;
}

class ForkCommand extends CommandAction {
  const ForkCommand(this.sessionId);

  final String sessionId;
}

class EndCommand extends CommandAction {
  const EndCommand(this.sessionId);

  final String sessionId;
}

/// A command with every required argument: what it would do, and why not.
class CommandPlan {
  const CommandPlan({
    required this.preview,
    required this.canonical,
    this.action,
    this.refusal,
    this.note,
  });

  /// One line, before anything runs: `Start Codex in api · WSL archlinux`.
  final String preview;

  /// The line under [preview] when nothing is refused.
  final String? note;

  /// The fully resolved text, for history — the default agent spelled out.
  final String canonical;

  /// Null only when refused.
  final CommandAction? action;
  final String? refusal;

  bool get runnable => refusal == null && action != null;
}

/// One completion for the argument being typed.
class CommandSuggestion {
  const CommandSuggestion({
    required this.id,
    required this.kind,
    required this.label,
    required this.completion,
    this.hint,
    this.detail,
    this.disabledReason,
    this.dot,
  });

  final String id;
  final CommandArgKind kind;
  final String label;

  /// The whole box after accepting it, ending in a space so the next argument
  /// can be typed at once.
  final String completion;
  final String? hint;
  final String? detail;

  /// Shown rather than hidden: an entry that cannot be used says why.
  final String? disabledReason;
  final SessionDot? dot;

  bool get enabled => disabledReason == null;
}

/// The parse of a typed command.
class TypedCommand {
  const TypedCommand({
    required this.verb,
    this.pending,
    this.suggestions = const [],
    this.plan,
    this.error,
    this.launches = const [],
  });

  final CommandVerb verb;

  /// The argument the suggestions complete, or null when nothing is left.
  final CommandArgKind? pending;
  final List<CommandSuggestion> suggestions;
  final CommandPlan? plan;

  /// `start`'s ready-to-run sessions, each Enter away, best first; the last
  /// opens the dialog instead.
  final List<CommandPlan> launches;

  /// Something typed and committed that cannot be resolved.
  final String? error;
}

/// Suggestions shown for one argument.
const int kCommandSuggestionLimit = 12;

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
  final verb = typedCommandVerbOf(input);
  if (verb == null) return null;
  // `new api: fix the login bug` — what follows the colon is said first.
  String? message;
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
  ).parse();
}

class _Parser {
  _Parser({
    required this.catalog,
    required this.verb,
    required this.verbWord,
    required this.committed,
    required this.partial,
    this.message,
  });

  final CommandCatalog catalog;
  final CommandVerb verb;

  /// `start`'s opening message, typed after a colon.
  final String? message;
  final String verbWord;
  final List<String> committed;
  final String partial;

  /// The words accepted so far, as written back into the box.
  final List<String> _written = [];

  String get _base => '${[verbWord, ..._written].join(' ')} ';

  String _completion(String token) => '$_base$token ';

  TypedCommand parse() => switch (verb) {
    CommandVerb.start => _start(),
    CommandVerb.resume => _resume(),
    CommandVerb.openTerminal => _openTerminal(),
    CommandVerb.answer => _answer(),
    CommandVerb.stop || CommandVerb.fork || CommandVerb.end => _sessionVerb(),
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
    completion: _completion(s.token),
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

  TypedCommand _resume() {
    CommandProject? project;
    CommandSession? session;
    for (final word in committed) {
      if (session != null) {
        return _fail('resume takes one session — "$word" is one too many.');
      }
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
      if (typed.isNotEmpty) {
        return _fail('resume takes one session — "$typed" is one too many.');
      }
      final how = session.live ? 'Go to' : 'Resume';
      return TypedCommand(
        verb: verb,
        plan: CommandPlan(
          preview: [
            '$how "${session.title}"',
            if (session.agentName.isNotEmpty) session.agentName,
            session.projectName,
            ?session.ageLabel,
          ].join(' · '),
          canonical: 'resume ${session.token}',
          action: ResumeCommand(
            sessionId: session.id,
            imported: session.imported,
          ),
        ),
      );
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
