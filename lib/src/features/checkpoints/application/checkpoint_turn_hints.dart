import 'dart:convert';

import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../sessions/application/session_providers.dart';
import 'session_checkpoint_recorder.dart';

/// The longest prompt kept for a checkpoint label; the view shows one line.
const int kCheckpointPromptLimit = 500;

/// What hooks said about a session's current turn that its status cannot: the
/// prompt, and the paths its tools named. In memory: a turn is short-lived.
class CheckpointTurnHints {
  final Map<String, String> _prompts = {};
  final Map<String, Set<String>> _paths = {};

  void recordPrompt(String sessionId, String prompt) {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) return;
    _prompts[sessionId] = trimmed.length > kCheckpointPromptLimit
        ? trimmed.substring(0, kCheckpointPromptLimit)
        : trimmed;
  }

  /// The prompt recorded for [sessionId], removed so a later turn that no hook
  /// announced cannot inherit it.
  String? takePrompt(String sessionId) => _prompts.remove(sessionId);

  /// Returns whether [path] was new for this turn.
  bool recordPath(String sessionId, String path) =>
      (_paths[sessionId] ??= <String>{}).add(path);

  Set<String> pathsOf(String sessionId) => _paths[sessionId] ?? const {};

  void clearPaths(String sessionId) => _paths.remove(sessionId);
}

final checkpointTurnHintsProvider = Provider<CheckpointTurnHints>(
  (ref) => CheckpointTurnHints(),
);

/// The argument keys whose values are paths a tool read or wrote: Claude Code's
/// `file_path`/`notebook_path`, Codex's `workdir`, and the generic `path`/`cwd`.
const Set<String> kToolPathKeys = {
  'file_path',
  'notebook_path',
  'path',
  'workdir',
  'cwd',
};

/// Files one hook's prompt and tool paths under **our** session id. Never
/// throws; a payload that says nothing records nothing.
void recordCheckpointHints(
  ProviderContainer container, {
  required String agentId,
  required String agentSessionId,
  required String? event,
  required String body,
}) {
  if (agentId.isEmpty || agentSessionId.isEmpty) return;
  final spec = container.read(agentRegistryProvider).byId(agentId)?.hooks;
  if (spec == null) return;
  final session = container
      .read(sessionDaoProvider)
      .getByExternalSessionId(agentSessionId);
  if (session == null) return;
  final Object? payload;
  try {
    payload = jsonDecode(body);
  } on FormatException {
    return;
  }
  final hints = container.read(checkpointTurnHintsProvider);
  if (event == 'UserPromptSubmit' && spec.promptPath.isNotEmpty) {
    final prompt = _valueAt(spec.promptPath, payload);
    if (prompt is String) hints.recordPrompt(session.id, prompt);
  }
  if (spec.toolInputPath.isEmpty) return;
  final input = _valueAt(spec.toolInputPath, payload);
  if (input is! Map) return;
  var touched = false;
  for (final entry in input.entries) {
    final value = entry.value;
    if (value is String &&
        value.isNotEmpty &&
        kToolPathKeys.contains(entry.key)) {
      if (hints.recordPath(session.id, value)) touched = true;
    }
  }
  if (touched) {
    container
        .read(sessionCheckpointRecorderProvider.notifier)
        .noteTouched(session.id);
  }
}

Object? _valueAt(List<String> path, Object? payload) {
  var value = payload;
  for (final segment in path) {
    if (value is! Map) return null;
    value = value[segment];
  }
  return value;
}

/// The longest a tool's hook is held for its before-turn checkpoint: inside
/// the two seconds the installed hook scripts give `curl`.
const Duration kCheckpointHookHold = Duration(milliseconds: 1500);

/// Holds a `PreToolUse` callback until [agentSessionId]'s queued captures are
/// done, at most [kCheckpointHookHold], so a repository the tool is about to
/// change is checkpointed before it does. Anything else returns at once.
///
/// **Giving up is not the same as succeeding, and it used to look identical.**
/// The bound cannot be raised into a guarantee: it has to fit inside the two
/// seconds the hook script gives `curl`, and holding longer than `curl` will
/// wait does not hold the tool — `curl` dies and the agent runs anyway. So a
/// hold that expires is a released tool and an unverified undo point, and it
/// is reported to the recorder, which marks the checkpoints that follow.
Future<void> holdToolForCheckpoint(
  ProviderContainer container, {
  required String agentSessionId,
  required String? event,
}) async {
  if (event != 'PreToolUse' || agentSessionId.isEmpty) return;
  final session = container
      .read(sessionDaoProvider)
      .getByExternalSessionId(agentSessionId);
  if (session == null) return;
  final recorder = container.read(sessionCheckpointRecorderProvider.notifier);
  await recorder
      .settled(session.id)
      .timeout(
        kCheckpointHookHold,
        onTimeout: () => recorder.noteHoldExpired(session.id),
      );
}

/// [holdToolForCheckpoint] for a transport with no reply to hold — the spool,
/// or a hook the session host answered at once because no app was watching to
/// hold it for (it reaches the app later, in the host's snapshot): the tool a `PreToolUse` announces has already
/// run by the time it is read, so the turn's before-turn snapshots still to
/// come are marked unverified. Called after the status step, so a turn this
/// very hook starts has begun and does not clear the mark.
void noteToolUnheld(
  ProviderContainer container, {
  required String agentSessionId,
  required String? event,
}) {
  if (event != 'PreToolUse' || agentSessionId.isEmpty) return;
  final session = container
      .read(sessionDaoProvider)
      .getByExternalSessionId(agentSessionId);
  if (session == null) return;
  container
      .read(sessionCheckpointRecorderProvider.notifier)
      .noteToolUnheld(session.id);
}
