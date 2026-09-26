import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_session/session.dart';

import 'session_sync_rows.dart';
import 'store_paths.dart';

/// How long after a session row is written its agent's conversation may have
/// begun and still be that session's — the row is written before the spawn.
const Duration kLaunchedAttributionWindow = Duration(minutes: 2);

/// How far *before* the row a conversation may have begun and still be it —
/// only clock skew: ours and the agent's, a different kernel under WSL.
const Duration kLaunchedAttributionSkew = Duration(seconds: 5);

/// Writes the agent's conversation id onto a running session launched for an
/// agent that takes none (`sessionIdAssignment` unsupported) — and only when
/// the store's answer is unambiguous: one conversation of that agent, in that
/// directory, begun in the launch window, held by no other row.
class LaunchedAttribution {
  LaunchedAttribution({
    required this.rows,
    this.agents = AgentRegistry.builtIn,
    this.translator = const PathTranslator(),
    this.window = kLaunchedAttributionWindow,
    this.skew = kLaunchedAttributionSkew,
  });

  final SessionSyncRows rows;
  final AgentRegistry agents;
  final PathTranslator translator;
  final Duration window;
  final Duration skew;

  /// sessionId → why nothing was written, in words. Diagnostics only.
  final Map<String, String> _refusals = {};

  /// Rows given an id, over this attribution's life.
  int attributions = 0;

  /// Whether a store scan would have anything to attribute.
  bool get wantsStoreSweep => _waiting(rows.environments()).isNotEmpty;

  String? reasonFor(String sessionId) => _refusals[sessionId];

  /// Learns what it can from [detected] — one pass's scan — and writes it.
  /// Returns how many rows gained an id.
  int attribute(List<DetectedSession> detected) {
    final environments = rows.environments();
    final waiting = _waiting(environments);
    if (waiting.isEmpty) return 0;
    final held = rows.sessions.heldExternalSessionIds();

    // Grouped by agent and directory, because that pair is all the store
    // knows: a rollout records where it ran, never which process ran it.
    final byPlace = <String, List<_Candidate>>{};
    for (final candidate in waiting) {
      byPlace.putIfAbsent(candidate.placeKey, () => []).add(candidate);
    }

    var learned = 0;
    for (final group in byPlace.values) {
      if (group.length > 1) {
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
      final matches = [
        for (final session in detected)
          if (_matches(candidate, session, environments, held)) session,
      ];
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

  bool _matches(
    _Candidate candidate,
    DetectedSession session,
    Map<String, ExecutionEnvironment> environments,
    Set<String> held,
  ) {
    if (session.cli != candidate.agentId) return false;
    // A store that cannot say when a conversation began cannot answer this.
    final startedAt = session.startedAt?.toUtc();
    if (startedAt == null) return false;
    final from = candidate.session.createdAt.subtract(skew);
    final to = candidate.session.createdAt.add(window);
    if (startedAt.isBefore(from) || startedAt.isAfter(to)) return false;
    if (held.contains(session.sessionId)) return false;
    return _keyFor(session.cwd, environments) == candidate.directoryKey;
  }

  /// Every running row still waiting for a conversation id.
  List<_Candidate> _waiting(Map<String, ExecutionEnvironment> environments) {
    final candidates = <_Candidate>[];
    for (final row in rows.sessions.getUnattributed()) {
      // Only a running session: a stopped one would buy a store scan on every
      // pass for ever. A resume recovers its id instead.
      if (row.status != SessionStatus.running) continue;
      final agentId = rows.agentOf(row);
      final adapter = agentId == null ? null : agents.adapterFor(agentId);
      if (adapter == null) continue;
      final descriptor = adapter.descriptor;
      // A row for an agent we could have told its id is a fork or a failed
      // launch, not something to infer.
      if (descriptor.launch.sessionIdAssignment.isSupported) continue;
      // An agent whose store records the last conversation per directory has
      // better evidence: `DirectoryAttribution` reads it.
      if (adapter.directoryConversations != null) continue;
      final directory = rows.directoryOf(row);
      if (directory == null) continue;
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

  String _keyFor(
    EnvironmentPath directory,
    Map<String, ExecutionEnvironment> environments,
  ) => canonicalStoreKey(
    directory,
    environments[directory.environmentId],
    translator,
  );
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

  String get placeKey => '$agentId $directoryKey';
}
