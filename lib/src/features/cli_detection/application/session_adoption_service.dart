import 'dart:convert';

import '../../../core/process/path_translator.dart';
import '../../../core/util/clock.dart';
import '../../../core/util/id_generator.dart';
import '../../agents/data/agent_installation_dao.dart';
import '../../agents/data/terminal_grid_status_source.dart';
import '../../agents/domain/agent_installation.dart';
import '../../agents/domain/agent_registry.dart';
import '../../environments/data/execution_environment_dao.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../../repositories/data/repository_dao.dart';
import '../../repositories/domain/repository.dart';
import '../../sessions/data/session_dao.dart';
import '../../sessions/data/session_repository_dao.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/domain/session_launch.dart';
import '../../sessions/domain/session_status.dart';
import '../data/imported_session_dao.dart';
import '../domain/agent_command_line.dart';
import '../domain/detected_session.dart';
import 'detected_project_merger.dart';

/// How many store sweeps one armed pane is worth before adoption gives up on
/// it.
///
/// A CLI writes its session file within a second or two of starting, so the
/// first sweep after a pane is armed normally answers. The cap is what stops a
/// pane running something that merely *looks* like an agent — or an agent whose
/// store we cannot read — from buying a store scan every ten seconds forever.
const int kAdoptionSweepAttempts = 6;

/// How far before a pane was armed a session file may have been written and
/// still count as the session that pane just started.
///
/// Small on purpose. The window is the whole defence against adopting a
/// conversation that was already running somewhere else in the same directory.
const Duration kAdoptionMtimeSlack = Duration(seconds: 10);

/// One terminal pane, as adoption sees it.
///
/// Deliberately a plain value rather than a `TerminalInstance`: adoption reads
/// pane state through the existing providers and never holds a pane, so it can
/// be driven at a hundred panes in a test with no terminal, no PTY and no
/// widget tree.
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

  /// What that block's command line was, once the shell said the command is
  /// running. `null` while it is still being typed, and for a shell that emits
  /// no `B` marker and so cannot have its input read back.
  final String? lastCommandLine;

  /// Whether that block is still running.
  ///
  /// `CommandBlockTracker.latest` goes on reporting a finished block — same id,
  /// same text — until the shell draws its next prompt, so this flag is the
  /// only thing separating `claude --help`, which has printed its usage and
  /// exited, from a `claude` sitting at its prompt. Defaults to true because a
  /// shell that never emits the end marker has told us nothing.
  final bool lastCommandRunning;
}

