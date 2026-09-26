import '../../workspaces/data/workspace_data.dart';
import 'package:agent_cli/process.dart';
import '../../agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import '../../environments/data/execution_environment_dao.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/session.dart';
import 'package:agent_cli/read.dart';
import 'detected_project_merger.dart';

/// How long after a session row is written its CLI's conversation may have
/// begun and still be that session's — the row is written before the spawn.
const Duration kLaunchedAttributionWindow = Duration(minutes: 2);

/// How far *before* the row a conversation may have begun and still be it —
/// only clock skew: ours and the CLI's, a different kernel under WSL.
const Duration kLaunchedAttributionSkew = Duration(seconds: 5);

/// Writes the CLI's conversation id onto a session we launched for an agent
/// that would not accept one — and only when the store's answer is unambiguous.
class LaunchedSessionAttributionService {
  LaunchedSessionAttributionService({
    required this.sessionDao,
    required this.installationDao,
    required this.workspace,
    required this.environmentDao,
    required this.agents,
    required this.scanStores,
    this.translator = const PathTranslator(),
    this.window = kLaunchedAttributionWindow,
    this.skew = kLaunchedAttributionSkew,
    this.onAttributed,
  });

  final SessionDao sessionDao;
  final AgentInstallationDao installationDao;
  final WorkspaceData workspace;
  final ExecutionEnvironmentDao environmentDao;
  final AgentRegistry agents;

  /// One pass over every CLI store — the same scan adoption and the title sync
  /// use.
  final Future<List<DetectedSession>> Function() scanStores;

  final PathTranslator translator;
  final Duration window;
  final Duration skew;

  /// Called with each row that gained an id, so the workspace can redraw.
  final void Function(Session session, String conversationId)? onAttributed;

  /// sessionId → why nothing was written, in words. Diagnostics only: what a
  /// user sees comes from the resume path, which re-reads the store.
  final Map<String, String> _refusals = {};

  /// Store scans actually run — the cost claim.
  int scans = 0;

  /// Rows given an id, over all sweeps.
  int attributions = 0;

  /// Whether a store scan would have anything to attribute.
  bool get wantsStoreSweep => _waiting().isNotEmpty;

  String? reasonFor(String sessionId) => _refusals[sessionId];

  /// Learns what it can and writes it. Returns how many rows gained an id.
  Future<int> attribute() async {
    final waiting = _waiting();
    if (waiting.isEmpty) return 0;
    scans++;
    final List<DetectedSession> detected;
    try {
      detected = await scanStores();
    } on Object {
      // A store we cannot read is the same answer as one with nothing in it —
      // never a reason to name a conversation.
      return 0;
    }

    final environments = {
      for (final environment in environmentDao.getAll())
        environment.id: environment,
    };
    final held = sessionDao.heldExternalSessionIds();

    // Grouped by agent and directory, because that pair is all the store knows:
    // a rollout records where it ran, never which process ran it.
    final byPlace = <String, List<_Candidate>>{};
    for (final candidate in waiting) {
      byPlace.putIfAbsent(candidate.placeKey, () => []).add(candidate);
    }

    var learned = 0;
    for (final entry in byPlace.entries) {
      final group = entry.value;
      if (group.length > 1) {
        // Two sessions started into one folder, and the store cannot say which
        // rollout is which. Attributing either would be a coin toss.
        for (final candidate in group) {
          _refusals[candidate.session.id] =
              '${group.length} sessions with no conversation id are running in '
              '${candidate.directory.path}, and the store records a '
              'conversation for the directory rather than for a process, so '
              'there is no way to tell which of them it belongs to.';
        }
        continue;
      }
      final candidate = group.single;
      final matches = _matchesFor(candidate, detected, environments, held);
      if (matches.length != 1) {
        _refusals[candidate.session.id] = matches.isEmpty
            ? 'No ${candidate.agentName} conversation began in '
                  '${candidate.directory.path} when this session started.'
            : '${matches.length} ${candidate.agentName} conversations began in '
                  '${candidate.directory.path} when this session started, and '
                  'the store cannot say which of them this one is on.';
        continue;
      }
      final id = matches.single.sessionId;
      sessionDao.updateExternalSessionId(candidate.session.id, id);
      held.add(id);
      _refusals.remove(candidate.session.id);
      attributions++;
      learned++;
      onAttributed?.call(candidate.session, id);
    }
    return learned;
  }

