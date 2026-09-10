import '../../../core/database/sqlite_row_reader.dart';
import '../../agents/data/agent_installation_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import '../../repositories/data/repository_dao.dart';
import '../../sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';

/// How many lines of a pane's scrollback to read looking for `agy`'s own resume
/// hint — printed as the CLI exits, so it sits at the bottom of a dead pane.
const int kAntigravityAnnouncementLines = 40;

/// Writes the Antigravity conversation id onto the session row that is on it.
/// `agy` takes no id and mints its own, so without this the row is a phantom.
class AntigravitySessionAttributionService {
  AntigravitySessionAttributionService({
    required this.sessionDao,
    required this.installationDao,
    required this.repositoryDao,
    required this.agents,
    required this.locateStores,
    this.readPaneTail,
    this.attributor = const AntigravitySessionAttributor(
      reader: AntigravityStoreReader(
        countSteps: false,
        readRows: readSqliteRows,
      ),
    ),
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

  /// sessionId → why nothing was learned. Diagnostics only: what a user sees
  /// comes from `planAntigravityResume`, which re-reads the store when asked.
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

    // The CLI's id is the key, one conversation one row. Grown as rows are
    // written, so two candidates cannot both take one conversation in a sweep.
    final held = sessionDao.heldExternalSessionIds();

    var learned = 0;
    for (final candidate in waiting) {
      final home = homes[candidate.directory.environmentId];
      if (home == null) continue;

      // The store records the directory, not the process, so two candidates in
      // one directory are a coin toss. A pane that stated its own id is not.
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
    for (final row in sessionDao.getUnattributed()) {
      final agentId = installationDao.getById(row.agentInstallationId)?.agentId;
      if (agentId != descriptor.id) continue;
      rows.add(row);
    }
    if (rows.isEmpty) return const [];

    final perDirectory = <String, int>{};
    final candidates = <_Candidate>[];
    for (final row in rows) {
      // Decreasing certainty, as `sessionWorkingDirectoryOf` does: where the
      // process started, then its worktree, then the repository root.
      final directory =
          row.workingDirectory ??
          row.worktree ??
          repositoryDao.getById(row.repositoryId)?.path;
      if (directory == null || directory.path.isEmpty) continue;
      final key = '${directory.environmentId}\u0000${directory.path}';
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

/// The registry's Antigravity descriptor, found by store format rather than by
/// id, so an agent with the same store layout is answered by the same rule.
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
