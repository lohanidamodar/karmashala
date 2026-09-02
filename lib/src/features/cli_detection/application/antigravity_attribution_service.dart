import '../../agents/data/agent_installation_dao.dart';
import '../../agents/data/antigravity_session_resume.dart';
import '../../agents/domain/agent_descriptor.dart';
import '../../agents/domain/agent_registry.dart';
import '../../environments/domain/environment_path.dart';
import '../../repositories/data/repository_dao.dart';
import '../../sessions/data/session_dao.dart';
import '../../sessions/domain/session.dart';
import 'cli_detection_service.dart';

/// How many lines of a pane's scrollback to read looking for `agy`'s own resume
/// hint.
///
/// The hint is printed as the CLI exits — `Resume with -c (or command below):`
/// then `agy --conversation=<uuid>` — so it is at the very bottom of a pane
/// whose agent has left. Generous rather than exact: a shell prompt and a line
/// or two of shutdown noise follow it, and the pattern is specific enough that
/// a wider window cannot match anything else.
const int kAntigravityAnnouncementLines = 40;

/// Writes the Antigravity conversation id onto the session row that is on it.
///
/// **Why this exists at all.** Claude Code takes `--session-id` and is told its
/// id at launch; Codex's id is discovered by scanning its store for a rollout
/// written in the right directory at the right time. `agy` allows neither — it
/// mints its own id and every conversation file looks alike from outside — so an
/// app-launched Antigravity session had no CLI id at all. That is the phantom
/// the owner hit: a row nothing could resume ("no CLI session id found"), rename
/// from the store, or find again. See
/// the design note and §6.2.
///
/// The rules for *which* conversation belong to `AntigravitySessionAttributor`
/// (`features/agents/data/`), where the evidence for each of them is written
/// down. This service is only the part that has to know about session rows:
/// which of them are still waiting for an id, what directory each ran in, whose
/// pane to read, and which conversations are already spoken for.
///
/// ## Cost
///
/// A JSON file per store and one `stat` per candidate — not a store scan. It
/// runs on the status registry's store slot beside adoption, and only while
/// [wantsStoreSweep]: a workspace with no unattributed Antigravity session pays
/// nothing. There is deliberately **no attempt cap**, unlike adoption's: a pane
/// can sit at its prompt for an hour before the user types the first message,
/// and `agy` writes nothing until they do, so giving up after six sweeps would
/// abandon exactly the sessions this exists for.
class AntigravitySessionAttributionService {
  AntigravitySessionAttributionService({
    required this.sessionDao,
    required this.installationDao,
    required this.repositoryDao,
    required this.agents,
    required this.locateStores,
    this.readPaneTail,
    this.attributor = const AntigravitySessionAttributor(),
    this.onAttributed,
  });

  final SessionDao sessionDao;
  final AgentInstallationDao installationDao;
  final RepositoryDao repositoryDao;
  final AgentRegistry agents;

  /// Where each environment's CLI stores are, in a form this app can read.
  final Future<List<CliStore>> Function() locateStores;

  /// The bottom rows of one pane's screen, for the announcement `agy` prints on
  /// its way out. Absent simply drops the strongest of the two signals.
  final List<String> Function(String paneId, int lines)? readPaneTail;

  final AntigravitySessionAttributor attributor;

  /// Called with each row that gained an id, so the workspace can redraw.
  final void Function(Session session, String conversationId)? onAttributed;

  /// sessionId → why nothing was learned, in the attributor's own words.
  ///
  /// Diagnostics. The words a *user* sees come from `planAntigravityResume` at
  /// the moment they ask to resume, so they describe the store as it is then
  /// rather than as it was on some earlier sweep.
  final Map<String, String> _refusals = {};

  /// Rows given an id, over all sweeps.
  int attributions = 0;

  /// Whether a sweep would have anything to attribute.
  bool get wantsStoreSweep => _waiting().isNotEmpty;

  String? reasonFor(String sessionId) => _refusals[sessionId];

