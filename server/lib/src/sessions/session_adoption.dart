import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show AgentInstallation;
import 'package:agent_cli/launch.dart' show agentIdForCommandLine;
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_agent_reporting/status.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';

import '../protocol/messages.dart' show PaneFacts;
import 'session_sync_rows.dart';
import 'store_paths.dart';

/// How many store sweeps one armed pane is worth before adoption gives up — a
/// pane that only *looks* like an agent must not buy a scan every pass
/// forever.
const int kAdoptionSweepAttempts = 6;

/// How far before a pane was armed a store conversation may still count as
/// its session — the defence against adopting one already running there.
const Duration kAdoptionMtimeSlack = Duration(seconds: 10);

/// Adopts an agent session a person started by hand in one of a client's
/// terminal panes. Keyed on the agent's own conversation id, never ours, so a
/// hook, a command line and a store sweep naming one conversation produce a
/// single row.
///
/// A pane is **armed** when its shell reports a running command that starts
/// an agent (OSC 133) or its screen shows exactly one agent's own TUI; it is
/// **claimed** by the first hook of that agent from its directory, or by a
/// store sweep that finds a conversation begun there since. Whatever ran in
/// a pane that moves on gives the pane back.
class SessionAdoption {
  SessionAdoption({
    required this.rows,
    required this.newId,
    required this.clock,
    this.agents = AgentRegistry.builtIn,
    this.translator = const PathTranslator(),
    this.gridSource = const TerminalGridStatusSource(),
    this.sweepAttempts = kAdoptionSweepAttempts,
    this.mtimeSlack = kAdoptionMtimeSlack,
  });

  final SessionSyncRows rows;
  final String Function() newId;
  final Clock clock;
  final AgentRegistry agents;
  final PathTranslator translator;
  final TerminalGridStatusSource gridSource;
  final int sweepAttempts;
  final Duration mtimeSlack;

  /// Every pane the clients reported last, by id.
  final Map<String, PaneFacts> _panes = {};

  /// Panes that look like they run an agent we have no row for.
  final Map<String, _Candidate> _armed = {};

  /// paneId → the last command block already read, so a pane costs one
  /// record comparison per report and nothing else.
  final Map<String, (String, String?, bool)> _seenCommand = {};

  /// paneId → the row standing in that pane, null when the row names
  /// another. The value is what lets a pane give the row back.
  final Map<String, String?> _bound = {};

  /// `<agentId>/<conversationId>` already decided, so the flood of hooks one
  /// session produces costs a set lookup after the first.
  final Set<String> _settled = {};

  /// Sessions adopted, over this service's life.
  int adoptions = 0;

  /// Pane screens read to look for an agent, over all sweeps.
  int gridReads = 0;

  /// Whether a store scan would have anything to resolve.
  bool get wantsStoreSweep => _sweepable.isNotEmpty;

  /// Panes armed, for diagnostics and tests.
  Iterable<String> get armedPaneIds => _armed.keys;

  List<_Candidate> get _sweepable => [
    for (final candidate in _armed.values)
      if (!_bound.containsKey(candidate.paneId) &&
          candidate.attempts < sweepAttempts)
        candidate,
  ];

  /// The panes whose screens a sweep would read to arm them: live, not the
  /// client's own launch, neither armed nor bound — what a client is asked
  /// for the tails of.
  List<String> get screenCandidates => [
    for (final pane in _panes.values)
      if (pane.live &&
          !pane.hostsLaunchedSession &&
          !_armed.containsKey(pane.paneId) &&
          !_bound.containsKey(pane.paneId))
        pane.paneId,
  ];

  /// How many rows of a screen tell one agent from another, at most.
  int get screenLines {
    var depth = 0;
    for (final descriptor in agents.descriptors) {
      if (descriptor.grid.isEmpty) continue;
      if (descriptor.grid.scanLines > depth) depth = descriptor.grid.scanLines;
    }
    return depth;
  }

  /// The pane [paneId] as last reported, or null.
  PaneFacts? pane(String paneId) => _panes[paneId];

