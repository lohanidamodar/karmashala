import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionForkFromCheckpoint;
import 'package:riverpod/riverpod.dart';

import '../data/sessions_client.dart';
import 'session_launcher.dart';
import 'turn_fork_points.dart';

/// One repository's file half of a fork, as the server's preview says it.
typedef ForkedFiles = ({String repository, bool restores, String? reason});

/// What forking from a turn would do: the route the conversation takes, each
/// repository's files, and what the new session will remember.
class TurnForkPreview {
  const TurnForkPreview({
    required this.explanation,
    required this.repositories,
    required this.conversation,
  });

  /// Reads the server's preview answer; a field out of shape reads as absent.
  factory TurnForkPreview.fromAnswer(Map<String, Object?> answer) {
    final conversation = answer['conversation'];
    return TurnForkPreview(
      explanation: switch (answer['explanation']) {
        final String text => text,
        _ => '',
      },
      repositories: [
        if (answer['repositories'] case final List<Object?> list)
          for (final entry in list)
            if (entry case {'repository': final String path})
              (
                repository: path,
                restores: entry['wouldRestore'] == true,
                reason: switch (entry['reason']) {
                  final String why => why,
                  _ => null,
                },
              ),
      ],
      conversation: conversation is Map && conversation['note'] is String
          ? conversation['note'] as String
          : '',
    );
  }

  final String explanation;
  final List<ForkedFiles> repositories;
  final String conversation;
}

/// **Fork from a turn**: the server's `session_fork_from_checkpoint`, asked
/// first for a preview and then for the fork, and the new session shown.
class TurnForks {
  TurnForks(this._client, {required this.show});

  final SessionsClient _client;

  /// Brings the new session into view.
  final Future<void> Function(String sessionId) show;

  SessionForkFromCheckpoint _request(
    String sessionId,
    TurnForkTarget target, {
    bool preview = false,
    String instruction = '',
  }) => SessionForkFromCheckpoint(
    sessionId: sessionId,
    turn: target.turn,
    checkpointId: target.checkpointId,
    preview: preview,
    instruction: instruction,
  );

  /// What the fork would do. Throws [StateError] in the server's words.
  Future<TurnForkPreview> preview(
    String sessionId,
    TurnForkTarget target,
  ) async => TurnForkPreview.fromAnswer(
    await _client.forkFromCheckpoint(
      _request(sessionId, target, preview: true),
    ),
  );

  /// Forks, shows the new session and answers its id. A refusal — a tree
  /// that moved, a turn running — throws [StateError] in the server's words,
  /// and nothing was started.
  Future<String> fork(
    String sessionId,
    TurnForkTarget target, {
    String instruction = '',
  }) async {
    final answer = await _client.forkFromCheckpoint(
      _request(sessionId, target, instruction: instruction),
    );
    final started = answer['sessionId'];
    if (started is! String) {
      throw StateError('The server forked nothing: it named no new session.');
    }
    await show(started);
    return started;
  }
}

final turnForksProvider = Provider<TurnForks>(
  (ref) => TurnForks(
    ref.watch(sessionsClientProvider),
    show: (id) async {
      await ref.read(sessionLauncherProvider).resumeAtServer(id);
    },
  ),
);
