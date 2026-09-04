import '../../../core/process/path_translator.dart';
import '../../agents/data/agent_installation_dao.dart';
import '../../agents/domain/agent_descriptor.dart';
import '../../agents/domain/agent_registry.dart';
import '../../environments/data/execution_environment_dao.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../../repositories/data/repository_dao.dart';
import '../../sessions/data/session_dao.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/domain/session_status.dart';
import '../domain/detected_session.dart';
import 'detected_project_merger.dart';

/// How long after a session row is written its CLI's conversation may have
/// begun and still be that session's.
///
/// The row is written *before* the process is spawned, so the conversation
/// always starts later — the question is how much later. In the owner's own
/// rollout the gap was 4.7 seconds through a WSL shell; two minutes is room for
/// a cold distro and a slow disk without reaching back to a conversation from
/// earlier in the day. It is not the only guard — the directory must match and
/// the match must be unambiguous — but it is the one that keeps "unambiguous"
/// meaningful in a folder somebody works in all day.
const Duration kLaunchedAttributionWindow = Duration(minutes: 2);

/// How far *before* the row a conversation may have begun and still be it.
///
/// Only clock skew: the two timestamps come from different clocks — ours and
/// the CLI's, which under WSL is a different kernel — and a second or two of
/// disagreement should not lose a session its name.
const Duration kLaunchedAttributionSkew = Duration(seconds: 5);

/// Writes the CLI's conversation id onto a session **we launched** for an agent
/// that would not accept one.
///
/// ## The bug this is
///
/// > "i started new session with codex, and started conversation. sessions
/// > explorer has the updated session with conv title, but the tabbar is still
/// > showing new session and when trying to open notification from inbox it
/// > show the session as not active weird"
///
/// One session, three disagreements, one cause: the row's
/// `external_session_id` was null and stayed null. `SessionLauncher` says so
/// itself — "Agents that cannot be told (Codex) keep a null id until something
/// discovers it" — and nothing did. `SessionAdoptionService` has the store scan
/// that could, but it deliberately only ever looks at panes the app did *not*
/// launch (`AdoptablePane.hostsLaunchedSession`), because its job is to write a
/// row, not to complete one. `AntigravitySessionAttributionService` completes
/// rows, but is gated on `agy`'s store.
///
/// Everything downstream of that id then failed together, and each failure is
/// one of the owner's three:
///
/// * `SessionTitleSyncService` skips a row with no id — it matches the store on
///   `externalSessionId` — so the **tab strip** kept the launcher's
///   "New session" while Codex's own thread name sat in `session_index.jsonl`.
/// * `ImportedSessionDao` hides an imported record when a native row holds the
///   same conversation. With no id nothing was superseded, so the **Explorer**
///   drew the read-only import beside the live row — that is the card wearing
///   the conversation's title.
/// * `SessionLauncher.hostedLive` joins a conversation to a pane by that id, so
///   opening the **inbox** notification — which is filed against the imported
///   record, the only one of the two with a transcript to read — found no live
///   pane for it and said the session was not active.
///
/// ## The rule
///
/// A conversation in the store is this row's when it is the **only** answer:
/// same agent, same directory, begun inside the row's window, and not already
/// held by another row — with only one such row waiting in that directory.
/// Anything less is refused, in words, rather than guessed at, because the
/// losing side of a coin toss is a user's session pointing at somebody else's
/// conversation.
///
/// ## Cost
///
/// One store scan, shared with the title sync that runs immediately after it on
/// the same slot (`cliStoreSyncRunnerProvider`), and only while
/// [wantsStoreSweep] — a workspace whose sessions all know their conversation
/// pays nothing at all. Unlike adoption there is no attempt cap: a pane can sit
/// at its prompt for an hour before the user types, and Codex writes no rollout
/// until they do.
class LaunchedSessionAttributionService {
  LaunchedSessionAttributionService({
    required this.sessionDao,
    required this.installationDao,
    required this.repositoryDao,
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
  final RepositoryDao repositoryDao;
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
  /// *user* sees about a session with no id comes from the resume path, which
  /// describes the store as it is when they ask.
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
    // The app's existing idempotence rule, borrowed from
    // `SessionAdoptionService`: the CLI's id is the key, and one conversation is
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
        // rollout belongs to which process. Attributing either would be a coin
        // toss whose losing side resumes the other session's conversation.
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
            // this question at all, and a match on directory alone would take
            // whatever the folder was last used for.
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
      // Only a running session. A stopped one has no CLI writing a conversation
      // to find, and leaving it waiting would buy a store scan on every slot
      // for the rest of the app's run; `SessionActions` recovers an id for one
      // of those at the moment the user asks to resume it, which is when the
      // question is actually being asked.
      if (row.status != SessionStatus.running) continue;

      final descriptor = _descriptorFor(row);
      if (descriptor == null) continue;
      // The capability that makes this rule applicable, rather than the name of
      // an agent: an agent we *could* have told its id was told at launch, and
      // a row of its with none is a fork or a failed launch — not something to
      // infer from a directory.
      if (descriptor.launch.sessionIdAssignment.isSupported) continue;
      // Antigravity is excluded by ownership, not by capability.
      // `AntigravitySessionAttributionService` has strictly better evidence for
      // those rows — `agy` prints its own resume command into our pane — and
      // its own refusal rules for when it does not.
      if (descriptor.store?.format == AgentStoreFormat.antigravityStore) {
        continue;
      }

      // The order of decreasing certainty `sessionWorkingDirectoryOf` uses:
      // where the process was started, then its worktree, then the repository
      // root — which is where a row written before schema v22 would have run.
      final directory =
          row.workingDirectory ??
          row.worktree ??
          repositoryDao.getById(row.repositoryId)?.path;
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