  /// Takes every pane the clients have now: notices what each pane's shell
  /// just ran. All in memory — no disk — so it runs on every report.
  void observePanes(Iterable<PaneFacts> panes) {
    _panes
      ..clear()
      ..addEntries([for (final pane in panes) MapEntry(pane.paneId, pane)]);
    for (final pane in _panes.values) {
      if (!pane.live || pane.hostsLaunchedSession) {
        _forget(pane.paneId);
        continue;
      }
      final commandId = pane.lastCommandId;
      if (commandId == null) continue;
      // Keyed by the block, its text *and* whether it runs: the id appears at
      // the prompt, the text only once running, the end marker neither.
      final seen = (commandId, pane.lastCommandLine, pane.lastCommandRunning);
      if (_seenCommand[pane.paneId] == seen) continue;
      _seenCommand[pane.paneId] = seen;
      // Whatever ran here has exited or been replaced, so the pane is free —
      // and a row standing in it is told, since the shell lives on.
      _releasePane(pane.paneId);
      _forget(pane.paneId, keepSeen: true);
      // A finished command starts no agent: arming on one would let
      // `claude --help` collect a hook meant for an agent elsewhere.
      if (!pane.lastCommandRunning) continue;
      final agentId = agentIdForCommandLine(pane.lastCommandLine ?? '', agents);
      if (agentId == null) continue;
      _arm(pane, agentId);
    }
    _armed.removeWhere((paneId, _) => !_panes.containsKey(paneId));
    _seenCommand.removeWhere((paneId, _) => !_panes.containsKey(paneId));
    // A pane that has gone away keeps its row's `paneId`: the row records
    // where the session ran. Only a live pane running something else lies.
    _bound.removeWhere((paneId, _) => !_panes.containsKey(paneId));
  }

  /// One hook of agent [agentId] about conversation [conversationId], from
  /// directory [cwd] when the hook says. Synchronous and cheap: a busy agent
  /// fires several a second.
  void hook({
    required String agentId,
    required String conversationId,
    String cwd = '',
  }) {
    if (agentId.isEmpty || conversationId.isEmpty) return;
    if (_settled.contains('$agentId/$conversationId')) return;
    final candidate = _claim(agentId, cwd);
    // Not ours. Deliberately not settled: the pane may be armed a moment from
    // now, and the next hook is a set lookup away.
    if (candidate == null) return;
    _adopt(candidate: candidate, conversationId: conversationId);
  }

  /// Arms the panes whose screen shows one agent's own TUI — the signal for
  /// a shell with no OSC 133 (`cmd.exe` always). [tails] are the rows the
  /// clients reported, by pane.
  void armFromScreens(Map<String, List<String>> tails) {
    final depth = screenLines;
    if (depth == 0) return;
    for (final paneId in screenCandidates) {
      final tail = tails[paneId];
      if (tail == null || tail.isEmpty) continue;
      gridReads++;
      final agentId = _agentOnScreen(tail);
      if (agentId == null) continue;
      _arm(_panes[paneId]!, agentId);
    }
  }

  /// The store half: names the conversation each armed pane most likely
  /// started, from [detected] — one pass's scan. Returns how many adopted.
  int sweep(List<DetectedSession> detected) {
    final waiting = _sweepable;
    if (waiting.isEmpty) return 0;
    final environments = rows.environments();
    var adopted = 0;
    waiting.sort((a, b) => a.armedAt.compareTo(b.armedAt));
    for (final candidate in waiting) {
      candidate.attempts++;
      final match = _bestMatch(
        candidate,
        detected,
        _directoryKeys(candidate.workingDirectory, environments),
        environments,
      );
      if (match == null) continue;
      final id = _adopt(
        candidate: candidate,
        conversationId: match.sessionId,
        title: match.displayTitle,
      );
      if (id != null) adopted++;
    }
    return adopted;
  }

  /// The agent whose screen [tail] shows, or null. Two matches is the same
  /// answer as none: two agents may draw the same footer.
  String? _agentOnScreen(List<String> tail) {
    final now = clock.nowUtc();
    String? only;
    for (final descriptor in agents.descriptors) {
      if (descriptor.grid.isEmpty) continue;
      final lines = descriptor.grid.scanLines;
      final rows = tail.length <= lines
          ? tail
          : tail.sublist(tail.length - lines);
      if (gridSource.read(descriptor, rows, now, sessionId: '') == null) {
        continue;
      }
      if (only != null) return null;
      only = descriptor.id;
    }
    return only;
  }

