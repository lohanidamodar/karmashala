import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/lineage.dart' show HandoffSourceBrief;
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// **Starting sessions, asked of the server** (slice 5b): the one launch path
/// is the server's — it writes the row, builds the command line on its own
/// OS with its own tools and vault, and runs the agent as a terminal under
/// the session's own id. This client names what to start and attaches a pane.
/// A refusal is thrown as a [StateError] in the server's own words.
class SessionsClient {
  const SessionsClient(this._client);

  final DataClient _client;

  Future<R> _send<R>(SessionWorkRequest<R> request) async {
    try {
      return (await _client.send(request)).value;
    } on DataRefused catch (refusal) {
      throw StateError(refusal.message);
    }
  }

  Future<SessionStarted> start(SessionStartSpec spec) =>
      _send(SessionStart(spec));

  /// Continues [sessionId] (answered as it is when already running);
  /// [restart] ends the running agent first.
  Future<SessionStarted> resume(
    String sessionId, {
    bool restart = false,
    int columns = 120,
    int rows = 40,
  }) => _send(
    SessionResume(sessionId, restart: restart, columns: columns, rows: rows),
  );

  /// Ends the agent behind [sessionId]; false when nothing ran it.
  Future<bool> end(String sessionId) async {
    try {
      await _client.send(SessionEndRequest(sessionId));
      return true;
    } on DataRefused catch (refusal) {
      if (refusal.code == DataRefusalCode.notFound) return false;
      throw StateError(refusal.message);
    }
  }

  Future<HandoffSourceBrief> sourceBrief(String sessionId) =>
      _send(SessionSourceBrief(sessionId));

  Future<String> handoffPreview(SessionHandoffPreview request) =>
      _send(request);

  Future<SessionStarted> handoff(SessionHandoff request) => _send(request);

  Future<SessionStarted> fork(SessionFork request) => _send(request);

  /// Forks a session and puts its files back to a checkpoint, answered as
  /// `session_fork_from_checkpoint` answers: per repository, and, unless
  /// [SessionForkFromCheckpoint.preview], the new session's id.
  Future<Map<String, Object?>> forkFromCheckpoint(
    SessionForkFromCheckpoint request,
  ) => _send(request);

  Future<SessionStarted> switchAgent(SessionSwitchAgent request) =>
      _send(request);
}

final sessionsClientProvider = Provider<SessionsClient>(
  (ref) => SessionsClient(ref.watch(dataClientProvider)),
);
