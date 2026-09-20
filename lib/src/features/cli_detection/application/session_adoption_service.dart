import '../../agents/application/hook_payload_field.dart';

import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart';
import '../../agents/data/agent_installation_dao.dart';
import 'package:karmashala_agent_reporting/status.dart';
import 'package:agent_cli/discovery.dart' hide Clock, IdGenerator;
import 'package:agent_cli/descriptors.dart';
import '../../environments/data/execution_environment_dao.dart';
import '../../repositories/data/repository_dao.dart';
import 'package:karmashala_git/repositories.dart';
import '../../sessions/data/session_dao.dart';
import '../../sessions/data/session_repository_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/launch.dart';
import '../data/imported_session_dao.dart';
import 'package:agent_cli/launch.dart';
import 'package:agent_cli/read.dart';
import 'detected_project_merger.dart';

/// How many store sweeps one armed pane is worth before adoption gives up — a
/// pane that only *looks* like an agent must not buy a scan every 10s forever.
const int kAdoptionSweepAttempts = 6;

/// How far before a pane was armed a session file may still count as its
/// session — the defence against adopting a conversation already running there.
const Duration kAdoptionMtimeSlack = Duration(seconds: 10);

/// One terminal pane, as adoption sees it. A plain value rather than a
/// `TerminalInstance`, so adoption is drivable in a test with no PTY.
class AdoptablePane {
  const AdoptablePane({
    required this.paneId,
    required this.workingDirectory,
    required this.isLive,
    required this.hostsLaunchedSession,
    this.lastCommandId,
    this.lastCommandLine,
    this.lastCommandRunning = true,
  });

  final String paneId;

  /// Where the pane was opened. `null` for a pane with no recorded directory,
  /// which can never be matched to a repository and so is never adopted.
  final String? workingDirectory;

  final bool isLive;

  /// Whether the app opened this pane to run a session it already has a row
  /// for. Those are the *launched* case and are never adopted.
  final bool hostsLaunchedSession;

  /// The newest OSC 133 command block's id, or `null` for a pane whose shell
  /// has no integration (`cmd.exe`, WSL bash today) or has run nothing yet.
  final String? lastCommandId;

  /// What that block's command line was, once the shell said it is running.
  /// `null` while still being typed, or for a shell that emits no `B` marker.
  final String? lastCommandLine;

  /// Whether that block is still running — the only thing separating an exited
  /// `claude --help` from a `claude` at its prompt. True when the shell is mute.
  final bool lastCommandRunning;
}

/// Adopts an agent session the user started by hand in one of our own terminal
/// panes. Keyed on the CLI's own session id, never ours, so a hook, an OSC
/// arming and a store sweep naming one conversation produce a single row.
class SessionAdoptionService {
  SessionAdoptionService({
    required this.sessionDao,
    required this.importedSessionDao,
    required this.repositoryDao,
    required this.environmentDao,
    required this.installationDao,
    required this.linkDao,
    required this.agents,
    required this.ids,
    required this.clock,
    required this.readPanes,
    this.readPaneTail,
    this.scanStores,
    this.onAdopted,
    this.translator = const PathTranslator(),
    this.gridSource = const TerminalGridStatusSource(),
    this.sweepAttempts = kAdoptionSweepAttempts,
    this.mtimeSlack = kAdoptionMtimeSlack,
  });

  final SessionDao sessionDao;
  final ImportedSessionDao importedSessionDao;
  final RepositoryDao repositoryDao;
  final ExecutionEnvironmentDao environmentDao;
  final AgentInstallationDao installationDao;
  final SessionRepositoryDao linkDao;
  final AgentRegistry agents;
  final IdGenerator ids;
  final Clock clock;

  /// Every pane the terminal layout is tracking. Called once a cycle.
  final List<AdoptablePane> Function() readPanes;

  /// The bottom rows of one pane's screen. Called only on the rationed slot,
  /// and only for a pane that is not already a candidate.
  final List<String> Function(String paneId, int lines)? readPaneTail;

