import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_session/session.dart';

import 'session_sync_rows.dart';
import 'store_session_scan.dart';

/// Writes the conversation id onto the session row that is on it, for an
/// agent whose store records the last conversation per directory
/// (`AgentDirectoryConversations`). Such an agent takes no id and mints its
/// own, so without this the row names no conversation at all.
///
/// Two signals, each through the agent's adapter: the resume line the agent
/// prints into its pane (the row's pane tail), and the store's record for
/// the directory.
class DirectoryAttribution {
  DirectoryAttribution({
    required this.rows,
    required this.locateStores,
    this.readTail,
    this.agents = AgentRegistry.builtIn,
    this.readRows = readStoreRows,
  });

  final SessionSyncRows rows;
  final AgentRegistry agents;

  /// Where each machine's agent stores are.
  final Future<List<CliStore>> Function() locateStores;

  /// The bottom [lines] rows of the screen row [session] runs on — the
  /// server's own screen for a hosted row, else the tail a client reported
  /// for the row's pane — or empty. Absent drops the stronger signal.
  final List<String> Function(Session session, int lines)? readTail;

  final SqliteRowReader readRows;

  /// sessionId → why nothing was learned. Diagnostics only.
  final Map<String, String> _refusals = {};

  /// Rows given an id, over this attribution's life.
  int attributions = 0;

  /// Whether a sweep would have anything to attribute.
  bool get wantsStoreSweep => _pending().isNotEmpty;

  String? reasonFor(String sessionId) => _refusals[sessionId];

  Iterable<AgentAdapter> get _adapters => agents.adapters.where(
    (adapter) => adapter.directoryConversations != null,
  );

  /// The rows waiting, with the pane each is on — what a client is asked for
  /// the tail of, when the server does not hold the screen.
  List<Session> waitingRows() => [
    for (final (_, waiting) in _pending())
      for (final candidate in waiting) candidate.session,
  ];

  /// How many rows of a tail the agents here read, at most.
  int get tailLines {
    var lines = 0;
    for (final adapter in _adapters) {
      final wanted = adapter.directoryConversations!.announcementLines;
      if (wanted > lines) lines = wanted;
    }
    return lines;
  }

  /// Learns what it can and writes it. Returns how many rows gained an id.
  Future<int> attribute() async {
    final pending = _pending();
    if (pending.isEmpty) return 0;
    final List<CliStore> stores;
    try {
      stores = await locateStores();
    } on Object {
      return 0;
    }
    // One conversation, one row: grown as rows are written, so two
    // candidates cannot both take one conversation in a sweep.
    final held = rows.sessions.heldExternalSessionIds();
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
    final homes = <String, String>{
      for (final store in stores)
        store.environmentId: ?store.homeFor(descriptor.id),
    };
    if (homes.isEmpty) return 0;

    var learned = 0;
    for (final candidate in waiting) {
      final home = homes[candidate.directory.environmentId];
      if (home == null) continue;
      final paneOutput = _paneOutput(candidate.session, conversations);
      // The store records the directory, not the process: two candidates in
      // one directory are a coin toss — unless the pane stated its own id.
      if (candidate.sharesDirectory && paneOutput.isEmpty) {
        _refusals[candidate.session.id] =
            'More than one session with no ${descriptor.displayName} '
            'conversation id is running in ${candidate.directory.path}, and '
            'the store records one conversation for the directory rather than '
            'for a process, so there is no way to tell which of them it '
            'belongs to.';
        continue;
      }
      final DirectoryConversationAttribution attribution;
      try {
        attribution = await conversations.attribute(
          descriptor: descriptor,
          storeHome: home,
          workingDirectory: candidate.directory.path,
          launchedAt: candidate.session.createdAt,
          readRows: readRows,
          paneOutput: paneOutput,
          conversationIdsHeldByOtherSessions: held,
        );
      } on Object catch (error) {
        _refusals[candidate.session.id] = 'the store could not be read: $error';
        continue;
      }
      final id = attribution.conversationId;
      if (id == null) {
        _refusals[candidate.session.id] = attribution.reason;
        continue;
      }
      if (rows.edit(candidate.session.id, SessionPatch.attribute(id)) == null) {
        continue;
      }
      held.add(id);
      _refusals.remove(candidate.session.id);
      attributions++;
      learned++;
    }
    return learned;
  }

  String _paneOutput(
    Session session,
    AgentDirectoryConversations conversations,
  ) {
    final read = readTail;
    if (read == null) return '';
    return read(session, conversations.announcementLines).join('\n');
  }

  List<(AgentAdapter, List<_Candidate>)> _pending() {
    final unattributed = rows.sessions.getUnattributed();
    if (unattributed.isEmpty) return const [];
    final pending = <(AgentAdapter, List<_Candidate>)>[];
    for (final adapter in _adapters) {
      final waiting = _waiting(adapter, unattributed);
      if (waiting.isNotEmpty) pending.add((adapter, waiting));
    }
    return pending;
  }

  List<_Candidate> _waiting(AgentAdapter adapter, List<Session> unattributed) {
    final perDirectory = <String, int>{};
    final candidates = <_Candidate>[];
    for (final row in unattributed) {
      if (rows.agentOf(row) != adapter.id) continue;
      final directory = rows.directoryOf(row);
      if (directory == null) continue;
      final key = '${directory.environmentId}\u0000${directory.path}';
      perDirectory[key] = (perDirectory[key] ?? 0) + 1;
      candidates.add(
        _Candidate(session: row, directory: directory, directoryKey: key),
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
  });

  final Session session;
  final EnvironmentPath directory;
  final String directoryKey;
  bool sharesDirectory = false;
}
