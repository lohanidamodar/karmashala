import 'package:agent_cli/descriptors.dart' show OwnRewindPoints, RewindMode;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionRewind;
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../agents/application/agent_providers.dart';
import '../data/sessions_client.dart';
import 'session_providers.dart';
import 'turn_fork_points.dart';

/// Why a rewind waits while the agent works.
const String kRewindWhileWorking =
    'The agent is working. Stop it first, then rewind.';

/// What a rewind goes back to: the person's message by its place among the
/// transcript's turns (rewound ones too), its words, and the checkpoint its
/// turn began at, or null when none was taken.
class TurnRewindTarget {
  const TurnRewindTarget({
    required this.turnIndex,
    required this.words,
    this.before,
  });

  final int turnIndex;
  final String words;
  final TurnForkTarget? before;

  bool get canRestoreCode => before != null;

  @override
  bool operator ==(Object other) =>
      other is TurnRewindTarget &&
      other.turnIndex == turnIndex &&
      other.words == words &&
      other.before == before;

  @override
  int get hashCode => Object.hash(turnIndex, words, before);
}

/// What a rewind would change, as the server's preview says it.
class RewindPreview {
  const RewindPreview({
    required this.turns,
    required this.files,
    required this.outside,
    required this.headMoved,
    required this.refusals,
    required this.note,
  });

  /// Reads the server's answer; a field out of shape reads as absent.
  factory RewindPreview.fromAnswer(Map<String, Object?> answer) {
    List<String> strings(Object? value) => [
      if (value is List)
        for (final item in value)
          if (item is String) item,
    ];
    final conversation = answer['conversation'];
    return RewindPreview(
      turns: answer['turns'] is int ? answer['turns'] as int : null,
      files: answer['files'] is int ? answer['files'] as int : 0,
      outside: strings(answer['outside']),
      headMoved: answer['headMoved'] == true,
      refusals: strings(answer['refusals']),
      note: conversation is Map && conversation['note'] is String
          ? conversation['note'] as String
          : '',
    );
  }

  /// The turns undone — the message's own and every live one after it.
  final int? turns;

  /// The files restoring the code would change.
  final int files;

  /// Files changed since then while no turn ran, which a restore discards.
  final List<String> outside;
  final bool headMoved;

  /// Why the files cannot be restored now, per repository.
  final List<String> refusals;

  /// What becomes of the agent's conversation.
  final String note;
}

/// One line of what [mode] changes: "3 turns will be undone · 5 files
/// restored".
String rewindSummary(RewindPreview preview, RewindMode mode) {
  final turns = preview.turns;
  final files = preview.files;
  return [
    if (mode.cutsConversation && turns != null)
      '$turns turn${turns == 1 ? '' : 's'} will be undone',
    if (mode.cutsConversation && turns == null) 'The conversation goes back',
    if (mode.restoresCode)
      files == 0
          ? 'no file changes'
          : '$files file${files == 1 ? '' : 's'} restored',
    if (!mode.cutsConversation) 'the conversation stays',
  ].join(' · ');
}

/// What a finished rewind did.
typedef RewindOutcome = ({int? turns, int files, String composerText});

/// **Rewind to here**: the server's `sessions.rewind`, asked first for a
/// preview and then to rewind.
class TurnRewinds {
  const TurnRewinds(this._client);

  final SessionsClient _client;

  SessionRewind _request(
    String sessionId,
    TurnRewindTarget target,
    RewindMode mode, {
    bool preview = false,
    bool confirm = false,
  }) => SessionRewind(
    sessionId: sessionId,
    turnIndex: target.turnIndex,
    words: target.words,
    mode: mode.name,
    checkpointTurn: mode.restoresCode ? target.before?.turn : null,
    checkpointId: mode.restoresCode ? target.before?.checkpointId : null,
    preview: preview,
    confirm: confirm,
  );

  /// What [mode] would change. Throws [StateError] in the server's words.
  Future<RewindPreview> preview(
    String sessionId,
    TurnRewindTarget target,
    RewindMode mode,
  ) async => RewindPreview.fromAnswer(
    await _client.rewind(_request(sessionId, target, mode, preview: true)),
  );

  /// Rewinds. A refusal — the agent working, files moved since the preview —
  /// throws [StateError] in the server's words, and nothing was changed.
  Future<RewindOutcome> rewind(
    String sessionId,
    TurnRewindTarget target,
    RewindMode mode, {
    bool confirm = false,
  }) async {
    final answer = await _client.rewind(
      _request(sessionId, target, mode, confirm: confirm),
    );
    return (
      turns: answer['turns'] is int ? answer['turns'] as int : null,
      files: answer['files'] is int ? answer['files'] as int : 0,
      composerText: answer['composerText'] is String
          ? answer['composerText'] as String
          : target.words,
    );
  }
}

final turnRewindsProvider = Provider<TurnRewinds>(
  (ref) => TurnRewinds(ref.watch(sessionsClientProvider)),
);

/// Whether [String] session can be rewound from its chat: the server offers
/// it, sessions may be started here, and its agent cuts its own conversation
/// (Claude Code, either form).
final sessionRewindableProvider = Provider.autoDispose.family<bool, String>((
  ref,
  sessionId,
) {
  final caps = ref.watch(capabilitiesProvider);
  if (!caps.rewindViaServer || !caps.mayStart) return false;
  final session = ref.read(sessionsDataProvider).getById(sessionId);
  if (session == null) return false;
  final agentId = ref
      .read(agentInstallationsDataProvider)
      .getById(session.agentInstallationId)
      ?.agentId;
  if (agentId == null) return false;
  final registry = ref.watch(agentRegistryProvider);
  final rewind = registry.adapterFor(registry.foldedIdOf(agentId))?.rewind;
  return rewind is OwnRewindPoints && rewind.conversation != null;
});