  void _arm(PaneFacts pane, String agentId) {
    _armed[pane.paneId] = _Candidate(
      paneId: pane.paneId,
      agentId: agentId,
      workingDirectory: pane.workingDirectory,
      armedAt: clock.nowUtc(),
    );
  }

  void _forget(String paneId, {bool keepSeen = false}) {
    _armed.remove(paneId);
    _bound.remove(paneId);
    if (!keepSeen) _seenCommand.remove(paneId);
  }

  /// The pane a hook of [agentId] belongs to; oldest arming wins. A [cwd] that
  /// matches none (WSL against Windows) narrows nothing rather than refusing.
  _Candidate? _claim(String agentId, String cwd) {
    final candidates = [
      for (final candidate in _armed.values)
        if (candidate.agentId == agentId &&
            !_bound.containsKey(candidate.paneId))
          candidate,
    ];
    if (candidates.isEmpty) return null;
    if (cwd.isNotEmpty) {
      final here = [
        for (final candidate in candidates)
          if (candidate.workingDirectory != null &&
              flattenedPath(candidate.workingDirectory!) == flattenedPath(cwd))
            candidate,
      ];
      if (here.isNotEmpty) candidates.retainWhere(here.contains);
    }
    candidates.sort((a, b) => a.armedAt.compareTo(b.armedAt));
    return candidates.first;
  }

  /// The store conversation [candidate]'s pane most likely just started.
  DetectedSession? _bestMatch(
    _Candidate candidate,
    List<DetectedSession> detected,
    Set<String> directoryKeys,
    Map<String, ExecutionEnvironment> environments,
  ) {
    if (directoryKeys.isEmpty) return null;
    final floor = candidate.armedAt.subtract(mtimeSlack);
    DetectedSession? best;
    for (final session in detected) {
      if (session.cli != candidate.agentId) continue;
      final at = session.modifiedAt?.toUtc();
      if (at == null || at.isBefore(floor)) continue;
      final key = canonicalStoreKey(
        session.cwd,
        environments[session.cwd.environmentId],
        translator,
      );
      if (!directoryKeys.contains(key)) continue;
      // Already a row: picking it is how one conversation ends up under two.
      if (rows.sessions
          .getAllByExternalSessionId(session.sessionId)
          .isNotEmpty) {
        continue;
      }
      final bestAt = best?.modifiedAt?.toUtc();
      if (bestAt == null || at.isAfter(bestAt)) best = session;
    }
    return best;
  }

  /// Every canonical key [directory] could carry — one per environment, plus
  /// a flattened form — because a pane records a path but not its
  /// environment.
  Set<String> _directoryKeys(
    String? directory,
    Map<String, ExecutionEnvironment> environments,
  ) {
    if (directory == null || directory.isEmpty) return const {};
    return {
      flattenedPath(directory),
      for (final environment in environments.values)
        canonicalStoreKey(
          EnvironmentPath(environmentId: environment.id, path: directory),
          environment,
          translator,
        ),
    };
  }

  /// Writes the row, or joins the one already there. Returns the new row's
  /// id, or null when nothing was adopted.
  String? _adopt({
    required _Candidate candidate,
    required String conversationId,
    String? title,
  }) {
    final key = '${candidate.agentId}/$conversationId';
    final existing = rows.sessions.getAllByExternalSessionId(conversationId);
    if (existing.isNotEmpty) {
      _settled.add(key);
      _rejoin(existing.first, candidate);
      return null;
    }
    final repository = _repositoryFor(candidate.workingDirectory);
    if (repository == null) return null;
    final installation = _installationFor(repository, candidate.agentId);
    if (installation == null) return null;

    final session = Session(
      id: newId(),
      repositoryId: repository.id,
      agentInstallationId: installation.id,
      title: _titleFor(title, candidate.agentId),
      useWorktree: false,
      // Never `worktree`: that would make this session claim a git worktree
      // and put the person's own checkout in reach of its removal.
      workingDirectory: _directoryOf(candidate, repository),
      status: SessionStatus.running,
      createdAt: clock.nowUtc(),
      externalSessionId: conversationId,
      paneId: candidate.paneId,
      surface: SessionSurface.pane,
      view: defaultViewFor(agents.adapterFor(candidate.agentId)),
      // No permission mode: the person chose one by typing it, and stamping a
      // default would claim a policy this session may not be under.
    );
    if (rows.create(session) == null) return null;
    // Imported history for the same conversation stays: this row supersedes
    // it, which every reader resolves (`visibleImported`).
    _bound[candidate.paneId] = session.id;
    _settled.add(key);
    adoptions++;
    return session.id;
  }