  /// The store conversations that could be [candidate]'s.
  List<DetectedSession> _matchesFor(
    _Candidate candidate,
    List<DetectedSession> detected,
    Map<String, ExecutionEnvironment> environments,
    Set<String> held,
  ) {
    final from = candidate.session.createdAt.subtract(skew);
    final to = candidate.session.createdAt.add(window);
    return [
      for (final session in detected)
        if (session.cli == candidate.agentId &&
            // A store that cannot say when a conversation began cannot answer
            // this; directory alone takes what the folder was last used for.
            session.startedAt != null &&
            !session.startedAt!.toUtc().isBefore(from) &&
            !session.startedAt!.toUtc().isAfter(to) &&
            !held.contains(session.sessionId) &&
            _keyFor(session.cwd, environments) == candidate.directoryKey)
          session,
    ];
  }

  /// Every row still waiting for a conversation id, with what matching needs.
  List<_Candidate> _waiting() {
    final environments = {
      for (final environment in environmentDao.getAll())
        environment.id: environment,
    };
    final candidates = <_Candidate>[];
    for (final row in sessionDao.getUnattributed()) {
      // Only a running session: a stopped one would buy a store scan on every
      // slot for ever. `SessionActions` recovers its id at resume instead.
      if (row.status != SessionStatus.running) continue;

      final descriptor = _descriptorFor(row);
      if (descriptor == null) continue;
      // Keyed on the capability, not an agent name: a row for an agent we could
      // have told its id is a fork or a failed launch, not something to infer.
      if (descriptor.launch.sessionIdAssignment.isSupported) continue;
      // An agent whose store records the last conversation per directory is
      // excluded by ownership: its own service has better evidence — the CLI
      // prints its resume command into our pane.
      if (agents.adapterFor(descriptor.id)?.directoryConversations != null) {
        continue;
      }

      // Decreasing certainty, as `sessionWorkingDirectoryOf` does: where the
      // process started, then its worktree, then the repository root.
      final directory =
          row.workingDirectory ??
          row.worktree ??
          workspace.repository(row.repositoryId)?.path;
      if (directory == null || directory.path.isEmpty) continue;

      candidates.add(
        _Candidate(
          session: row,
          agentId: descriptor.id,
          agentName: descriptor.displayName,
          directory: directory,
          directoryKey: _keyFor(directory, environments),
        ),
      );
    }
    return candidates;
  }

  AgentDescriptor? _descriptorFor(Session row) {
    final agentId = installationDao.getById(row.agentInstallationId)?.agentId;
    return agentId == null ? null : agents.byId(agentId);
  }

  /// The canonical form of a directory, so a WSL row and the rollout it wrote
  /// are compared as the same folder.
  String _keyFor(
    EnvironmentPath directory,
    Map<String, ExecutionEnvironment> environments,
  ) {
    final (key, _) = canonicalProjectPath(
      directory,
      environments[directory.environmentId],
      translator,
    );
    return key;
  }
}

class _Candidate {
  _Candidate({
    required this.session,
    required this.agentId,
    required this.agentName,
    required this.directory,
    required this.directoryKey,
  });

  final Session session;
  final String agentId;
  final String agentName;
  final EnvironmentPath directory;
  final String directoryKey;

  /// Agent and folder — everything the store can distinguish two sessions by.
  String get placeKey => '$agentId $directoryKey';
}
