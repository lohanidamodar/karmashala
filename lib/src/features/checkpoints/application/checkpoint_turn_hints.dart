import 'dart:convert';

import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../sessions/application/session_providers.dart';

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
  for (final entry in input.entries) {
    final value = entry.value;
    if (value is String &&
        value.isNotEmpty &&
        kToolPathKeys.contains(entry.key)) {
      hints.recordPath(session.id, value);
    }
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
