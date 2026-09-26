import '../../workspaces/data/workspace_data.dart';
import '../../../core/database/sqlite_row_reader.dart';
import '../../agents/data/agent_installation_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/sessions/data/sessions_data.dart';

/// Writes the conversation id onto the session row that is on it, for an agent
/// whose store records the last conversation per directory
/// (`AgentDirectoryConversations`). Such a CLI takes no id and mints its own,
/// so without this the row is a phantom.
class DirectoryConversationAttributionService {
  DirectoryConversationAttributionService({
    required this.sessionDao,
    required this.installationDao,
    required this.workspace,
    required this.agents,
    required this.locateStores,
    this.readPaneTail,
    this.readRows = readSqliteRows,
    this.onAttributed,
  });

  final SessionsData sessionDao;
  final AgentInstallationDao installationDao;
  final WorkspaceData workspace;
  final AgentRegistry agents;

  /// Where each environment's CLI stores are, in a form this app can read.
  final Future<List<CliStore>> Function() locateStores;

  /// The bottom rows of one pane's screen, for the announcement the CLI prints
  /// on its way out. Absent simply drops the strongest of the two signals.
  final List<String> Function(String paneId, int lines)? readPaneTail;

  /// The app's SQLite binding, handed to the agent's store reader.
  final SqliteRowReader readRows;

  /// Called with each row that gained an id, so the workspace can redraw.
  final void Function(Session session, String conversationId)? onAttributed;

  /// sessionId → why nothing was learned. Diagnostics only: what a user sees
  /// comes from the resume planner, which re-reads the store when asked.
  final Map<String, String> _refusals = {};

  /// Rows given an id, over all sweeps.
  int attributions = 0;

  /// Whether a sweep would have anything to attribute.
  bool get wantsStoreSweep =>
      _adapters.any((adapter) => _waiting(adapter).isNotEmpty);

  String? reasonFor(String sessionId) => _refusals[sessionId];

  /// The agents this applies to: those whose adapter declares the capability.
  Iterable<AgentAdapter> get _adapters =>
      agents.adapters.where((a) => a.directoryConversations != null);

  /// Learns what it can and writes it. Returns how many rows gained an id.
  Future<int> attribute() async {
    final pending = [
      for (final adapter in _adapters)
        if (_waiting(adapter) case final waiting when waiting.isNotEmpty)
          (adapter, waiting),
    ];
    if (pending.isEmpty) return 0;

    final List<CliStore> stores;
    try {
      stores = await locateStores();
    } on Object {
      // A store we cannot locate is the same answer as one with nothing in it.
      return 0;
    }

    // The CLI's id is the key, one conversation one row. Grown as rows are
    // written, so two candidates cannot both take one conversation in a sweep.
    final held = sessionDao.heldExternalSessionIds();

    var learned = 0;
    for (final (adapter, waiting) in pending) {
      learned += await _attributeFor(adapter, waiting, stores, held);
    }
    return learned;
  }

  Future<int> _attributeFor(
    AgentAdapter adapter,
    List<_Candidate> waiting,
    List<CliStore> stores,
    Set<String> held,
  ) async {
    final conversations = adapter.directoryConversations!;
    final descriptor = adapter.descriptor;
    final homes = <String, String>{};
    for (final store in stores) {
      final home = store.homeFor(descriptor.id);
      if (home != null) homes[store.environmentId] = home;
    }
    if (homes.isEmpty) return 0;

    var learned = 0;
    for (final candidate in waiting) {
      final home = homes[candidate.directory.environmentId];
      if (home == null) continue;

      // The store records the directory, not the process, so two candidates in
      // one directory are a coin toss. A pane that stated its own id is not.
      if (candidate.sharesDirectory && candidate.paneOutput.isEmpty) {
        _refusals[candidate.session.id] =
            'More than one session with no ${descriptor.displayName} '
            'conversation id is running in ${candidate.directory.path}, and '
            'the store records one conversation for the directory rather than '
            'for a process, so there is no way to tell which of them it '
            'belongs to.';
        continue;
      }

      final attribution = await conversations.attribute(
        descriptor: descriptor,
        storeHome: home,
        workingDirectory: candidate.directory.path,
        launchedAt: candidate.session.createdAt,
        readRows: readRows,
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

  /// Every row of [adapter]'s agent still waiting for a conversation id, with
  /// what attribution needs to know about it.
  List<_Candidate> _waiting(AgentAdapter adapter) {
    final rows = <Session>[];
    for (final row in sessionDao.getUnattributed()) {
      final agentId = installationDao.getById(row.agentInstallationId)?.agentId;
      if (agentId != adapter.id) continue;
      rows.add(row);
    }
    if (rows.isEmpty) return const [];

    final lines = adapter.directoryConversations!.announcementLines;
    final perDirectory = <String, int>{};
    final candidates = <_Candidate>[];
    for (final row in rows) {
      // Decreasing certainty, as `sessionWorkingDirectoryOf` does: where the
      // process started, then its worktree, then the repository root.
      final directory =
          row.workingDirectory ??
          row.worktree ??
          workspace.repository(row.repositoryId)?.path;
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
              : read(paneId, lines).join('\n'),
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