  /// A conversation that has a row, met again in a pane. Only a row with no
  /// pane is joined; overwriting one would move a live session.
  void _rejoin(Session session, _Candidate candidate) {
    if (session.paneId != null) {
      _bound[candidate.paneId] = null;
      return;
    }
    _bound[candidate.paneId] = session.id;
    var patch = SessionPatch.pane(candidate.paneId);
    if (session.status != SessionStatus.running) {
      patch = patch.and(SessionPatch.status(SessionStatus.running));
    }
    // Only a row that recorded no directory: one that names one was told by
    // its launcher, and this evidence is not stronger.
    if (session.workingDirectory == null) {
      final repository = rows.repository(session.repositoryId);
      final directory = repository == null
          ? null
          : _directoryOf(candidate, repository);
      if (directory != null) {
        patch = patch.and(SessionPatch.directory(directory));
      }
    }
    rows.edit(session.id, patch);
  }

  EnvironmentPath? _directoryOf(_Candidate candidate, Repository repository) {
    final directory = candidate.workingDirectory;
    if (directory == null || directory.isEmpty) return null;
    return EnvironmentPath(
      environmentId: repository.path.environmentId,
      path: directory,
    );
  }

  /// Hands the pane back from the row adoption placed in it. The pane outlives
  /// the agent, so without this a row reads its badge off whatever runs next.
  void _releasePane(String paneId) {
    final sessionId = _bound[paneId];
    if (sessionId == null) return;
    final session = rows.sessions.getById(sessionId);
    // Only a row still naming this pane: a resume may have moved it since.
    if (session == null || session.paneId != paneId) return;
    rows.edit(sessionId, SessionPatch.pane(null));
  }

  String _titleFor(String? title, String agentId) {
    final trimmed = title?.trim() ?? '';
    // The store knows what the conversation is about; a hook does not.
    return trimmed.isEmpty ? agents.displayNameFor(agentId) : trimmed;
  }

  /// The deepest checkout containing [directory] — deepest, so a nested
  /// repository wins over its parent.
  Repository? _repositoryFor(String? directory) {
    if (directory == null || directory.isEmpty) return null;
    final environments = rows.environments();
    Repository? best;
    var depth = -1;
    for (final repository in rows.repositories()) {
      final environment = environments[repository.path.environmentId];
      final repositoryKey = canonicalStoreKey(
        repository.path,
        environment,
        translator,
      );
      final paneKey = canonicalStoreKey(
        EnvironmentPath(
          environmentId: repository.path.environmentId,
          path: directory,
        ),
        environment,
        translator,
      );
      final contained =
          paneKey == repositoryKey ||
          paneKey.startsWith('$repositoryKey\\') ||
          paneKey.startsWith('$repositoryKey/');
      if (contained && repositoryKey.length > depth) {
        best = repository;
        depth = repositoryKey.length;
      }
    }
    return best;
  }

  /// The installation of [agentId] in [repository]'s environment, or null —
  /// guessing would write a row whose resume cannot be built.
  AgentInstallation? _installationFor(Repository repository, String agentId) {
    for (final installation in rows.installationsIn(
      repository.path.environmentId,
    )) {
      if (installation.agentId == agentId) return installation;
    }
    return null;
  }
}

class _Candidate {
  _Candidate({
    required this.paneId,
    required this.agentId,
    required this.workingDirectory,
    required this.armedAt,
  });

  final String paneId;
  final String agentId;
  final String? workingDirectory;
  final DateTime armedAt;

  /// Store sweeps spent trying to name this pane's conversation.
  int attempts = 0;
}
