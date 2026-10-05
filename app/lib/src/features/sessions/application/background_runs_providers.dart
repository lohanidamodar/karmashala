import 'package:agent_cli/read.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_session/launch.dart';

import '../../../core/capabilities/capabilities.dart';
import '../data/server_transcripts.dart';
import 'session_activity_providers.dart' show hasReadableRecord;
import 'session_chat_source.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// One background run as the chat lists it: the run, when its call was
/// issued, and the subagent's own turns when it is an agent we can open.
@immutable
class SessionBackgroundRun {
  const SessionBackgroundRun({
    required this.run,
    required this.startedAt,
    this.subagent,
  });

  final BackgroundRun run;
  final DateTime? startedAt;
  final SubagentRef? subagent;

  /// How long it ran, or has run so far at [now]; null without a start.
  Duration? elapsedAt(DateTime now) {
    final start = startedAt;
    if (start == null) return null;
    final elapsed = (run.endedAt ?? now).difference(start);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  @override
  bool operator ==(Object other) =>
      other is SessionBackgroundRun &&
      other.run == run &&
      other.startedAt == startedAt &&
      other.subagent?.filePath == subagent?.filePath;

  @override
  int get hashCode => Object.hash(run, startedAt, subagent?.filePath);
}

/// The runs worth listing in [messages]: none while nothing runs, else the
/// running ones and those that finished while they ran — its siblings — but
/// not one that ended before any of them began.
List<SessionBackgroundRun> backgroundRunsIn(List<TranscriptMessage> messages) {
  final all = [
    for (final message in messages)
      if (message.background case final run?)
        SessionBackgroundRun(
          run: run,
          startedAt: message.at,
          subagent: message.subagent,
        ),
  ];
  return List.unmodifiable(
    listedBackgroundRuns(
      all,
      runOf: (entry) => entry.run,
      startOf: (entry) => entry.startedAt,
    ),
  );
}

/// **The background runs session [sessionId] is waiting on**, read from the
/// conversation's own transcript, whatever the turn is doing: a turn that
/// launched them ends long before they do.
final sessionBackgroundRunsProvider = Provider.autoDispose
    .family<List<SessionBackgroundRun>, String>((ref, sessionId) {
      ref.watchSessionKinds(const {SessionChangeKind.status});
      final row = ref.read(sessionsDataProvider).getById(sessionId);
      if (row == null || row.surface != SessionSurface.pane) return const [];
      if (!hasReadableRecord(ref, row)) return const [];
      var messages = ref
          .watch(sessionChatTranscriptProvider(sessionId))
          .asData
          ?.value;
      if (messages == null) return const [];
      // From a server, [messages] are the tail: a run started before it is in
      // the window's digest.
      final older = ref.read(capabilitiesProvider).chatViaServer
          ? ref
                .read(serverTranscriptsProvider)
                .windowFor(sessionId, messages)
                ?.olderPending
          : null;
      if (older != null && older.isNotEmpty) messages = [...older, ...messages];
      return backgroundRunsIn(messages);
    });

/// Whether each session's background runs are folded to their one-line
/// summary, as the person last left them; absent until they choose.
class BackgroundRunsFolded extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => const {};

  void set(String sessionId, {required bool folded}) =>
      state = {...state, sessionId: folded};
}

final backgroundRunsFoldedProvider =
    NotifierProvider<BackgroundRunsFolded, Map<String, bool>>(
      BackgroundRunsFolded.new,
    );
