import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_session/session.dart';

import 'session_open_files.dart' show transcriptFileName;
import 'session_sync_rows.dart';
import 'store_paths.dart';

/// How long after a session row is written its agent's conversation may have
/// begun and still be that session's — the row is written before the spawn.
const Duration kLaunchedAttributionWindow = Duration(minutes: 2);

/// How far *before* the row a conversation may have begun and still be it —
/// only clock skew: ours and the agent's, a different kernel under WSL.
const Duration kLaunchedAttributionSkew = Duration(seconds: 5);

/// Writes the agent's conversation id onto a running session launched for an
/// agent that takes none (`sessionIdAssignment` unsupported).
///
/// **Its own pane's word first.** A hook fired from the row's pane names the
/// conversation ([hookNamed]), and on WSL or Linux the row's process holds its
/// transcript open ([holding]). Either is checked against the store, whose
/// conversations exclude a subagent's thread — Codex holds those open and may
/// hook from them, but they belong to the parent. Two sessions started in one
/// folder together were never told apart without this (2026-10-25 and -26).
///
/// Without that evidence, only an unambiguous store answers: one conversation
/// of that agent, in that directory, begun in the launch window, held by no
/// other row, and only one row waiting there.
class LaunchedAttribution {
  LaunchedAttribution({
    required this.rows,
    this.agents = AgentRegistry.builtIn,
    this.translator = const PathTranslator(),
    this.window = kLaunchedAttributionWindow,
    this.skew = kLaunchedAttributionSkew,
    void Function(String message)? log,
  }) : _log = log;

  final SessionSyncRows rows;
  final AgentRegistry agents;
  final PathTranslator translator;
  final Duration window;
  final Duration skew;
  final void Function(String message)? _log;

  /// sessionId → why nothing was written, in words. Diagnostics only.
  final Map<String, String> _refusals = {};

  /// The refusal last written to the log per row, so a pass every ten seconds
  /// says it once rather than every time.
  final Map<String, String> _logged = {};

  /// sessionId → conversations its pane's hooks named.
  final Map<String, Set<String>> _named = {};

  /// sessionId → names of the transcripts its process holds open.
  final Map<String, Set<String>> _open = {};

  /// Rows given an id, over this attribution's life.
  int attributions = 0;

  /// Whether a store scan would have anything to attribute.
  bool get wantsStoreSweep => _waiting(rows.environments()).isNotEmpty;

  String? reasonFor(String sessionId) => _refusals[sessionId];

  /// A hook from [sessionId]'s own pane named [conversationId]. Kept until the
  /// next scan settles it; a subagent's id is kept too, and never matches.
  void hookNamed(String sessionId, String conversationId) {
    if (conversationId.isEmpty) return;
    final row = rows.sessions.getById(sessionId);
    if (row == null || (row.externalSessionId ?? '').isNotEmpty) return;
    (_named[sessionId] ??= {}).add(conversationId);
  }

  /// What [sessionId]'s process holds open now, as paths: replaces the last.
  void holding(String sessionId, Set<String> paths) {
    _open[sessionId] = {for (final path in paths) transcriptFileName(path)};
  }

  /// The waiting rows, by the environment their agent runs in: whose processes
  /// are worth looking inside.
  Map<String, Set<String>> waitingByEnvironment() {
    final byEnvironment = <String, Set<String>>{};
    for (final candidate in _waiting(rows.environments())) {
      byEnvironment
          .putIfAbsent(candidate.directory.environmentId, () => {})
          .add(candidate.session.id);
    }
    return byEnvironment;
  }