/// Adopts an agent session the user started **by hand** in one of our own
/// terminal panes, so it lands in the Explorer beside the ones the app
/// launched.
///
/// ## The signals, in precedence order
///
/// 1. **A hook callback** (`/agent-hook`) — authoritative and free: it names
///    the agent and the CLI's own session id, which is the only identifier that
///    can make adoption idempotent. Event-driven, so adoption is immediate.
/// 2. **An OSC 133 command line** — free, because the pane has already parsed
///    it. `claude` at a prompt *arms* the pane: it says which agent is running
///    and where, but not which conversation, so it cannot adopt on its own.
/// 3. **The agent's own screen** — cheap. A pane whose bottom rows match a
///    registry [AgentGridRules] is running that agent, which arms panes whose
///    shell has no OSC 133 at all. Read on the rationed slot, not every cycle.
/// 4. **A CLI-store scan** — the disk, and the fallback. It turns an armed pane
///    into a conversation id for an agent with no hooks (Codex has none). It
///    runs on `SessionStatusRegistry`'s store slot, at most once per ten
///    seconds, and only while some pane is armed and unresolved.
///
/// ## What makes it idempotent
///
/// The key is the **CLI's own session id**, never ours, and it is checked
/// against `sessions.external_session_id` before anything is written — so a
/// hook, an OSC arming and a store sweep all naming one conversation produce
/// one row, and a restart (which loses every in-memory signal) re-reads the row
/// from the database rather than minting a second. A pane is bound at most
/// once, and a bound pane stops being a candidate, so two signals about one
/// pane cannot become two sessions either.
///
/// ## What it will not do
///
/// **Adoption always needs one of our panes.** A hook from a Claude Code
/// running in somebody else's terminal names a real conversation, and adopting
/// it would put a row in the Explorer for a process we do not host and cannot
/// show. So a signal with no candidate pane is dropped, and the existing
/// `SessionAutoImportService` remains the way such a session enters the
/// workspace — as history.
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

  /// Every pane the terminal workspace is tracking. Called once a cycle.
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

  /// paneId → the session row standing in that pane, or `null` for a pane bound
  /// to a row that names a *different* pane. Never candidates again until the
  /// shell returns to a prompt and runs something else.
  ///
  /// The value is what lets a pane give the row back when its agent leaves: a
  /// bare set could tell that the pane had moved on but not which row was still
  /// claiming it.
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

  /// One cycle's free work: notice what each pane's shell just ran.
  ///
  /// O(panes), all in memory — a map lookup and one record comparison per pane,
  /// against state the pane parsed for its own command history. Nothing here
  /// touches the disk, so it is safe to run on every status cycle.
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
      // Keyed by the block *and* its text: the id appears at the prompt, and
      // the command line only arrives once the shell says it is running.
      // Keyed by the block, its text *and* whether it is still running: the id
      // appears at the prompt, the command line only once the shell says it is
      // running, and the end marker changes neither of the first two.
      final seen = (commandId, pane.lastCommandLine, pane.lastCommandRunning);
      if (_seenCommand[pane.paneId] == seen) continue;
      _seenCommand[pane.paneId] = seen;
      // Whatever was running here before has either exited or been replaced, so
      // the pane is free again — and any row standing in it has to be told,
      // because the pane itself lives on as a shell.
      _releasePane(pane.paneId);
      _forget(pane.paneId, keepSeen: true);
      // A command the shell has reported finished starts no agent. Arming on
      // one would let `claude --help` collect a passing hook meant for an agent
      // running somewhere else entirely.
      if (!pane.lastCommandRunning) continue;
      final agentId = agentIdForCommandLine(pane.lastCommandLine ?? '', agents);
      if (agentId == null) continue;
      _arm(pane, agentId);
    }
    _armed.removeWhere((paneId, _) => !present.contains(paneId));
    _seenCommand.removeWhere((paneId, _) => !present.contains(paneId));
    // A pane that has gone away keeps its row's `paneId`, exactly as a launched
    // session's does: the row records where the session ran, and the terminal
    // controller answers with no instance for it. Only a pane that is still
    // there running something else is a lie worth correcting.
    _bound.removeWhere((paneId, _) => !present.contains(paneId));
  }

  /// One hook callback for a session we may not know about.
  ///
  /// Synchronous and cheap by design: the endpoint that calls it must never be
  /// slowed down, and a busy agent fires these several times a second.
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

  /// One hook callback, still in the shape the agent posted it.
  ///
  /// The transport hands over the raw body rather than a parsed one because the
  /// only extra field adoption wants — the directory the agent is working in —
  /// is declared per agent on [AgentHookSpec.cwdPath], and the endpoint has no
  /// business knowing that.
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

  /// The string at [path] in the JSON [body], or `''` for anything else — a
  /// missing key, a non-string value, or a body that is not JSON at all.
  String _stringAt(List<String> path, String body) {
    Object? value;
    try {
      value = jsonDecode(body);
    } on FormatException {
      return '';
    }
    for (final segment in path) {
      if (value is! Map) return '';
      value = value[segment];
    }
    return value is String ? value : '';
  }

  /// The rationed half: look at pane screens, then at the CLI stores.
  ///
  /// Returns how many sessions were adopted. Runs only on
  /// `SessionStatusRegistry`'s store slot, and returns immediately when nothing
  /// is waiting on it, so an idle workspace pays nothing.
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

  /// Arms panes whose screen shows an agent's own TUI.
  ///
  /// The signal for a shell with no OSC 133 — WSL bash today, `cmd.exe`
  /// always. Only unarmed, unbound, live plain panes are read, so the cost
  /// falls as panes are adopted and is zero once every pane is accounted for.
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

  /// The agent whose screen [pane] is showing, or `null`.
  ///
  /// One read of the pane, sliced per descriptor: each agent states how far up
  /// its own prompt reaches, and reading the deepest once is what keeps this a
  /// single screen read per pane rather than one per agent in the registry.
  ///
  /// **Only an unambiguous screen arms a pane.** Claude Code and Codex both
  /// draw `esc to interrupt` while they work, so a busy screen names no
  /// particular agent — and arming it as the first match would send the store
  /// sweep looking through the wrong CLI's store. Two matches is therefore the
  /// same answer as none: this pane stays invisible until a signal that can
  /// tell them apart arrives.
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

  /// The pane a signal for [agentId] belongs to, or `null`.
  ///
  /// [cwd] narrows when the agent's hooks carry one and it actually matches a
  /// candidate; a directory in a form we cannot compare (a WSL path against a
  /// Windows pane) simply does not narrow, rather than rejecting everything.
  /// Among what is left the **oldest arming wins**, because the first pane to
  /// start an agent is the first to reach a turn worth reporting.
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

  /// The store session [candidate]'s pane most likely just started.
  ///
  /// Ordered cheapest test first — agent, then age, then directory — so the one
  /// database lookup per store session is paid only by the handful that could
  /// still be it.
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

  /// Every canonical key [directory] could carry, one per environment it might
  /// belong to, plus its flattened form for a path we cannot place.
  ///
  /// A pane records a directory string and not the environment it came from, so
  /// this asks the question from the other end: which environment would make
  /// this path mean the folder a store session names.
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
      // Where the user actually started the agent, which until now was known
      // here and thrown away. Bound to the repository's environment because
      // that is the environment `_repositoryFor` made the match under, so the
      // path means the same folder it meant when it was compared. Never
      // `worktree`: that field would make this session claim a git worktree
      // and put the user's own checkout in reach of `WorktreeService.remove`.
      workingDirectory: _directoryOf(candidate, repository),
      status: SessionStatus.running,
      createdAt: clock.nowUtc(),
      externalSessionId: externalSessionId,
      paneId: candidate.paneId,
      surface: SessionSurface.pane,
      view: defaultViewFor(descriptor),
      // Deliberately null. The user typed the command line themselves, so we
      // did not choose a mode and have no way to read the one they chose;
      // stamping a default would claim a policy this session may not be under.
      // `SessionLauncher.permissionFor` reads the per-agent setting instead.
    );
    sessionDao.insert(session);
    linkDao.link(
      session.id,
      repository.id,
      role: SessionRepositoryRole.primary,
    );
    // The same conversation may already be in the workspace as read-only
    // history. Nothing is deleted for that: the row above now *supersedes* it,
    // which `ImportedSessionDao` resolves for every reader — so the Explorer
    // shows one card, and the history is still there if this row is ever
    // removed. See that class's doc for why the tie is broken there.
    _bound[candidate.paneId] = session.id;
    _settled.add(key);
    adoptions++;
    onAdopted?.call(session);
    return session.id;
  }

  /// A conversation we already have a row for, met again in a pane.
  ///
  /// Only a row with **no pane at all** is joined. One that names a pane is
  /// either the live session (in which case there is nothing to do) or a
  /// record of where it used to run, and overwriting that would move a session
  /// on evidence this weak. A joined row goes back to running, because a
  /// resumed conversation is running whatever its last recorded state was.
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
    // Only a row that recorded nothing. A row written before schema v22 has an
    // unknown directory and this pane is a real answer for it; a row that
    // already names one was told by whoever launched it, and this evidence —
    // a pane running an agent with the same conversation id — is not stronger
    // than that.
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

  /// Hands the pane back from the row adoption placed in it.
  ///
  /// Called when a bound pane's shell moves on to something else. The pane
  /// outlives the agent — it is a shell, not the agent's own process — so
  /// without this the row goes on reporting itself as hosted live in a pane
  /// showing a prompt, and its status badge is read off whatever runs there
  /// next. The status is deliberately left alone: the conversation still
  /// exists and can be resumed, and only its whereabouts have changed.
  void _releasePane(String paneId) {
    final sessionId = _bound[paneId];
    if (sessionId == null) return;
    final session = sessionDao.getById(sessionId);
    // Only a row still naming this pane is released. A resume may have moved
    // the conversation into a pane of its own since, and that placement is
    // newer than ours.
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

  /// The deepest repository containing [directory], or `null`.
  ///
  /// Deepest rather than first, so a pane opened inside a nested repository is
  /// adopted into that one rather than into its parent.
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

  /// The installation of [agentId] in [repository]'s environment, or `null`.
  ///
  /// A session row has to name one, and guessing at an agent the workspace has
  /// never discovered would produce a row whose resume command cannot be built.
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
      ..addEntries(
        environmentDao.getAll().map((e) => MapEntry(e.id, e)),
      );
  }

  static String _flatten(String path) => path
      .replaceAll(r'\', '/')
      .replaceAll(RegExp(r'/+$'), '')
      .toLowerCase();
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