  /// One pass over every CLI store. The fallback, and the only disk work here.
  final Future<List<DetectedSession>> Function()? scanStores;

  /// Called with each row adoption touches — adopted, rejoined, or released
  /// from the pane it was standing in — so the workspace can redraw.
  final void Function(Session session)? onAdopted;

  final PathTranslator translator;
  final TerminalGridStatusSource gridSource;
  final int sweepAttempts;
  final Duration mtimeSlack;

  /// Panes that look like they are running an agent we have no row for.
  final Map<String, _Candidate> _armed = {};

  /// paneId → the last command block we have already read, so a pane costs one
  /// record comparison per cycle and nothing else.
  final Map<String, (String, String?, bool)> _seenCommand = {};

  /// paneId → the row standing in that pane, `null` when the row names another.
  /// The value is what lets a pane give the row back when its agent leaves.
  final Map<String, String?> _bound = {};

  /// `<agentId>/<sessionId>` we have already decided about, so the flood of
  /// hook callbacks one session produces costs a set lookup after the first.
  final Set<String> _settled = {};

  /// The workspace's execution environments, re-read at the start of the work
  /// that needs them rather than once per path being compared.
  final Map<String, ExecutionEnvironment> _environments = {};

  /// Sessions adopted. Diagnostics, and what the idempotence tests count.
  int adoptions = 0;

  /// Store scans actually run — the cost claim.
  int storeSweeps = 0;

  /// Pane screens read to look for an agent, over all sweeps.
  int gridReads = 0;

  /// Whether a store scan would have anything to resolve.
  bool get wantsStoreSweep => _sweepable.isNotEmpty;

  /// Panes armed for adoption, for diagnostics and tests.
  Iterable<String> get armedPaneIds => _armed.keys;

  List<_Candidate> get _sweepable => [
    for (final candidate in _armed.values)
      if (!_bound.containsKey(candidate.paneId) &&
          candidate.attempts < sweepAttempts)
        candidate,
  ];

  /// One cycle's free work: notice what each pane's shell just ran. All in
  /// memory — no disk — so it is safe to run on every status cycle.
  void observePanes() {
    final panes = readPanes();
    final present = <String>{};
    for (final pane in panes) {
      present.add(pane.paneId);
      if (!pane.isLive || pane.hostsLaunchedSession) {
        _forget(pane.paneId);
        continue;
      }
      final commandId = pane.lastCommandId;
      if (commandId == null) continue;
      // Keyed by the block, its text *and* whether it is running: the id
      // appears at the prompt, the text only once running, the end marker neither.
      final seen = (commandId, pane.lastCommandLine, pane.lastCommandRunning);
      if (_seenCommand[pane.paneId] == seen) continue;
      _seenCommand[pane.paneId] = seen;
      // Whatever ran here has exited or been replaced, so the pane is free —
      // and any row standing in it must be told, since the shell lives on.
      _releasePane(pane.paneId);
      _forget(pane.paneId, keepSeen: true);
      // A finished command starts no agent: arming on one would let
      // `claude --help` collect a hook meant for an agent running elsewhere.
      if (!pane.lastCommandRunning) continue;
      final agentId = agentIdForCommandLine(pane.lastCommandLine ?? '', agents);
      if (agentId == null) continue;
      _arm(pane, agentId);
    }
    _armed.removeWhere((paneId, _) => !present.contains(paneId));
    _seenCommand.removeWhere((paneId, _) => !present.contains(paneId));
    // A pane that has gone away keeps its row's `paneId`: the row records where
    // the session ran. Only a live pane running something else is a lie.
    _bound.removeWhere((paneId, _) => !present.contains(paneId));
  }