  /// Learns what it can from [detected] — one pass's scan — and writes it.
  /// Returns how many rows gained an id.
  int attribute(List<DetectedSession> detected) {
    final environments = rows.environments();
    final waiting = _waiting(environments);
    _forgetAllBut({for (final candidate in waiting) candidate.session.id});
    if (waiting.isEmpty) return 0;
    final held = rows.sessions.heldExternalSessionIds();
    var learned = 0;

    bool write(_Candidate candidate, String id) {
      if (rows.edit(candidate.session.id, SessionPatch.attribute(id)) == null) {
        return false;
      }
      held.add(id);
      for (final map in [_refusals, _logged, _named, _open]) {
        map.remove(candidate.session.id);
      }
      attributions++;
      learned++;
      return true;
    }

    // What a row's own pane said settles it, however many share its folder.
    final settled = <String>{};
    final unsettled = <_Candidate>[];
    for (final candidate in waiting) {
      final evidence = _evidenceFor(candidate, detected, held);
      if (evidence == null || evidence.isEmpty) {
        unsettled.add(candidate);
      } else if (evidence.length == 1) {
        if (write(candidate, evidence.single.sessionId)) {
          settled.add(candidate.session.id);
        }
      } else {
        _refusals[candidate.session.id] =
            'its own pane names ${evidence.length} ${candidate.agentName} '
            'conversations (${_list(evidence)}), and nothing says which is '
            'its own.';
      }
    }

    // Grouped by agent and directory, because that pair is all the store
    // knows: a rollout records where it ran, never which process ran it.
    final byPlace = <String, List<_Candidate>>{};
    for (final candidate in waiting) {
      if (settled.contains(candidate.session.id)) continue;
      byPlace.putIfAbsent(candidate.placeKey, () => []).add(candidate);
    }
    for (final candidate in unsettled) {
      final group = byPlace[candidate.placeKey]!;
      final nearby = [
        for (final session in detected)
          if (_matches(candidate, session, environments, held)) session,
      ];
      if (group.length > 1) {
        final others = [
          for (final other in group)
            if (other != candidate) other.session.id,
        ];
        _refusals[candidate.session.id] =
            '${group.length} sessions with no conversation id are running in '
            '${candidate.directory.path} (with ${others.join(', ')}), the '
            'store records a conversation for the directory rather than for '
            'a process, and nothing from its own pane has named one the store '
            'knows yet. Candidates: '
            '${nearby.isEmpty ? 'none' : _list(nearby)}.';
        continue;
      }
      if (nearby.length != 1) {
        _refusals[candidate.session.id] = nearby.isEmpty
            ? 'no ${candidate.agentName} conversation began in '
                  '${candidate.directory.path} when this session started.'
            : '${nearby.length} ${candidate.agentName} conversations began in '
                  '${candidate.directory.path} when this session started '
                  '(${_list(nearby)}), and the store cannot say which of them '
                  'this one is on.';
        continue;
      }
      write(candidate, nearby.single.sessionId);
    }

    for (final candidate in waiting) {
      final id = candidate.session.id;
      final reason = _refusals[id];
      if (reason == null || _logged[id] == reason) continue;
      _logged[id] = reason;
      _log?.call('session sync: $id is on no conversation yet: $reason');
    }
    return learned;
  }

  /// The conversations [candidate]'s own pane named or holds open that the
  /// store knows as its agent's and no other row holds; null when its pane
  /// has said nothing.
  List<DetectedSession>? _evidenceFor(
    _Candidate candidate,
    List<DetectedSession> detected,
    Set<String> held,
  ) {
    final named = _named[candidate.session.id] ?? const <String>{};
    final open = _open[candidate.session.id] ?? const <String>{};
    if (named.isEmpty && open.isEmpty) return null;
    return [
      for (final session in detected)
        if (session.cli == candidate.agentId &&
            !held.contains(session.sessionId) &&
            (named.contains(session.sessionId) ||
                open.contains(transcriptFileName(session.filePath))))
          session,
    ];
  }

  String _list(List<DetectedSession> sessions) => [
    for (final session in sessions)
      '${session.sessionId} begun '
          '${session.startedAt?.toIso8601String() ?? 'at an unknown time'}',
  ].join('; ');

  void _forgetAllBut(Set<String> waiting) {
    for (final map in [_named, _open, _refusals, _logged]) {
      map.removeWhere((id, _) => !waiting.contains(id));
    }
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