  /// Learns what it can and writes it. Returns how many rows gained an id.
  Future<int> attribute() async {
    final descriptor = _antigravityIn(agents);
    final waiting = _waiting();
    if (descriptor == null || waiting.isEmpty) return 0;

    final List<CliStore> stores;
    try {
      stores = await locateStores();
    } on Object {
      // A store we cannot locate is the same answer as one with nothing in it.
      return 0;
    }
    final homes = <String, String>{};
    for (final store in stores) {
      final home = store.homesByAgentId[descriptor.id];
      if (home != null) homes[store.environmentId] = home;
    }
    if (homes.isEmpty) return 0;

    // The app's existing idempotence rule, borrowed from
    // `SessionAdoptionService`: the CLI's id is the key, one conversation is
    // one row. Grown as rows are written, so two candidates cannot both be
    // given the same conversation inside one sweep.
    final held = <String>{
      for (final row in sessionDao.getAll())
        if ((row.externalSessionId ?? '').isNotEmpty) row.externalSessionId!,
    };

    var learned = 0;
    for (final candidate in waiting) {
      final home = homes[candidate.directory.environmentId];
      if (home == null) continue;

      // One entry, two candidates, and nothing to tell them apart: the store
      // records the *directory*, not the process. Attributing it to either
      // would be a coin toss whose losing side resumes the other session's
      // conversation, so both refuse — the announcement route is unaffected,
      // because a pane that stated its own id is not an inference.
      if (candidate.sharesDirectory && candidate.paneOutput.isEmpty) {
        _refusals[candidate.session.id] =
            'More than one session with no Antigravity conversation id is '
            'running in ${candidate.directory.path}, and the store records '
            'one conversation for the directory rather than for a process, so '
            'there is no way to tell which of them it belongs to.';
        continue;
      }

      final attribution = await attributor.attribute(
        descriptor: descriptor,
        storeHome: home,
        workingDirectory: candidate.directory.path,
        launchedAt: candidate.session.createdAt,
        paneOutput: candidate.paneOutput,
        conversationIdsHeldByOtherSessions: held,
      );
      final id = attribution.conversationId;
      if (id == null) {
        _refusals[candidate.session.id] = attribution.reason;
        continue;
      }
      sessionDao.updateExternalSessionId(candidate.session.id, id);
      held.add(id);
      _refusals.remove(candidate.session.id);
      attributions++;
      learned++;
      onAttributed?.call(candidate.session, id);
    }
    return learned;
  }

  /// Every row still waiting for a conversation id, with what attribution needs
  /// to know about it.
  List<_Candidate> _waiting() {
    final descriptor = _antigravityIn(agents);
    if (descriptor == null) return const [];
    final rows = <Session>[];
    for (final row in sessionDao.getAll()) {
      if (row.isArchived) continue;
      if ((row.externalSessionId ?? '').isNotEmpty) continue;
      final agentId = installationDao.getById(row.agentInstallationId)?.agentId;
      if (agentId != descriptor.id) continue;
      rows.add(row);
    }
    if (rows.isEmpty) return const [];

    final perDirectory = <String, int>{};
    final candidates = <_Candidate>[];
    for (final row in rows) {
      // The order of decreasing certainty `sessionWorkingDirectoryOf` uses:
      // where the process was started, then its worktree, then the repository
      // root — which is where a row written before schema v22 would have run.
      final directory =
          row.workingDirectory ??
          row.worktree ??
          repositoryDao.getById(row.repositoryId)?.path;
      if (directory == null || directory.path.isEmpty) continue;
      final key = '${directory.environmentId} ${directory.path}';
      perDirectory[key] = (perDirectory[key] ?? 0) + 1;
      final paneId = row.paneId;
      final read = readPaneTail;
      candidates.add(
        _Candidate(
          session: row,
          directory: directory,
          directoryKey: key,
          paneOutput: paneId == null || read == null
              ? ''
              : read(paneId, kAntigravityAnnouncementLines).join('\n'),
        ),
      );
    }
    for (final candidate in candidates) {
      candidate.sharesDirectory =
          (perDirectory[candidate.directoryKey] ?? 0) > 1;
    }
    return candidates;
  }
}

/// The registry's Antigravity descriptor, found by the fact that makes this
/// service applicable rather than by its id: it is the agent whose store this
/// reads. An agent added tomorrow with the same store layout is answered by the
/// same rule.
AgentDescriptor? _antigravityIn(AgentRegistry agents) {
  for (final descriptor in agents.descriptors) {
    if (descriptor.store?.format == AgentStoreFormat.antigravityStore) {
      return descriptor;
    }
  }
  return null;
}

class _Candidate {
  _Candidate({
    required this.session,
    required this.directory,
    required this.directoryKey,
    required this.paneOutput,
  });

  final Session session;
  final EnvironmentPath directory;
  final String directoryKey;
  final String paneOutput;
  bool sharesDirectory = false;
}