  /// One hook callback for a session we may not know about. Synchronous and
  /// cheap: a busy agent fires these several times a second.
  void onHook({
    required String agentId,
    required String sessionId,
    String cwd = '',
  }) {
    if (agentId.isEmpty || sessionId.isEmpty) return;
    if (_settled.contains('$agentId/$sessionId')) return;
    final candidate = _claim(agentId, cwd);
    // Not ours. Deliberately not settled either: the pane may be armed a
    // moment from now, and the next callback is a set lookup away.
    if (candidate == null) return;
    _adopt(candidate: candidate, externalSessionId: sessionId);
  }

  /// One hook callback, raw: the one field adoption wants is declared per agent
  /// on [AgentHookSpec.cwdPath], so the endpoint has no business parsing it.
  void onHookPayload({
    required String agentId,
    required String sessionId,
    required String body,
  }) {
    if (agentId.isEmpty || sessionId.isEmpty) return;
    if (_settled.contains('$agentId/$sessionId')) return;
    final path = agents.byId(agentId)?.hooks?.cwdPath ?? const <String>[];
    onHook(
      agentId: agentId,
      sessionId: sessionId,
      cwd: path.isEmpty ? '' : _stringAt(path, body),
    );
  }

  /// The declared field, read by the one shared parser — see [hookStringAt].
  String _stringAt(List<String> path, String body) => hookStringAt(path, body);

  /// The rationed half — pane screens, then the CLI stores. Returns how many
  /// were adopted; runs only on `SessionStatusRegistry`'s store slot.
  Future<int> sweep() async {
    _armFromScreens();
    final waiting = _sweepable;
    if (waiting.isEmpty) return 0;
    final scan = scanStores;
    if (scan == null) return 0;
    storeSweeps++;
    final List<DetectedSession> detected;
    try {
      detected = await scan();
    } on Object {
      // A store we cannot read is the same answer as one with nothing in it.
      return 0;
    }
    var adopted = 0;
    _loadEnvironments();
    waiting.sort((a, b) => a.armedAt.compareTo(b.armedAt));
    for (final candidate in waiting) {
      candidate.attempts++;
      final match = _bestMatch(
        candidate,
        detected,
        _directoryKeys(candidate.workingDirectory),
      );
      if (match == null) continue;
      final id = _adopt(
        candidate: candidate,
        externalSessionId: match.sessionId,
        title: match.displayTitle,
      );
      if (id != null) adopted++;
    }
    return adopted;
  }

  /// Arms panes whose screen shows an agent's own TUI — the signal for a shell
  /// with no OSC 133 (`cmd.exe` always). Only unarmed, unbound live panes.
  void _armFromScreens() {
    final read = readPaneTail;
    if (read == null) return;
    for (final pane in readPanes()) {
      if (!pane.isLive || pane.hostsLaunchedSession) continue;
      if (_armed.containsKey(pane.paneId) || _bound.containsKey(pane.paneId)) {
        continue;
      }
      final agentId = _agentOnScreen(pane);
      if (agentId == null) continue;
      _arm(pane, agentId);
    }
  }

  /// The agent whose screen [pane] is showing, or `null`. Two matches is the
  /// same answer as none: Claude Code and Codex both draw `esc to interrupt`.
  String? _agentOnScreen(AdoptablePane pane) {
    final read = readPaneTail!;
    final now = clock.nowUtc();
    var depth = 0;
    for (final descriptor in agents.descriptors) {
      if (descriptor.grid.isEmpty) continue;
      if (descriptor.grid.scanLines > depth) depth = descriptor.grid.scanLines;
    }
    if (depth == 0) return null;
    gridReads++;
    final tail = read(pane.paneId, depth);
    if (tail.isEmpty) return null;
    String? only;
    for (final descriptor in agents.descriptors) {
      if (descriptor.grid.isEmpty) continue;
      final lines = descriptor.grid.scanLines;
      final rows = tail.length <= lines
          ? tail
          : tail.sublist(tail.length - lines);
      // `sessionId` is not known yet and is not what is being asked: this is
      // "whose screen is this", and the source answers it from the rows alone.
      if (gridSource.read(descriptor, rows, now, sessionId: '') == null) {
        continue;
      }
      if (only != null) return null;
      only = descriptor.id;
    }
    return only;
  }

  void _arm(AdoptablePane pane, String agentId) {
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

  /// The pane a signal for [agentId] belongs to; oldest arming wins. A [cwd] we
  /// cannot compare (WSL vs Windows) narrows nothing rather than rejecting all.
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
          if (_sameDirectory(candidate.workingDirectory, cwd)) candidate,
      ];
      if (here.isNotEmpty) candidates.retainWhere(here.contains);
    }
    candidates.sort((a, b) => a.armedAt.compareTo(b.armedAt));
    return candidates.first;
  }

  /// The store session [candidate]'s pane most likely just started. Cheapest
  /// test first, so the database lookup is paid only by plausible matches.
  DetectedSession? _bestMatch(
    _Candidate candidate,
    List<DetectedSession> detected,
    Set<String> directoryKeys,
  ) {
    if (directoryKeys.isEmpty) return null;
    final floor = candidate.armedAt.subtract(mtimeSlack);
    DetectedSession? best;
    for (final session in detected) {
      if (session.cli != candidate.agentId) continue;
      final at = session.modifiedAt?.toUtc();
      if (at == null || at.isBefore(floor)) continue;
      if (!directoryKeys.contains(_storeKey(session))) continue;
      // Already a row of ours: nothing to adopt, and picking it would be how
      // one conversation ends up under two ids.
      if (sessionDao.getAllByExternalSessionId(session.sessionId).isNotEmpty) {
        continue;
      }
      final bestAt = best?.modifiedAt?.toUtc();
      if (bestAt == null || at.isAfter(bestAt)) best = session;
    }
    return best;
  }

  /// The canonical key of a store session's own directory.
  String _storeKey(DetectedSession session) {
    final (key, _) = canonicalProjectPath(
      session.cwd,
      _environments[session.cwd.environmentId],
      translator,
    );
    return key;
  }

  /// Every canonical key [directory] could carry — one per environment, plus a
  /// flattened form — because a pane records a path but not its environment.
  Set<String> _directoryKeys(String? directory) {
    if (directory == null || directory.isEmpty) return const {};
    final keys = <String>{_flatten(directory)};
    for (final environment in _environments.values) {
      final (key, _) = canonicalProjectPath(
        EnvironmentPath(environmentId: environment.id, path: directory),
        environment,
        translator,
      );
      keys.add(key);
    }
    return keys;
  }

  /// Writes the row, or joins the one already there. Returns the session id
  /// when a session was adopted, `null` when nothing needed writing.
  String? _adopt({
    required _Candidate candidate,
    required String externalSessionId,
    String? title,
  }) {
    final key = '${candidate.agentId}/$externalSessionId';
    final existing = sessionDao.getAllByExternalSessionId(externalSessionId);
    if (existing.isNotEmpty) {
      _settled.add(key);
      _rejoin(existing.first, candidate);
      return null;
    }

    final repository = _repositoryFor(candidate.workingDirectory);
    if (repository == null) return null;
    final installation = _installationFor(repository, candidate.agentId);
    if (installation == null) return null;

    final descriptor = agents.byId(candidate.agentId);
    final session = Session(
      id: ids.newId(),
      repositoryId: repository.id,
      agentInstallationId: installation.id,
      title: _titleFor(title, candidate.agentId),
      useWorktree: false,
      // Never `worktree`: that field would make this session claim a git worktree
      // and put the user's own checkout in reach of `WorktreeService.remove`.
      workingDirectory: _directoryOf(candidate, repository),
      status: SessionStatus.running,
      createdAt: clock.nowUtc(),
      externalSessionId: externalSessionId,
      paneId: candidate.paneId,
      surface: SessionSurface.pane,
      view: defaultViewFor(descriptor),
      // Permission deliberately null: the user chose the mode by typing it, and
      // stamping a default would claim a policy this session may not be under.
    );
    sessionDao.insert(session);
    linkDao.link(
      session.id,
      repository.id,
      role: SessionRepositoryRole.primary,
    );
    // A read-only history row for the same conversation is not deleted: this
    // row supersedes it, and `ImportedSessionDao` resolves that for readers.
    _bound[candidate.paneId] = session.id;
    _settled.add(key);
    adoptions++;
    onAdopted?.call(session);
    return session.id;
  }

  /// A conversation we already have a row for, met again in a pane. Only a row
  /// with no pane at all is joined; overwriting one would move a live session.
  void _rejoin(Session session, _Candidate candidate) {
    // Bound either way, so the pane is not offered again — but only the row we
    // actually place here is ours to take back.
    if (session.paneId != null) {
      _bound[candidate.paneId] = null;
      return;
    }
    _bound[candidate.paneId] = session.id;
    sessionDao.updatePaneId(session.id, candidate.paneId);
    if (session.status != SessionStatus.running) {
      sessionDao.updateStatus(session.id, SessionStatus.running);
    }
    // Only a row that recorded no directory (pre-schema-v22). One that names
    // one was told by its launcher, and this evidence is not stronger.
    var updated = session.copyWith(
      paneId: candidate.paneId,
      status: SessionStatus.running,
    );
    if (session.workingDirectory == null) {
      final repository = repositoryDao.getById(session.repositoryId);
      final directory = repository == null
          ? null
          : _directoryOf(candidate, repository);
      if (directory != null) {
        sessionDao.updateWorkingDirectory(session.id, directory);
        updated = updated.copyWith(workingDirectory: directory);
      }
    }
    onAdopted?.call(updated);
  }

  /// The pane's directory, bound to [repository]'s environment, or `null` when
  /// the pane never recorded one.
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
    final session = sessionDao.getById(sessionId);
    // Only a row still naming this pane is released: a resume may have moved
    // the conversation into a pane of its own since, which is newer than ours.
    if (session == null || session.paneId != paneId) return;
    sessionDao.updatePaneId(sessionId, null);
    final updated = sessionDao.getById(sessionId);
    if (updated != null) onAdopted?.call(updated);
  }

  String _titleFor(String? title, String agentId) {
    final trimmed = title?.trim() ?? '';
    // The store knows what the conversation is about; a hook does not, and
    // inventing a summary from nothing would be worse than the agent's name.
    return trimmed.isEmpty ? agents.displayNameFor(agentId) : trimmed;
  }

  /// The deepest repository containing [directory], or `null` — deepest so a
  /// nested repository wins over its parent.
  Repository? _repositoryFor(String? directory) {
    if (directory == null || directory.isEmpty) return null;
    _loadEnvironments();
    Repository? best;
    var depth = -1;
    for (final repository in repositoryDao.getAll()) {
      final environment = _environments[repository.path.environmentId];
      final (repositoryKey, _) = canonicalProjectPath(
        repository.path,
        environment,
        translator,
      );
      final (paneKey, _) = canonicalProjectPath(
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

  /// The installation of [agentId] in [repository]'s environment, or `null` —
  /// guessing would produce a row whose resume command cannot be built.
  AgentInstallation? _installationFor(Repository repository, String agentId) {
    for (final installation in installationDao.getByEnvironment(
      repository.path.environmentId,
    )) {
      if (installation.agentId == agentId) return installation;
    }
    return null;
  }

  /// Whether two paths from the same environment name the same directory.
  bool _sameDirectory(String? a, String? b) {
    if (a == null || b == null) return false;
    return _flatten(a) == _flatten(b);
  }

  void _loadEnvironments() {
    _environments
      ..clear()
      ..addEntries(environmentDao.getAll().map((e) => MapEntry(e.id, e)));
  }

  static String _flatten(String path) =>
      path.replaceAll(r'\', '/').replaceAll(RegExp(r'/+$'), '').toLowerCase();
}

/// A pane that looks like it is running an agent we have no row for.
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
